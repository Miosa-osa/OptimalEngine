defmodule OptimalEngine.MemoryCore.ReconstructionScheduler do
  @moduledoc """
  Periodic Adapter for associative projection refresh and path consolidation.

  Scheduling is optional. Manual and scheduled work call the same governed
  Interfaces, so the scheduler contains no second implementation.
  """

  use GenServer
  require Logger

  alias OptimalEngine.MemoryCore.{AssociativeProjection, ReconstructionLearning, ScopeEnvelope}
  alias OptimalEngine.Store

  @day_ms 86_400_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def force_run, do: GenServer.call(__MODULE__, :force_run, 120_000)

  @impl true
  def init(opts) do
    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:optimal_engine, :reconstruction_scheduler_enabled, false)
      )

    interval =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:optimal_engine, :reconstruction_scheduler_interval_ms, @day_ms)
      )

    state = %{enabled: enabled, interval_ms: interval}
    if enabled, do: Process.send_after(self(), :tick, min(interval, 300_000))
    {:ok, state}
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
    case Store.raw_query(
           "SELECT tenant_id, id FROM workspaces WHERE status = 'active' ORDER BY tenant_id, id"
         ) do
      {:ok, rows} ->
        results = Enum.map(rows, fn [tenant, workspace] -> maintain(tenant, workspace) end)
        {:ok, %{workspaces: length(rows), results: results}}

      error ->
        error
    end
  end

  defp maintain(tenant, workspace) do
    scope =
      ScopeEnvelope.resolve(%{
        tenant_id: tenant,
        workspace_id: workspace,
        actor_id: "system:reconstruction-maintenance"
      })

    with {:ok, projection} <- AssociativeProjection.rebuild(scope),
         {:ok, proposals} <- ReconstructionLearning.propose_consolidation(scope) do
      %{
        workspace_id: workspace,
        associations: projection.associations,
        proposals: length(proposals),
        ok: true
      }
    else
      {:error, reason} ->
        Logger.warning(
          "[MemoryCore.ReconstructionScheduler] workspace=#{workspace} failed: #{inspect(reason)}"
        )

        %{workspace_id: workspace, ok: false, error: inspect(reason)}
    end
  end
end
