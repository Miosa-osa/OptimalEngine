defmodule OptimalEngine.Imports.Worker do
  @moduledoc """
  Drains queued import jobs (`OptimalEngine.Imports`).

  Runs every two seconds by default (`config :optimal_engine,
  :imports_interval_ms`, env `OPTIMAL_IMPORTS_INTERVAL_MS`; 0 disables), so
  an import starts promptly after it is posted. Imports run one at a time:
  each is a long write into one workspace, and the job is durable, so a
  stopped worker only delays it.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Imports

  @default_interval 2_000
  @boot_delay 1_000
  @max_jobs_per_tick 5

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Drains now and returns how many jobs ran. Used by tests and by ops."
  def tick, do: GenServer.call(__MODULE__, :tick, :infinity)

  @impl true
  def init(_opts) do
    interval = Application.get_env(:optimal_engine, :imports_interval_ms, @default_interval)
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
      case Imports.drain(lease_owner: state.owner) do
        {:ok, :idle} ->
          {:halt, count}

        {:ok, _job} ->
          {:cont, count + 1}

        {:error, reason} ->
          Logger.warning("[Imports] drain failed: #{inspect(reason)}")
          {:halt, count}
      end
    end)
  rescue
    error ->
      Logger.warning("[Imports] pass failed: #{Exception.message(error)}")
      0
  end

  defp owner, do: "imports-worker:#{node()}:#{System.pid()}"
end
