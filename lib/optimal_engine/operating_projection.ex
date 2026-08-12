defmodule OptimalEngine.OperatingProjection do
  @moduledoc "Builds current, evidence-linked operating projections from durable Engine records."

  alias OptimalEngine.Store

  @active_kinds ~w(task decision close aware)

  def workspace(workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    with {:ok, memories} <- recent_memories(workspace_id, limit),
         {:ok, [[memory_count]]} <- inventory_count("memories", workspace_id),
         {:ok, [[claim_count]]} <- actionable_claim_count(workspace_id),
         {:ok, [[context_count]]} <-
           Store.raw_query(
             "SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1 AND archived_at IS NULL",
             [workspace_id]
           ) do
      commitments =
        memories
        |> Enum.filter(&(&1.kind in @active_kinds))
        |> Enum.map(&commitment(&1, workspace_id))

      {:ok,
       %{
         workspace_id: workspace_id,
         generated_at: now(),
         commitments: commitments,
         review_queue: %{actionable_claims: claim_count},
         inventory: %{
           contexts: context_count,
           memories: memory_count,
           recent_memories_sampled: length(memories)
         },
         freshness: freshness(memories),
         evidence_policy: "projection_only_human_review_required"
       }}
    end
  end

  def daily_draft(workspace_id, opts \\ []) do
    with {:ok, projection} <- workspace(workspace_id, opts) do
      lines =
        projection.commitments
        |> Enum.take(10)
        |> Enum.map_join("\n", fn item ->
          "- [ ] #{item.summary} (#{item.status}, evidence #{item.evidence_at})"
        end)

      {:ok,
       """
       # Generated Daily Draft - #{Date.utc_today()}

       > Projection from verified Engine records. Review before treating as commitment truth.

       ## Workspace

       #{workspace_id}

       ## Current Commitments and Signals

       #{if(lines == "", do: "- No current durable items found.", else: lines)}

       ## Review Queue

       - #{projection.review_queue.actionable_claims} actionable claims require evidence review.
       """
       |> String.trim()}
    end
  end

  defp recent_memories(workspace_id, limit) do
    case Store.raw_query(
           """
           SELECT id, content, metadata, created_at, updated_at
           FROM memories
           WHERE workspace_id = ?1 AND is_latest = 1 AND is_forgotten = 0
           ORDER BY COALESCE(updated_at, created_at) DESC
           LIMIT ?2
           """,
           [workspace_id, limit]
         ) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [id, content, metadata, created_at, updated_at] ->
           decoded = decode(metadata)

           %{
             id: id,
             content: content,
             kind: decoded["kind"] || "memory",
             created_at: created_at,
             updated_at: updated_at
           }
         end)}

      error ->
        error
    end
  end

  defp inventory_count("memories", workspace_id) do
    Store.raw_query(
      "SELECT COUNT(*) FROM memories WHERE workspace_id = ?1 AND is_latest = 1 AND is_forgotten = 0",
      [workspace_id]
    )
  end

  defp actionable_claim_count(workspace_id) do
    Store.raw_query(
      """
      SELECT COUNT(*) FROM claims
      WHERE workspace_id = ?1 AND lifecycle_state = 'pending'
        AND claim_type != 'memory_candidate'
      """,
      [workspace_id]
    )
  end

  defp commitment(memory, workspace_id) do
    %{
      id: memory.id,
      kind: memory.kind,
      summary: summarize(memory.content),
      status: infer_status(memory),
      owner: infer_owner(memory.content),
      evidence_at: memory.updated_at || memory.created_at,
      evidence_uri: "optimal://memory/#{workspace_id}/#{memory.id}",
      confidence: "durable_memory_not_reviewed_fact"
    }
  end

  defp infer_status(%{content: content, kind: kind} = memory) do
    normalized = String.downcase(content)

    cond do
      String.contains?(normalized, ["completed", "fixed", "shipped", "deployed", "resolved"]) ->
        "completed"

      String.contains?(normalized, ["superseded", "replaced by", "no longer current"]) ->
        "superseded"

      String.contains?(normalized, ["blocked"]) ->
        "blocked"

      String.contains?(normalized, ["waiting on", "awaiting", "pending response"]) ->
        "waiting"

      historical?(memory.updated_at || memory.created_at) ->
        "historical"

      kind == "task" ->
        "active"

      kind == "decision" ->
        "active"

      true ->
        "unknown"
    end
  end

  defp historical?(nil), do: false

  defp historical?(timestamp) do
    with {:ok, recorded_at, _offset} <- DateTime.from_iso8601(timestamp),
         age when age > 30 * 24 * 60 * 60 <- DateTime.diff(DateTime.utc_now(), recorded_at) do
      true
    else
      _ -> false
    end
  end

  defp infer_owner(content) do
    case Regex.run(~r/(?:owner|action):\s*([^.;\n]+)/i, content) do
      [_, owner] -> String.trim(owner)
      _ -> "unassigned"
    end
  end

  defp freshness([]), do: %{latest_at: nil, status: "unknown"}

  defp freshness([latest | _]) do
    %{latest_at: latest.updated_at || latest.created_at, status: "current"}
  end

  defp summarize(content) do
    content |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 240)
  end

  defp decode(nil), do: %{}
  defp decode(value) when is_map(value), do: value

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
