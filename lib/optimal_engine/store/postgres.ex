defmodule OptimalEngine.Store.Postgres do
  @moduledoc """
  The PostgreSQL implementation of the canonical store, for engines that share
  one database (`docs/guides/postgres-provider.md`).

  The process owns a connection pool (`OptimalEngine.Store.Postgres.Connection`)
  and, when it starts, brings the database schema in line with this build's
  migrations (`OptimalEngine.Store.Postgres.Schema`). Every operation runs in
  the calling process on a pooled connection; nothing is serialized through
  this process.

  ## Configuration

      config :optimal_engine, :postgres_store,
        schema: "public",
        pool_size: 10

  The connection URL is `OPTIMAL_POSTGRES_URL`, read when the store starts and
  never stored.

  ## Differences from the SQLite store

  - There is no hot cache: a per-process cache cannot see another engine's
    writes, so every read goes to the database and `evict_cached/1` has
    nothing to drop.
  - Full-text search is unavailable on PostgreSQL until a slice ports it to
    `tsvector`: the FTS5 tables are not derived, and a statement that uses
    `MATCH` is refused by the dialect with `{:error, {:unsupported, "FTS5 MATCH"}}`.

  This module implements the read side of `OptimalEngine.Store.Adapter`;
  the writes and `transaction/2` land in the next stage 3 slice, together with
  `@behaviour`.
  """

  use GenServer

  alias OptimalEngine.{Context, Signal, Store}
  alias OptimalEngine.Store.Postgres.{Connection, Schema}

  @pool __MODULE__.Pool

  # The columns of a context, in the order Context.from_row/1 reads them.
  @context_fields ~w(
    id uri type path title l0_abstract l1_overview content
    mode genre signal_type format structure node sn_ratio entities
    created_at modified_at valid_from valid_until supersedes
    routed_to metadata workspace_id
  )a

  @context_columns Enum.map_join(@context_fields, ", ", &Atom.to_string/1)

  @select_context "SELECT #{@context_columns} FROM contexts"

  # ---------------------------------------------------------------------------
  # Process
  # ---------------------------------------------------------------------------

  @doc """
  Starts the store: opens the pool and syncs the schema.

  Options override `config :optimal_engine, :postgres_store`: `:url`,
  `:schema`, `:pool_size`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  What the last schema sync reported: the fingerprint, and every object
  PostgreSQL did not get (the FTS5 tables and their triggers, and any view it
  rejected). Any other difference from the derived schema stops the store
  from starting.
  """
  @spec schema_report() :: map()
  def schema_report, do: GenServer.call(__MODULE__, :schema_report)

  @impl GenServer
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:optimal_engine, :postgres_store, []), opts)

    # The pool is the store's: it stops with the store, whatever the reason,
    # and the store stops when the pool does.
    Process.flag(:trap_exit, true)

    with {:ok, schema} <- Connection.schema(opts),
         {:ok, pool} <- Connection.start_link(Keyword.put(opts, :name, @pool)) do
      case ready(schema) do
        {:ok, report} ->
          {:ok, %{pool: pool, schema: schema, report: report}}

        {:error, reason} ->
          stop_pool(pool)
          {:stop, {:postgres_store_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, {:postgres_store_failed, reason}}
    end
  end

  defp ready(schema), do: Schema.sync(@pool, schema: schema)

  @impl GenServer
  def handle_call(:schema_report, _from, state), do: {:reply, state.report, state}

  @impl GenServer
  def handle_info({:EXIT, pool, reason}, %{pool: pool} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{pool: pool}), do: stop_pool(pool)
  def terminate(_reason, _state), do: :ok

  defp stop_pool(pool) do
    GenServer.stop(pool, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "Reads one context by id."
  @spec get_context(String.t()) :: {:ok, Context.t()} | {:error, :not_found}
  def get_context(id) when is_binary(id) do
    :telemetry.execute([:optimal_engine, :store, :cache_miss], %{count: 1}, %{})

    case native("#{@select_context} WHERE id = $1", [id]) do
      {:ok, [row]} -> {:ok, Context.from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads one signal by id."
  @spec get_signal(String.t()) :: {:ok, Signal.t()} | {:error, :not_found}
  def get_signal(id) when is_binary(id) do
    with {:ok, context} <- get_context(id), do: {:ok, Context.to_signal(context)}
  end

  @doc """
  The contexts of a node, newest modification first, optionally of one type.

  A context without a modification time sorts last, as on SQLite.
  """
  @spec get_by_node(String.t(), keyword()) :: {:ok, [Context.t()]} | {:error, term()}
  def get_by_node(node, opts \\ []) when is_binary(node) do
    {filter, params} =
      case Keyword.get(opts, :type) do
        nil -> {"node = $1", [node]}
        type -> {"node = $1 AND type = $2", [node, to_string(type)]}
      end

    sql = "#{@select_context} WHERE #{filter} ORDER BY modified_at DESC NULLS LAST"

    with {:ok, rows} <- native(sql, params, timeout: 10_000) do
      {:ok, Enum.map(rows, &Context.from_row/1)}
    end
  end

  @stats [
    {"total_contexts", "SELECT COUNT(*) FROM contexts WHERE archived_at IS NULL"},
    {"total_signals",
     "SELECT COUNT(*) FROM contexts WHERE type = 'signal' AND archived_at IS NULL"},
    {"total_resources",
     "SELECT COUNT(*) FROM contexts WHERE type = 'resource' AND archived_at IS NULL"},
    {"total_memories", "SELECT COUNT(*) FROM memories WHERE is_latest = 1 AND is_forgotten = 0"},
    {"total_skills", "SELECT COUNT(*) FROM contexts WHERE type = 'skill' AND archived_at IS NULL"},
    {"total_entities", "SELECT COUNT(*) FROM entities"},
    {"total_edges", "SELECT COUNT(*) FROM graph_edges"},
    {"total_decisions", "SELECT COUNT(*) FROM decisions"}
  ]

  @doc "Row counts, as the SQLite store reports them; `cache_size` is always 0."
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    Enum.reduce_while(@stats, {:ok, %{"cache_size" => 0}}, fn {key, sql}, {:ok, acc} ->
      case native(sql, []) do
        {:ok, [[count]]} -> {:cont, {:ok, Map.put(acc, key, count)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "There is no hot cache to drop entries from."
  @spec evict_cached([String.t()]) :: :ok
  def evict_cached(ids) when is_list(ids), do: :ok

  # ---------------------------------------------------------------------------
  # Statements
  # ---------------------------------------------------------------------------

  @doc "Runs one statement written for SQLite and returns its rows."
  @spec raw_query(String.t(), [term()]) :: {:ok, [[term()]]} | {:error, term()}
  def raw_query(sql, params \\ []) do
    with {:ok, %{rows: rows}} <-
           Connection.query(@pool, sql, params, timeout: Store.call_timeout()) do
      {:ok, rows}
    end
  end

  # The store's own statements are written for PostgreSQL.
  defp native(sql, params, opts \\ []) do
    with {:ok, %{rows: rows}} <-
           Connection.query(@pool, sql, params, Keyword.put(opts, :dialect, :postgres)) do
      {:ok, rows}
    end
  end
end
