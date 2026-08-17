defmodule OptimalEngine.ContextHealth do
  @moduledoc "Read-only health audit for retrieval, routing, freshness, and memory projections."

  alias OptimalEngine.Store

  def run(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id, "default")

    checks = [
      check("memory_projection", fn -> memory_projection(workspace_id) end),
      check("routing_concentration", &routing_concentration/0),
      check("pending_claims", fn -> pending_claims(workspace_id) end),
      check("workspace_integrity", fn -> workspace_integrity(workspace_id) end),
      check("fixture_visibility", &fixture_visibility/0),
      check("freshness", fn -> freshness(workspace_id) end)
    ]

    score =
      checks
      |> Enum.map(& &1.score)
      |> then(fn scores ->
        if scores == [], do: 0, else: round(Enum.sum(scores) / length(scores))
      end)

    %{
      ok: Enum.all?(checks, & &1.ok),
      status: status(score),
      score: score,
      workspace_id: workspace_id,
      checks: checks
    }
  end

  defp check(name, fun) do
    case fun.() do
      {ok, score, detail} -> %{name: name, ok: ok, score: score, detail: detail}
    end
  rescue
    error -> %{name: name, ok: false, score: 0, detail: Exception.message(error)}
  end

  defp memory_projection(workspace_id) do
    {:ok, [[durable]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM memories WHERE workspace_id = ?1 AND is_latest = 1 AND is_forgotten = 0",
        [workspace_id]
      )

    {:ok, [[searchable]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM memories_fts JOIN memories m ON m.rowid = memories_fts.rowid WHERE m.workspace_id = ?1 AND m.is_latest = 1 AND m.is_forgotten = 0",
        [workspace_id]
      )

    ok = searchable == durable
    {ok, if(ok, do: 100, else: 35), %{durable_memories: durable, searchable_memories: searchable}}
  end

  defp routing_concentration do
    {:ok, [[total]]} =
      Store.raw_query("SELECT COUNT(*) FROM contexts WHERE archived_at IS NULL", [])

    {:ok, [[generic]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE archived_at IS NULL AND workspace_id = 'default:knowledge-intake'",
        []
      )

    {:ok, [[queued]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE archived_at IS NULL AND workspace_id = 'default:knowledge-intake' AND json_extract(metadata, '$.routing_review.state') IN ('review', 'unresolved')",
        []
      )

    ratio = if total == 0, do: 0.0, else: generic / total
    unqueued = max(0, generic - queued)
    routed_score = max(0, round(100 * (1 - ratio)))
    queue_coverage = if generic == 0, do: 100, else: round(100 * queued / generic)
    score = round((routed_score + queue_coverage) / 2)

    {ratio <= 0.5, score,
     %{
       generic: generic,
       queued_for_review: queued,
       unqueued: unqueued,
       total: total,
       ratio: Float.round(ratio, 3)
     }}
  end

  defp pending_claims(workspace_id) do
    {:ok, [[actionable, memory_candidates]]} =
      Store.raw_query(
        """
        SELECT
          SUM(CASE WHEN claim_type != 'memory_candidate' THEN 1 ELSE 0 END),
          SUM(CASE WHEN claim_type = 'memory_candidate' THEN 1 ELSE 0 END)
        FROM claims
        WHERE workspace_id = ?1 AND lifecycle_state = 'pending'
        """,
        [workspace_id]
      )

    actionable = actionable || 0
    memory_candidates = memory_candidates || 0
    score = max(0, 100 - actionable)

    {actionable <= 25, score,
     %{
       actionable: actionable,
       memory_candidates: memory_candidates,
       total: actionable + memory_candidates
     }}
  end

  defp workspace_integrity(workspace_id) do
    {:ok, [[count]]} =
      Store.raw_query(
        """
        SELECT COUNT(*)
        FROM (
          SELECT DISTINCT workspace_id FROM contexts WHERE archived_at IS NULL AND workspace_id = ?1
          UNION SELECT DISTINCT workspace_id FROM memories WHERE is_latest = 1 AND is_forgotten = 0 AND workspace_id = ?1
          UNION SELECT DISTINCT workspace_id FROM claims WHERE workspace_id = ?1
        ) owned
        LEFT JOIN workspaces registered ON registered.id = owned.workspace_id
        WHERE registered.id IS NULL
        """,
        [workspace_id]
      )

    {count == 0, if(count == 0, do: 100, else: 0), %{orphan_workspace_scopes: count}}
  end

  defp fixture_visibility do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE archived_at IS NULL AND (path LIKE '/var/folders/%/optimal_%test_%' OR path LIKE '/tmp/optimal_%test_%' OR node = 'test' OR node LIKE 'node-a-%' OR node LIKE 'node-b-%' OR title LIKE 'Backfill %' OR title LIKE 'bf task %')",
        []
      )

    {count == 0, if(count == 0, do: 100, else: 0), %{visible: count}}
  end

  defp freshness(workspace_id) do
    {:ok, [[latest]]} =
      Store.raw_query(
        "SELECT MAX(updated_at) FROM memories WHERE workspace_id = ?1 AND is_latest = 1 AND is_forgotten = 0",
        [workspace_id]
      )

    age_days = age_days(latest)
    score = if is_nil(age_days), do: 0, else: max(0, 100 - age_days * 10)
    {not is_nil(age_days) and age_days <= 7, score, %{latest_memory_at: latest, age_days: age_days}}
  end

  defp age_days(nil), do: nil

  defp age_days(value) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      max(0, DateTime.diff(DateTime.utc_now(), datetime, :day))
    else
      _ -> nil
    end
  end

  defp status(score) when score >= 90, do: "healthy"
  defp status(score) when score >= 60, do: "degraded"
  defp status(_), do: "unhealthy"
end
