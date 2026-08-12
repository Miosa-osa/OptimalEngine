defmodule OptimalEngine.ReviewQueue do
  @moduledoc "Evidence-preserving review interface for claim and routing decisions."

  alias OptimalEngine.{CorpusOrganizer, MemoryCore, Store}

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

  def routing(opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)
    state = Keyword.get(opts, :state, "review")

    case Store.raw_query(
           """
           SELECT id, title, l0_abstract, json_extract(metadata, '$.routing_review')
           FROM contexts
           WHERE workspace_id = 'default:knowledge-intake' AND archived_at IS NULL
             AND json_extract(metadata, '$.routing_review.state') = ?1
           ORDER BY modified_at DESC LIMIT ?2
           """,
           [state, limit]
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

  def decide_route(id, decision, target_workspace_id, opts \\ [])

  def decide_route(id, :accept, target_workspace_id, _opts) do
    CorpusOrganizer.move_context(id, target_workspace_id)
  end

  def decide_route(id, :reject, _target_workspace_id, opts) do
    actor_id = Keyword.get(opts, :actor_id, "unknown")

    Store.raw_query(
      """
      UPDATE contexts SET metadata = json_set(
        COALESCE(metadata, '{}'), '$.routing_review.state', 'rejected',
        '$.routing_review.reviewed_at', datetime('now')
        ,'$.routing_review.reviewed_by', ?2
      ) WHERE id = ?1 AND workspace_id = 'default:knowledge-intake' AND archived_at IS NULL
      """,
      [id, actor_id]
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
