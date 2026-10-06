defmodule OptimalEngine.MemoryCore.Reconstruction do
  @moduledoc """
  Governed reconstructive recall lifecycle.

  Reconstruction is a strategy behind `RetrievalCoordinator`, not a second
  answer surface. It expands only authorized associations, records exact paths,
  and persists a terminal run atomically with its trace.
  """

  alias OptimalEngine.MemoryCore.{AssociativeProjection, ID, RetrievalPackage, ScopeEnvelope, Store}

  @policy_version "governed-reconstruction-v2"
  @default_steps 4
  @default_tokens 8_000
  @cue_stopwords ~w[
    a an and are as at be by did do does for from had has have how i in is it its
    of on or that the this to was were what when where which who why with you your
  ]

  @doc "Adds bounded association paths to an authorized Retrieval Package."
  @spec enrich(RetrievalPackage.t(), keyword()) ::
          {:ok, RetrievalPackage.t(), map()} | {:error, term()}
  def enrich(%RetrievalPackage{} = package, opts \\ []) do
    scope = scope_from(package)
    step_budget = positive(Keyword.get(opts, :reconstruction_steps, @default_steps), @default_steps)

    token_budget =
      positive(Keyword.get(opts, :reconstruction_tokens, @default_tokens), @default_tokens)

    obligations = evidence_obligations(package)
    role_cues = role_cues(obligations)
    cues = obligations |> Enum.flat_map(&obligation_cues/1) |> Enum.uniq()
    required_roles = required_roles(obligations)

    with {:ok, associations} <- expand_or_rebuild(cues, scope, package, opts) do
      associations = annotate_roles(associations, role_cues)

      {selected, steps, paths, stop_reason} =
        traverse(associations, cues, required_roles, step_budget, token_budget)

      citations = citations(selected)
      context = render(selected, token_budget)
      confidence = confidence(selected)
      {associated_facts, associated_memories} = hydrate_selected(selected, package)

      reconstruction = %{
        policy_version: @policy_version,
        cues: cues,
        required_evidence_roles: required_roles,
        covered_evidence_roles: covered_roles(selected),
        missing_evidence_roles: missing_roles(selected, required_roles),
        paths: paths,
        citations: citations,
        context: context,
        confidence: confidence,
        stop_reason: stop_reason,
        step_budget: step_budget,
        token_budget: token_budget,
        steps: steps
      }

      facts = unique_by_id(package.facts ++ associated_facts)
      memories = unique_by_id(package.memory_objects ++ associated_memories)

      enriched = %{
        package
        | facts: facts,
          memory_objects: memories,
          filtered_summary:
            package.filtered_summary
            |> Map.put(:returned_facts, length(facts))
            |> Map.put(:returned_memory_objects, length(memories)),
          retrieval_plan:
            Map.merge(package.retrieval_plan, %{
              strategy: "reconstructive",
              reconstruction: Map.drop(reconstruction, [:steps])
            }),
          evidence_links:
            unique(package.evidence_links ++ Enum.flat_map(selected, & &1.evidence_links)),
          source_package_links:
            unique(
              package.source_package_links ++ Enum.flat_map(selected, & &1.source_package_links)
            )
      }

      {:ok, enriched, reconstruction}
    end
  end

  @doc "Persists a completed run and its exact trace after Context Package creation."
  @spec record(RetrievalPackage.t(), map(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def record(%RetrievalPackage{} = package, context_package, reconstruction, opts \\ []) do
    run_id = ID.random_id("reconstruction")

    run = %{
      id: run_id,
      tenant_id: package.tenant_id,
      workspace_id: package.workspace_id,
      actor_id: Map.get(package.scope, :actor_id),
      query: package.query,
      cues: reconstruction.cues,
      status: "completed",
      stop_reason: reconstruction.stop_reason,
      step_budget: reconstruction.step_budget,
      token_budget: reconstruction.token_budget,
      evidence: Enum.flat_map(reconstruction.paths, & &1.evidence_links),
      citations: reconstruction.citations,
      answer_context: reconstruction.context,
      confidence: reconstruction.confidence,
      metadata: %{
        policy_version: @policy_version,
        engine_version: OptimalEngine.Version.application_version(),
        associative_projection_version: AssociativeProjection.version(),
        authorization_envelope: context_package.authorization_envelope,
        request_id: Keyword.get(opts, :request_id)
      },
      completed_at: timestamp(),
      context_package_id: context_package.id,
      strategy: "reconstructive",
      time_mode: package.time_mode
    }

    case Store.record_reconstruction(run, reconstruction.steps, reconstruction.paths) do
      :ok -> {:ok, run_id}
      error -> error
    end
  end

  defp expand_or_rebuild(cues, scope, package, opts) do
    expansion_opts = [
      limit: Keyword.get(opts, :association_limit, 60),
      time_mode: package.time_mode,
      allowed_security_labels: Map.get(package.scope, :allowed_security_labels, []),
      allowed_partitions: Map.get(package.scope, :allowed_partitions, [])
    ]

    case AssociativeProjection.expand(cues, scope, expansion_opts) do
      {:ok, []} ->
        with {:ok, _} <- AssociativeProjection.rebuild(scope) do
          AssociativeProjection.expand(cues, scope, expansion_opts)
        end

      result ->
        result
    end
  end

  defp traverse(associations, cues, required_roles, step_budget, token_budget) do
    grouped = Enum.group_by(associations, & &1.cue)

    Enum.reduce_while(1..step_budget, {[], [], [], cues, 0}, fn step,
                                                                {selected, steps, paths, frontier,
                                                                 tokens} ->
      cue = Enum.at(frontier, step - 1) || Enum.at(cues, rem(step - 1, max(length(cues), 1)), "")
      candidates = Map.get(grouped, cue, [])
      chosen = candidates |> Enum.reject(&seen?(selected, &1)) |> Enum.take(8)
      step_tokens = chosen |> Enum.map(& &1.content) |> Enum.join(" ") |> estimate_tokens()
      accumulated = unique_by_id(selected ++ chosen)
      score = confidence(accumulated)
      covered_before = covered_roles(selected)
      covered_after = covered_roles(accumulated)

      trace = %{
        step_number: step,
        action: if(step == 1, do: "governed_cue_expansion", else: "governed_association_traversal"),
        cue: cue,
        candidates:
          Enum.map(candidates, &Map.take(&1, [:id, :relationship_type, :confidence, :precision])),
        selected_evidence: Enum.map(chosen, &evidence_ref/1),
        accumulated_score: score,
        token_count: step_tokens,
        covered_roles_before: covered_before,
        covered_roles_after: covered_after,
        missing_required_roles: missing_roles(accumulated, required_roles)
      }

      path = %{
        intent: intent(cues),
        cue: cue,
        evidence_roles: Enum.flat_map(chosen, & &1.evidence_roles) |> Enum.uniq(),
        association_ids: Enum.map(chosen, & &1.id),
        evidence_links: Enum.map(chosen, &evidence_ref/1),
        path_score: confidence(chosen)
      }

      next_frontier = frontier ++ derived_cues(chosen, frontier)
      next = {accumulated, steps ++ [trace], paths ++ [path], next_frontier, tokens + step_tokens}

      cond do
        tokens + step_tokens >= token_budget ->
          {:halt, append_reason(next, "token_budget")}

        sufficient?(accumulated, required_roles) ->
          {:halt, append_reason(next, "coverage_satisfied")}

        step == step_budget ->
          {:halt, append_reason(next, "step_budget")}

        true ->
          {:cont, next}
      end
    end)
    |> normalize_traversal()
  end

  defp normalize_traversal({selected, steps, paths, _frontier, _tokens, reason}),
    do: {selected, steps, Enum.reject(paths, &(&1.association_ids == [])), reason}

  defp normalize_traversal({selected, steps, paths, _frontier, _tokens}),
    do: {selected, steps, Enum.reject(paths, &(&1.association_ids == [])), "frontier_exhausted"}

  defp append_reason({selected, steps, paths, frontier, tokens}, reason),
    do: {selected, steps, paths, frontier, tokens, reason}

  defp scope_from(package) do
    ScopeEnvelope.resolve(%{
      actor_id: Map.get(package.scope, :actor_id),
      tenant_id: package.tenant_id,
      workspace_id: package.workspace_id,
      operation_class: "memory.reconstruct",
      permissions: Map.get(package.scope, :permissions, [])
    })
  end

  defp hydrate_selected(selected, package) do
    {facts, memories} =
      selected
      |> Enum.map(& &1.to)
      |> Enum.uniq()
      |> Enum.reduce({[], []}, fn
        %{type: "fact", id: id}, {facts, memories} ->
          case Store.get_fact(package.workspace_id, id, tenant_id: package.tenant_id) do
            {:ok, fact} -> {[fact_candidate(fact) | facts], memories}
            _ -> {facts, memories}
          end

        %{type: "memory_object", id: id}, {facts, memories} ->
          case Store.get_memory_object(package.workspace_id, id, tenant_id: package.tenant_id) do
            {:ok, memory} -> {facts, [memory_candidate(memory) | memories]}
            _ -> {facts, memories}
          end

        _, acc ->
          acc
      end)

    # The accumulator prepends for linear construction, so restore traversal
    # rank before section assembly. Token clipping must retain the strongest
    # authorized evidence first, not the last graph neighbor visited.
    {Enum.reverse(facts), Enum.reverse(memories)}
  end

  defp fact_candidate(fact) do
    %{
      id: fact.id,
      type: "fact",
      text: fact.fact_text,
      confidence: fact.aggregate_confidence,
      precision: fact.aggregate_precision,
      source_package_links: fact.supporting_evidence_links,
      evidence_links: fact.supporting_evidence_links,
      security_labels: fact.security_labels,
      partition_ids: fact.partition_ids
    }
  end

  defp memory_candidate(memory) do
    %{
      id: memory.id,
      type: "memory_object",
      text: memory.summary,
      confidence: memory.aggregate_confidence,
      precision: memory.aggregate_precision,
      fact_links: memory.fact_links,
      source_package_links: memory.source_package_links,
      evidence_links: memory.evidence_links,
      security_labels: memory.security_labels,
      partition_ids: memory.partition_ids
    }
  end

  defp citations(associations) do
    associations
    |> Enum.flat_map(fn association ->
      association.source_package_links ++ association.evidence_links
    end)
    |> unique()
  end

  defp render(associations, budget) do
    associations
    |> Enum.reduce_while({[], 0}, fn association, {parts, tokens} ->
      part = "- [#{association.relationship_type}] #{association.content}\n"
      cost = estimate_tokens(part)

      if tokens + cost > budget,
        do: {:halt, {parts, tokens}},
        else: {:cont, {parts ++ [part], tokens + cost}}
    end)
    |> elem(0)
    |> Enum.join()
  end

  defp derived_cues(associations, seen) do
    associations
    |> Enum.flat_map(&cues(&1.content))
    |> Enum.reject(&(&1 in seen))
    |> Enum.take(8)
  end

  defp cues(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}-]+/u, " ")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 3 or &1 in @cue_stopwords))
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.sort_by(fn {cue, index} -> {-String.length(cue), index} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(16)
  end

  defp sufficient?(selected, required_roles) do
    required_roles != [] and missing_roles(selected, required_roles) == [] and
      confidence(selected) >= 0.65
  end

  defp evidence_obligations(package) do
    case Map.get(package.retrieval_plan, :evidence_obligations) do
      obligations when is_list(obligations) and obligations != [] -> obligations
      _ -> [%{role: "primary", probe: package.query, required: true}]
    end
  end

  defp role_cues(obligations) do
    Enum.reduce(obligations, %{}, fn obligation, acc ->
      role = Map.get(obligation, :role) || Map.get(obligation, "role")
      probe = Map.get(obligation, :probe) || Map.get(obligation, "probe") || ""

      Enum.reduce(cues(probe), acc, fn cue, role_acc ->
        Map.update(role_acc, cue, [role], &Enum.uniq([role | &1]))
      end)
    end)
  end

  defp obligation_cues(obligation) do
    obligation
    |> then(&(Map.get(&1, :probe) || Map.get(&1, "probe") || ""))
    |> cues()
  end

  defp required_roles(obligations) do
    obligations
    |> Enum.filter(&(Map.get(&1, :required) || Map.get(&1, "required")))
    |> Enum.map(&(Map.get(&1, :role) || Map.get(&1, "role")))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp annotate_roles(associations, role_cues) do
    Enum.map(associations, fn association ->
      Map.put(association, :evidence_roles, Map.get(role_cues, association.cue, []))
    end)
  end

  defp covered_roles(selected) do
    selected |> Enum.flat_map(& &1.evidence_roles) |> Enum.uniq()
  end

  defp missing_roles(selected, required_roles),
    do: required_roles -- covered_roles(selected)

  defp confidence([]), do: 0.0

  defp confidence(items),
    do: Enum.sum(Enum.map(items, &((&1.confidence + &1.precision) / 2))) / length(items)

  defp evidence_ref(a),
    do: %{
      association_id: a.id,
      object_type: a.to.type,
      object_id: a.to.id,
      relationship_type: a.relationship_type
    }

  defp seen?(selected, candidate), do: Enum.any?(selected, &(&1.id == candidate.id))
  defp unique(items), do: Enum.uniq_by(items, &inspect/1)
  defp unique_by_id(items), do: Enum.uniq_by(items, & &1.id)
  defp estimate_tokens(text), do: div(String.length(text), 4) + 1
  defp positive(value, _) when is_integer(value) and value > 0, do: value
  defp positive(_, fallback), do: fallback
  defp intent(cues), do: Enum.take(cues, 4) |> Enum.join("+")
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
