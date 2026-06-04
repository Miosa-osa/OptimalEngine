defmodule OptimalEngine.MemoryCore.RetrievalCoordinator do
  @moduledoc """
  First governed recall slice for Memory Core.

  The coordinator returns a Context Package instead of loose search chunks. This
  first implementation reads accepted Facts, current Memory Objects, governed
  asset extraction projections, workflow candidates, and approved Skill Packages
  in a workspace. It applies partition/security filtering, writes a
  `context_packages` row, and returns the structured package.
  """

  alias OptimalEngine.MemoryCore.{ID, Store}
  alias OptimalEngine.Store, as: BaseStore

  @default_limit 10

  @spec retrieve(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve(query, opts \\ []) when is_binary(query) do
    now = timestamp()
    tenant_id = string_opt(opts, :tenant_id, "default")
    workspace_id = string_opt(opts, :workspace_id, "default")
    limit = Keyword.get(opts, :limit, @default_limit)

    actor_id =
      string_or_nil(Keyword.get(opts, :actor_id) || Keyword.get(opts, :requesting_actor_id))

    allowed_partitions = Keyword.get(opts, :allowed_partitions, [])
    allowed_security_labels = Keyword.get(opts, :allowed_security_labels, [])
    time_mode = string_opt(opts, :time_mode, "current_valid")
    request_intent = string_opt(opts, :request_intent, classify_intent(query))
    retrieval_plan = build_retrieval_plan(query, opts)

    with {:ok, facts} <- fetch_facts(workspace_id, query, limit * 2, retrieval_plan),
         {:ok, memories} <- fetch_memory_objects(workspace_id, query, limit * 2, retrieval_plan),
         {:ok, asset_extractions} <-
           fetch_asset_extractions(workspace_id, query, limit * 2, retrieval_plan),
         {:ok, workflows} <- fetch_workflows(workspace_id, query, limit * 2, retrieval_plan),
         {:ok, skill_packages} <-
           fetch_skill_packages(workspace_id, query, limit * 2, retrieval_plan, opts) do
      authorized_facts =
        facts
        |> Enum.filter(&authorized?(&1, allowed_partitions, allowed_security_labels))
        |> Enum.take(limit)

      authorized_memories =
        memories
        |> Enum.filter(&authorized?(&1, allowed_partitions, allowed_security_labels))
        |> Enum.take(limit)

      authorized_asset_extractions =
        asset_extractions
        |> Enum.filter(&authorized?(&1, allowed_partitions, allowed_security_labels))
        |> Enum.take(limit)

      authorized_workflows =
        workflows
        |> Enum.filter(&authorized?(&1, allowed_partitions, allowed_security_labels))
        |> Enum.take(limit)

      authorized_skill_packages =
        skill_packages
        |> Enum.filter(&authorized?(&1, allowed_partitions, allowed_security_labels))
        |> Enum.take(limit)

      redacted =
        length(facts) - length(authorized_facts) +
          (length(memories) - length(authorized_memories)) +
          (length(asset_extractions) - length(authorized_asset_extractions)) +
          (length(workflows) - length(authorized_workflows)) +
          (length(skill_packages) - length(authorized_skill_packages))

      fact_links = Enum.map(authorized_facts, &ref("fact", &1.id))
      memory_links = Enum.map(authorized_memories, &ref("memory_object", &1.id))

      asset_extraction_links =
        Enum.map(authorized_asset_extractions, &ref("asset_extraction", &1.id))

      workflow_links =
        Enum.map(authorized_workflows, &ref("generalized_workflow", &1.id))

      skill_package_links =
        Enum.map(authorized_skill_packages, &ref("skill_package", &1.id))

      returned_objects =
        authorized_facts ++
          authorized_memories ++
          authorized_asset_extractions ++ authorized_workflows ++ authorized_skill_packages

      source_links =
        collect_unique_links(returned_objects, :source_package_links)

      evidence_links =
        collect_unique_links(returned_objects, :evidence_links)

      returned_links =
        fact_links ++
          memory_links ++ asset_extraction_links ++ workflow_links ++ skill_package_links

      context_package = %{
        id:
          ID.content_id("ctxpkg", [
            tenant_id,
            ":",
            workspace_id,
            ":",
            query,
            ":",
            now
          ]),
        tenant_id: tenant_id,
        workspace_id: workspace_id,
        request_id: string_or_nil(Keyword.get(opts, :request_id)),
        request_intent: request_intent,
        requesting_actor_id: actor_id,
        active_memory_pool_id: string_or_nil(Keyword.get(opts, :active_memory_pool_id)),
        time_mode: time_mode,
        detail_depth: Keyword.get(opts, :detail_depth, 1),
        memory_links: memory_links,
        fact_links: fact_links,
        workflow_links: workflow_links,
        skill_package_links: skill_package_links,
        source_package_links: source_links,
        evidence_links: evidence_links,
        retrieval_plan: Map.put(retrieval_plan, :limit, limit),
        package_confidence_summary: summarize_score(returned_objects, :confidence),
        package_precision_summary: summarize_score(returned_objects, :precision),
        filtered_object_summary: %{
          candidate_facts: length(facts),
          returned_facts: length(authorized_facts),
          candidate_memory_objects: length(memories),
          returned_memory_objects: length(authorized_memories),
          candidate_asset_extractions: length(asset_extractions),
          returned_asset_extractions: length(authorized_asset_extractions),
          candidate_workflows: length(workflows),
          returned_workflows: length(authorized_workflows),
          candidate_skill_packages: length(skill_packages),
          returned_skill_packages: length(authorized_skill_packages),
          redacted_or_filtered_objects: redacted
        },
        returned_object_links: returned_links,
        redacted_object_links: [],
        authorization_envelope: %{
          actor_id: actor_id,
          allowed_partitions: allowed_partitions,
          allowed_security_labels: allowed_security_labels,
          applied_before_package_assembly: true
        },
        lifecycle_state: "assembled",
        refresh_state: "fresh",
        refresh_time: now,
        transaction_time_start: now,
        security_labels: merge_lists(returned_objects, :security_labels),
        partition_ids: merge_lists(returned_objects, :partition_ids),
        metadata:
          Map.merge(
            %{
              query: query,
              answer_surface: "context_package",
              asset_extraction_links: asset_extraction_links,
              workflow_links: workflow_links,
              skill_package_links: skill_package_links
            },
            Keyword.get(opts, :metadata, %{})
          )
      }

      with :ok <- Store.insert_context_package(context_package) do
        {:ok,
         Map.merge(context_package, %{
           facts: authorized_facts,
           memory_objects: authorized_memories,
           asset_extractions: authorized_asset_extractions,
           workflows: authorized_workflows,
           skill_packages: authorized_skill_packages
         })}
      end
    end
  end

  @spec refresh_context_package(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh_context_package(context_package_id, opts \\ []) when is_binary(context_package_id) do
    tenant_id = string_opt(opts, :tenant_id, "default")
    workspace_id = Keyword.get(opts, :workspace_id)

    with {:ok, stale_package} <- get_context_package(context_package_id, tenant_id, workspace_id),
         :ok <- ensure_refreshable(stale_package, opts),
         {:ok, query} <- original_query(stale_package) do
      refresh_opts =
        stale_package
        |> refresh_opts_from_package(opts)
        |> Keyword.put(
          :metadata,
          Map.merge(Keyword.get(opts, :metadata, %{}), %{
            refreshed_from_context_package_id: stale_package.id,
            refreshed_from_invalidation_reason: stale_package.invalidation_reason
          })
        )

      with {:ok, refreshed_package} <- retrieve(query, refresh_opts),
           :ok <-
             Store.mark_context_package_refreshed(stale_package.id,
               tenant_id: stale_package.tenant_id,
               workspace_id: stale_package.workspace_id
             ) do
        {:ok, refreshed_package}
      end
    end
  end

  @spec refresh_stale_context_packages(keyword()) :: {:ok, map()} | {:error, term()}
  def refresh_stale_context_packages(opts \\ []) when is_list(opts) do
    with {:ok, stale_packages} <- list_stale_context_packages(opts) do
      refresh_opts = Keyword.drop(opts, [:batch_limit, :continue_on_error])

      stale_packages
      |> Enum.reduce_while(
        {:ok,
         %{stale_context_package_ids: Enum.map(stale_packages, & &1.id), refreshed: [], errors: []}},
        fn stale_package, {:ok, acc} ->
          case refresh_context_package(stale_package.id, refresh_opts) do
            {:ok, refreshed_package} ->
              {:cont, {:ok, put_in(acc.refreshed, acc.refreshed ++ [refreshed_package])}}

            {:error, reason} ->
              if Keyword.get(opts, :continue_on_error, true) do
                error = %{context_package_id: stale_package.id, reason: reason}
                {:cont, {:ok, put_in(acc.errors, acc.errors ++ [error])}}
              else
                {:halt, {:error, {stale_package.id, reason}}}
              end
          end
        end
      )
      |> case do
        {:ok, result} ->
          {:ok,
           %{
             stale_context_package_ids: result.stale_context_package_ids,
             refreshed_context_packages: result.refreshed,
             errors: result.errors
           }}

        other ->
          other
      end
    end
  end

  @spec list_stale_context_packages(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_stale_context_packages(opts \\ []) when is_list(opts) do
    tenant_id = string_opt(opts, :tenant_id, "default")
    workspace_id = Keyword.get(opts, :workspace_id)
    batch_limit = Keyword.get(opts, :batch_limit, 50)

    {clauses, params} = {["tenant_id = ?1", "refresh_state = 'stale'"], [tenant_id]}

    {clauses, params} =
      case workspace_id do
        nil -> {clauses, params}
        value -> {clauses ++ ["workspace_id = ?#{length(params) + 1}"], params ++ [value]}
      end

    sql =
      context_package_select() <>
        " WHERE " <>
        Enum.join(clauses, " AND ") <>
        " ORDER BY transaction_time_end DESC, refresh_time DESC LIMIT ?#{length(params) + 1}"

    case BaseStore.raw_query(sql, params ++ [batch_limit]) do
      {:ok, rows} -> {:ok, Enum.map(rows, &context_package_from_row/1)}
      other -> other
    end
  end

  defp ensure_refreshable(%{refresh_state: "stale"}, _opts), do: :ok

  defp ensure_refreshable(_package, opts) when is_list(opts) do
    if Keyword.get(opts, :force, false), do: :ok, else: {:error, :context_package_not_stale}
  end

  defp get_context_package(context_package_id, tenant_id, nil) do
    sql = context_package_select() <> " WHERE id = ?1 AND tenant_id = ?2 LIMIT 1"
    context_package_query(sql, [context_package_id, tenant_id])
  end

  defp get_context_package(context_package_id, tenant_id, workspace_id) do
    sql =
      context_package_select() <>
        " WHERE id = ?1 AND tenant_id = ?2 AND workspace_id = ?3 LIMIT 1"

    context_package_query(sql, [context_package_id, tenant_id, workspace_id])
  end

  defp context_package_query(sql, params) do
    case BaseStore.raw_query(sql, params) do
      {:ok, [row]} -> {:ok, context_package_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  defp context_package_select do
    """
    SELECT id, tenant_id, workspace_id, request_id, request_intent,
           requesting_actor_id, active_memory_pool_id, time_mode, detail_depth,
           memory_links, fact_links, workflow_links, skill_package_links,
           source_package_links, evidence_links, retrieval_plan,
           package_confidence_summary, package_precision_summary,
           filtered_object_summary, returned_object_links, redacted_object_links,
           authorization_envelope, lifecycle_state, refresh_state,
           invalidation_reason, valid_time_start, valid_time_end,
           transaction_time_start, transaction_time_end, stale_after, refresh_time,
           access_policy_id, security_labels, partition_ids, audit_event_links,
           policy_version, metadata
    FROM context_packages
    """
  end

  defp context_package_from_row([
         id,
         tenant_id,
         workspace_id,
         request_id,
         request_intent,
         requesting_actor_id,
         active_memory_pool_id,
         time_mode,
         detail_depth,
         memory_links,
         fact_links,
         workflow_links,
         skill_package_links,
         source_package_links,
         evidence_links,
         retrieval_plan,
         package_confidence_summary,
         package_precision_summary,
         filtered_object_summary,
         returned_object_links,
         redacted_object_links,
         authorization_envelope,
         lifecycle_state,
         refresh_state,
         invalidation_reason,
         valid_time_start,
         valid_time_end,
         transaction_time_start,
         transaction_time_end,
         stale_after,
         refresh_time,
         access_policy_id,
         security_labels,
         partition_ids,
         audit_event_links,
         policy_version,
         metadata
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      request_id: request_id,
      request_intent: request_intent,
      requesting_actor_id: requesting_actor_id,
      active_memory_pool_id: active_memory_pool_id,
      time_mode: time_mode,
      detail_depth: detail_depth,
      memory_links: decode_list(memory_links),
      fact_links: decode_list(fact_links),
      workflow_links: decode_list(workflow_links),
      skill_package_links: decode_list(skill_package_links),
      source_package_links: decode_list(source_package_links),
      evidence_links: decode_list(evidence_links),
      retrieval_plan: decode_map(retrieval_plan),
      package_confidence_summary: decode_map(package_confidence_summary),
      package_precision_summary: decode_map(package_precision_summary),
      filtered_object_summary: decode_map(filtered_object_summary),
      returned_object_links: decode_list(returned_object_links),
      redacted_object_links: decode_list(redacted_object_links),
      authorization_envelope: decode_map(authorization_envelope),
      lifecycle_state: lifecycle_state,
      refresh_state: refresh_state,
      invalidation_reason: invalidation_reason,
      valid_time_start: valid_time_start,
      valid_time_end: valid_time_end,
      transaction_time_start: transaction_time_start,
      transaction_time_end: transaction_time_end,
      stale_after: stale_after,
      refresh_time: refresh_time,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      audit_event_links: decode_list(audit_event_links),
      policy_version: policy_version,
      metadata: decode_map(metadata)
    }
  end

  defp original_query(package) do
    query =
      map_get(package.metadata, :query) ||
        map_get(package.retrieval_plan, :query) ||
        ""

    case query do
      "" -> {:error, :missing_original_query}
      query when is_binary(query) -> {:ok, query}
      query -> {:ok, to_string(query)}
    end
  end

  defp refresh_opts_from_package(package, opts) do
    auth = package.authorization_envelope

    [
      tenant_id: Keyword.get(opts, :tenant_id, package.tenant_id),
      workspace_id: Keyword.get(opts, :workspace_id, package.workspace_id),
      request_id: Keyword.get(opts, :request_id, package.request_id),
      request_intent: Keyword.get(opts, :request_intent, package.request_intent),
      actor_id:
        Keyword.get(opts, :actor_id) ||
          Keyword.get(opts, :requesting_actor_id) ||
          package.requesting_actor_id,
      active_memory_pool_id:
        Keyword.get(opts, :active_memory_pool_id, package.active_memory_pool_id),
      time_mode: Keyword.get(opts, :time_mode, package.time_mode),
      detail_depth: Keyword.get(opts, :detail_depth, package.detail_depth),
      allowed_partitions:
        Keyword.get(opts, :allowed_partitions) ||
          map_get(auth, :allowed_partitions) ||
          package.partition_ids,
      allowed_security_labels:
        Keyword.get(opts, :allowed_security_labels) ||
          map_get(auth, :allowed_security_labels) ||
          package.security_labels,
      limit: Keyword.get(opts, :limit) || map_get(package.retrieval_plan, :limit) || @default_limit
    ]
  end

  defp fetch_facts(workspace_id, query, limit, retrieval_plan) do
    pattern = "%#{query}%"
    filters = Map.fetch!(retrieval_plan, :structured_filters)

    sql = """
    SELECT id, tenant_id, workspace_id, fact_text, fact_type, subject_anchor,
           action_class, object_anchor, accepted_claim_ids, supporting_evidence_links,
           aggregate_confidence, aggregate_precision, access_policy_id,
           security_labels, partition_ids, lifecycle_state, contradiction_status, valid_time_start,
           valid_time_end, stale_after
    FROM facts
    WHERE workspace_id = ?1
      AND lifecycle_state = 'accepted'
      AND contradiction_status = 'none'
      AND (valid_time_end IS NULL OR datetime(valid_time_end) >= datetime('now'))
      AND (stale_after IS NULL OR datetime(stale_after) >= datetime('now'))
      AND (
        fact_text LIKE ?2 OR subject_anchor LIKE ?2 OR action_class LIKE ?2
        OR object_anchor LIKE ?2 OR ?3 = ''
      )
      AND (?4 IS NULL OR subject_anchor = ?4)
      AND (?5 IS NULL OR action_class = ?5)
      AND (?6 IS NULL OR object_anchor = ?6)
    ORDER BY aggregate_confidence DESC, updated_at DESC
    LIMIT ?7
    """

    params = [
      workspace_id,
      pattern,
      query,
      Map.get(filters, :subject_anchor),
      Map.get(filters, :action_class),
      Map.get(filters, :object_anchor),
      limit
    ]

    with {:ok, rows} <- BaseStore.raw_query(sql, params) do
      {:ok, Enum.map(rows, &fact_from_row/1)}
    end
  end

  defp fetch_memory_objects(workspace_id, query, limit, retrieval_plan) do
    pattern = "%#{query}%"
    filters = Map.fetch!(retrieval_plan, :structured_filters)

    sql = """
    SELECT id, tenant_id, workspace_id, memory_type, summary, subject_anchor,
           action_class, fact_links, claim_links, source_package_links, evidence_links,
           aggregate_confidence, aggregate_precision, access_policy_id,
           security_labels, partition_ids, lifecycle_state, staleness_status,
           supersession_status, valid_time_start, valid_time_end, stale_after
    FROM memory_objects
    WHERE workspace_id = ?1
      AND lifecycle_state = 'current'
      AND staleness_status = 'current'
      AND supersession_status = 'none'
      AND (valid_time_end IS NULL OR datetime(valid_time_end) >= datetime('now'))
      AND (stale_after IS NULL OR datetime(stale_after) >= datetime('now'))
      AND (
        summary LIKE ?2 OR subject_anchor LIKE ?2 OR action_class LIKE ?2
        OR ?3 = ''
      )
      AND (?4 IS NULL OR subject_anchor = ?4)
      AND (?5 IS NULL OR action_class = ?5)
    ORDER BY salience DESC, aggregate_confidence DESC, updated_at DESC
    LIMIT ?6
    """

    params = [
      workspace_id,
      pattern,
      query,
      Map.get(filters, :subject_anchor),
      Map.get(filters, :action_class),
      limit
    ]

    with {:ok, rows} <- BaseStore.raw_query(sql, params) do
      {:ok, Enum.map(rows, &memory_from_row/1)}
    end
  end

  defp fetch_asset_extractions(workspace_id, query, limit, retrieval_plan) do
    pattern = "%#{query}%"
    filters = Map.fetch!(retrieval_plan, :asset_filters)

    sql = """
    SELECT id, tenant_id, workspace_id, asset_id, source_package_id, adapter_run_id,
           extraction_type, modality, content_text, content_ref, content_hash,
           confidence, precision, security_labels, partition_ids, metadata,
           derivation_ledger_id, created_by, created_at
    FROM asset_extractions
    WHERE workspace_id = ?1
      AND (
        content_text LIKE ?2 OR content_ref LIKE ?2 OR extraction_type LIKE ?2
        OR modality LIKE ?2 OR ?3 = ''
      )
      AND (?4 IS NULL OR modality = ?4)
      AND (?5 IS NULL OR extraction_type = ?5)
    ORDER BY confidence DESC, created_at DESC
    LIMIT ?6
    """

    params = [
      workspace_id,
      pattern,
      query,
      Map.get(filters, :modality),
      Map.get(filters, :extraction_type),
      limit
    ]

    with {:ok, rows} <- BaseStore.raw_query(sql, params) do
      {:ok, Enum.map(rows, &asset_extraction_from_row/1)}
    end
  end

  defp fetch_workflows(workspace_id, query, limit, retrieval_plan) do
    pattern = "%#{query}%"
    filters = Map.fetch!(retrieval_plan, :workflow_filters)

    sql = """
    SELECT id, tenant_id, workspace_id, workflow_family, scope,
           applicability_conditions, outcome_class, workflow_trace_links,
           supporting_episode_links, contradicting_trace_links, step_pattern_links,
           aggregate_confidence, aggregate_precision, validation_score,
           lifecycle_state, validation_status, supersession_status,
           valid_time_start, valid_time_end, stale_after, access_policy_id,
           security_labels, partition_ids, metadata
    FROM generalized_workflows
    WHERE workspace_id = ?1
      AND lifecycle_state IN ('candidate', 'current', 'approved')
      AND validation_status != 'rejected'
      AND supersession_status = 'none'
      AND (valid_time_end IS NULL OR datetime(valid_time_end) >= datetime('now'))
      AND (stale_after IS NULL OR datetime(stale_after) >= datetime('now'))
      AND (
        workflow_family LIKE ?2 OR outcome_class LIKE ?2 OR metadata LIKE ?2
        OR ?3 = ''
      )
      AND (?4 IS NULL OR workflow_family = ?4)
    ORDER BY validation_score DESC, aggregate_confidence DESC, updated_at DESC
    LIMIT ?5
    """

    params = [
      workspace_id,
      pattern,
      query,
      Map.get(filters, :workflow_family),
      limit
    ]

    with {:ok, rows} <- BaseStore.raw_query(sql, params) do
      {:ok, Enum.map(rows, &workflow_from_row/1)}
    end
  end

  defp fetch_skill_packages(workspace_id, query, limit, retrieval_plan, opts) do
    pattern = "%#{query}%"
    filters = Map.fetch!(retrieval_plan, :skill_filters)
    include_draft_skills? = Keyword.get(opts, :include_draft_skills, false)

    eligibility_sql =
      if include_draft_skills? do
        "AND retirement_status = 'active'"
      else
        """
        AND review_status = 'approved'
        AND enabled_state = 'enabled'
        AND retirement_status = 'active'
        AND suspension_reason IS NULL
        """
      end

    sql = """
    SELECT id, tenant_id, workspace_id, version, skill_package_name, task_family,
           competency_links, risk_class, procedural_memory_links, workflow_links,
           validation_links, evidence_links, input_contract, output_contract,
           execution_policy, required_privileges, tool_requirements, model_policy_id,
           aggregate_confidence, aggregate_precision, review_status, enabled_state,
           suspension_reason, retirement_status, valid_time_start, valid_time_end,
           stale_after, access_policy_id, security_labels, partition_ids, metadata
    FROM skill_packages
    WHERE workspace_id = ?1
      #{eligibility_sql}
      AND (valid_time_end IS NULL OR datetime(valid_time_end) >= datetime('now'))
      AND (stale_after IS NULL OR datetime(stale_after) >= datetime('now'))
      AND (
        skill_package_name LIKE ?2 OR task_family LIKE ?2 OR metadata LIKE ?2
        OR ?3 = ''
      )
      AND (?4 IS NULL OR task_family = ?4)
      AND (?5 IS NULL OR skill_package_name = ?5)
    ORDER BY aggregate_confidence DESC, updated_at DESC
    LIMIT ?6
    """

    params = [
      workspace_id,
      pattern,
      query,
      Map.get(filters, :task_family),
      Map.get(filters, :skill_package_name),
      limit
    ]

    with {:ok, rows} <- BaseStore.raw_query(sql, params) do
      {:ok, Enum.map(rows, &skill_package_from_row/1)}
    end
  end

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

  defp asset_extraction_from_row([
         id,
         tenant_id,
         workspace_id,
         asset_id,
         source_package_id,
         adapter_run_id,
         extraction_type,
         modality,
         content_text,
         content_ref,
         content_hash,
         confidence,
         precision,
         security_labels,
         partition_ids,
         metadata,
         derivation_ledger_id,
         created_by,
         created_at
       ]) do
    source_links =
      if is_binary(source_package_id) do
        [ref("source_package", source_package_id)]
      else
        []
      end

    evidence_links =
      [
        ref("asset", asset_id),
        ref("asset_adapter_run", adapter_run_id),
        ref("asset_extraction", id)
        | source_links
      ]
      |> Enum.reject(&(is_nil(&1.id) or &1.id == ""))

    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      text: if(content_text == "", do: content_ref, else: content_text),
      type: extraction_type,
      asset_id: asset_id,
      source_package_id: source_package_id,
      adapter_run_id: adapter_run_id,
      extraction_type: extraction_type,
      modality: modality,
      content_text: content_text,
      content_ref: content_ref,
      content_hash: content_hash,
      source_package_links: source_links,
      evidence_links: evidence_links,
      confidence: confidence,
      precision: precision,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      metadata: decode_map(metadata),
      derivation_ledger_id: derivation_ledger_id,
      created_by: created_by,
      created_at: created_at
    }
  end

  defp workflow_from_row([
         id,
         tenant_id,
         workspace_id,
         workflow_family,
         scope,
         applicability_conditions,
         outcome_class,
         workflow_trace_links,
         supporting_episode_links,
         contradicting_trace_links,
         step_pattern_links,
         aggregate_confidence,
         aggregate_precision,
         validation_score,
         lifecycle_state,
         validation_status,
         supersession_status,
         valid_time_start,
         valid_time_end,
         stale_after,
         access_policy_id,
         security_labels,
         partition_ids,
         metadata
       ]) do
    workflow_trace_links = decode_list(workflow_trace_links)
    supporting_episode_links = decode_list(supporting_episode_links)
    contradicting_trace_links = decode_list(contradicting_trace_links)
    step_pattern_links = decode_list(step_pattern_links)

    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      text: workflow_family,
      type: "generalized_workflow",
      workflow_family: workflow_family,
      scope: decode_map(scope),
      applicability_conditions: decode_map(applicability_conditions),
      outcome_class: outcome_class,
      workflow_trace_links: workflow_trace_links,
      supporting_episode_links: supporting_episode_links,
      contradicting_trace_links: contradicting_trace_links,
      step_pattern_links: step_pattern_links,
      source_package_links: [],
      evidence_links: workflow_trace_links ++ supporting_episode_links ++ contradicting_trace_links,
      confidence: aggregate_confidence,
      precision: aggregate_precision,
      validation_score: validation_score,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      lifecycle_state: lifecycle_state,
      validation_status: validation_status,
      supersession_status: supersession_status,
      valid_time_start: valid_time_start,
      valid_time_end: valid_time_end,
      stale_after: stale_after,
      metadata: decode_map(metadata)
    }
  end

  defp skill_package_from_row([
         id,
         tenant_id,
         workspace_id,
         version,
         skill_package_name,
         task_family,
         competency_links,
         risk_class,
         procedural_memory_links,
         workflow_links,
         validation_links,
         evidence_links,
         input_contract,
         output_contract,
         execution_policy,
         required_privileges,
         tool_requirements,
         model_policy_id,
         aggregate_confidence,
         aggregate_precision,
         review_status,
         enabled_state,
         suspension_reason,
         retirement_status,
         valid_time_start,
         valid_time_end,
         stale_after,
         access_policy_id,
         security_labels,
         partition_ids,
         metadata
       ]) do
    procedural_memory_links = decode_list(procedural_memory_links)
    workflow_links = decode_list(workflow_links)
    validation_links = decode_list(validation_links)
    evidence_links = decode_list(evidence_links)

    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      text: skill_package_name,
      type: "skill_package",
      version: version,
      skill_package_name: skill_package_name,
      task_family: task_family,
      competency_links: decode_list(competency_links),
      risk_class: risk_class,
      procedural_memory_links: procedural_memory_links,
      workflow_links: workflow_links,
      validation_links: validation_links,
      source_package_links: [],
      evidence_links:
        evidence_links ++ workflow_links ++ procedural_memory_links ++ validation_links,
      input_contract: decode_map(input_contract),
      output_contract: decode_map(output_contract),
      execution_policy: decode_map(execution_policy),
      required_privileges: decode_list(required_privileges),
      tool_requirements: decode_list(tool_requirements),
      model_policy_id: model_policy_id,
      confidence: aggregate_confidence,
      precision: aggregate_precision,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      review_status: review_status,
      enabled_state: enabled_state,
      suspension_reason: suspension_reason,
      retirement_status: retirement_status,
      valid_time_start: valid_time_start,
      valid_time_end: valid_time_end,
      stale_after: stale_after,
      metadata: decode_map(metadata)
    }
  end

  defp authorized?(object, allowed_partitions, allowed_security_labels) do
    partition_allowed? =
      allowed_partitions == [] or
        MapSet.intersection(MapSet.new(object.partition_ids), MapSet.new(allowed_partitions))
        |> MapSet.size()
        |> Kernel.>(0)

    security_allowed? =
      allowed_security_labels == [] or
        MapSet.subset?(MapSet.new(object.security_labels), MapSet.new(allowed_security_labels))

    partition_allowed? and security_allowed?
  end

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
    values =
      objects
      |> Enum.map(&(Map.get(&1, field) || 0.0))
      |> Enum.map(&(&1 + 0.0))

    count = length(values)

    %{
      count: count,
      min: Enum.min(values),
      max: Enum.max(values),
      average: Enum.sum(values) / count
    }
  end

  defp build_retrieval_plan(query, opts) do
    structured_filters =
      %{
        subject_anchor: string_opt_or_nil(opts, :subject_anchor),
        action_class: string_opt_or_nil(opts, :action_class),
        object_anchor: string_opt_or_nil(opts, :object_anchor)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    asset_filters =
      %{
        modality: string_opt_or_nil(opts, :modality),
        extraction_type: string_opt_or_nil(opts, :extraction_type)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    workflow_filters =
      %{
        workflow_family: string_opt_or_nil(opts, :workflow_family)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    skill_filters =
      %{
        task_family: string_opt_or_nil(opts, :task_family),
        skill_package_name: string_opt_or_nil(opts, :skill_package_name)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      query: query,
      path: retrieval_path(structured_filters, asset_filters, workflow_filters, skill_filters),
      executed_paths: [
        "facts.sql_like",
        "memory_objects.sql_like",
        "asset_extractions.sql_like",
        "generalized_workflows.sql_like",
        "skill_packages.sql_like",
        "workflow_skill.eligibility_filter",
        "authorization.pre_assembly_filter"
      ],
      filters: %{
        workspace_id: string_opt(opts, :workspace_id, "default"),
        lifecycle: [
          "facts.accepted",
          "memory_objects.current",
          "asset_extractions.projected",
          "generalized_workflows.candidate_or_current",
          skill_package_lifecycle_filter(opts)
        ],
        time_mode: string_opt(opts, :time_mode, "current_valid")
      },
      structured_filters: structured_filters,
      asset_filters: asset_filters,
      workflow_filters: workflow_filters,
      skill_filters: skill_filters,
      temporal_filter: %{
        mode: string_opt(opts, :time_mode, "current_valid"),
        valid_at: string_opt_or_nil(opts, :valid_at)
      }
    }
  end

  defp retrieval_path(structured_filters, asset_filters, workflow_filters, skill_filters)

  defp retrieval_path(filters, asset_filters, workflow_filters, skill_filters)
       when map_size(filters) > 0 or map_size(asset_filters) > 0 or
              map_size(workflow_filters) > 0 or map_size(skill_filters) > 0 do
    "memory_core_structured_lookup"
  end

  defp retrieval_path(_filters, _asset_filters, _workflow_filters, _skill_filters) do
    "memory_core_fact_memory_workflow_skill_lookup"
  end

  defp skill_package_lifecycle_filter(opts) do
    if Keyword.get(opts, :include_draft_skills, false) do
      "skill_packages.active_including_drafts"
    else
      "skill_packages.approved_enabled_active"
    end
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

  defp decode_map(nil), do: %{}
  defp decode_map(""), do: %{}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_map(value) when is_map(value), do: value
  defp decode_map(_value), do: %{}

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp link_type?(%{type: type}, expected), do: type == expected
  defp link_type?(%{"type" => type}, expected), do: type == expected
  defp link_type?(_, _expected), do: false

  defp ref(type, id), do: %{type: type, id: id}

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp string_opt(opts, key, default), do: Keyword.get(opts, key, default) |> to_string()

  defp string_opt_or_nil(opts, key), do: string_or_nil(Keyword.get(opts, key))

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: to_string(value)
end
