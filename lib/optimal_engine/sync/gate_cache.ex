defmodule OptimalEngine.Sync.GateCache do
  @moduledoc """
  What `OptimalEngine.Sync.Gate` builds from a whole workspace, kept between
  gates.

  A gate reads two things that cost a scan of the workspace: the index of the
  documents and memories derived from sources above a class (or, for a reader,
  from sources that carry a label), and whether the workspace holds anything
  above a class (what decides an aggregate). A pull of many pages opens a gate
  per page, and a peer is pushed to every cycle; without this each of them would
  scan the workspace again.

  An entry is kept under `{what, tenant, workspace, mode, rank}` (`what` is
  `:index` or `:holds_above`, `mode` is the gate of a peer or of a reader, `rank`
  is the class of the gate), so gates that select different sources never share
  one. It is valid while its stamp is unchanged. The stamp is the write
  sequence of the change capture and of the ledger (`sync_capture` and
  `sync_mutations` in `sqlite_sequence`; both are `AUTOINCREMENT`, so they
  survive the deletes that sealing does). Every write to a replicated table of a
  workspace that syncs moves one of them, and so does applying a change from a
  peer, so a source labelled a moment ago is never missed. A workspace that does
  not sync is captured by no one, so nothing tells when it changed: it is never
  cached.

  Entries also expire after `config :optimal_engine, :sync_gate_cache_ttl_ms`
  (default 30 seconds; `0` turns the cache off). That bounds how long a write
  that capture does not see could go unnoticed. Every replicated table the gate
  scans is captured (`test/sync/sync_gate_test.exs` pins that); a table that
  stays on its Engine (assets, active pools, context packages, model and tool
  runs, skill packages) is not, so for a write there the ttl is the bound.
  The cache is dropped after a change from a peer is applied and when sync is
  enabled or disabled for a workspace, so it does not rest on the sequences alone
  there.

  The table is owned by this process and holds at most 1,024 entries (the
  expired ones are dropped first, then all of them). A value is copied out of
  the table on every lookup. Without the process (the application not started,
  or between a crash and its restart) every lookup builds.
  """

  use GenServer

  @table :optimal_sync_gate_cache
  @default_ttl_ms 30_000
  @max_entries 1024

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

  @doc "Drops every entry (tests, and after anything the stamp cannot see)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(key) do
    if ttl_ms() > 0 do
      case :ets.lookup(@table, key) do
        [{^key, stamp, expires, value}] -> {stamp, expires, value}
        [] -> nil
      end
    end
  rescue
    # The owner died between the check and the read: build.
    ArgumentError -> nil
  end

  defp store(key, stamp, now, value) do
    ttl = ttl_ms()

    if ttl > 0 do
      if :ets.info(@table, :size) >= @max_entries, do: make_room(now)
      :ets.insert(@table, {key, stamp, now + ttl, value})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # The expired entries first; all of them when the live ones fill the table.
  defp make_room(now) do
    :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}])
    if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
  end

  defp ttl_ms do
    case Application.get_env(:optimal_engine, :sync_gate_cache_ttl_ms, @default_ttl_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @default_ttl_ms
    end
  end
end
