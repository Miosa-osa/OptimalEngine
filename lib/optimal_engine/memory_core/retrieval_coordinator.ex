defmodule OptimalEngine.MemoryCore.RetrievalCoordinator do
  @moduledoc """
  Governed recall for Memory Core.

  The gate pipeline runs `query -> Scope Envelope -> authorization envelope ->
  retrieval plan -> Retrieval Package -> Context Package`:

    * `retrieve_package/2` reads accepted Facts and current Memory Objects in a
      tenant + workspace scope with partition/security predicates applied
      inside the candidate SQL (authorization happens during candidate
      expansion, not as a post-filter), and returns the inspectable
      `OptimalEngine.MemoryCore.RetrievalPackage` intermediate. The
      authorization envelope fails closed: an empty/absent envelope excludes
      every security-labeled or partitioned object.
    * `build_context_package/2` projects a Retrieval Package into a persisted
      `OptimalEngine.MemoryCore.ContextPackage` with assembled sections and a
      derivation ledger entry.
    * `retrieve/2` composes both stages and returns the Context Package.

  No function here returns bare ranked chunks.
  """

  alias OptimalEngine.MemoryCore.{
    ContextPackage,
    DerivationLedgerEntry,
    ID,
    RetrievalPackage,
    ScopeEnvelope,
    Store
  }

  alias OptimalEngine.Store, as: BaseStore

  @default_limit 10
  @default_token_budget 2_000
  @max_redacted_links 25
  @policy_version "governed_recall_v1"

  @doc """
  Retrieve governed context for `query`.

  Returns `{:ok, %ContextPackage{}}` — the persisted Context Package with
  hydrated `:facts`/`:memory_objects` and assembled `:sections` — never raw
  search hits.

  The second argument is either a `%ScopeEnvelope{}` or a keyword list:

    * `:scope` — `%ScopeEnvelope{}`; wins over individual scope opts
    * `:workspace_id` / `:tenant_id` / `:actor_id` (or `:requesting_actor_id`)
    * `:allowed_partitions` / `:allowed_security_labels` — authorization
      envelope; fails closed: an empty/absent list only admits objects that
      carry no partition ids / no security labels at all. Callers must present
      an explicit envelope to read partitioned or labeled objects.
    * `:limit` (default #{@default_limit}), `:time_mode` (default
      `"current_valid"`), `:detail_depth`, `:request_id`,
      `:active_memory_pool_id`, `:token_budget` (default
      #{@default_token_budget} tokens for section assembly)
  """
  @spec retrieve(String.t(), keyword() | ScopeEnvelope.t()) ::
          {:ok, ContextPackage.t()} | {:error, term()}
  def retrieve(query, opts \\ [])

  def retrieve(query, %ScopeEnvelope{} = scope), do: retrieve(query, scope: scope)

  def retrieve(query, opts) when is_binary(query) and is_list(opts) do
    with {:ok, retrieval_package} <- retrieve_package(query, opts) do
      build_context_package(retrieval_package, opts)
    end
  end

  @doc """
  Run the retrieval stage only.

  Returns `{:ok, %RetrievalPackage{}}` — the inspectable intermediate with
  authorized candidates, plan, freshness, and filtered-object accounting. Not
  persisted; not a Context Package. Accepts the same options as `retrieve/2`.
  """
  @spec retrieve_package(String.t(), keyword() | ScopeEnvelope.t()) ::
          {:ok, RetrievalPackage.t()} | {:error, term()}
  def retrieve_package(query, opts \\ [])

  def retrieve_package(query, %ScopeEnvelope{} = scope),
    do: retrieve_package(query, scope: scope)

  def retrieve_package(query, opts) when is_binary(query) and is_list(opts) do
    scope = resolve_scope(opts)
    limit = Keyword.get(opts, :limit, @default_limit)
    time_mode = string_opt(opts, :time_mode, "current_valid")
    request_intent = string_opt(opts, :request_intent, classify_intent(query))

    authorization = %{
      allowed_partitions: string_list_opt(opts, :allowed_partitions),
      allowed_security_labels: string_list_opt(opts, :allowed_security_labels)
    }

    with {:ok, facts, fact_accounting} <-
           fetch_candidates(:facts, scope, query, limit, authorization),
         {:ok, memories, memory_accounting} <-
           fetch_candidates(:memory_objects, scope, query, limit, authorization) do
      now = timestamp()
      objects = facts ++ memories
      redacted_links = fact_accounting.redacted_links ++ memory_accounting.redacted_links
      policy_excluded = fact_accounting.policy_excluded + memory_accounting.policy_excluded

      {:ok,
       %RetrievalPackage{
         id: ID.random_id("rpkg"),
         tenant_id: scope.tenant_id,
         workspace_id: scope.workspace_id,
         query: query,
         request_intent: request_intent,
         time_mode: time_mode,
         limit: limit,
         scope: %{
           actor_id: scope.actor,
           tenant_id: scope.tenant_id,
           workspace_id: scope.workspace_id,
           operation_class: scope.operation_class,
           permissions: scope.permissions,
           allowed_partitions: authorization.allowed_partitions,
           allowed_security_labels: authorization.allowed_security_labels,
           unresolved: scope.unresolved
         },
         retrieval_plan: %{
           query: query,
           path: "memory_core_fact_memory_lookup",
           intent: request_intent,
           filters: %{
             tenant_id: scope.tenant_id,
             workspace_id: scope.workspace_id,
             lifecycle: ["facts.accepted", "memory_objects.current"],
             time_mode: time_mode,
             authorization: %{
               allowed_partitions: authorization.allowed_partitions,
               allowed_security_labels: authorization.allowed_security_labels,
               applied: "during_candidate_expansion",
               empty_envelope_behavior: "fail_closed"
             }
           },
           limit: limit
         },
         facts: facts,
         memory_objects: memories,
         source_package_links: collect_unique_links(objects, :source_package_links),
         evidence_links: collect_unique_links(objects, :evidence_links),
         redacted_object_links: redacted_links,
         filtered_summary: %{
           candidate_facts: fact_accounting.candidates,
           returned_facts: fact_accounting.returned,
           candidate_memory_objects: memory_accounting.candidates,
           returned_memory_objects: memory_accounting.returned,
           redacted_or_filtered_objects: policy_excluded,
           reason_classes: reason_class_counts(redacted_links)
         },
         confidence_summary: summarize_score(objects, :confidence),
         precision_summary: summarize_score(objects, :precision),
         freshness: %{
           time_mode: time_mode,
           retrieved_at: now,
           refresh_state: "fresh",
           staleness_filter: "stale_superseded_and_expired_excluded"
         },
         retrieved_at: now
       }}
    end
  end

  @doc """
  Project a Retrieval Package into a Context Package.

  Returns `{:ok, %ContextPackage{}}`. Assembles token-budget-aware sections,
  persists the `context_packages` row, and records a
  `memory_core.assemble_context_package` derivation ledger entry (source,
  processor, actor, policy).
  """
  @spec build_context_package(RetrievalPackage.t(), keyword()) ::
          {:ok, ContextPackage.t()} | {:error, term()}
  def build_context_package(%RetrievalPackage{} = retrieval_package, opts \\ []) do
    now = timestamp()
    objects = retrieval_package.facts ++ retrieval_package.memory_objects
    fact_links = Enum.map(retrieval_package.facts, &ref("fact", &1.id))
    memory_links = Enum.map(retrieval_package.memory_objects, &ref("memory_object", &1.id))

    sections =
      assemble_sections(
        retrieval_package,
        Keyword.get(opts, :token_budget, @default_token_budget)
      )

    package =
      ContextPackage.new(%{
        id:
          ID.content_id("ctxpkg", [
            retrieval_package.tenant_id,
            ":",
            retrieval_package.workspace_id,
            ":",
            retrieval_package.query,
            ":",
            now
          ]),
        tenant_id: retrieval_package.tenant_id,
        workspace_id: retrieval_package.workspace_id,
        request_id: string_or_nil(Keyword.get(opts, :request_id)),
        request_intent: retrieval_package.request_intent,
        requesting_actor_id: Map.get(retrieval_package.scope, :actor_id),
        active_memory_pool_id: string_or_nil(Keyword.get(opts, :active_memory_pool_id)),
        time_mode: retrieval_package.time_mode,
        detail_depth: Keyword.get(opts, :detail_depth, 1),
        memory_links: memory_links,
        fact_links: fact_links,
        workflow_links: [],
        skill_package_links: [],
        source_package_links: retrieval_package.source_package_links,
        evidence_links: retrieval_package.evidence_links,
        retrieval_plan: retrieval_package.retrieval_plan,
        package_confidence_summary: retrieval_package.confidence_summary,
        package_precision_summary: retrieval_package.precision_summary,
        filtered_object_summary: retrieval_package.filtered_summary,
        returned_object_links: fact_links ++ memory_links,
        redacted_object_links: retrieval_package.redacted_object_links,
        authorization_envelope: %{
          actor_id: Map.get(retrieval_package.scope, :actor_id),
          permissions: Map.get(retrieval_package.scope, :permissions, []),
          allowed_partitions: Map.get(retrieval_package.scope, :allowed_partitions, []),
          allowed_security_labels: Map.get(retrieval_package.scope, :allowed_security_labels, []),
          applied_during_candidate_expansion: true,
          applied_before_package_assembly: true
        },
        lifecycle_state: "assembled",
        refresh_state: "fresh",
        refresh_time: now,
        transaction_time_start: now,
        security_labels: merge_lists(objects, :security_labels),
        partition_ids: merge_lists(objects, :partition_ids),
        policy_version: @policy_version,
        metadata: %{
          query: retrieval_package.query,
          answer_surface: "context_package",
          retrieval_package_id: retrieval_package.id,
          sections: sections
        },
        facts: retrieval_package.facts,
        memory_objects: retrieval_package.memory_objects,
        sections: sections
      })

    with :ok <- Store.insert_context_package(package),
         :ok <- record_assembly(retrieval_package, package, opts) do
      {:ok, package}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: scope resolution
  # ---------------------------------------------------------------------------

  defp resolve_scope(opts) do
    case Keyword.get(opts, :scope) do
      %ScopeEnvelope{} = scope ->
        scope

      _ ->
        opts
        |> normalize_actor_opt()
        |> Keyword.put_new(:operation_class, "recall.retrieve")
        |> ScopeEnvelope.resolve()
    end
  end

  defp normalize_actor_opt(opts) do
    case Keyword.get(opts, :requesting_actor_id) do
      nil -> opts
      actor -> Keyword.put_new(opts, :actor_id, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # Private: candidate expansion (authorization inside the SQL)
  # ---------------------------------------------------------------------------

  defp fetch_candidates(kind, %ScopeEnvelope{} = scope, query, limit, authorization) do
    parts = sql_parts(kind)
    pattern = "%#{query}%"
    base_params = [scope.tenant_id, scope.workspace_id, pattern, query]
    where = base_where(parts)

    {auth_clauses, auth_params} = authorization_clauses(parts.table, authorization, 4)
    limit_placeholder = "?#{5 + length(auth_params)}"

    authorized_sql = """
    #{parts.select}
    FROM #{parts.table}
    #{where}#{and_all(auth_clauses)}
    #{parts.order}
    LIMIT #{limit_placeholder}
    """

    authorized_count_sql = """
    SELECT COUNT(*) FROM #{parts.table}
    #{where}#{and_all(auth_clauses)}
    """

    with {:ok, rows} <-
           BaseStore.raw_query(authorized_sql, base_params ++ auth_params ++ [limit]),
         {:ok, [[authorized_count]]} <-
           BaseStore.raw_query(authorized_count_sql, base_params ++ auth_params),
         {:ok, redacted_links, excluded_count} <-
           fetch_excluded(parts, where, auth_clauses, base_params, auth_params, authorization) do
      objects = Enum.map(rows, &object_from_row(kind, &1))

      {:ok, objects,
       %{
         candidates: authorized_count + excluded_count,
         returned: length(objects),
         policy_excluded: excluded_count,
         redacted_links: redacted_links
       }}
    end
  end

  # The authorization envelope always yields both predicates (fail-closed),
  # so the excluded-object accounting runs on every retrieval.
  defp fetch_excluded(parts, where, auth_clauses, base_params, auth_params, authorization) do
    excluded_where = "#{where}  AND NOT (#{Enum.join(auth_clauses, " AND ")})\n"

    excluded_sql = """
    SELECT id, security_labels, partition_ids FROM #{parts.table}
    #{excluded_where}
    LIMIT #{@max_redacted_links}
    """

    excluded_count_sql = """
    SELECT COUNT(*) FROM #{parts.table}
    #{excluded_where}
    """

    with {:ok, rows} <- BaseStore.raw_query(excluded_sql, base_params ++ auth_params),
         {:ok, [[count]]} <-
           BaseStore.raw_query(excluded_count_sql, base_params ++ auth_params) do
      {:ok, Enum.map(rows, &redacted_ref(parts.object_type, &1, authorization)), count}
    end
  end

  # Tenant + workspace predicates together form the scope key: rows from
  # another tenant that share a workspace id (e.g. the literal "default")
  # never enter the candidate set.
  defp base_where(parts) do
    """
    WHERE tenant_id = ?1
      AND workspace_id = ?2
    #{parts.lifecycle_filter}  AND (valid_time_end IS NULL OR datetime(valid_time_end) >= datetime('now'))
      AND (stale_after IS NULL OR datetime(stale_after) >= datetime('now'))
    #{parts.match_filter}
    """
  end

  defp and_all(clauses), do: Enum.map_join(clauses, fn clause -> "  AND #{clause}\n" end)

  # Partition access requires intersection with the allowed partitions;
  # security access requires the object's labels to be a subset of the allowed
  # labels. The envelope fails closed: an empty/absent allowed list only
  # admits objects that carry no partition ids / no security labels at all —
  # it never grants access to partitioned or labeled objects. Predicates run
  # inside the candidate SQL so unauthorized rows never enter (or crowd out)
  # the candidate window.
  defp authorization_clauses(table, authorization, param_offset) do
    {partition_clause, partition_params} =
      case authorization.allowed_partitions do
        [] ->
          {"NOT EXISTS (SELECT 1 FROM json_each(COALESCE(NULLIF(#{table}.partition_ids, ''), '[]')))",
           []}

        partitions ->
          marks = placeholders(param_offset + 1, length(partitions))

          {"EXISTS (SELECT 1 FROM json_each(COALESCE(NULLIF(#{table}.partition_ids, ''), '[]')) AS object_partition WHERE object_partition.value IN (#{marks}))",
           partitions}
      end

    security_offset = param_offset + length(partition_params)

    {security_clause, security_params} =
      case authorization.allowed_security_labels do
        [] ->
          {"NOT EXISTS (SELECT 1 FROM json_each(COALESCE(NULLIF(#{table}.security_labels, ''), '[]')))",
           []}

        labels ->
          marks = placeholders(security_offset + 1, length(labels))

          {"NOT EXISTS (SELECT 1 FROM json_each(COALESCE(NULLIF(#{table}.security_labels, ''), '[]')) AS object_label WHERE object_label.value NOT IN (#{marks}))",
           labels}
      end

    {[partition_clause, security_clause], partition_params ++ security_params}
  end

  defp placeholders(start, count) do
    start..(start + count - 1)
    |> Enum.map_join(", ", &"?#{&1}")
  end

  defp sql_parts(:facts) do
    %{
      table: "facts",
      object_type: "fact",
      select: """
      SELECT id, tenant_id, workspace_id, fact_text, fact_type, subject_anchor,
             action_class, object_anchor, accepted_claim_ids, supporting_evidence_links,
             aggregate_confidence, aggregate_precision, access_policy_id,
             security_labels, partition_ids, lifecycle_state, contradiction_status, valid_time_start,
             valid_time_end, stale_after
      """,
      lifecycle_filter: """
        AND lifecycle_state = 'accepted'
        AND contradiction_status = 'none'
      """,
      match_filter: """
        AND (
          fact_text LIKE ?3 OR subject_anchor LIKE ?3 OR action_class LIKE ?3
          OR object_anchor LIKE ?3 OR ?4 = ''
        )
      """,
      order: "ORDER BY aggregate_confidence DESC, updated_at DESC"
    }
  end

  defp sql_parts(:memory_objects) do
    %{
      table: "memory_objects",
      object_type: "memory_object",
      select: """
      SELECT id, tenant_id, workspace_id, memory_type, summary, subject_anchor,
             action_class, fact_links, claim_links, source_package_links, evidence_links,
             aggregate_confidence, aggregate_precision, access_policy_id,
             security_labels, partition_ids, lifecycle_state, staleness_status,
             supersession_status, valid_time_start, valid_time_end, stale_after
      """,
      lifecycle_filter: """
        AND lifecycle_state = 'current'
        AND staleness_status = 'current'
        AND supersession_status = 'none'
      """,
      match_filter: """
        AND (
          summary LIKE ?3 OR subject_anchor LIKE ?3 OR action_class LIKE ?3
          OR ?4 = ''
        )
      """,
      order: "ORDER BY salience DESC, aggregate_confidence DESC, updated_at DESC"
    }
  end

  defp object_from_row(:facts, row), do: fact_from_row(row)
  defp object_from_row(:memory_objects, row), do: memory_from_row(row)

  defp fact_from_row([
         id,
         tenant_id,
         workspace_id,
         fact_text,
         fact_type,
         subject_anchor,
         action_class,
         object_anchor,
         accepted_claim_ids,
         supporting_evidence_links,
         aggregate_confidence,
         aggregate_precision,
         access_policy_id,
         security_labels,
         partition_ids,
         lifecycle_state,
         contradiction_status,
         valid_time_start,
         valid_time_end,
         stale_after
       ]) do
    source_links =
      supporting_evidence_links
      |> decode_list()
      |> Enum.filter(&link_type?(&1, "source_package"))

    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      text: fact_text,
      type: fact_type,
      subject_anchor: subject_anchor,
      action_class: action_class,
      object_anchor: object_anchor,
      accepted_claim_ids: decode_list(accepted_claim_ids),
      evidence_links: decode_list(supporting_evidence_links),
      source_package_links: source_links,
      confidence: aggregate_confidence,
      precision: aggregate_precision,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      lifecycle_state: lifecycle_state,
      contradiction_status: contradiction_status,
      valid_time_start: valid_time_start,
      valid_time_end: valid_time_end,
      stale_after: stale_after
    }
  end

  defp memory_from_row([
         id,
         tenant_id,
         workspace_id,
         memory_type,
         summary,
         subject_anchor,
         action_class,
         fact_links,
         claim_links,
         source_package_links,
         evidence_links,
         aggregate_confidence,
         aggregate_precision,
         access_policy_id,
         security_labels,
         partition_ids,
         lifecycle_state,
         staleness_status,
         supersession_status,
         valid_time_start,
         valid_time_end,
         stale_after
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      text: summary,
      type: memory_type,
      subject_anchor: subject_anchor,
      action_class: action_class,
      fact_links: decode_list(fact_links),
      claim_links: decode_list(claim_links),
      source_package_links: decode_list(source_package_links),
      evidence_links: decode_list(evidence_links),
      confidence: aggregate_confidence,
      precision: aggregate_precision,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      lifecycle_state: lifecycle_state,
      staleness_status: staleness_status,
      supersession_status: supersession_status,
      valid_time_start: valid_time_start,
      valid_time_end: valid_time_end,
      stale_after: stale_after
    }
  end

  # ---------------------------------------------------------------------------
  # Private: filtered-object accounting
  # ---------------------------------------------------------------------------

  defp redacted_ref(object_type, [id, security_labels, partition_ids], authorization) do
    object = %{
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids)
    }

    reasons =
      []
      |> add_reason(
        "partition_filtered",
        not partition_allowed?(object, authorization.allowed_partitions)
      )
      |> add_reason(
        "security_label_filtered",
        not security_allowed?(object, authorization.allowed_security_labels)
      )
      |> Enum.reverse()

    %{type: object_type, id: id, reasons: reasons}
  end

  defp add_reason(reasons, reason, true), do: [reason | reasons]
  defp add_reason(reasons, _reason, false), do: reasons

  # Mirrors the fail-closed SQL predicates: an empty envelope only allows
  # objects with no partitions / no labels.
  defp partition_allowed?(object, []), do: object.partition_ids == []

  defp partition_allowed?(object, allowed_partitions) do
    MapSet.intersection(MapSet.new(object.partition_ids), MapSet.new(allowed_partitions))
    |> MapSet.size()
    |> Kernel.>(0)
  end

  defp security_allowed?(object, []), do: object.security_labels == []

  defp security_allowed?(object, allowed_security_labels) do
    MapSet.subset?(MapSet.new(object.security_labels), MapSet.new(allowed_security_labels))
  end

  defp reason_class_counts(redacted_links) do
    redacted_links
    |> Enum.flat_map(& &1.reasons)
    |> Enum.frequencies()
  end

  # ---------------------------------------------------------------------------
  # Private: section assembly (token-budget-aware tiering)
  # ---------------------------------------------------------------------------

  defp assemble_sections(retrieval_package, token_budget) do
    summary = summary_section(retrieval_package)
    remaining = max(token_budget - estimate_tokens(summary), 0)
    fact_budget = div(remaining * 6, 10)

    {facts_section, fact_tokens, facts_truncated?} =
      object_section("## Facts", retrieval_package.facts, fact_budget, &fact_entry/1)

    {memory_section, memory_tokens, memory_truncated?} =
      object_section(
        "## Memory",
        retrieval_package.memory_objects,
        remaining - fact_tokens,
        &memory_entry/1
      )

    %{
      summary: summary,
      facts: facts_section,
      memory: memory_section,
      token_budget: token_budget,
      total_tokens: estimate_tokens(summary) + fact_tokens + memory_tokens,
      truncated?: facts_truncated? or memory_truncated?
    }
  end

  defp summary_section(retrieval_package) do
    filtered = retrieval_package.filtered_summary

    """
    # Context Package
    Query: #{retrieval_package.query}
    Workspace: #{retrieval_package.workspace_id}
    Facts: #{filtered.returned_facts} returned of #{filtered.candidate_facts} candidates
    Memory objects: #{filtered.returned_memory_objects} returned of #{filtered.candidate_memory_objects} candidates
    Policy-excluded objects: #{filtered.redacted_or_filtered_objects}
    Freshness: #{retrieval_package.time_mode} as of #{retrieval_package.retrieved_at}
    Actor: #{Map.get(retrieval_package.scope, :actor_id) || "unscoped"}
    """
  end

  defp object_section(_header, [], _budget, _entry_fun), do: {"", 0, false}

  defp object_section(header, objects, budget, entry_fun) do
    opening = header <> "\n"

    {body, tokens, kept} =
      Enum.reduce(objects, {"", estimate_tokens(opening), 0}, fn object, {acc, acc_tokens, kept} ->
        entry = entry_fun.(object)
        entry_tokens = estimate_tokens(entry)

        if acc_tokens + entry_tokens <= budget do
          {acc <> entry, acc_tokens + entry_tokens, kept + 1}
        else
          {acc, acc_tokens, kept}
        end
      end)

    {opening <> body, tokens, kept < length(objects)}
  end

  defp fact_entry(fact) do
    "- #{fact.text} (confidence: #{fact.confidence})#{citations(fact.source_package_links)}\n"
  end

  defp memory_entry(memory) do
    fact_ids = Enum.map(memory.fact_links, &link_id/1) |> Enum.reject(&is_nil/1)
    fact_note = if fact_ids == [], do: "", else: " [facts: #{Enum.join(fact_ids, ", ")}]"
    "- #{memory.text}#{fact_note}#{citations(memory.source_package_links)}\n"
  end

  defp citations([]), do: ""

  defp citations(source_package_links) do
    ids = source_package_links |> Enum.map(&link_id/1) |> Enum.reject(&is_nil/1)
    if ids == [], do: "", else: " [sources: #{Enum.join(ids, ", ")}]"
  end

  defp estimate_tokens(text) when is_binary(text), do: div(String.length(text), 4)
  defp estimate_tokens(_), do: 0

  # ---------------------------------------------------------------------------
  # Private: derivation ledger
  # ---------------------------------------------------------------------------

  defp record_assembly(retrieval_package, package, opts) do
    entry =
      DerivationLedgerEntry.new(
        "memory_core.assemble_context_package",
        "retrieval_package_to_context_package",
        [
          %{type: "retrieval_package", id: retrieval_package.id}
          | package.returned_object_links
        ],
        [%{type: "context_package", id: package.id}],
        tenant_id: package.tenant_id,
        workspace_id: package.workspace_id,
        actor_id:
          Map.get(retrieval_package.scope, :actor_id) ||
            string_or_nil(Keyword.get(opts, :actor_id)),
        parser_id: "optimal_engine.memory_core.retrieval_coordinator",
        source_package_links: package.source_package_links,
        evidence_links: package.evidence_links,
        security_labels: package.security_labels,
        partition_ids: package.partition_ids,
        policy_version: @policy_version,
        metadata: %{
          query: retrieval_package.query,
          retrieval_path: retrieval_package.retrieval_plan[:path],
          filtered_object_summary: retrieval_package.filtered_summary
        }
      )

    Store.insert_derivation_entry(entry)
  end

  # ---------------------------------------------------------------------------
  # Private: helpers
  # ---------------------------------------------------------------------------

  defp collect_unique_links(objects, key) do
    objects
    |> Enum.flat_map(&Map.get(&1, key, []))
    |> Enum.uniq()
  end

  defp merge_lists(objects, key) do
    objects
    |> Enum.flat_map(&Map.get(&1, key, []))
    |> Enum.uniq()
  end

  defp summarize_score([], _field), do: %{count: 0, min: nil, max: nil, average: nil}

  defp summarize_score(objects, field) do
    values = Enum.map(objects, &Map.get(&1, field, 0.0))
    count = length(values)

    %{
      count: count,
      min: Enum.min(values),
      max: Enum.max(values),
      average: Enum.sum(values) / count
    }
  end

  defp classify_intent(""), do: "recall"
  defp classify_intent(_query), do: "recall"

  defp decode_list(nil), do: []
  defp decode_list(""), do: []

  defp decode_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      {:ok, other} -> [other]
      _ -> []
    end
  end

  defp decode_list(value) when is_list(value), do: value
  defp decode_list(value), do: [value]

  defp link_type?(%{type: type}, expected), do: type == expected
  defp link_type?(%{"type" => type}, expected), do: type == expected
  defp link_type?(_, _expected), do: false

  defp link_id(%{"id" => id}), do: id
  defp link_id(%{id: id}), do: id
  defp link_id(id) when is_binary(id), do: id
  defp link_id(_), do: nil

  defp ref(type, id), do: %{type: type, id: id}

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp string_opt(opts, key, default), do: Keyword.get(opts, key, default) |> to_string()

  defp string_list_opt(opts, key) do
    opts
    |> Keyword.get(key, [])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: to_string(value)
end
