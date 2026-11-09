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

  def insert_chunks(chunks), do: adapter().insert_chunks(chunks)

  def insert_classifications(rows), do: adapter().insert_classifications(rows)

  def insert_intents(rows), do: adapter().insert_intents(rows)

  def insert_embeddings(rows), do: adapter().insert_embeddings(rows)

  def insert_clusters(rows), do: adapter().insert_clusters(rows)

  def insert_cluster_members(rows), do: adapter().insert_cluster_members(rows)
end
