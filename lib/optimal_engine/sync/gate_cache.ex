defmodule OptimalEngine.Sync.GateCache do
  @moduledoc """
  What `OptimalEngine.Sync.Gate` builds from a whole workspace, kept between
  gates.

  A gate reads two things that cost a scan of the workspace: the index of the
  documents and memories derived from sources above a class, and whether the
  workspace holds anything above a class (what decides an aggregate). A pull
  of many pages opens a gate per page, and a peer is pushed to every cycle;
  without this each of them would scan the workspace again.

  An entry is valid while its stamp is unchanged. The stamp is the write
  sequence of the change capture (`OptimalEngine.Sync.Gate.stamp/1`), which
  moves with every write to a replicated table of a workspace that syncs, so a
  source labelled a moment ago is never missed. Entries also expire after
  `config :optimal_engine, :sync_gate_cache_ttl_ms` (default 30 seconds; `0`
  turns the cache off), which bounds how long a write that capture does not
  see (an in-place update of a keyless table) can go unnoticed.

  The table is owned by this process. Without it (the application not
  started) every lookup builds.
  """

  use GenServer

  @table :optimal_sync_gate_cache
  @default_ttl_ms 30_000
  @max_entries 512

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  The value cached under `key` for `stamp`, or what `build` returns (cached
  for the next caller). A stamp of `:uncached` always builds.
  """
  @spec fetch(term(), term(), (-> value)) :: value when value: term()
  def fetch(_key, :uncached, build), do: build.()

  def fetch(key, stamp, build) do
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      {^stamp, expires, value} when expires > now ->
        value

      _stale_or_none ->
        value = build.()
        store(key, stamp, now, value)
        value
    end
  end

  @doc "Drops every entry (tests, and after a restore of the Store)."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp lookup(key) do
    if ttl_ms() > 0 and :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, key) do
        [{^key, stamp, expires, value}] -> {stamp, expires, value}
        [] -> nil
      end
    end
  end

  defp store(key, stamp, now, value) do
    ttl = ttl_ms()

    if ttl > 0 and :ets.whereis(@table) != :undefined do
      if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
      :ets.insert(@table, {key, stamp, now + ttl, value})
    end

    :ok
  end

  defp ttl_ms, do: Application.get_env(:optimal_engine, :sync_gate_cache_ttl_ms, @default_ttl_ms)
end
