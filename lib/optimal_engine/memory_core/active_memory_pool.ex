defmodule OptimalEngine.MemoryCore.ActiveMemoryPool do
  @moduledoc """
  Task-scoped working memory for humans, agents, and tools.

  Pool observations are not accepted truth. Publishing an observation preserves
  it as a Source Package and creates a pending Claim that can later be reviewed
  through the normal truth lifecycle.
  """

  alias OptimalEngine.MemoryCore.{
    ID,
    KnowledgeLifecycle,
    RetrievalCoordinator,
    SourcePackage,
    Store
  }

  alias OptimalEngine.Store, as: BaseStore

  @spec open(keyword()) :: {:ok, map()} | {:error, term()}
  def open(opts \\ []) do
    now = timestamp()
    tenant_id = string_opt(opts, :tenant_id, "default")
    workspace_id = string_opt(opts, :workspace_id, "default")
    task_type = string_or_nil(Keyword.get(opts, :task_type))
    subject_anchor = string_or_nil(Keyword.get(opts, :subject_anchor))

    pool = %{
      id:
        ID.content_id("amp", [
          tenant_id,
          ":",
          workspace_id,
          ":",
          task_type || "task",
          ":",
          subject_anchor || "general",
          ":",
          now
        ]),
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      pool_scope: Keyword.get(opts, :pool_scope, %{}),
      task_type: task_type,
      subject_anchor: subject_anchor,
      time_mode: string_opt(opts, :time_mode, "current_valid"),
      loaded_context_links: [],
      source_package_links: [],
      evidence_links: [],
      context_package_links: [],
      promotion_candidate_links: [],
      context_confidence_summary: %{},
      context_precision_summary: %{},
      member_links: Keyword.get(opts, :member_links, []),
      agent_links: Keyword.get(opts, :agent_links, []),
      tool_links: Keyword.get(opts, :tool_links, []),
      membership_policy: Keyword.get(opts, :membership_policy, %{}),
      delegation_chain_links: Keyword.get(opts, :delegation_chain_links, []),
      lifecycle_state: "open",
      refresh_state: "fresh",
      archive_state: "active",
      opened_at: now,
      closed_at: nil,
      transaction_time_start: now,
      access_policy_id: string_or_nil(Keyword.get(opts, :access_policy_id)),
      security_labels: Keyword.get(opts, :security_labels, []),
      partition_ids: Keyword.get(opts, :partition_ids, []),
      audit_event_links: Keyword.get(opts, :audit_event_links, []),
      policy_version: string_or_nil(Keyword.get(opts, :policy_version)),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    with :ok <- Store.insert_active_memory_pool(pool) do
      {:ok, pool}
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(pool_id) when is_binary(pool_id) do
    sql = """
    SELECT id, tenant_id, workspace_id, pool_scope, task_type, subject_anchor,
           time_mode, loaded_context_links, source_package_links, evidence_links,
           context_package_links, promotion_candidate_links,
           context_confidence_summary, context_precision_summary, member_links,
           agent_links, tool_links, membership_policy, delegation_chain_links,
           lifecycle_state, refresh_state, archive_state, opened_at, closed_at,
           valid_time_start, valid_time_end, transaction_time_start,
           transaction_time_end, stale_after, access_policy_id, security_labels,
           partition_ids, audit_event_links, policy_version, metadata
    FROM active_memory_pools
    WHERE id = ?1
    """

    case BaseStore.raw_query(sql, [pool_id]) do
      {:ok, [row]} -> {:ok, pool_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  @spec load_context_package(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_context_package(pool_id, context_package, _opts \\ [])
      when is_binary(pool_id) and is_map(context_package) do
    with {:ok, pool} <- get(pool_id) do
      package_ref = ref("context_package", context_package.id)

      updated =
        pool
        |> put_unique(:context_package_links, package_ref)
        |> put_unique(:loaded_context_links, package_ref)
        |> merge_unique(:source_package_links, Map.get(context_package, :source_package_links, []))
        |> merge_unique(:evidence_links, Map.get(context_package, :evidence_links, []))
        |> Map.put(
          :context_confidence_summary,
          Map.get(context_package, :package_confidence_summary, %{})
        )
        |> Map.put(
          :context_precision_summary,
          Map.get(context_package, :package_precision_summary, %{})
        )
        |> Map.put(:refresh_state, "fresh")

      with :ok <- Store.update_active_memory_pool(updated) do
        {:ok, updated}
      end
    end
  end

  @spec refresh_context_packages(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh_context_packages(pool_id, opts \\ []) when is_binary(pool_id) and is_list(opts) do
    with {:ok, pool} <- get(pool_id) do
      base_opts = [
        tenant_id: pool.tenant_id,
        workspace_id: pool.workspace_id,
        active_memory_pool_id: pool.id
      ]

      refresh_opts = Keyword.merge(base_opts, opts)

      pool.context_package_links
      |> Enum.reduce_while({:ok, %{refreshed: [], skipped: [], errors: []}}, fn link, {:ok, acc} ->
        case refresh_pool_context_link(pool.id, link, refresh_opts) do
          {:ok, :skipped, package_id} ->
            {:cont, {:ok, put_in(acc.skipped, acc.skipped ++ [package_id])}}

          {:ok, refreshed_package} ->
            {:cont, {:ok, put_in(acc.refreshed, acc.refreshed ++ [refreshed_package])}}

          {:error, reason} ->
            if Keyword.get(opts, :continue_on_error, true) do
              {:cont, {:ok, put_in(acc.errors, acc.errors ++ [%{link: link, reason: reason}])}}
            else
              {:halt, {:error, {link, reason}}}
            end
        end
      end)
      |> case do
        {:ok, result} ->
          with {:ok, refreshed_pool} <- get(pool_id) do
            {:ok,
             %{
               pool: refreshed_pool,
               refreshed_context_packages: result.refreshed,
               skipped_context_package_ids: result.skipped,
               errors: result.errors
             }}
          end

        other ->
          other
      end
    end
  end

  defp refresh_pool_context_link(pool_id, link, refresh_opts) do
    package_id = link_id(link)

    case RetrievalCoordinator.refresh_context_package(package_id, refresh_opts) do
      {:ok, refreshed_package} ->
        with {:ok, _pool} <- load_context_package(pool_id, refreshed_package) do
          {:ok, refreshed_package}
        end

      {:error, :context_package_not_stale} ->
        {:ok, :skipped, package_id}

      other ->
        other
    end
  end

  @spec publish_observation(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish_observation(pool_id, observation_text, opts \\ [])
      when is_binary(pool_id) and is_binary(observation_text) do
    with {:ok, pool} <- get(pool_id) do
      source =
        SourcePackage.from_text(observation_text,
          tenant_id: pool.tenant_id,
          workspace_id: pool.workspace_id,
          source_type: string_opt(opts, :source_type, "pool_observation"),
          source_class: "text",
          source_system: "active_memory_pool",
          source_uri: "optimal://active-memory-pools/#{pool.id}/observations",
          trust_label: string_opt(opts, :trust_label, "unreviewed"),
          access_policy_id: pool.access_policy_id,
          security_labels: pool.security_labels,
          partition_ids: pool.partition_ids,
          created_by: Keyword.get(opts, :actor_id),
          metadata: %{
            active_memory_pool_id: pool.id,
            observation_kind: string_opt(opts, :observation_kind, "observation")
          }
        )

      with {:ok, claim} <-
             KnowledgeLifecycle.extract_claim(source,
               claim_text: string_opt(opts, :claim_text, observation_text),
               claim_type: "observation",
               subject_anchor: Keyword.get(opts, :subject_anchor) || pool.subject_anchor,
               action_class: Keyword.get(opts, :action_class),
               object_anchor: Keyword.get(opts, :object_anchor),
               aggregate_confidence: Keyword.get(opts, :aggregate_confidence, 0.5),
               aggregate_precision: Keyword.get(opts, :aggregate_precision, 0.5),
               actor_id: Keyword.get(opts, :actor_id),
               metadata: %{active_memory_pool_id: pool.id}
             ) do
        updated =
          pool
          |> put_unique(:source_package_links, ref("source_package", source.id))
          |> put_unique(:evidence_links, ref("source_package", source.id))
          |> put_unique(:promotion_candidate_links, ref("claim", claim.id))
          |> Map.put(:refresh_state, "dirty")

        with :ok <- Store.update_active_memory_pool(updated) do
          {:ok, %{pool: updated, source_package: source, pending_claim: claim}}
        end
      end
    end
  end

  @spec close(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close(pool_id, opts \\ []) when is_binary(pool_id) do
    with {:ok, pool} <- get(pool_id) do
      now = timestamp()

      updated =
        pool
        |> Map.put(:lifecycle_state, string_opt(opts, :lifecycle_state, "closed"))
        |> Map.put(:archive_state, string_opt(opts, :archive_state, "archived"))
        |> Map.put(:closed_at, now)
        |> Map.put(:transaction_time_end, now)
        |> Map.put(:metadata, Map.merge(pool.metadata, %{close_reason: Keyword.get(opts, :reason)}))

      with :ok <- Store.update_active_memory_pool(updated) do
        {:ok, updated}
      end
    end
  end

  defp pool_from_row([
         id,
         tenant_id,
         workspace_id,
         pool_scope,
         task_type,
         subject_anchor,
         time_mode,
         loaded_context_links,
         source_package_links,
         evidence_links,
         context_package_links,
         promotion_candidate_links,
         context_confidence_summary,
         context_precision_summary,
         member_links,
         agent_links,
         tool_links,
         membership_policy,
         delegation_chain_links,
         lifecycle_state,
         refresh_state,
         archive_state,
         opened_at,
         closed_at,
         valid_time_start,
         valid_time_end,
         transaction_time_start,
         transaction_time_end,
         stale_after,
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
      pool_scope: decode_map(pool_scope),
      task_type: task_type,
      subject_anchor: subject_anchor,
      time_mode: time_mode,
      loaded_context_links: decode_list(loaded_context_links),
      source_package_links: decode_list(source_package_links),
      evidence_links: decode_list(evidence_links),
      context_package_links: decode_list(context_package_links),
      promotion_candidate_links: decode_list(promotion_candidate_links),
      context_confidence_summary: decode_map(context_confidence_summary),
      context_precision_summary: decode_map(context_precision_summary),
      member_links: decode_list(member_links),
      agent_links: decode_list(agent_links),
      tool_links: decode_list(tool_links),
      membership_policy: decode_map(membership_policy),
      delegation_chain_links: decode_list(delegation_chain_links),
      lifecycle_state: lifecycle_state,
      refresh_state: refresh_state,
      archive_state: archive_state,
      opened_at: opened_at,
      closed_at: closed_at,
      valid_time_start: valid_time_start,
      valid_time_end: valid_time_end,
      transaction_time_start: transaction_time_start,
      transaction_time_end: transaction_time_end,
      stale_after: stale_after,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      audit_event_links: decode_list(audit_event_links),
      policy_version: policy_version,
      metadata: decode_map(metadata)
    }
  end

  defp put_unique(pool, key, value), do: merge_unique(pool, key, [value])

  defp link_id(%{id: id}), do: id
  defp link_id(%{"id" => id}), do: id
  defp link_id(id) when is_binary(id), do: id

  defp merge_unique(pool, key, values) do
    Map.update(pool, key, Enum.uniq(values), fn existing ->
      (existing ++ values) |> Enum.map(&normalize_link/1) |> Enum.uniq()
    end)
  end

  defp decode_map(nil), do: %{}
  defp decode_map(""), do: %{}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_map(value) when is_map(value), do: value
  defp decode_map(_), do: %{}

  defp decode_list(nil), do: []
  defp decode_list(""), do: []

  defp decode_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> Enum.map(list, &normalize_link/1)
      {:ok, other} -> [other]
      _ -> []
    end
  end

  defp decode_list(value) when is_list(value), do: Enum.map(value, &normalize_link/1)
  defp decode_list(value), do: [value]

  defp normalize_link(%{"type" => type, "id" => id}), do: %{type: type, id: id}
  defp normalize_link(link), do: link

  defp ref(type, id), do: %{type: type, id: id}

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp string_opt(opts, key, default), do: Keyword.get(opts, key, default) |> to_string()

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: to_string(value)
end
