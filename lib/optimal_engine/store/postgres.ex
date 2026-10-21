defmodule OptimalEngine.Store.Postgres do
  @moduledoc """
  The PostgreSQL implementation of `OptimalEngine.Store.Adapter`, for engines
  that share one database (`docs/guides/postgres-provider.md`).

  The process owns a connection pool (`OptimalEngine.Store.Postgres.Connection`)
  and, when it starts, brings the database schema in line with this build's
  migrations (`OptimalEngine.Store.Postgres.Schema`). Every operation runs in
  the calling process on a pooled connection; nothing is serialized through
  this process, so writers in one engine and in other engines proceed in
  parallel.

  ## Configuration

      config :optimal_engine, :postgres_store,
        schema: "public",
        pool_size: 10

  The connection URL is `OPTIMAL_POSTGRES_URL`, read when the store starts and
  never stored.

  ## Writes

  A context write replaces the stored row the way SQLite's `INSERT OR REPLACE`
  does: the old row is deleted, with every `ON DELETE` action of the keys that
  point at it, and the new row inserted, in one transaction. Its entities and
  edges follow in the same transaction, and a duplicate entity or edge is
  ignored, as on SQLite. Chunks are written the same way.

  Every transaction runs at `SERIALIZABLE`; see
  `OptimalEngine.Store.Postgres.Connection` for how a transaction that
  PostgreSQL aborts is run again.

  ## Features not on PostgreSQL

  Replication, app data collections, full-text search and the statements that
  use SQLite's JSON functions, date arithmetic, catalog, `rowid` and other
  SQLite-only functions are not on PostgreSQL yet
  (`OptimalEngine.Storage.Postgres.unavailable/0`). Each is refused by name
  when used. A database that holds replication or app data collection data
  stops the store from starting, rather than letting it run without them.

  ## Differences from the SQLite store

  - There is no hot cache: a per-process cache cannot see another engine's
    writes, so every read goes to the database and `evict_cached/1` has
    nothing to drop.
  - Full-text search is unavailable on PostgreSQL until a slice ports it to
    `tsvector`: the FTS5 tables are not derived, and a statement that uses
    `MATCH` is refused by the dialect with `{:error, {:unsupported, "FTS5 MATCH"}}`.
  - A failed statement inside a transaction ends it, unless the statement
    passes `recoverable: true` (`OptimalEngine.Store.Adapter`). No call site
    goes on after a failed statement today except through a savepoint of its
    own, which works as on SQLite.
  """

  @behaviour OptimalEngine.Store.Adapter

  use GenServer

  alias OptimalEngine.{Context, Graph, Signal, Store}
  alias OptimalEngine.Store.ContextTenant
  alias OptimalEngine.Store.Postgres.{Connection, Schema}
  alias OptimalEngine.Store.SQLite

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

  # The tenant is decided before the insert (`Store.ContextTenant`): the one
  # the writer names, the owner of the workspace id, or the one of the row it
  # replaces.
  @insert_context """
  INSERT INTO contexts (#{@context_columns}, tenant_id)
  VALUES (#{Enum.map_join(1..25, ", ", &"$#{&1}")})
  """

  # The owner of a workspace id: its registered workspace's tenant, else the
  # tenant its "<tenant>:" prefix names, else none (a bare id).
  @workspace_owner """
  SELECT COALESCE((SELECT w.tenant_id FROM workspaces w WHERE w.id = $1),
                  (SELECT t.id FROM tenants t
                   WHERE t.id = CASE WHEN strpos($1, ':') > 0
                                     THEN substr($1, 1, strpos($1, ':') - 1) ELSE '' END))
  """

  @existing_context "SELECT tenant_id, workspace_id FROM contexts WHERE id = $1"

  # SQLite's chunk statement without OR REPLACE: the old chunk is deleted first.
  @insert_chunk """
  INSERT INTO chunks
    (id, tenant_id, signal_id, parent_id, scale, offset_bytes, length_bytes,
     text, modality, asset_ref, classification_level, created_at, workspace_id)
  VALUES
    (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, COALESCE(?12, datetime('now')), ?13)
  """

  @insert_entity """
  INSERT INTO entities (context_id, name, type, workspace_id, tenant_id)
  VALUES ($1, $2, 'person', $3, $4)
  ON CONFLICT DO NOTHING
  """

  # ---------------------------------------------------------------------------
  # Process
  # ---------------------------------------------------------------------------

  @doc """
  Starts the store: opens the pool and syncs the schema.

  Options override `config :optimal_engine, :postgres_store`: `:url`,
  `:schema`, `:pool_size`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  @impl OptimalEngine.Store.Adapter
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

  defp ready(schema) do
    with {:ok, report} <- Schema.sync(@pool, schema: schema),
         :ok <- nothing_unsupported_in_use(),
         do: {:ok, report}
  end

  # Data of a feature this store cannot run (`Storage.Postgres.unavailable/0`)
  # means an engine moved here would silently stop replicating, or stop
  # serving a collection; such an engine does not start.
  @in_use [
    {"replication",
     "SELECT 1 FROM sync_workspaces UNION ALL SELECT 1 FROM sync_peers WHERE status <> 'disabled'"},
    {"app_data_collections", "SELECT 1 FROM data_collections"}
  ]

  defp nothing_unsupported_in_use do
    @in_use
    |> Enum.reduce_while([], fn {feature, sql}, in_use ->
      case native("SELECT EXISTS (#{sql})", []) do
        {:ok, [[0]]} -> {:cont, in_use}
        {:ok, [[1]]} -> {:cont, in_use ++ [feature]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      [] -> :ok
      {:error, reason} -> {:error, reason}
      in_use -> {:error, {:unsupported_in_use, in_use}}
    end
  end

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
  # Contexts and signals
  # ---------------------------------------------------------------------------

  @doc "Writes one context, its entities and its edges."
  @spec insert_context(Context.t()) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_context(%Context{} = context) do
    result = Connection.transaction(@pool, &write_context(&1, context), 10_000)

    :telemetry.execute(
      [:optimal_engine, :store, :insert],
      %{count: 1},
      %{node: context.node, type: context.type}
    )

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Writes contexts in one transaction and returns how many were written."
  @spec insert_contexts([Context.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_contexts(contexts) when is_list(contexts) do
    Connection.transaction(
      @pool,
      fn txn ->
        Enum.reduce_while(contexts, {:ok, 0}, fn context, {:ok, count} ->
          case write_context(txn, context) do
            {:ok, _} -> {:cont, {:ok, count + 1}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end,
      60_000
    )
  end

  @doc "Writes one signal as a context of type `:signal`."
  @spec insert_signal(Signal.t()) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_signal(%Signal{} = signal), do: insert_context(Context.from_signal(signal))

  @doc "Writes signals in one transaction."
  @spec insert_signals([Signal.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_signals(signals) when is_list(signals),
    do: signals |> Enum.map(&Context.from_signal/1) |> insert_contexts()

  # Delete then insert, as SQLite's INSERT OR REPLACE does: the old row's
  # entities go with it through their ON DELETE CASCADE key. Entities and
  # edges are best effort on SQLite, so a failed one does not fail the write.
  defp write_context(txn, %Context{} = context) do
    with {:ok, tenant_id, previous} <- context_tenant(txn, context),
         :ok <- relabel_children(txn, context.id, tenant_id, previous) do
      write_context_row(txn, %{context | tenant_id: tenant_id})
    end
  end

  # A context the default tenant held is taken over by the owner of its workspace:
  # the chunks, chunk embeddings, claims and vectors written for it go with it.
  defp relabel_children(txn, id, tenant_id, previous) do
    if ContextTenant.takeover?(previous, tenant_id) do
      Enum.reduce_while(ContextTenant.relabel_sql(), :ok, fn sql, :ok ->
        case Connection.txn_query(txn, sql, [tenant_id, id]) do
          {:ok, _} -> {:cont, :ok}
          {:error, _reason} = err -> {:halt, err}
        end
      end)
    else
      :ok
    end
  end

  defp context_tenant(txn, %Context{} = context) do
    ContextTenant.decide(context, fn
      :owner, params -> first_row(txn, @workspace_owner, params)
      :existing, params -> first_row(txn, @existing_context, params)
    end)
  end

  defp first_row(txn, sql, params) do
    with {:ok, %{rows: rows}} <- txn_native(txn, sql, params), do: {:ok, List.first(rows)}
  end

  defp write_context_row(txn, %Context{tenant_id: tenant_id} = context) do
    row = Context.to_row(context)
    params = Enum.map(@context_fields, &Map.fetch!(row, &1)) ++ [tenant_id]

    with {:ok, _} <- txn_native(txn, "DELETE FROM contexts WHERE id = $1", [row.id]),
         {:ok, _} <- txn_native(txn, @insert_context, params) do
      write_entities(txn, context)

      for edge <- Graph.context_edges(context) do
        Connection.txn_query(txn, Graph.edge_insert_sql(), edge)
      end

      {:ok, context.id}
    end
  end

  defp write_entities(txn, %Context{id: id, entities: entities, tenant_id: tenant_id} = context)
       when is_list(entities) do
    workspace_id = context.workspace_id || "default"

    for entity <- entities do
      txn_native(txn, @insert_entity, [id, entity, workspace_id, tenant_id])
    end
  end

  defp write_entities(_txn, _context), do: []

  @doc "Reads one context by id."
  @spec get_context(String.t()) :: {:ok, Context.t()} | {:error, :not_found}
  @impl OptimalEngine.Store.Adapter
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
  @impl OptimalEngine.Store.Adapter
  def get_signal(id) when is_binary(id) do
    with {:ok, context} <- get_context(id), do: {:ok, Context.to_signal(context)}
  end

  @doc """
  The contexts of a node, newest modification first, optionally of one type.

  A context without a modification time sorts last, as on SQLite.
  """
  @spec get_by_node(String.t(), keyword()) :: {:ok, [Context.t()]} | {:error, term()}
  @impl OptimalEngine.Store.Adapter
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
  @impl OptimalEngine.Store.Adapter
  def stats do
    Enum.reduce_while(@stats, {:ok, %{"cache_size" => 0}}, fn {key, sql}, {:ok, acc} ->
      case native(sql, []) do
        {:ok, [[count]]} -> {:cont, {:ok, Map.put(acc, key, count)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Deletes one context; rows that point at it follow their `ON DELETE` actions."
  @spec delete_context(String.t()) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def delete_context(id) when is_binary(id) do
    with {:ok, _} <- native("DELETE FROM contexts WHERE id = $1", [id]), do: :ok
  end

  @doc "Deletes one signal."
  @spec delete_signal(String.t()) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def delete_signal(id), do: delete_context(id)

  @doc "There is no hot cache to drop entries from."
  @spec evict_cached([String.t()]) :: :ok
  @impl OptimalEngine.Store.Adapter
  def evict_cached(ids) when is_list(ids), do: :ok

  # ---------------------------------------------------------------------------
  # Statements and transactions
  # ---------------------------------------------------------------------------

  @doc "Runs one statement written for SQLite and returns its rows."
  @spec raw_query(String.t(), [term()]) :: {:ok, [[term()]]} | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def raw_query(sql, params \\ []) do
    with {:ok, %{rows: rows}} <-
           Connection.query(@pool, sql, params, timeout: Store.call_timeout()) do
      {:ok, rows}
    end
  end

  @doc "Runs one statement written for SQLite that returns no rows."
  @spec raw_execute(String.t(), [term()]) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def raw_execute(sql, params \\ []) do
    with {:ok, _} <- Connection.query(@pool, sql, params, timeout: Store.call_timeout()) do
      :ok
    end
  end

  @doc """
  Runs `fun` in one transaction, with the contract of
  `OptimalEngine.Store.Adapter`.

  The fun runs in the calling process. When PostgreSQL aborts the transaction
  to keep it serializable, it is rolled back and the fun runs again, so the fun
  must only change the database.
  """
  @spec transaction((term() -> {:ok, term()} | {:error, term()}), timeout()) ::
          {:ok, term()} | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def transaction(fun, timeout \\ 30_000) when is_function(fun, 1) do
    Connection.transaction(@pool, fun, timeout)
  end

  @doc """
  Runs a statement written for SQLite inside a transaction and returns its
  rows. A failed statement ends the transaction unless it passes
  `recoverable: true`, which runs it in a savepoint.
  """
  @spec txn_query(term(), String.t(), [term()], keyword()) :: {:ok, [[term()]]} | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def txn_query(txn, sql, params \\ [], opts \\ []) do
    with {:ok, %{rows: rows}} <- Connection.txn_query(txn, sql, params, recoverable(opts)),
         do: {:ok, rows}
  end

  @doc """
  Runs a statement written for SQLite inside a transaction and returns how many
  rows it changed. Options as for `txn_query/4`.
  """
  @spec txn_execute(term(), String.t(), [term()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def txn_execute(txn, sql, params \\ [], opts \\ []) do
    with {:ok, %{num_rows: count}} <- Connection.txn_query(txn, sql, params, recoverable(opts)),
         do: {:ok, count}
  end

  defp recoverable(opts), do: Keyword.take(opts, [:recoverable])

  # ---------------------------------------------------------------------------
  # Pipeline rows
  # ---------------------------------------------------------------------------

  @doc "Writes chunks in one transaction, replacing a chunk with the same id."
  @spec insert_chunks([struct() | map()]) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_chunks(chunks) when is_list(chunks) do
    write_all(chunks, fn txn, chunk ->
      [id | _] = params = SQLite.chunk_params(chunk)

      with {:ok, _} <- txn_native(txn, "DELETE FROM chunks WHERE id = $1", [id]) do
        Connection.txn_query(txn, @insert_chunk, params)
      end
    end)
  end

  @doc "Upserts chunk classifications in one transaction."
  @spec insert_classifications([struct() | map()]) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_classifications(rows) when is_list(rows),
    do: write_statements(rows, &SQLite.statement(:classification, &1))

  @doc "Upserts chunk intents in one transaction."
  @spec insert_intents([struct() | map()]) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_intents(rows) when is_list(rows),
    do: write_statements(rows, &SQLite.statement(:intent, &1))

  @doc "Upserts chunk embeddings in one transaction."
  @spec insert_embeddings([struct() | map()]) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_embeddings(rows) when is_list(rows),
    do: write_statements(rows, &SQLite.statement(:embedding, &1))

  @doc "Upserts clusters in one transaction."
  @spec insert_clusters([struct() | map()]) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_clusters(rows) when is_list(rows),
    do: write_statements(rows, &SQLite.statement(:cluster, &1))

  @doc "Upserts cluster memberships in one transaction."
  @spec insert_cluster_members([map()]) :: :ok | {:error, term()}
  @impl OptimalEngine.Store.Adapter
  def insert_cluster_members(rows) when is_list(rows),
    do: write_statements(rows, &SQLite.statement(:cluster_member, &1))

  # The SQLite store's own statements, through the dialect, so both stores
  # write the same rows.
  defp write_statements(rows, statement) do
    write_all(rows, fn txn, row ->
      {sql, params} = statement.(row)
      Connection.txn_query(txn, sql, params)
    end)
  end

  defp write_all([], _write), do: :ok

  defp write_all(rows, write) do
    result =
      Connection.transaction(
        @pool,
        fn txn ->
          Enum.reduce_while(rows, {:ok, :written}, fn row, ok ->
            case write.(txn, row) do
              {:ok, _} -> {:cont, ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end,
        60_000
      )

    with {:ok, _} <- result, do: :ok
  end

  # The store's own statements are written for PostgreSQL.
  defp native(sql, params, opts \\ []) do
    with {:ok, %{rows: rows}} <-
           Connection.query(@pool, sql, params, Keyword.put(opts, :dialect, :postgres)) do
      {:ok, rows}
    end
  end

  defp txn_native(txn, sql, params),
    do: Connection.txn_query(txn, sql, params, dialect: :postgres)
end
