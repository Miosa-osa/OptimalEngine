defmodule OptimalEngine.Reindex.Worker do
  @moduledoc """
  Drains queued reindex jobs (`OptimalEngine.Reindex`).

  Runs every five seconds by default (`config :optimal_engine,
  :reindex_interval_ms`, env `OPTIMAL_REINDEX_INTERVAL_MS`; 0 disables).
  The interval is short because a writer that changes files expects the crawl
  to start promptly; the job itself is durable, so a slow or stopped worker
  only delays the crawl, it never loses the request.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Reindex

  @default_interval 5_000
  @boot_delay 1_000
  @max_jobs_per_tick 5

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Drains now and returns how many jobs ran. Used by tests and by ops."
  def tick, do: GenServer.call(__MODULE__, :tick, 60_000)

  @impl true
  def init(_opts) do
    interval = Application.get_env(:optimal_engine, :reindex_interval_ms, @default_interval)
    if interval > 0, do: Process.send_after(self(), :tick, min(@boot_delay, interval))
    {:ok, %{interval: interval, owner: owner()}}
  end

  @impl true
  def handle_info(:tick, state) do
    run(state)
    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, run(state), state}

  defp run(state) do
    Enum.reduce_while(1..@max_jobs_per_tick, 0, fn _n, count ->
      case Reindex.drain(lease_owner: state.owner) do
        {:ok, :idle} ->
          {:halt, count}

        {:ok, _job} ->
          {:cont, count + 1}

        {:error, reason} ->
          Logger.warning("[Reindex] drain failed: #{inspect(reason)}")
          {:halt, count}
      end
    end)
  rescue
    error ->
      Logger.warning("[Reindex] pass failed: #{Exception.message(error)}")
      0
  end

  defp owner, do: "reindex-worker:#{node()}:#{System.pid()}"
end
