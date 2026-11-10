defmodule OptimalEngine.Store.Postgres.Migrate do
  @moduledoc """
  Moves an existing SQLite Engine's canonical store into PostgreSQL, and
  proves the copy before it commits (stage 4 of
  `docs/guides/postgres-provider.md`).

  `run/1` never writes the Engine's own database file:

  1. The source is opened read-only and copied with `VACUUM INTO` to a
     snapshot, one consistent read of the whole database; the snapshot's
     SHA-256 is reported. A `:snapshot` that is already a backup is copied the
     same way.
  2. The snapshot, not the source, is brought to this build's schema with the
     SQLite store's own migrations, so an Engine one release behind moves too.
  3. The target schema is created and synced from the migrations
     (`OptimalEngine.Store.Postgres.Schema`) with the full-text objects
     (`OptimalEngine.Store.Postgres.FullText`). A target that already holds
     tables is refused unless `replace: true`.
  4. In one transaction, with every foreign key deferred to the commit, every
     table of the plan is emptied (the rows a fresh schema is seeded with,
     `sync_identity` among them, so the replica keeps its identity) and every
     row of the snapshot is inserted, each value converted to its PostgreSQL
     column's type with SQLite's affinity rules. Identity sequences move past
     the largest id and past SQLite's `AUTOINCREMENT` high-water mark.
  5. Still in that transaction, the copy is verified: per table, the row count
     and an order-independent checksum (the sum, modulo 2^256, of the SHA-256
     of each row's values as the PostgreSQL column holds them) are computed
     from the snapshot and read back from PostgreSQL, then the parity queries
     run against both, per workspace. Any difference rolls everything back.
  6. After the commit, the full-text indexes are rebuilt from the copied rows.

  `dry_run: true` does all of it and rolls the transaction back.

  The connection URL is `OPTIMAL_POSTGRES_URL` (or `:url`); it is never
  logged, returned or written. The report names tables, counts and checksums
  only.

  ## What is refused

  - A table or column the snapshot has and this build's schema does not
    (`{:unknown_tables, names}`, `{:unknown_columns, ...}`) unless
    `ignore_unknown: true`, which leaves it behind and reports it.
  - An Engine that has enabled replication or app data collections
    (`{:unsupported_in_use, features}`): both work on a PostgreSQL store,
    but this copy does not carry their state (the replication ledger's
    capture, the collections' own tables), so the Engine moves without them
    and turns them on again after.
  - A value PostgreSQL's column cannot hold as SQLite did (text that is not
    UTF-8, a non-integer in an integer column): the transaction rolls back
    with the table named.
  """

  require Logger

  alias OptimalEngine.Store.Postgres.{Affinity, Connection, FullText, Schema}

  @default_timeout 3_600_000
  @fetch 2_000

  @typedoc "What a migration did and what it proved."
  @type report :: %{
          snapshot: %{sha256: String.t(), bytes: non_neg_integer()},
          schema: String.t(),
          dry_run: boolean(),
          tables: [%{table: String.t(), rows: non_neg_integer(), checksum: String.t()}],
          ignored: %{tables: [String.t()], columns: [String.t()]},
          parity: %{workspaces: non_neg_integer(), queries: non_neg_integer()},
          full_text: [String.t()]
        }

  @doc """
  Copies the SQLite store at `:source` (default the configured `db_path`) into
  the PostgreSQL schema `:schema` (default the store's configured schema).

  Options: `:source`, `:snapshot` (copy this backup file instead of the live
  database), `:url`, `:schema`, `:replace`, `:ignore_unknown`, `:dry_run`,
  `:timeout` (milliseconds, default one hour), `:keep_snapshot`.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) do
    source = Keyword.get(opts, :snapshot) || Keyword.get(opts, :source) || default_source()
    dir = Path.join(System.tmp_dir!(), "optimal-migrate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    snapshot_path = Path.join(dir, "snapshot.db")

    try do
      with {:ok, snapshot} <- snapshot(source, snapshot_path),
           {:ok, db} <- open_migrated(snapshot_path) do
        try do
          migrate(db, Map.put(snapshot, :path, snapshot_path), opts)
        after
          Exqlite.Sqlite3.close(db)
        end
      end
    after
      if Keyword.get(opts, :keep_snapshot, false),
        do: Logger.info("[Migrate] snapshot kept at #{snapshot_path}"),
        else: File.rm_rf(dir)
    end
  end

  defp default_source, do: Application.get_env(:optimal_engine, :db_path, ".optimal/index.db")

  defp default_schema,
    do: Keyword.get(Application.get_env(:optimal_engine, :postgres_store, []), :schema, "public")

  # ---------------------------------------------------------------------------
  # Snapshot
  # ---------------------------------------------------------------------------

  defp snapshot(source, target) do
    cond do
      not File.regular?(source) ->
        {:error, {:source_not_found, source}}

      true ->
        with {:ok, db} <- Exqlite.Sqlite3.open(source, mode: :readonly) do
          try do
            literal = "'" <> String.replace(target, "'", "''") <> "'"

            case Exqlite.Sqlite3.execute(db, "VACUUM INTO #{literal}") do
              :ok -> {:ok, %{sha256: file_sha256(target), bytes: File.stat!(target).size}}
              {:error, reason} -> {:error, {:snapshot_failed, reason}}
            end
          after
            Exqlite.Sqlite3.close(db)
          end
        end
    end
  end

  defp file_sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp open_migrated(path) do
    with {:ok, db} <- Exqlite.Sqlite3.open(path) do
      case OptimalEngine.Store.SQLite.migrate(db) do
        :ok ->
          {:ok, db}

        other ->
          Exqlite.Sqlite3.close(db)
          {:error, {:snapshot_migration_failed, other}}
      end
    end
  rescue
    error -> {:error, {:snapshot_migration_failed, Exception.message(error)}}
  end

  # ---------------------------------------------------------------------------
  # Migration
  # ---------------------------------------------------------------------------

  defp migrate(db, snapshot, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    schema = Keyword.get(opts, :schema) || default_schema()

    with {:ok, plan} <- Schema.derive(),
         {:ok, layout} <- layout(db, plan, opts),
         :ok <- nothing_unsupported(db),
         {:ok, pool} <- start_pool(opts, schema) do
      try do
        with :ok <- target_empty(pool, schema, opts),
             {:ok, _} <- Schema.sync(pool, schema: schema),
             :ok <- FullText.ensure(pool),
             {:ok, result} <- copy(pool, db, layout, opts, timeout) do
          finish(pool, snapshot, schema, layout, result, opts)
        end
      after
        stop_pool(pool)
      end
    end
  end

  defp finish(pool, snapshot, schema, layout, result, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    full_text =
      if dry_run do
        []
      else
        for name <- Map.keys(OptimalEngine.Store.FullText.indexes()) |> Enum.sort() do
          :ok = FullText.rebuild(pool, name)
          {:ok, _} = FullText.refresh(pool, [name], timeout: 600_000)
          name
        end
      end

    {:ok,
     %{
       snapshot: Map.take(snapshot, [:sha256, :bytes]),
       schema: schema,
       dry_run: dry_run,
       tables: result.tables,
       ignored: layout.ignored,
       parity: result.parity,
       full_text: full_text
     }}
  end

  defp start_pool(opts, schema) do
    Connection.start_link(
      url: Keyword.get(opts, :url),
      schema: schema,
      pool_size: 2,
      statement_timeout: 0,
      lock_timeout: 0,
      idle_in_transaction_session_timeout: 0
    )
  end

  defp stop_pool(pool) do
    Process.unlink(pool)
    GenServer.stop(pool, :normal, 10_000)
  catch
    :exit, _ -> :ok
  end

  defp target_empty(pool, schema, opts) do
    {:ok, %{rows: [[count]]}} =
      Connection.query(
        pool,
        """
        SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r', 'p')
        """,
        [schema],
        dialect: :postgres
      )

    if count == 0 or Keyword.get(opts, :replace, false),
      do: :ok,
      else: {:error, {:target_not_empty, schema}}
  end

  # A precondition of this copy: an Engine that has enabled these is not
  # copied, because their state is not part of the copy (both work on a
  # PostgreSQL store; turn them on again after the move).
  @in_use [
    {"replication",
     "SELECT 1 FROM sync_workspaces UNION ALL SELECT 1 FROM sync_peers WHERE status <> 'disabled'"},
    {"app_data_collections", "SELECT 1 FROM data_collections"}
  ]

  defp nothing_unsupported(db) do
    case for({feature, sql} <- @in_use, sqlite!(db, "SELECT EXISTS (#{sql})") == [[1]], do: feature) do
      [] -> :ok
      features -> {:error, {:unsupported_in_use, features}}
    end
  end

  # ---------------------------------------------------------------------------
  # Layout: which tables and columns move
  # ---------------------------------------------------------------------------

  defp layout(db, plan, opts) do
    source_tables =
      db
      |> sqlite!("""
      SELECT name FROM sqlite_master
      WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
        AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'
      ORDER BY name
      """)
      |> Enum.map(&hd/1)
      |> Enum.reject(&full_text_shadow?(db, &1))

    planned = MapSet.new(plan.tables, & &1.name)
    unknown_tables = Enum.reject(source_tables, &MapSet.member?(planned, &1))
    present = MapSet.new(source_tables)

    tables =
      for table <- plan.tables, MapSet.member?(present, table.name) do
        source_columns =
          db |> sqlite!("SELECT name FROM pragma_table_info(?1)", [table.name]) |> Enum.map(&hd/1)

        names = MapSet.new(source_columns)
        columns = Enum.filter(table.columns, &MapSet.member?(names, &1.name))
        known = MapSet.new(table.columns, & &1.name)
        extra = for c <- source_columns, not MapSet.member?(known, c), do: "#{table.name}.#{c}"
        %{name: table.name, columns: columns, extra: extra}
      end

    unknown_columns = Enum.flat_map(tables, & &1.extra)
    ignored = %{tables: unknown_tables, columns: unknown_columns}

    cond do
      Keyword.get(opts, :ignore_unknown, false) -> {:ok, %{tables: tables, ignored: ignored}}
      unknown_tables != [] -> {:error, {:unknown_tables, unknown_tables}}
      unknown_columns != [] -> {:error, {:unknown_columns, unknown_columns}}
      true -> {:ok, %{tables: tables, ignored: ignored}}
    end
  end

  # FTS5 keeps its index in ordinary tables named after the virtual table.
  defp full_text_shadow?(db, name) do
    case Regex.run(~r/\A(.+)_(data|idx|docsize|config|content)\z/, name) do
      [_, base, _] ->
        sqlite!(
          db,
          "SELECT 1 FROM sqlite_master WHERE name = ?1 AND sql LIKE 'CREATE VIRTUAL TABLE%'",
          [base]
        ) != []

      nil ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Copy and verify, in one transaction
  # ---------------------------------------------------------------------------

  defp copy(pool, db, layout, opts, timeout) do
    after_import = Keyword.get(opts, :after_import, fn _txn -> :ok end)
    dry_run = Keyword.get(opts, :dry_run, false)

    result =
      Connection.transaction(
        pool,
        fn txn ->
          with :ok <- pg(txn, "SET CONSTRAINTS ALL DEFERRED"),
               :ok <- truncate(txn, layout.tables),
               {:ok, source} <- insert_all(txn, db, layout.tables),
               :ok <- advance_identities(txn, db, layout.tables),
               :ok <- after_import.(txn),
               {:ok, tables} <- verify_tables(txn, layout.tables, source),
               {:ok, parity} <- parity(txn, db) do
            result = %{tables: tables, parity: parity}
            if dry_run, do: {:error, {:dry_run, result}}, else: {:ok, result}
          end
        end,
        timeout
      )

    case result do
      {:error, {:dry_run, result}} -> {:ok, result}
      other -> other
    end
  end

  defp truncate(_txn, []), do: :ok

  defp truncate(txn, tables) do
    pg(txn, "TRUNCATE #{Enum.map_join(tables, ", ", &quote_name(&1.name))} CASCADE")
  end

  defp insert_all(txn, db, tables) do
    Enum.reduce_while(tables, {:ok, %{}}, fn table, {:ok, acc} ->
      case insert_table(txn, db, table) do
        {:ok, summary} -> {:cont, {:ok, Map.put(acc, table.name, summary)}}
        {:error, reason} -> {:halt, {:error, {:copy_failed, table.name, reason}}}
      end
    end)
  end

  defp insert_table(_txn, _db, %{columns: []}), do: {:ok, %{rows: 0, sum: 0}}

  defp insert_table(txn, db, table) do
    names = Enum.map_join(table.columns, ", ", &quote_name(&1.name))
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, "SELECT #{names} FROM #{quote_name(table.name)}")
    batch = max(1, min(500, div(60_000, length(table.columns))))

    try do
      stream_rows(db, statement, %{rows: 0, sum: 0}, fn rows, acc ->
        converted = Enum.map(rows, &convert_row(&1, table.columns))

        converted
        |> Enum.chunk_every(batch)
        |> Enum.reduce_while(:ok, fn chunk, :ok ->
          case insert_rows(txn, table, names, chunk) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
        |> case do
          :ok -> {:ok, %{rows: acc.rows + length(converted), sum: add_rows(acc.sum, converted)}}
          error -> error
        end
      end)
    rescue
      error in DBConnection.EncodeError -> {:error, Exception.message(error)}
      error in ArgumentError -> {:error, Exception.message(error)}
    after
      Exqlite.Sqlite3.release(db, statement)
    end
  end

  defp stream_rows(db, statement, acc, fun) do
    case Exqlite.Sqlite3.multi_step(db, statement, @fetch) do
      {:rows, rows} ->
        with {:ok, acc} <- fun.(rows, acc), do: stream_rows(db, statement, acc, fun)

      {:done, rows} ->
        fun.(rows, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_rows(txn, table, names, rows) do
    width = length(table.columns)

    values =
      rows
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {_row, r} ->
        "(" <> Enum.map_join(1..width, ", ", &"$#{r * width + &1}") <> ")"
      end)

    sql = "INSERT INTO #{quote_name(table.name)} (#{names}) VALUES #{values}"

    case Connection.txn_query(txn, sql, List.flatten(rows), dialect: :postgres) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Each value as its PostgreSQL column holds it, with SQLite's conversions.
  defp convert_row(row, columns) do
    row
    |> Enum.zip(columns)
    |> Enum.map(fn {value, column} -> convert(value, column) end)
  end

  defp convert(nil, _column), do: nil

  defp convert(value, %{type: type, name: name}) do
    cond do
      String.starts_with?(type, "BIGINT") ->
        Affinity.to_integer(value, -9_223_372_036_854_775_808..9_223_372_036_854_775_807)

      String.starts_with?(type, "DOUBLE") ->
        Affinity.to_float(value)

      String.starts_with?(type, "BYTEA") ->
        Affinity.to_bytes(value)

      String.starts_with?(type, "TEXT") ->
        text = Affinity.to_text(value)

        if String.valid?(text) and not String.contains?(text, <<0>>),
          do: text,
          else: raise(ArgumentError, "column #{name} holds a value that is not UTF-8 text")

      true ->
        raise ArgumentError, "column #{name} has a type the migration does not map: #{type}"
    end
  end

  # Order-independent: the sum of the rows' digests modulo 2^256, so equal
  # multisets of rows give equal checksums whatever order they are read in.
  @modulus Integer.pow(2, 256)

  defp add_rows(sum, rows) do
    Enum.reduce(rows, sum, fn row, acc -> rem(acc + row_digest(row), @modulus) end)
  end

  defp row_digest(row) do
    <<digest::unsigned-256>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(row, [:deterministic, minor_version: 2]))

    digest
  end

  defp verify_tables(txn, tables, source) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, acc} ->
      expected = Map.fetch!(source, table.name)

      with {:ok, actual} <- postgres_summary(txn, table) do
        if actual == expected do
          entry = %{table: table.name, rows: actual.rows, checksum: hex(actual.sum)}
          {:cont, {:ok, acc ++ [entry]}}
        else
          {:halt,
           {:error,
            {:verification_failed,
             %{
               table: table.name,
               sqlite: %{rows: expected.rows, checksum: hex(expected.sum)},
               postgres: %{rows: actual.rows, checksum: hex(actual.sum)}
             }}}}
        end
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp postgres_summary(_txn, %{columns: []}), do: {:ok, %{rows: 0, sum: 0}}

  defp postgres_summary(txn, table) do
    names = Enum.map_join(table.columns, ", ", &quote_name(&1.name))

    with :ok <-
           pg(
             txn,
             "DECLARE optimal_migrate_rows NO SCROLL CURSOR FOR SELECT #{names} FROM #{quote_name(table.name)}"
           ),
         {:ok, summary} <- fetch_summary(txn, %{rows: 0, sum: 0}),
         :ok <- pg(txn, "CLOSE optimal_migrate_rows") do
      {:ok, summary}
    end
  end

  defp fetch_summary(txn, acc) do
    case Connection.txn_query(txn, "FETCH #{@fetch} FROM optimal_migrate_rows", [],
           dialect: :postgres
         ) do
      {:ok, %{rows: []}} ->
        {:ok, acc}

      {:ok, %{rows: rows}} ->
        fetch_summary(txn, %{rows: acc.rows + length(rows), sum: add_rows(acc.sum, rows)})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hex(sum), do: sum |> :binary.encode_unsigned() |> Base.encode16(case: :lower)

  # The next generated id follows the largest id copied, and SQLite's
  # AUTOINCREMENT high-water mark, so an id SQLite would never hand out again
  # is not handed out by PostgreSQL either.
  defp advance_identities(txn, db, tables) do
    copied = MapSet.new(tables, & &1.name)

    high_water =
      if sqlite!(db, "SELECT 1 FROM sqlite_master WHERE name = 'sqlite_sequence'") == [],
        do: %{},
        else: db |> sqlite!("SELECT name, seq FROM sqlite_sequence") |> Map.new(&List.to_tuple/1)

    Schema.identity_columns()
    |> Enum.filter(fn {table, _column} -> MapSet.member?(copied, table) end)
    |> Enum.reduce_while(:ok, fn {table, column}, :ok ->
      sql = """
      SELECT setval(pg_get_serial_sequence($1, $2),
                    GREATEST(COALESCE((SELECT MAX(#{quote_name(column)}) FROM #{quote_name(table)}), 0), $3, 1),
                    GREATEST(COALESCE((SELECT MAX(#{quote_name(column)}) FROM #{quote_name(table)}), 0), $3) > 0)
      """

      case Connection.txn_query(txn, sql, [table, column, Map.get(high_water, table, 0)],
             dialect: :postgres
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:identity_failed, table, reason}}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Parity
  # ---------------------------------------------------------------------------

  defp parity(txn, db) do
    workspaces =
      db
      |> sqlite!("""
      SELECT workspace_id FROM contexts UNION SELECT workspace_id FROM memories
      UNION SELECT id FROM workspaces ORDER BY 1
      """)
      |> Enum.map(&hd/1)

    mismatches =
      for workspace <- workspaces,
          {sql, params} <- parity_queries(workspace),
          expected = sqlite!(db, sql, params),
          actual = postgres_rows(txn, sql, params),
          actual != expected do
        %{workspace: workspace, sql: sql, sqlite: Enum.take(expected, 3), postgres: actual}
      end

    case mismatches do
      [] ->
        {:ok,
         %{workspaces: length(workspaces), queries: length(parity_queries("")) * length(workspaces)}}

      _ ->
        {:error, {:parity_failed, Enum.take(mismatches, 5)}}
    end
  end

  defp postgres_rows(txn, sql, params) do
    case Connection.txn_query(txn, sql, params) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Twenty reads, per workspace, of the shapes the engine issues: counts,
  ordering and pagination, grouping, joins, subqueries, text timestamps,
  entities, edges, memories, claims, facts, chunks and the `signals` view. A
  migration commits only when each returns the same rows from the snapshot and
  from PostgreSQL.
  """
  @spec parity_queries(String.t()) :: [{String.t(), [term()]}]
  def parity_queries(ws) do
    [
      {"SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [ws]},
      {"SELECT id, title, node, type, sn_ratio FROM contexts WHERE workspace_id = ?1 ORDER BY id",
       [ws]},
      {"SELECT node, COUNT(*) FROM contexts WHERE workspace_id = ?1 GROUP BY node ORDER BY node",
       [ws]},
      {"SELECT id FROM contexts WHERE workspace_id = ?1 ORDER BY modified_at DESC, id LIMIT 10",
       [ws]},
      {"SELECT id FROM contexts WHERE workspace_id = ?1 ORDER BY modified_at DESC, id LIMIT 10 OFFSET 10",
       [ws]},
      {"SELECT type, COUNT(*), MIN(sn_ratio), MAX(sn_ratio) FROM contexts WHERE workspace_id = ?1 GROUP BY type ORDER BY type",
       [ws]},
      {"SELECT name, COUNT(*) FROM entities WHERE workspace_id = ?1 GROUP BY name ORDER BY name",
       [ws]},
      {"SELECT e.name, c.id FROM entities e JOIN contexts c ON c.id = e.context_id WHERE c.workspace_id = ?1 ORDER BY e.name, c.id",
       [ws]},
      {"SELECT relation, COUNT(*), MIN(weight), MAX(weight) FROM graph_edges WHERE workspace_id = ?1 GROUP BY relation ORDER BY relation",
       [ws]},
      {"SELECT source_id, target_id, relation, weight FROM graph_edges WHERE workspace_id = ?1 ORDER BY source_id, target_id, relation",
       [ws]},
      {"SELECT c.id, (SELECT COUNT(*) FROM entities e WHERE e.context_id = c.id) FROM contexts c WHERE c.workspace_id = ?1 ORDER BY c.id",
       [ws]},
      {"SELECT id, CASE WHEN sn_ratio >= 0.5 THEN 'high' ELSE 'low' END FROM contexts WHERE workspace_id = ?1 ORDER BY id",
       [ws]},
      {"SELECT id, created_at, modified_at FROM contexts WHERE workspace_id = ?1 AND modified_at >= '2000-01-01' ORDER BY id",
       [ws]},
      {"SELECT id, title, genre FROM signals WHERE id IN (SELECT id FROM contexts WHERE workspace_id = ?1) ORDER BY id",
       [ws]},
      {"SELECT id, version, is_latest, is_forgotten, content FROM memories WHERE workspace_id = ?1 ORDER BY id",
       [ws]},
      {"SELECT audience, COUNT(*) FROM memories WHERE workspace_id = ?1 AND is_latest = 1 GROUP BY audience ORDER BY audience",
       [ws]},
      {"SELECT id, claim_text, review_status FROM claims WHERE workspace_id = ?1 ORDER BY id",
       [ws]},
      {"SELECT id, fact_text, accepted_claim_ids FROM facts WHERE workspace_id = ?1 ORDER BY id",
       [ws]},
      {"SELECT signal_id, scale, COUNT(*), SUM(length_bytes) FROM chunks WHERE workspace_id = ?1 GROUP BY signal_id, scale ORDER BY signal_id, scale",
       [ws]},
      {"SELECT ch.id, LENGTH(ce.vector), ce.dim, ce.model FROM chunks ch JOIN chunk_embeddings ce ON ce.chunk_id = ch.id WHERE ch.workspace_id = ?1 ORDER BY ch.id",
       [ws]}
    ]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp pg(txn, sql) do
    case Connection.txn_query(txn, sql, [], dialect: :postgres) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sqlite!(db, sql, params \\ []) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(statement, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
      rows
    after
      Exqlite.Sqlite3.release(db, statement)
    end
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
