defmodule OptimalEngine.Viability do
  @moduledoc """
  Viability of a workspace or an org, computed from what is in the Engine:
  Beer's five systems (`Viability.Systems`), the six proxy metrics and the
  requisite variety ratio of Signal Theory (`Viability.Metrics`), trajectory
  alerts (`Viability.Trajectory`), and the System 3* audit
  (`Viability.Audit`).

  `report/2` is computed live. `snapshot/3` stores a day's metrics and
  system states in `viability_reports`, `history/3` reads them back, and the
  scheduler (`Viability.Scheduler`) keeps one snapshot per scope per day
  (today's is refreshed each pass), backfills up to 30 days the first time,
  and runs the weekly audit.
  Nothing here blocks ingest: it reads and annotates.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Viability.{Audit, Metrics, Systems, Trajectory}
  alias OptimalEngine.Workspace

  @window_days 7
  @history_days 30
  @org "*"

  @doc """
  The viability report. Options: `:workspace_ids` (a list; for an org, the
  workspaces to include, nil for all), `:scope` (`:workspace` or `:org`),
  `:today`.
  """
  @spec report(String.t(), keyword()) :: map()
  def report(tenant_id, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    scope = Keyword.get(opts, :scope, :workspace)
    workspace_ids = workspace_ids(tenant_id, scope, opts[:workspace_ids])
    window = window(today)
    metrics = Metrics.compute(tenant_id, workspace_ids, window)
    systems = Systems.evaluate(tenant_id, workspace_ids, scope, today)

    report = %{
      scope: if(scope == :org, do: "org", else: "workspace"),
      tenant_id: tenant_id,
      workspace_ids: workspace_ids,
      as_of: Date.to_iso8601(today),
      window: metrics.window,
      signals_received: metrics.signals_received,
      summary: summary(systems),
      systems: systems,
      metrics: metrics.metrics,
      variety: metrics.variety,
      trajectory: Trajectory.analyze(tenant_id, workspace_ids, today)
    }

    if scope == :org do
      Map.put(report, :workspaces, Enum.map(workspace_ids, &workspace_line(tenant_id, &1, today)))
    else
      report
    end
  end

  @doc """
  Stores the metrics and system states for `scope_key` (a workspace id, or
  `"*"` for the org) on `date`. `backfilled: true` marks a retrospective day.
  """
  @spec snapshot(String.t(), String.t(), keyword()) :: {:ok, map()}
  def snapshot(tenant_id, scope_key, opts \\ []) do
    date = Keyword.get(opts, :today, Date.utc_today())
    backfilled = Keyword.get(opts, :backfilled, false)
    {scope, ids} = scope_of(scope_key)
    workspace_ids = workspace_ids(tenant_id, scope, ids)
    metrics = Metrics.compute(tenant_id, workspace_ids, window(date))

    # A backfilled day has no record of how the systems stood then.
    systems =
      if backfilled do
        nil
      else
        tenant_id
        |> Systems.evaluate(workspace_ids, scope, date)
        |> Map.new(&{&1.id, &1.status})
      end

    record = %{
      period: Date.to_iso8601(date),
      signals_received: metrics.signals_received,
      metrics: Map.new(metrics.metrics, &{&1.name, &1.value}),
      r: metrics.variety.r,
      band: metrics.variety.band,
      systems: systems,
      backfilled: backfilled
    }

    {:ok, _} =
      Store.raw_query(
        """
        INSERT OR REPLACE INTO viability_reports (tenant_id, scope, period, report, backfilled)
        VALUES (?1, ?2, ?3, ?4, ?5)
        """,
        [tenant_id, scope_key, record.period, Jason.encode!(record), if(backfilled, do: 1, else: 0)]
      )

    {:ok, record}
  end

  @doc "Stored snapshots for `scope_key` over the last `days` days, oldest first."
  @spec history(String.t(), String.t(), pos_integer(), Date.t()) :: map()
  def history(tenant_id, scope_key, days \\ @history_days, today \\ Date.utc_today()) do
    days = days |> max(1) |> min(400)
    from = today |> Date.add(-(days - 1)) |> Date.to_iso8601()

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT report FROM viability_reports
        WHERE tenant_id = ?1 AND scope = ?2 AND period >= ?3 AND period <= ?4
        ORDER BY period
        """,
        [tenant_id, scope_key, from, Date.to_iso8601(today)]
      )

    snapshots = Enum.map(rows, fn [json] -> Jason.decode!(json) end)
    stored = MapSet.new(snapshots, & &1["period"])

    missing =
      for offset <- (days - 1)..0//-1,
          day = today |> Date.add(-offset) |> Date.to_iso8601(),
          not MapSet.member?(stored, day),
          do: day

    %{scope: scope_key, days: days, snapshots: snapshots, missing: missing}
  end

  @doc """
  Refreshes today's snapshot for `scope_key` and backfills missing days
  within the last `days` (default 30). Returns how many days were written.
  """
  @spec catch_up(String.t(), String.t(), keyword()) :: {:ok, non_neg_integer()}
  def catch_up(tenant_id, scope_key, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    days = Keyword.get(opts, :days, @history_days)
    %{missing: missing} = history(tenant_id, scope_key, days, today)
    today_iso = Date.to_iso8601(today)

    # Past days are written once; today is refreshed on every pass.
    days_to_write = Enum.reject(missing, &(&1 == today_iso)) ++ [today_iso]

    Enum.each(days_to_write, fn day ->
      date = Date.from_iso8601!(day)
      snapshot(tenant_id, scope_key, today: date, backfilled: day != today_iso)
    end)

    {:ok, length(days_to_write)}
  end

  @doc """
  The scheduled pass: for every tenant, every active workspace and the org,
  catch up the daily snapshots and run this week's audit where none ran.
  """
  @spec run_due(Date.t()) :: %{snapshots: non_neg_integer(), audits: non_neg_integer()}
  def run_due(today \\ Date.utc_today()) do
    {:ok, tenants} = Tenant.list()

    Enum.reduce(tenants, %{snapshots: 0, audits: 0}, fn tenant, acc ->
      workspace_ids = workspace_ids(tenant.id, :org, nil)

      written =
        Enum.reduce([@org | workspace_ids], 0, fn scope_key, n ->
          {:ok, count} = catch_up(tenant.id, scope_key, today: today)
          n + count
        end)

      audits =
        Enum.count(workspace_ids, fn workspace_id ->
          if audited?(tenant.id, workspace_id, today) do
            false
          else
            {:ok, result} = Audit.run(tenant.id, workspace_id, today: today)
            result.sampled > 0
          end
        end)

      %{snapshots: acc.snapshots + written, audits: acc.audits + audits}
    end)
  end

  @doc """
  Marks cross-reference copies indexed before the classifier kept
  `cross_ref_from`: reads the frontmatter of each Signal file on disk and
  records the marker, so a Signal routed to two nodes counts once. Run once
  after upgrading an Engine with existing data. Returns how many were marked.
  """
  @spec repair_cross_refs() :: {:ok, %{checked: non_neg_integer(), marked: non_neg_integer()}}
  def repair_cross_refs do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, path FROM contexts
        WHERE type = 'signal' AND path LIKE '%/signals/%'
          AND (CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.cross_ref_from') END) IS NULL
        """,
        []
      )

    marked =
      Enum.count(rows, fn [id, path] ->
        with {:ok, head} <- read_head(path),
             %{"cross_ref_from" => from} <-
               OptimalEngine.Pipeline.Classifier.frontmatter_metadata(head) do
          {:ok, _} =
            Store.raw_query(
              "UPDATE contexts SET metadata = json_set(CASE WHEN json_valid(metadata) THEN metadata ELSE '{}' END, '$.cross_ref_from', ?2) WHERE id = ?1",
              [id, from]
            )

          true
        else
          _ -> false
        end
      end)

    {:ok, %{checked: length(rows), marked: marked}}
  end

  defp read_head(path) do
    case File.open(path, [:read]) do
      {:ok, file} ->
        head = IO.binread(file, 4_096)
        File.close(file)
        if is_binary(head), do: {:ok, head}, else: :error

      _ ->
        :error
    end
  end

  @doc "The 7-day window ending on `today` (inclusive)."
  @spec window(Date.t()) :: %{from: Date.t(), to: Date.t()}
  def window(today), do: %{from: Date.add(today, -(@window_days - 1)), to: Date.add(today, 1)}

  @doc "The scope key for the org."
  @spec org() :: String.t()
  def org, do: @org

  # ---------------------------------------------------------------------------

  defp summary(systems) do
    counts = Enum.frequencies_by(systems, & &1.status)
    missing = Map.get(counts, "missing", 0)
    degraded = Map.get(counts, "degraded", 0)

    verdict =
      cond do
        systems == [] -> "no_data"
        missing >= 2 -> "not_viable"
        missing == 1 or degraded > 0 -> "at_risk"
        true -> "viable"
      end

    %{
      verdict: verdict,
      present: Map.get(counts, "present", 0),
      degraded: degraded,
      missing: missing,
      predicted_failures:
        for system <- systems, system[:predicted_failure] do
          Map.merge(%{system: system.id, status: system.status}, system.predicted_failure)
        end
    }
  end

  defp workspace_line(tenant_id, workspace_id, today) do
    systems = Systems.evaluate(tenant_id, [workspace_id], :workspace, today)

    %{
      workspace_id: workspace_id,
      verdict: summary(systems).verdict,
      systems: Map.new(systems, &{&1.id, &1.status})
    }
  end

  defp scope_of(@org), do: {:org, nil}
  defp scope_of(workspace_id), do: {:workspace, [workspace_id]}

  defp workspace_ids(_tenant_id, :workspace, ids) when is_list(ids), do: ids

  defp workspace_ids(tenant_id, :org, allowed) do
    {:ok, workspaces} = Workspace.list(tenant_id: tenant_id, status: :active, limit: 10_000)
    ids = Enum.map(workspaces, & &1.id)
    if is_list(allowed), do: Enum.filter(ids, &(&1 in allowed)), else: ids
  end

  defp workspace_ids(_tenant_id, :workspace, _ids), do: []

  defp audited?(tenant_id, workspace_id, today) do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM audit_samples WHERE tenant_id = ?1 AND workspace_id = ?2 AND period = ?3",
        [tenant_id, workspace_id, Audit.period(today)]
      )

    count > 0
  end
end
