defmodule OptimalEngine.Maintenance.Worker do
  @moduledoc """
  Drains maintenance jobs, runs the chunk embedding sweep, and prunes
  completed maintenance jobs (`OptimalEngine.Maintenance`).

  Draining runs every ten seconds by default (`config :optimal_engine,
  :maintenance_interval_ms`, env `OPTIMAL_MAINTENANCE_INTERVAL_MS`; 0
  disables), and while it is on, completed maintenance jobs older than seven
  days are pruned hourly. The sweep runs two minutes after boot, then every
  30 minutes (`config :optimal_engine, :embedding_sweep_interval_ms`, env
  `OPTIMAL_EMBEDDING_SWEEP_INTERVAL_MS`; 0 disables). Both are off in tests.
  A workspace the sweep cannot queue (its chunks name a workspace that is not
  registered and active) is logged once. The work runs in this process: the
  Store only sees its small reads and writes.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Maintenance

  @default_interval 10_000
  @default_sweep_interval 30 * 60_000
  @boot_delay 5_000
  @sweep_boot_delay 120_000
  @prune_interval 3_600_000
  @max_jobs_per_tick 3

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Drains now and returns how many jobs ran."
  def tick, do: GenServer.call(__MODULE__, :tick, :infinity)

  @doc "Runs the sweep now and returns its result."
  def sweep, do: GenServer.call(__MODULE__, :sweep, :infinity)

  @impl true
  def init(_opts) do
    interval = Application.get_env(:optimal_engine, :maintenance_interval_ms, @default_interval)

    sweep_interval =
      Application.get_env(
        :optimal_engine,
        :embedding_sweep_interval_ms,
        @default_sweep_interval
      )

    if interval > 0 do
      Process.send_after(self(), :tick, min(@boot_delay, interval))
      Process.send_after(self(), :prune, @prune_interval)
    end

    if sweep_interval > 0,
      do: Process.send_after(self(), :sweep, min(@sweep_boot_delay, sweep_interval))

    {:ok,
     %{interval: interval, sweep_interval: sweep_interval, owner: owner(), skipped: MapSet.new()}}
  end

  @impl true
  def handle_info(:tick, state) do
    drain(state)
    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    {_result, state} = run_sweep(state)

    if state.sweep_interval > 0,
      do: Process.send_after(self(), :sweep, state.sweep_interval)

    {:noreply, state}
  end

  def handle_info(:prune, state) do
    prune()
    Process.send_after(self(), :prune, @prune_interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, drain(state), state}

  def handle_call(:sweep, _from, state) do
    {result, state} = run_sweep(state)
    {:reply, result, state}
  end

  defp drain(state) do
    Enum.reduce_while(1..@max_jobs_per_tick, 0, fn _n, count ->
      case Maintenance.drain(lease_owner: state.owner) do
        {:ok, :idle} ->
          {:halt, count}

        {:ok, _ran} ->
          {:cont, count + 1}

        {:error, reason} ->
          Logger.warning("[Maintenance] drain failed: #{inspect(reason)}")
          {:halt, count}
      end
    end)
  rescue
    error ->
      Logger.warning("[Maintenance] drain pass failed: #{Exception.message(error)}")
      0
  catch
    :exit, reason ->
      Logger.warning("[Maintenance] drain pass exited: #{inspect(reason)}")
      0
  end

  defp run_sweep(state) do
    case Maintenance.sweep(pause_ms: 5) do
      {:ok, %{skipped: skipped}} = result ->
        new = Enum.reject(skipped, &MapSet.member?(state.skipped, &1))

        if new != [] do
          Logger.info(
            "[Maintenance] sweep skips chunks in workspaces that are not registered and " <>
              "active: #{Enum.join(new, ", ")}"
          )
        end

        {result, %{state | skipped: MapSet.union(state.skipped, MapSet.new(new))}}

      result ->
        {result, state}
    end
  rescue
    error ->
      Logger.warning("[Maintenance] sweep failed: #{Exception.message(error)}")
      {{:error, Exception.message(error)}, state}
  catch
    :exit, reason ->
      Logger.warning("[Maintenance] sweep exited: #{inspect(reason)}")
      {{:error, {:exit, reason}}, state}
  end

  defp prune do
    case Maintenance.prune() do
      {:ok, n} when n > 0 -> Logger.info("[Maintenance] pruned #{n} completed maintenance jobs")
      _ -> :ok
    end
  rescue
    error -> Logger.warning("[Maintenance] prune failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("[Maintenance] prune exited: #{inspect(reason)}")
  end

  defp owner, do: "maintenance-worker:#{node()}:#{System.pid()}"
end
