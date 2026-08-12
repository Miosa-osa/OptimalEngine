defmodule OptimalEngine.DataQualityScheduler do
  @moduledoc "Periodic, non-mutating data-quality drift detector."

  use GenServer
  require Logger

  alias OptimalEngine.{DataSteward, Store}
  alias OptimalEngine.MemoryCore.ID

  @day_ms 86_400_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def force_run, do: GenServer.call(__MODULE__, :force_run, 120_000)

  @impl true
  def init(opts) do
    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:optimal_engine, :data_quality_scheduler_enabled, true)
      )

    interval =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:optimal_engine, :data_quality_scheduler_interval_ms, @day_ms)
      )

    if enabled, do: Process.send_after(self(), :tick, min(interval, 300_000))
    {:ok, %{enabled: enabled, interval_ms: interval}}
  end

  @impl true
  def handle_call(:force_run, _from, state), do: {:reply, run_all(), state}

  @impl true
  def handle_info(:tick, state) do
    _ = run_all()
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  defp run_all do
    with {:ok, rows} <-
           Store.raw_query(
             "SELECT tenant_id, id FROM workspaces WHERE status='active' ORDER BY id",
             []
           ) do
      results = Enum.map(rows, fn [tenant, workspace] -> snapshot(tenant, workspace) end)
      {:ok, %{workspaces: length(rows), results: results}}
    end
  end

  defp snapshot(tenant, workspace) do
    with {:ok, dashboard} <- DataSteward.dashboard(workspace, tenant_id: tenant),
         {:ok, previous} <- previous_score(tenant, workspace) do
      score = dashboard.context_health.score

      regressions =
        if is_number(previous) and score < previous, do: [%{from: previous, to: score}], else: []

      Store.raw_execute(
        "INSERT INTO data_quality_snapshots (id,tenant_id,workspace_id,health_score,health_status,dashboard,detected_regressions) VALUES (?1,?2,?3,?4,?5,?6,?7)",
        [
          ID.random_id("quality"),
          tenant,
          workspace,
          score,
          dashboard.context_health.status,
          Jason.encode!(dashboard),
          Jason.encode!(regressions)
        ]
      )

      %{workspace_id: workspace, score: score, regressions: regressions, ok: true}
    else
      {:error, reason} ->
        Logger.warning("[DataQualityScheduler] workspace=#{workspace} failed: #{inspect(reason)}")
        %{workspace_id: workspace, ok: false, error: inspect(reason)}
    end
  end

  defp previous_score(tenant, workspace) do
    case Store.raw_query(
           "SELECT health_score FROM data_quality_snapshots WHERE tenant_id=?1 AND workspace_id=?2 ORDER BY created_at DESC LIMIT 1",
           [tenant, workspace]
         ) do
      {:ok, [[score]]} -> {:ok, score}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end
end
