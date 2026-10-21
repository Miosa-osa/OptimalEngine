defmodule OptimalEngine.ReviewQueue do
  @moduledoc "Evidence-preserving review interface for claim and routing decisions."

  alias OptimalEngine.{CorpusOrganizer, MemoryCore, Store}
  alias OptimalEngine.Viability.Audit

  def claims(workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    with {:ok, claims} <- MemoryCore.pending_claims(workspace_id: workspace_id) do
      actionable = Enum.reject(claims, &memory_candidate?/1)
      {:ok, Enum.take(actionable, limit)}
    end
  end

  def decide_claim(id, decision, opts \\ []) when decision in [:accept, :reject] do
    case decision do
      :accept -> MemoryCore.promote_claim(id, opts)
      :reject -> MemoryCore.reject_claim(id, opts)
    end
  end

  @doc """
  Records in the routing review queue of a tenant's intake workspace, with
  the state `:state` (default `"review"`), newest first. Options: `:tenant_id`
  (required), `:state`, `:limit`.
  """
  def routing(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    limit = Keyword.get(opts, :limit, 25)
    state = Keyword.get(opts, :state, "review")

    case Store.raw_query(
           """
           SELECT id, title, l0_abstract, json_extract(metadata, '$.routing_review')
           FROM contexts
           WHERE tenant_id = ?1 AND workspace_id = ?2 AND archived_at IS NULL
             AND json_extract(metadata, '$.routing_review.state') = ?3
           ORDER BY modified_at DESC LIMIT ?4
           """,
           [tenant_id, CorpusOrganizer.source_workspace(tenant_id), state, limit]
         ) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [id, title, abstract, review] ->
           %{id: id, title: title, abstract: abstract, review: decode(review)}
         end)}

      error ->
        error
    end
  end

  @doc """
  Accepts a routing review entry, filing the record into
  `target_workspace_id`, or rejects it. Options: `:tenant_id` (required),
  `:actor_id`.

  Only a record of the tenant, in the tenant's intake workspace, can be
  decided (`{:error, :not_found_or_not_in_intake}`), and the target must be
  an active workspace of the tenant (`{:error, :target_workspace_not_registered}`).
  """
  def decide_route(id, decision, target_workspace_id, opts)

  def decide_route(id, :accept, target_workspace_id, opts) do
    CorpusOrganizer.move_context(id, target_workspace_id,
      tenant_id: Keyword.fetch!(opts, :tenant_id),
      reviewed_by: Keyword.get(opts, :actor_id, "unknown")
    )
  end

  def decide_route(id, :reject, _target_workspace_id, opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    actor_id = Keyword.get(opts, :actor_id, "unknown")
    intake = CorpusOrganizer.source_workspace(tenant_id)

    Store.transaction(fn txn ->
      case Store.txn_execute(
             txn,
             """
             UPDATE contexts SET metadata = json_set(
               COALESCE(metadata, '{}'), '$.routing_review.state', 'rejected',
               '$.routing_review.reviewed_at', datetime('now'),
               '$.routing_review.reviewed_by', ?2
             ) WHERE id = ?1 AND tenant_id = ?3 AND workspace_id = ?4 AND archived_at IS NULL
             """,
             [id, actor_id, tenant_id, intake]
           ) do
        {:ok, 0} -> {:error, :not_found_or_not_in_intake}
        {:ok, _changed} -> {:ok, %{id: id, state: "rejected"}}
        {:error, _} = error -> error
      end
    end)
    |> tap(fn result ->
      # The read cache holds the record as it was before the decision.
      if match?({:ok, _}, result), do: Store.evict_cached([id])
    end)
  end

  @doc "Flagged System 3* audit samples in `workspace_ids`."
  def audits(tenant_id, workspace_ids, opts \\ []) do
    {:ok, Audit.list(tenant_id, workspace_ids, Keyword.put(opts, :state, "flagged"))}
  end

  @doc "Confirms or dismisses a flagged audit sample."
  def decide_audit(tenant_id, id, decision, opts \\ []) when decision in [:confirm, :dismiss] do
    Audit.review(
      tenant_id,
      id,
      Atom.to_string(decision),
      Keyword.get(opts, :actor_id, "unknown"),
      opts[:note]
    )
  end

  defp memory_candidate?(claim) do
    claim.claim_type == "memory_candidate" or
      get_in(claim.metadata || %{}, ["memory_intake", "path"]) == "memory_core_pending_claim"
  end

  defp decode(nil), do: %{}
  defp decode(value) when is_map(value), do: value

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, map} -> map
      _ -> %{}
    end
  end
end
