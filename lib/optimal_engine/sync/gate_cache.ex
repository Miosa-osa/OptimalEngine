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
  sequence of the change capture, of the ledger and of the local stamp
  (`sync_capture`, `sync_mutations` and `sync_local_stamp` in `sqlite_sequence`;
  all are `AUTOINCREMENT`, so they survive the deletes that sealing does and the
  local stamp does). Every write to a replicated table of a workspace that syncs
  moves one of the first two, and so does applying a change from a peer; a write
  to a table the gate scans that stays on its Engine (assets, active pools,
  context packages, model and tool runs, skill packages, tool definitions)
  moves the third, through triggers that capture no row (see
  `OptimalEngine.Sync.Capture`). So a source labelled a moment ago is never
  missed. A workspace that does not sync is captured by no one, so nothing tells
  when it changed: it is never cached.

  Entries also expire after `config :optimal_engine, :sync_gate_cache_ttl_ms`
  (default 30 seconds; `0` turns the cache off, and so does a value that is not
  a non-negative integer, with one warning in the log for each such value, so a
  mistyped setting never leaves it on). That bounds how long a write that
  nothing sees could go unnoticed, such as a write to a scanned table before the
  Engine installed its triggers. Every table the gate scans is captured or
  stamped (`test/sync/sync_gate_test.exs` pins that).
  The cache is dropped after a change from a peer is applied and when sync is
  enabled or disabled for a workspace, so it does not rest on the sequences alone
  there.

  The table is owned by this process and holds at most 1,024 entries (the
  expired ones are dropped first, then all of them). A value is copied out of
  the table on every lookup. Without the process (the application not started,
  or between a crash and its restart) every lookup builds.

  With `OPTIMAL_VALKEY_URL` set the entries live in Valkey instead
  (`OptimalEngine.Storage.Shared`), signed, under a key that also carries this
  Engine's replica id: the stamp is a set of SQLite sequences, which only
  mean something for the store they were read from, so two Engines with
  stores of their own never share an entry, while the processes on one store
  do. Without a replica id nothing is cached on Valkey. `clear/0` reaches
  Valkey too (deferred while it is unreachable), and a lookup Valkey cannot
  answer falls back to this table.
  """

  use GenServer

  require Logger

  alias OptimalEngine.Storage.Shared
  alias OptimalEngine.Storage.Shared.Local

  @table :optimal_sync_gate_cache
  @default_ttl_ms 30_000
  @max_entries 1024

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Local.new_table(@table)
    {:ok, %{}}
  end

  @doc """
  The value cached under `key` for `stamp`, or what `build` returns (cached
  for the next caller). A stamp of `:uncached` always builds.
  """
  @spec fetch(term(), term(), (-> value)) :: value when value: term()
  def fetch(_key, :uncached, build), do: build.()

  def fetch(key, stamp, build) do
    ttl = ttl_ms()

    case ttl > 0 && scoped(key) do
      false ->
        build.()

      nil ->
        build.()

      scoped ->
        case Shared.get(@table, scoped) do
          {:ok, {^stamp, value}} ->
            value

          _stale_or_none ->
            value = build.()
            Shared.put(@table, scoped, {stamp, value}, ttl, max_entries: @max_entries)
            value
        end
    end
  end

  @doc "Drops every entry (tests, and after anything the stamp cannot see)."
  @spec clear() :: :ok
  def clear, do: Shared.clear(@table)

  # Locally the key is the key; on Valkey it is scoped to this store.
  defp scoped(key) do
    case Shared.backend() do
      :local -> key
      :valkey -> with id when is_binary(id) <- replica_id(), do: {id, key}
    end
  end

  defp replica_id do
    case OptimalEngine.Store.raw_query("SELECT replica_id FROM sync_identity WHERE id = 1", []) do
      {:ok, [[id]]} when is_binary(id) -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp ttl_ms do
    case Application.get_env(:optimal_engine, :sync_gate_cache_ttl_ms, @default_ttl_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      other -> off(other)
    end
  end

  # `ttl_ms/0` runs on every lookup, so the warning is given once for each value.
  defp off(value) do
    key = {__MODULE__, :invalid_ttl, value}

    if :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)

      Logger.warning(
        "[Sync] :sync_gate_cache_ttl_ms is #{inspect(value)}, which is not a non-negative integer " <>
          "of milliseconds; the gate cache is off"
      )
    end

    0
  end
end
