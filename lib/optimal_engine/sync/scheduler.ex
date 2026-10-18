defmodule OptimalEngine.Sync.Scheduler do
  @moduledoc """
  Keeps replication moving: installs capture triggers at startup, seals
  captured changes, and runs every active peer on an interval (default 20
  seconds, `config :optimal_engine, :sync_interval_ms`) so a change on one
  replica reaches the other within a minute when both are online.

  Peers that cannot be reached are retried on the next tick; their status
  and message are kept on the peer row (`GET /api/sync/status`).
  """

  use GenServer
  require Logger

  alias OptimalEngine.Sync
  alias OptimalEngine.Sync.Capture

  @default_interval 20_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one cycle now (seal and every active peer)."
  def tick, do: GenServer.call(__MODULE__, :tick, 120_000)

  @impl true
  def init(_opts) do
    send(self(), :install)
    {:ok, %{interval: Application.get_env(:optimal_engine, :sync_interval_ms, @default_interval)}}
  end

  @impl true
  def handle_info(:install, state) do
    case safely(&Capture.install/0) do
      {:ok, %{tables: n}} -> Logger.debug("[Sync] capture triggers on #{n} tables")
      other -> Logger.warning("[Sync] capture install failed: #{inspect(other)}")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    run_cycle()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, run_cycle(), state}

  defp run_cycle do
    _ = safely(&Capture.seal/0)
    safely(&Sync.run_all/0)
  end

  defp schedule(interval) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :tick, interval)

  defp schedule(_interval), do: :ok

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end
end
