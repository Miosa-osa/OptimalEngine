defmodule OptimalEngine.Analyses.Worker do
  @moduledoc """
  Schedules the day's analyses and drains the analysis jobs
  (`OptimalEngine.Analyses`).

  Runs every five minutes by default (`config :optimal_engine,
  :analyses_interval_ms`, env `OPTIMAL_ANALYSES_INTERVAL_MS`; 0 disables).
  Scheduling is idempotent per kind, workspace, and day, so each analysis
  runs once a day; failed jobs retry and then dead-letter.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Analyses

  @default_interval 300_000
  @boot_delay 120_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one pass now."
  def tick, do: GenServer.call(__MODULE__, :tick, 600_000)

  @impl true
  def init(_opts) do
    interval = Application.get_env(:optimal_engine, :analyses_interval_ms, @default_interval)
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
    scheduled = Analyses.schedule()
    %{scheduled: scheduled, ran: Analyses.drain()}
  rescue
    error ->
      Logger.warning("[Analyses] pass failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end
end
