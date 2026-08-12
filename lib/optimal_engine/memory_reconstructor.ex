defmodule OptimalEngine.MemoryReconstructor do
  @moduledoc """
  Reconstructs task context through bounded, adaptive traversal.

  The canonical stores remain the source of truth. This module builds a
  temporary Cue-Tag-Content projection, records the reasoning trace, and
  returns cited evidence. It never promotes evidence into facts.
  """

  alias OptimalEngine.MemoryCore.ID
  alias OptimalEngine.Retrieval.ContextAssembler
  alias OptimalEngine.Store

  @default_steps 4
  @default_tokens 8_000
  @stopwords ~w(a an and are as at be by for from how i in is it of on or that the this to was what when where which who why with)

  @type result :: %{
          run_id: String.t(),
          query: String.t(),
          workspace_id: String.t(),
          cues: [String.t()],
          evidence: [map()],
          citations: [map()],
          context: String.t(),
          confidence: float(),
          stop_reason: String.t(),
          steps: [map()]
        }

  @doc "Runs bounded reconstruction and persists an auditable trace."
  @spec reconstruct(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def reconstruct(query, opts \\ []) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:error, :empty_query}
    else
      workspace = Keyword.get(opts, :workspace_id, "default")
      step_budget = positive(Keyword.get(opts, :step_budget, @default_steps), @default_steps)
      token_budget = positive(Keyword.get(opts, :token_budget, @default_tokens), @default_tokens)
      limit = positive(Keyword.get(opts, :limit, 8), 8)

      nonce = System.unique_integer([:positive]) |> Integer.to_string()
      run_id = ID.content_id("reconstruction", [workspace, query, nonce])

      cues = extract_cues(query)

      :ok = insert_run(run_id, workspace, query, cues, step_budget, token_budget)

      {evidence, steps, stop_reason} =
        traverse(query, workspace, cues, step_budget, token_budget, limit)

      citations = Enum.map(evidence, &citation/1)
      context = render_context(evidence, token_budget)
      confidence = confidence(evidence)

      :ok = complete_run(run_id, evidence, citations, context, confidence, stop_reason)
      :ok = insert_steps(run_id, steps)

      {:ok,
       %{
         run_id: run_id,
         query: query,
         workspace_id: workspace,
         cues: cues,
         evidence: evidence,
         citations: citations,
         context: context,
         confidence: confidence,
         stop_reason: stop_reason,
         steps: steps
       }}
    end
  end

  @doc "Records whether a reconstruction helped and updates path priors."
  @spec feedback(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def feedback(run_id, outcome, opts \\ [])

  def feedback(run_id, outcome, opts) when outcome in ["success", "partial", "failure"] do
    score = Keyword.get(opts, :score, outcome_score(outcome)) |> clamp()
    actor_id = Keyword.get(opts, :actor_id, "user:roberto")
    notes = Keyword.get(opts, :notes)

    with {:ok, [[workspace, evidence_json]]} <-
           Store.raw_query(
             "SELECT workspace_id, evidence FROM memory_reconstruction_runs WHERE id = ?1",
             [run_id]
           ),
         {:ok, evidence} <- Jason.decode(evidence_json),
         :ok <- insert_outcome(run_id, workspace, outcome, score, notes, actor_id),
         :ok <- update_path_feedback(workspace, evidence, outcome) do
      {:ok, %{run_id: run_id, outcome: outcome, score: score, evidence_count: length(evidence)}}
    else
      {:ok, []} -> {:error, :run_not_found}
      error -> error
    end
  end

  def feedback(_run_id, _outcome, _opts), do: {:error, :invalid_outcome}

  @doc "Proposes repeated evidence groups for human-reviewed consolidation."
  @spec consolidate(keyword()) :: {:ok, [map()]} | {:error, term()}
  def consolidate(opts \\ []) do
    workspace = Keyword.get(opts, :workspace_id, "default")
    minimum = positive(Keyword.get(opts, :minimum_observations, 2), 2)

    sql = """
    SELECT object_type, object_id, success_weight, failure_weight, observations
    FROM memory_path_feedback
    WHERE workspace_id = ?1 AND observations >= ?2
    ORDER BY (success_weight - failure_weight) DESC, observations DESC
    LIMIT 50
    """

    with {:ok, rows} <- Store.raw_query(sql, [workspace, minimum]) do
      proposals =
        rows
        |> Enum.chunk_every(3)
        |> Enum.map(&build_proposal(workspace, &1))

      Enum.each(proposals, &insert_proposal/1)
      {:ok, proposals}
    end
  end

  @doc "Returns operational quality metrics for the reconstruction loop."
  @spec quality(keyword()) :: {:ok, map()} | {:error, term()}
  def quality(opts \\ []) do
    workspace = Keyword.get(opts, :workspace_id, "default")

    sql = """
    SELECT
      COUNT(DISTINCT r.id),
      COALESCE(AVG(r.confidence), 0),
      COALESCE(AVG(json_array_length(r.citations)), 0),
      COALESCE(AVG(CASE o.outcome WHEN 'success' THEN 1.0 WHEN 'partial' THEN 0.5 WHEN 'failure' THEN 0.0 END), 0),
      COUNT(o.id)
    FROM memory_reconstruction_runs r
    LEFT JOIN memory_reconstruction_outcomes o ON o.run_id = r.id
    WHERE r.workspace_id = ?1
    """

    case Store.raw_query(sql, [workspace]) do
      {:ok, [[runs, avg_confidence, avg_citations, outcome_score, outcomes]]} ->
        {:ok,
         %{
           workspace_id: workspace,
           runs: runs,
           average_confidence: avg_confidence,
           average_citations: avg_citations,
           feedback_count: outcomes,
           outcome_score: outcome_score
         }}

      error ->
        error
    end
  end

  @doc "Runs a repeatable reconstruction benchmark over representative questions."
  @spec benchmark([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def benchmark(questions, opts \\ []) when is_list(questions) do
    workspace = Keyword.get(opts, :workspace_id, "default")

    results =
      Enum.map(questions, fn question ->
        case reconstruct(question, workspace_id: workspace) do
          {:ok, result} ->
            %{
              question: question,
              run_id: result.run_id,
              evidence_count: length(result.evidence),
              citation_count: length(result.citations),
              confidence: result.confidence,
              stop_reason: result.stop_reason,
              passed: result.evidence != [] and result.citations != []
            }

          {:error, reason} ->
            %{question: question, passed: false, error: inspect(reason)}
        end
      end)

    passed = Enum.count(results, & &1.passed)

    {:ok,
     %{
       workspace_id: workspace,
       questions: length(questions),
       passed: passed,
       pass_rate: if(questions == [], do: 0.0, else: passed / length(questions)),
       results: results
     }}
  end

  defp traverse(query, workspace, cues, step_budget, token_budget, limit) do
    initial = [%{cue: query, depth: 0}]

    Enum.reduce_while(1..step_budget, {initial, [], [], 0}, fn step,
                                                               {frontier, seen, trace, tokens} ->
      case Enum.find(frontier, fn item -> item.cue not in seen end) do
        nil ->
          {:halt, {trace_evidence(trace), trace, "frontier_exhausted"}}

        current ->
          hits = search(current.cue, workspace, limit)

          evidence =
            hits |> Enum.map(&project(&1, current.cue, query, workspace)) |> rank(workspace)

          fresh = Enum.reject(evidence, fn item -> Enum.any?(trace, &contains_id?(&1, item.id)) end)
          selected = Enum.take(fresh, limit)
          step_tokens = selected |> Enum.map(& &1.content) |> Enum.join(" ") |> estimate_tokens()
          next_tokens = tokens + step_tokens
          accumulated = trace_evidence(trace) ++ selected
          next_cues = derive_cues(selected, cues ++ Enum.map(frontier, & &1.cue))
          next_frontier = frontier ++ Enum.map(next_cues, &%{cue: &1, depth: current.depth + 1})

          entry = %{
            step_number: step,
            action: if(step == 1, do: "cue_recall", else: "associative_traversal"),
            cue: current.cue,
            candidates: Enum.map(evidence, &Map.take(&1, [:id, :score, :tag])),
            selected_evidence: selected,
            accumulated_score: confidence(accumulated),
            token_count: step_tokens
          }

          next_trace = trace ++ [entry]

          cond do
            selected == [] ->
              {:cont, {next_frontier, seen ++ [current.cue], next_trace, next_tokens}}

            next_tokens >= token_budget ->
              {:halt, {accumulated, next_trace, "token_budget"}}

            sufficient?(accumulated, cues) ->
              {:halt, {accumulated, next_trace, "sufficient_evidence"}}

            true ->
              {:cont, {next_frontier, seen ++ [current.cue], next_trace, next_tokens}}
          end
      end
    end)
    |> normalize_traversal_result()
  end

  defp normalize_traversal_result({evidence, steps, reason}) when is_binary(reason),
    do: {dedupe(evidence), steps, reason}

  defp normalize_traversal_result({_frontier, _seen, steps, _tokens}),
    do: {dedupe(trace_evidence(steps)), steps, "step_budget"}

  defp search(cue, workspace, limit) do
    case ContextAssembler.fused_search(cue, workspace_id: workspace, limit: limit) do
      {:ok, []} ->
        cue
        |> extract_cues()
        |> Enum.take(4)
        |> Enum.flat_map(fn term ->
          case ContextAssembler.fused_search(term, workspace_id: workspace, limit: limit) do
            {:ok, hits} -> hits
            _ -> []
          end
        end)
        |> Enum.uniq_by(&Map.get(&1, :id))
        |> Enum.take(limit)

      {:ok, hits} ->
        hits

      _ ->
        []
    end
  end

  defp project(hit, cue, goal, workspace) do
    uri = Map.get(hit, :uri) || "optimal://context/#{Map.get(hit, :id)}"
    content = Map.get(hit, :l0_abstract) || Map.get(hit, :overview) || Map.get(hit, :title) || ""

    %{
      id: to_string(Map.get(hit, :id)),
      object_type: to_string(Map.get(hit, :type, "context")),
      cue: cue,
      tag: to_string(Map.get(hit, :node, "memory")),
      title: Map.get(hit, :title) || "Untitled",
      content: content,
      uri: uri,
      workspace_id: workspace,
      base_score: numeric(Map.get(hit, :score, 0.0)),
      trust_score: trust_score(hit),
      relevance_score: relevance_score(hit, goal),
      cue_relevance_score: relevance_score(hit, cue),
      score: numeric(Map.get(hit, :score, 0.0)),
      provenance: "canonical_search_projection"
    }
  end

  defp rank(evidence, workspace) do
    priors = feedback_priors(workspace, Enum.map(evidence, & &1.id))

    evidence
    |> Enum.map(fn item ->
      prior = Map.get(priors, {item.object_type, item.id}, 0.0)

      Map.put(
        item,
        :score,
        clamp(
          item.relevance_score * 0.55 + item.cue_relevance_score * 0.15 + item.base_score * 0.1 +
            item.trust_score * 0.1 + prior * 0.1
        )
      )
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp feedback_priors(_workspace, []), do: %{}

  defp feedback_priors(workspace, ids) do
    placeholders = Enum.map_join(ids, ",", fn _ -> "?" end)

    sql =
      "SELECT object_type, object_id, success_weight, failure_weight FROM memory_path_feedback WHERE workspace_id = ? AND object_id IN (#{placeholders})"

    case Store.raw_query(sql, [workspace | ids]) do
      {:ok, rows} ->
        Map.new(rows, fn [type, id, success, failure] ->
          {{type, id}, clamp(0.5 + (success - failure) / max(success + failure, 1.0) / 2)}
        end)

      _ ->
        %{}
    end
  end

  defp derive_cues(evidence, prior) do
    evidence
    |> Enum.flat_map(fn item -> extract_cues(item.title <> " " <> item.content) end)
    |> Enum.reject(&(&1 in prior))
    |> Enum.take(6)
  end

  defp extract_cues(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}-]+/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 3))
    |> Enum.uniq()
    |> Enum.take(12)
  end

  defp sufficient?(evidence, cues) do
    covered =
      cues
      |> Enum.count(fn cue ->
        Enum.any?(evidence, fn item ->
          String.contains?(String.downcase(item.title <> " " <> item.content), cue)
        end)
      end)

    length(evidence) >= 3 and covered >= min(2, length(cues)) and confidence(evidence) >= 0.35
  end

  defp render_context(evidence, token_budget) do
    evidence
    |> Enum.reduce_while({[], 0}, fn item, {parts, tokens} ->
      part = "## #{item.title}\n#{item.content}\nSource: #{item.uri}\n"
      part_tokens = estimate_tokens(part)

      if tokens + part_tokens > token_budget do
        {:halt, {parts, tokens}}
      else
        {:cont, {parts ++ [part], tokens + part_tokens}}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp confidence([]), do: 0.0

  defp confidence(items),
    do: items |> Enum.map(& &1.score) |> Enum.sum() |> Kernel./(length(items)) |> clamp()

  defp citation(item),
    do: Map.take(item, [:id, :object_type, :title, :uri, :score, :provenance])

  defp trace_evidence(trace), do: Enum.flat_map(trace, &Map.get(&1, :selected_evidence, []))
  defp contains_id?(step, id), do: Enum.any?(step.selected_evidence, &(&1.id == id))
  defp dedupe(items), do: Enum.uniq_by(items, &{&1.object_type, &1.id})

  defp insert_run(id, workspace, query, cues, steps, tokens) do
    Store.raw_execute(
      "INSERT INTO memory_reconstruction_runs (id, workspace_id, query, cues, step_budget, token_budget) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      [id, workspace, query, Jason.encode!(cues), steps, tokens]
    )
  end

  defp complete_run(id, evidence, citations, context, confidence, reason) do
    Store.raw_execute(
      "UPDATE memory_reconstruction_runs SET status = 'completed', stop_reason = ?2, evidence = ?3, citations = ?4, answer_context = ?5, confidence = ?6, completed_at = datetime('now') WHERE id = ?1",
      [id, reason, Jason.encode!(evidence), Jason.encode!(citations), context, confidence]
    )
  end

  defp insert_steps(run_id, steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      id = ID.content_id("reconstruction_step", [run_id, Integer.to_string(step.step_number)])

      case Store.raw_execute(
             "INSERT INTO memory_reconstruction_steps (id, run_id, step_number, action, cue, candidates, selected_evidence, accumulated_score, token_count) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
             [
               id,
               run_id,
               step.step_number,
               step.action,
               step.cue,
               Jason.encode!(step.candidates),
               Jason.encode!(step.selected_evidence),
               step.accumulated_score,
               step.token_count
             ]
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp insert_outcome(run_id, workspace, outcome, score, notes, actor) do
    nonce = System.unique_integer([:positive]) |> Integer.to_string()
    id = ID.content_id("reconstruction_outcome", [run_id, nonce])

    Store.raw_execute(
      "INSERT INTO memory_reconstruction_outcomes (id, run_id, workspace_id, outcome, score, notes, actor_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
      [id, run_id, workspace, outcome, score, notes, actor]
    )
  end

  defp update_path_feedback(workspace, evidence, outcome) do
    {success, failure} =
      if outcome == "failure", do: {0.0, 1.0}, else: {outcome_score(outcome), 0.0}

    Enum.reduce_while(evidence, :ok, fn item, :ok ->
      case Store.raw_execute(
             "INSERT INTO memory_path_feedback (workspace_id, object_type, object_id, success_weight, failure_weight, observations) VALUES (?1, ?2, ?3, ?4, ?5, 1) ON CONFLICT(workspace_id, object_type, object_id) DO UPDATE SET success_weight = success_weight + excluded.success_weight, failure_weight = failure_weight + excluded.failure_weight, observations = observations + 1, updated_at = datetime('now')",
             [workspace, item["object_type"], item["id"], success, failure]
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp build_proposal(workspace, rows) do
    links =
      Enum.map(rows, fn [type, id, _, _, _] -> %{"object_type" => type, "object_id" => id} end)

    observations = Enum.map(rows, &Enum.at(&1, 4)) |> Enum.sum()
    confidence = min(0.95, 0.5 + observations / 100)

    %{
      id: ID.content_id("consolidation", [workspace, Jason.encode!(links)]),
      workspace_id: workspace,
      proposal_type: "frequent_success_path",
      member_links: links,
      rationale: "Evidence objects repeatedly contributed to successful reconstructions.",
      confidence: confidence,
      status: "proposed",
      metadata: %{observations: observations}
    }
  end

  defp insert_proposal(proposal) do
    Store.raw_execute(
      "INSERT OR IGNORE INTO memory_consolidation_proposals (id, workspace_id, proposal_type, member_links, rationale, confidence, status, metadata) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
      [
        proposal.id,
        proposal.workspace_id,
        proposal.proposal_type,
        Jason.encode!(proposal.member_links),
        proposal.rationale,
        proposal.confidence,
        proposal.status,
        Jason.encode!(proposal.metadata)
      ]
    )
  end

  defp estimate_tokens(text), do: div(String.length(text), 4) + 1
  defp numeric(value) when is_float(value), do: value
  defp numeric(value) when is_integer(value), do: value / 1
  defp numeric(_), do: 0.0
  defp positive(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive(_, fallback), do: fallback
  defp outcome_score("success"), do: 1.0
  defp outcome_score("partial"), do: 0.5
  defp outcome_score("failure"), do: 0.0

  defp trust_score(hit) do
    case Map.get(hit, :trust_label) || Map.get(hit, :trust) do
      value when value in ["verified", "authoritative", "first_party"] -> 1.0
      value when value in ["untrusted", "quarantined", "rejected"] -> 0.1
      _ -> 0.6
    end
  end

  defp relevance_score(hit, cue) do
    terms = extract_cues(cue) |> MapSet.new()

    text =
      [Map.get(hit, :title), Map.get(hit, :l0_abstract), Map.get(hit, :overview)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> extract_cues()
      |> MapSet.new()

    if MapSet.size(terms) == 0 do
      0.0
    else
      MapSet.intersection(terms, text) |> MapSet.size() |> Kernel./(MapSet.size(terms))
    end
  end

  defp clamp(value), do: value |> max(0.0) |> min(1.0)
end
