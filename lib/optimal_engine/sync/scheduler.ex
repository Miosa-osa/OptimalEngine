defmodule OptimalEngine.Sync.Scheduler do
  @moduledoc """
  Keeps replication moving: installs capture triggers at startup (retrying
  every 30 seconds, `:sync_install_retry_ms`, until it succeeds), seals
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
  @install_retry 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one cycle now (seal and every active peer)."
  def tick, do: GenServer.call(__MODULE__, :tick, 120_000)

  @impl true
  def init(_opts) do
    send(self(), :install)
    {:ok, %{interval: Application.get_env(:optimal_engine, :sync_interval_ms, @default_interval)}}
  end

  # The install is retried until it succeeds: a Store busy at startup would
  # otherwise leave a new or changed table uncaptured until the next restart.
  # The tick chain starts once, after the first attempt. Capture is made of
  # SQLite triggers, so an engine whose canonical store is PostgreSQL says so
  # once instead of retrying forever.
  @impl true
  def handle_info(:install, state) do
    if OptimalEngine.Store.selected?(OptimalEngine.Store.SQLite) do
      install_capture()
    else
      Logger.info("[Sync] change capture uses SQLite triggers and is off on this store")
    end

    unless state[:ticking], do: schedule(state.interval)
    {:noreply, Map.put(state, :ticking, true)}
  end

  def handle_info(:tick, state) do
    run_cycle()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, run_cycle(), state}

  defp install_capture do
    case safely(&Capture.install/0) do
      {:ok, %{tables: n}} ->
        Logger.debug("[Sync] capture triggers on #{n} tables")
        purge_ledger()

      other ->
        retry = Application.get_env(:optimal_engine, :sync_install_retry_ms, @install_retry)
        Logger.warning("[Sync] capture install failed, retrying in #{retry} ms: #{inspect(other)}")
        Process.send_after(self(), :install, retry)
    end
  end

  # Ledger rows of tables that do not replicate (an earlier version captured and
  # applied every workspace table) are removed once the triggers are in place.
  defp purge_ledger do
    case safely(&Sync.purge_unreplicated_once/0) do
      {:ok, purged} when purged == %{} ->
        :ok

      {:ok, purged} ->
        Logger.warning(
          "[Sync] removed #{Enum.sum(Map.values(purged))} ledger rows of tables that do not replicate: " <>
            inspect(purged) <>
            "; rows of api_keys, principals, roles or tenants among them were written by a peer, " <>
            "check those tables (each such row is logged above with its entity id, device and time)"
        )

      other ->
        Logger.warning("[Sync] could not purge the ledger: #{inspect(other)}")
    end
  end

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
