defmodule OptimalEngine.Store.Adapter do
  @moduledoc """
  The contract every canonical store implementation must satisfy.

  Stage 3 of the PostgreSQL provider (`docs/guides/postgres-provider.md`) fixes
  this contract before moving the SQLite implementation behind it. Keeping the
  contract in one place means the PostgreSQL implementation is written against
  the same operations the engine already calls, and a store function that is
  missing from an implementation fails at compile time rather than at the first
  query.

  The contract covers the canonical relational store only. Vectors, assets,
  graph, cache and jobs keep their own providers; the store's own tables
  (`contexts`, `entities`, `graph_edges`, `decisions`, `sessions`, and the ledger)
  are what this behaviour governs.

  ## Transaction semantics

  `transaction/2` runs a caller-supplied fun against an opaque handle and
  commits or rolls back as one unit. The fun must use `txn_query/4` and
  `txn_execute/4`; calling any other function of the implementation inside the
  fun is a deadlock for a single-connection implementation. An exception raised
  by the fun rolls back and is re-raised in the caller with its stacktrace.

  On SQLite a failed statement leaves the transaction open. On PostgreSQL it
  ends the transaction, and the commit rolls back. A statement whose failure
  the fun handles and goes on from passes `recoverable: true`, so it runs in a
  savepoint of its own; an implementation where a failed statement never ends
  the transaction ignores the option. A savepoint the fun opens itself
  (`SAVEPOINT`, `ROLLBACK TO`, `RELEASE`) works on both.

  ## Timestamps

  Timestamps remain ISO-8601 text in the format the engine already stores.
  An implementation must not reinterpret existing values on read.
  """

  alias OptimalEngine.{Context, Signal}

  @doc "Starts the implementation's process."
  @callback start_link(keyword()) :: GenServer.on_start()

  @doc "Inserts one context."
  @callback insert_context(Context.t()) :: :ok | {:error, term()}

  @doc "Inserts contexts in one transaction; returns how many were written."
  @callback insert_contexts([Context.t()]) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Inserts one signal."
  @callback insert_signal(Signal.t()) :: :ok | {:error, term()}

  @doc "Inserts signals in one transaction; returns how many were written."
  @callback insert_signals([Signal.t()]) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Reads one context by id."
  @callback get_context(String.t()) :: {:ok, Context.t()} | {:error, :not_found}

  @doc "Reads one signal by id."
  @callback get_signal(String.t()) :: {:ok, Signal.t()} | {:error, :not_found}

  @doc "Reads the contexts attached to a node, optionally filtered."
  @callback get_by_node(String.t(), keyword()) :: {:ok, [Context.t()]} | {:error, term()}

  @doc "Returns row counts and cache statistics."
  @callback stats() :: {:ok, map()} | {:error, term()}

  @doc "Deletes one context."
  @callback delete_context(String.t()) :: :ok | {:error, term()}

  @doc "Deletes one signal."
  @callback delete_signal(String.t()) :: :ok | {:error, term()}

  @doc "Drops entries from the hot cache without touching the database."
  @callback evict_cached([String.t()]) :: :ok

  @doc "Runs one SELECT and returns raw rows."
  @callback raw_query(String.t(), [term()]) :: {:ok, [[term()]]} | {:error, term()}

  @doc "Runs one non-SELECT statement."
  @callback raw_execute(String.t(), [term()]) :: :ok | {:error, term()}

  @doc "Runs a fun inside one transaction."
  @callback transaction((term() -> {:ok, term()} | {:error, term()}), timeout()) ::
              {:ok, term()} | {:error, term()}

  @doc "Runs a SELECT inside a transaction handle. Options: `:recoverable`."
  @callback txn_query(term(), String.t(), [term()], keyword()) ::
              {:ok, [[term()]]} | {:error, term()}

  @doc "Runs a non-SELECT statement inside a transaction handle. Options: `:recoverable`."
  @callback txn_execute(term(), String.t(), [term()], keyword()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc "Inserts chunks in one transaction."
  @callback insert_chunks([struct() | map()]) :: :ok | {:error, term()}

  @doc "Inserts classification rows in one transaction."
  @callback insert_classifications([struct() | map()]) :: :ok | {:error, term()}

  @doc "Inserts intent rows in one transaction."
  @callback insert_intents([struct() | map()]) :: :ok | {:error, term()}

  @doc "Inserts embedding rows in one transaction."
  @callback insert_embeddings([struct() | map()]) :: :ok | {:error, term()}

  @doc "Inserts cluster rows in one transaction."
  @callback insert_clusters([struct() | map()]) :: :ok | {:error, term()}

  @doc "Inserts cluster membership rows in one transaction."
  @callback insert_cluster_members([map()]) :: :ok | {:error, term()}
end
