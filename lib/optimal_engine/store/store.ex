defmodule OptimalEngine.Store do
  @moduledoc """
  The canonical store facade.

  Every operation is delegated to the configured implementation of
  `OptimalEngine.Store.Adapter`.
  The default is `OptimalEngine.Store.SQLite`, the embedded store; a deployment
  that moves its canonical store to PostgreSQL selects another implementation
  with `config :optimal_engine, :store_adapter, <module>`.
  The choice is read when the Engine boots (`OPTIMAL_STORE`, `sqlite` or
  `postgres`, through `config/runtime.exs`), so one release runs either store;
  each call looks the implementation up in a `:persistent_term`, which costs
  no more than a function call.

  The contract, the transaction rules, and the timestamp rules live in
  `OptimalEngine.Store.Adapter`.
  Callers keep using this module; nothing outside the implementation knows
  which database answers.
  """

  @behaviour OptimalEngine.Store.Adapter

  @implementations [OptimalEngine.Store.SQLite, OptimalEngine.Store.Postgres]
  @key {__MODULE__, :adapter}

  @doc """
  The store implementation this Engine runs: `config :optimal_engine,
  :store_adapter`, read once and kept for the life of the node.
  """
  @spec adapter() :: module()
  def adapter do
    case :persistent_term.get(@key, nil) do
      nil -> resolve()
      adapter -> adapter
    end
  end

  defp resolve do
    adapter = Application.get_env(:optimal_engine, :store_adapter, OptimalEngine.Store.SQLite)

    unless adapter in @implementations,
      do: raise(ArgumentError, "unknown store implementation #{inspect(adapter)}")

    :persistent_term.put(@key, adapter)
    adapter
  end

  @doc "True when this Engine's store is `implementation`."
  @spec selected?(module()) :: boolean()
  def selected?(implementation) when is_atom(implementation), do: implementation == adapter()

  @doc false
  # The supervisor starts `OptimalEngine.Store`; the child spec stays here so
  # the implementation module can change without touching the supervision tree.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts \\ []), do: adapter().start_link(opts)

  def insert_context(context), do: adapter().insert_context(context)

  def insert_contexts(contexts), do: adapter().insert_contexts(contexts)

  def insert_signal(signal), do: adapter().insert_signal(signal)

  def insert_signals(signals), do: adapter().insert_signals(signals)

  def get_context(id), do: adapter().get_context(id)

  def get_signal(id), do: adapter().get_signal(id)

  def get_by_node(node, opts \\ []), do: adapter().get_by_node(node, opts)

  def stats(), do: adapter().stats()

  def delete_context(id), do: adapter().delete_context(id)

  def delete_signal(id), do: adapter().delete_signal(id)

  def evict_cached(ids), do: adapter().evict_cached(ids)

  def raw_query(sql, params \\ []), do: adapter().raw_query(sql, params)

  @doc """
  How long a raw query or statement waits for the Store, in milliseconds
  (`config :optimal_engine, :store_call_timeout_ms`, default 15,000). A
  caller that waits longer exits with a timeout.
  """
  @spec call_timeout() :: pos_integer()
  def call_timeout, do: Application.get_env(:optimal_engine, :store_call_timeout_ms, 15_000)

  def raw_execute(sql, params \\ []), do: adapter().raw_execute(sql, params)

  def transaction(fun, timeout \\ 30_000), do: adapter().transaction(fun, timeout)

  def txn_query(txn, sql, params \\ [], opts \\ []), do: adapter().txn_query(txn, sql, params, opts)

  def txn_execute(txn, sql, params \\ [], opts \\ []),
    do: adapter().txn_execute(txn, sql, params, opts)

  @doc """
  Runs the rest of the transaction at READ COMMITTED on PostgreSQL: each
  statement sees what was committed before it, not one snapshot. For a bulk
  write across many tables (a workspace's rows deleted at once) that at
  SERIALIZABLE meets every concurrent writer of those tables, and its rows
  are its own: it still commits or rolls back whole, and deferred foreign keys
  are still checked at the commit. SQLite's store runs one writer at a time,
  so there it does nothing. Call it first in the transaction.
  """
  @spec txn_read_committed(term()) :: :ok | {:error, term()}
  def txn_read_committed(txn) do
    if selected?(OptimalEngine.Store.Postgres) do
      sql = "SET TRANSACTION ISOLATION LEVEL READ COMMITTED"
      with {:ok, _} <- OptimalEngine.Store.Postgres.txn_execute_native(txn, sql, []), do: :ok
    else
      :ok
    end
  end

  @doc """
  Holds the row of `table` whose `column` is `key` until the transaction ends,
  so a long transaction that rewrites it is not starved by writers of that row:
  they wait for it instead of committing under it. SQLite's store runs one
  writer at a time, so there it does nothing. Call it first in the transaction.
  """
  @spec txn_lock_row(term(), String.t(), String.t(), term()) :: :ok | {:error, term()}
  def txn_lock_row(txn, table, column, key) do
    if selected?(OptimalEngine.Store.Postgres) do
      sql = ~s|SELECT 1 FROM "#{table}" WHERE "#{column}" = $1 FOR UPDATE|

      with {:ok, _rows} <- OptimalEngine.Store.Postgres.txn_query_native(txn, sql, [key]), do: :ok
    else
      :ok
    end
  end

  @doc """
  Holds `tables` against every other writer until the transaction ends, for a
  transaction that reads and rewrites rows across many tables (a workspace
  renamed or merged). At SERIALIZABLE such a transaction conflicts with nearly
  every concurrent writer and, being the longest, is the one aborted, again and
  again; with the tables held, writers wait for it as they wait for SQLite's
  one writer, and a writer that read what it changed is the one run again.
  Readers do not wait. The locks are taken before the transaction's snapshot,
  so the transaction sees every write committed before it holds them; call it
  first in the transaction, with a list read before it began. The locks are
  taken in name order, one statement, in SHARE ROW EXCLUSIVE mode, which two
  such transactions cannot hold at once. The cost: every writer of those
  tables, in any workspace, stalls until the transaction ends, and one that
  waits past its lock timeout (15 seconds, or its call's time when shorter) is
  `:busy`. Keep such transactions rare and short. SQLite's store runs one
  writer at a time, so there it does nothing.
  """
  @spec txn_lock_tables(term(), [String.t()]) :: :ok | {:error, term()}
  def txn_lock_tables(_txn, []), do: :ok

  def txn_lock_tables(txn, tables) when is_list(tables) do
    if selected?(OptimalEngine.Store.Postgres) do
      list =
        tables
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map_join(", ", &~s("#{String.replace(&1, ~s("), ~s(""))}"))

      sql = "LOCK TABLE #{list} IN SHARE ROW EXCLUSIVE MODE"
      with {:ok, _} <- OptimalEngine.Store.Postgres.txn_execute_native(txn, sql, []), do: :ok
    else
      :ok
    end
  end

  @doc """
  The clause that ends a `SELECT` of rows to claim from a queue: on PostgreSQL
  ` FOR UPDATE SKIP LOCKED`, so the rows are locked until the transaction ends
  and a concurrent claimer passes over them instead of waiting for them or
  claiming them too. Used with `txn_read_committed/1`. SQLite's store runs one
  writer at a time, so there it is empty.
  """
  @spec skip_locked() :: String.t()
  def skip_locked do
    if selected?(OptimalEngine.Store.Postgres), do: " FOR UPDATE SKIP LOCKED", else: ""
  end

  def insert_chunks(chunks), do: adapter().insert_chunks(chunks)

  def insert_classifications(rows), do: adapter().insert_classifications(rows)

  def insert_intents(rows), do: adapter().insert_intents(rows)

  def insert_embeddings(rows), do: adapter().insert_embeddings(rows)

  def insert_clusters(rows), do: adapter().insert_clusters(rows)

  def insert_cluster_members(rows), do: adapter().insert_cluster_members(rows)
end
