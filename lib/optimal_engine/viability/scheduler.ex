defmodule OptimalEngine.Viability.Scheduler do
  @moduledoc """
  Takes the daily viability snapshots and runs the weekly System 3* audit
  for every tenant (`OptimalEngine.Viability.run_due/1`).

  Runs every hour by default (`config :optimal_engine, :viability_interval_ms`,
  env `OPTIMAL_VIABILITY_INTERVAL_MS`; 0 disables). Each pass only writes what
  is missing, so restarts and repeated passes are cheap.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Viability

  @default_interval 3_600_000
  @boot_delay 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one pass now."
  def tick, do: GenServer.call(__MODULE__, :tick, 600_000)

  @impl true
  def init(_opts) do
    interval = Application.get_env(:optimal_engine, :viability_interval_ms, @default_interval)
    if interval > 0, do: Process.send_after(self(), :tick, min(@boot_delay, interval))
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    run()
    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, run(), state}

  defp run do
    Viability.run_due()
  rescue
    error ->
      Logger.warning("[Viability] scheduled pass failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end
end
