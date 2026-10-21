defmodule OptimalEngine.Store do
  @moduledoc """
  The canonical store facade.

  Every operation is delegated to the configured implementation of
  `OptimalEngine.Store.Adapter`.
  The default is `OptimalEngine.Store.SQLite`, the embedded store; a deployment
  that moves its canonical store to PostgreSQL selects another implementation
  with `config :optimal_engine, :store_adapter, <module>`.
  The choice is resolved at compile time, so a release ships one implementation
  and never dispatches per call.

  The contract, the transaction rules, and the timestamp rules live in
  `OptimalEngine.Store.Adapter`.
  Callers keep using this module; nothing outside the implementation knows
  which database answers.
  """

  @behaviour OptimalEngine.Store.Adapter

  @adapter Application.compile_env(:optimal_engine, :store_adapter, OptimalEngine.Store.SQLite)

  @doc "The store implementation this build was compiled with."
  @spec adapter() :: module()
  def adapter, do: @adapter

  @doc "True when this build's store is `implementation`."
  @spec selected?(module()) :: boolean()
  def selected?(implementation) when is_atom(implementation), do: implementation == @adapter

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

  defdelegate start_link(opts \\ []), to: @adapter

  defdelegate insert_context(context), to: @adapter

  defdelegate insert_contexts(contexts), to: @adapter

  defdelegate insert_signal(signal), to: @adapter

  defdelegate insert_signals(signals), to: @adapter

  defdelegate get_context(id), to: @adapter

  defdelegate get_signal(id), to: @adapter

  defdelegate get_by_node(node, opts \\ []), to: @adapter

  defdelegate stats(), to: @adapter

  defdelegate delete_context(id), to: @adapter

  defdelegate delete_signal(id), to: @adapter

  defdelegate evict_cached(ids), to: @adapter

  defdelegate raw_query(sql, params \\ []), to: @adapter

  @doc """
  How long a raw query or statement waits for the Store, in milliseconds
  (`config :optimal_engine, :store_call_timeout_ms`, default 15,000). A
  caller that waits longer exits with a timeout.
  """
  @spec call_timeout() :: pos_integer()
  def call_timeout, do: Application.get_env(:optimal_engine, :store_call_timeout_ms, 15_000)

  defdelegate raw_execute(sql, params \\ []), to: @adapter

  defdelegate transaction(fun, timeout \\ 30_000), to: @adapter

  defdelegate txn_query(txn, sql, params \\ [], opts \\ []), to: @adapter

  defdelegate txn_execute(txn, sql, params \\ [], opts \\ []), to: @adapter

  defdelegate insert_chunks(chunks), to: @adapter

  defdelegate insert_classifications(rows), to: @adapter

  defdelegate insert_intents(rows), to: @adapter

  defdelegate insert_embeddings(rows), to: @adapter

  defdelegate insert_clusters(rows), to: @adapter

  defdelegate insert_cluster_members(rows), to: @adapter
end
