defmodule OptimalEngine.MemoryCore.RetrievalCoordinator do
  @moduledoc """
  First governed recall slice for Memory Core.

  The coordinator returns a Context Package instead of loose search chunks. This
  first implementation is intentionally narrow: it reads accepted Facts and
  current Memory Objects in a workspace, applies basic partition/security
  filtering, writes a `context_packages` row, and returns the structured package.
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

    with {:ok, facts} <- fetch_facts(workspace_id, query, limit * 2),
         {:ok, memories} <- fetch_memory_objects(workspace_id, query, limit * 2) do
      authorized_facts =
        facts
        |> Enum.filter(&authorized?(&1, allowed_partitions, allowed_security_labels))
        |> Enum.take(limit)

      authorized_memories =
        memories
        |> Enum.filter(&authorized?(&1, allowed_partitions, allowed_security_labels))
        |> Enum.take(limit)

      redacted =
        length(facts) - length(authorized_facts) +
          (length(memories) - length(authorized_memories))

      fact_links = Enum.map(authorized_facts, &ref("fact", &1.id))
      memory_links = Enum.map(authorized_memories, &ref("memory_object", &1.id))

      source_links =
        collect_unique_links(authorized_facts ++ authorized_memories, :source_package_links)

      evidence_links =
        collect_unique_links(authorized_facts ++ authorized_memories, :evidence_links)

      returned_links = fact_links ++ memory_links

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
        workflow_links: [],
        skill_package_links: [],
        source_package_links: source_links,
        evidence_links: evidence_links,
        retrieval_plan: %{
          query: query,
          path: "memory_core_fact_memory_lookup",
          filters: %{
            workspace_id: workspace_id,
            lifecycle: ["facts.accepted", "memory_objects.current"],
            time_mode: time_mode
          },
          limit: limit
        },
        package_confidence_summary:
          summarize_score(authorized_facts ++ authorized_memories, :confidence),
        package_precision_summary:
          summarize_score(authorized_facts ++ authorized_memories, :precision),
        filtered_object_summary: %{
          candidate_facts: length(facts),
          returned_facts: length(authorized_facts),
          candidate_memory_objects: length(memories),
          returned_memory_objects: length(authorized_memories),
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
        security_labels: merge_lists(authorized_facts ++ authorized_memories, :security_labels),
        partition_ids: merge_lists(authorized_facts ++ authorized_memories, :partition_ids),
        metadata: %{
          query: query,
          answer_surface: "context_package"
        }
      }

      with :ok <- Store.insert_context_package(context_package) do
        {:ok,
         Map.merge(context_package, %{
           facts: authorized_facts,
           memory_objects: authorized_memories
         })}
      end
    end
  end

  defp fetch_facts(workspace_id, query, limit) do
    pattern = "%#{query}%"

    sql = """
    SELECT id, tenant_id, workspace_id, fact_text, fact_type, subject_anchor,
           action_class, object_anchor, accepted_claim_ids, supporting_evidence_links,
           aggregate_confidence, aggregate_precision, access_policy_id,
           security_labels, partition_ids, lifecycle_state, valid_time_start,
           valid_time_end, stale_after
    FROM facts
    WHERE workspace_id = ?1
      AND lifecycle_state = 'accepted'
      AND (valid_time_end IS NULL OR valid_time_end >= datetime('now'))
      AND (
        fact_text LIKE ?2 OR subject_anchor LIKE ?2 OR action_class LIKE ?2
        OR object_anchor LIKE ?2 OR ?3 = ''
      )
    ORDER BY aggregate_confidence DESC, updated_at DESC
    LIMIT ?4
    """

    with {:ok, rows} <- BaseStore.raw_query(sql, [workspace_id, pattern, query, limit]) do
      {:ok, Enum.map(rows, &fact_from_row/1)}
    end
  end

  defp fetch_memory_objects(workspace_id, query, limit) do
    pattern = "%#{query}%"

    sql = """
    SELECT id, tenant_id, workspace_id, memory_type, summary, subject_anchor,
           action_class, fact_links, claim_links, source_package_links, evidence_links,
           aggregate_confidence, aggregate_precision, access_policy_id,
           security_labels, partition_ids, lifecycle_state, staleness_status,
           valid_time_start, valid_time_end, stale_after
    FROM memory_objects
    WHERE workspace_id = ?1
      AND lifecycle_state = 'current'
      AND staleness_status = 'current'
      AND (valid_time_end IS NULL OR valid_time_end >= datetime('now'))
      AND (
        summary LIKE ?2 OR subject_anchor LIKE ?2 OR action_class LIKE ?2
        OR ?3 = ''
      )
    ORDER BY salience DESC, aggregate_confidence DESC, updated_at DESC
    LIMIT ?4
    """

    with {:ok, rows} <- BaseStore.raw_query(sql, [workspace_id, pattern, query, limit]) do
      {:ok, Enum.map(rows, &memory_from_row/1)}
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
      valid_time_start: valid_time_start,
      valid_time_end: valid_time_end,
      stale_after: stale_after
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

  defp ref(type, id), do: %{type: type, id: id}

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp string_opt(opts, key, default), do: Keyword.get(opts, key, default) |> to_string()

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: to_string(value)
end
