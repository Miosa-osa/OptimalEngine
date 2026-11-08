defmodule OptimalEngine.Backup.Postgres do
  @moduledoc """
  Backups of a PostgreSQL store, in the format of a SQLite backup.

  A backup of a PostgreSQL store is a SQLite database file: the engine's own
  migrations create its schema, and every table of the store is copied into it
  from one PostgreSQL snapshot (`SERIALIZABLE, READ ONLY, DEFERRABLE`, so the
  copy is consistent and never aborted). Everything a backup goes through after
  that is the SQLite path, unchanged: the SHA-256 checksum, `PRAGMA
  integrity_check`, the catalog row, sealing with the backup envelope, the
  offsite copy, the schedule, and an offsite restore to a file. The FTS5
  tables of the file are filled by its own triggers, so the file is a
  complete, searchable engine database that a SQLite engine can also open.

  ## Why not pg_dump

  `pg_dump` needs a client of the server's major version on the machine and
  writes a format only `pg_restore` reads, into a schema of the dump's own
  name. The copy here needs nothing beyond the engine's connection, restores
  into any schema, is checked by the same integrity check and checksum as
  every other backup, and its rows are compared with the database's before a
  restore commits.

  ## Restoring

  `restore/3` copies a backup file into a schema in one transaction:

  1. The file's migration versions must be the build's; a backup of another
     schema version is refused (`{:backup_schema_mismatch, ...}`).
  2. Every table of the store, and the full-text index tables, are locked
     `ACCESS EXCLUSIVE`, so every other engine's reads and writes wait until
     the restore commits or rolls back: no write lands during a restore.
  3. The tables are emptied, the file's rows inserted, and each identity
     column's sequence is moved past its largest id. The full-text indexes are
     emptied and every restored row is queued for them by their triggers.
  4. The row count and a digest of every table are compared with the file's;
     any difference rolls the restore back.

  The digest of a table is the sum, modulo 2^256, of the SHA-256 of each row
  normalised by its column type, so it does not depend on row order.
  """

  alias OptimalEngine.Store.Postgres.{Connection, FullText, Schema}

  @store_pool OptimalEngine.Store.Postgres.Pool
  @chunk 500
  @modulus Integer.pow(2, 256)

  @fts_tables ~w(optimal_fts_docs optimal_fts_postings optimal_fts_queue)

  @doc """
  Runs `fun` with a pool on `schema` (default: the configured schema). The
  running store's pool is used when it serves that schema; otherwise a pool of
  its own is started and stopped afterwards, so a restore works before boot.
  """
  @spec with_pool(keyword(), (GenServer.server() -> result)) :: result | {:error, term()}
        when result: term()
  def with_pool(opts, fun) do
    configured = configured_schema()
    schema = Keyword.get(opts, :schema, configured)

    if schema == configured and Process.whereis(@store_pool) do
      fun.(@store_pool)
    else
      pool_opts =
        Application.get_env(:optimal_engine, :postgres_store, [])
        |> Keyword.merge(Keyword.take(opts, [:url]))
        |> Keyword.merge(schema: schema, pool_size: 2)
        |> Keyword.delete(:name)

      {:ok, _} = Application.ensure_all_started(:postgrex)

      case Connection.start_link(pool_opts) do
        {:ok, pool} ->
          try do
            fun.(pool)
          after
            Process.unlink(pool)
            GenServer.stop(pool, :normal, 15_000)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "The schema the PostgreSQL store is configured for."
  @spec configured_schema() :: String.t()
  def configured_schema,
    do: Keyword.get(Application.get_env(:optimal_engine, :postgres_store, []), :schema, "public")

  @doc "True when `schema` holds tables of the store."
  @spec populated?(GenServer.server()) :: boolean()
  def populated?(pool) do
    case Postgrex.query(
           pool,
           "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = current_schema() AND tablename = 'schema_migrations')",
           []
         ) do
      {:ok, %{rows: [[true]]}} -> true
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshot to a file
  # ---------------------------------------------------------------------------

  @doc """
  Copies every table of the store into a new SQLite database at `target`,
  from one consistent snapshot. Returns the row count of each table.
  """
  @spec snapshot(GenServer.server(), String.t()) ::
          {:ok, %{tables: %{String.t() => non_neg_integer()}}} | {:error, term()}
  def snapshot(pool, target) do
    with {:ok, plan} <- Schema.derive(),
         {:ok, db} <- Exqlite.Sqlite3.open(target) do
      result =
        try do
          with :ok <- prepare_file(db, plan) do
            Postgrex.transaction(
              pool,
              fn conn ->
                Postgrex.query!(
                  conn,
                  "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ ONLY, DEFERRABLE",
                  []
                )

                Postgrex.query!(conn, "SET LOCAL statement_timeout = 0", [])
                Postgrex.query!(conn, "SET LOCAL idle_in_transaction_session_timeout = 0", [])
                copy_out(conn, db, plan)
              end,
              timeout: :infinity
            )
          end
        after
          finish_file(db)
        end

      case result do
        {:ok, tables} ->
          {:ok, %{tables: tables}}

        {:error, reason} ->
          File.rm(target)
          {:error, reason}
      end
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      File.rm(target)
      {:error, {:postgres_backup_failed, Exception.message(error)}}
  end

  # The migrated schema, with the rows the migrations seed removed: every row
  # of the file comes from the snapshot.
  defp prepare_file(db, plan) do
    with :ok <- OptimalEngine.Store.SQLite.migrate(db),
         :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA foreign_keys = OFF"),
         :ok <- Exqlite.Sqlite3.execute(db, "BEGIN") do
      Enum.reduce_while(plan.tables, :ok, fn table, :ok ->
        case Exqlite.Sqlite3.execute(db, "DELETE FROM #{quote_name(table.name)}") do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:backup_file_failed, reason}}}
        end
      end)
    end
  end

  defp copy_out(conn, db, plan) do
    tables =
      Map.new(plan.tables, fn table ->
        names = Enum.map(table.columns, & &1.name)
        blobs = Enum.map(table.columns, &(&1.type == "BYTEA"))
        marks = Enum.map_join(1..length(names), ", ", fn _ -> "?" end)

        {:ok, insert} =
          Exqlite.Sqlite3.prepare(
            db,
            "INSERT INTO #{quote_name(table.name)} (#{column_list(names)}) VALUES (#{marks})"
          )

        count =
          try do
            conn
            |> Postgrex.stream("SELECT #{column_list(names)} FROM #{quote_name(table.name)}", [],
              max_rows: 2_000
            )
            |> Enum.reduce(0, fn %{rows: rows}, count ->
              Enum.each(rows, &insert_row(db, insert, &1, blobs, table.name))
              count + length(rows)
            end)
          after
            Exqlite.Sqlite3.release(db, insert)
          end

        {table.name, count}
      end)

    case Exqlite.Sqlite3.execute(db, "COMMIT") do
      :ok -> tables
      {:error, reason} -> Postgrex.rollback(conn, {:backup_file_failed, reason})
    end
  end

  defp insert_row(db, insert, row, blobs, table) do
    values =
      Enum.zip_with(row, blobs, fn
        value, true when is_binary(value) -> {:blob, value}
        value, _ -> value
      end)

    :ok = Exqlite.Sqlite3.bind(insert, values)

    case Exqlite.Sqlite3.step(db, insert) do
      :done -> :ok = Exqlite.Sqlite3.reset(insert)
      other -> raise "backup of #{table} failed: #{inspect(other)}"
    end
  end

  # One self-contained file: no WAL left beside it for the checksum to miss.
  defp finish_file(db) do
    Exqlite.Sqlite3.execute(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode = DELETE")
    Exqlite.Sqlite3.close(db)
  end

  # ---------------------------------------------------------------------------
  # Restore from a file
  # ---------------------------------------------------------------------------

  @doc """
  Replaces the contents of the pool's schema with the backup at `source`,
  creating the schema's tables first when it has none (`:schema` names the
  pool's schema, which a schema that does not exist yet cannot report). See
  the moduledoc for the steps; returns the row count of each table.
  """
  @spec restore(GenServer.server(), String.t(), keyword()) ::
          {:ok, %{tables: %{String.t() => non_neg_integer()}}} | {:error, term()}
  def restore(pool, source, opts \\ []) do
    with {:ok, plan} <- Schema.derive(),
         {:ok, file_digests} <- file_digests(source, plan),
         :ok <- same_versions(source, plan),
         {:ok, _} <-
           Schema.sync(pool, schema: Keyword.get_lazy(opts, :schema, fn -> pool_schema(pool) end)),
         :ok <- FullText.ensure(pool),
         {:ok, tables} <- import(pool, source, plan, file_digests) do
      {:ok, %{tables: tables}}
    end
  end

  defp pool_schema(pool) do
    %{rows: [[schema]]} = Postgrex.query!(pool, "SELECT current_schema()", [])
    schema
  end

  defp same_versions(source, plan) do
    versions =
      read_file(source, fn db ->
        db |> all("SELECT version FROM schema_migrations ORDER BY version") |> Enum.map(&hd/1)
      end)

    if versions == plan.versions,
      do: :ok,
      else:
        {:error,
         {:backup_schema_mismatch,
          %{missing: plan.versions -- versions, unknown: versions -- plan.versions}}}
  end

  defp import(pool, source, plan, file_digests) do
    identity = Schema.identity_columns()
    names = Enum.map(plan.tables, & &1.name)

    Postgrex.transaction(
      pool,
      fn conn ->
        Postgrex.query!(conn, "SET LOCAL statement_timeout = 0", [])
        Postgrex.query!(conn, "SET LOCAL idle_in_transaction_session_timeout = 0", [])
        Postgrex.query!(conn, "SET CONSTRAINTS ALL DEFERRED", [])

        Postgrex.query!(
          conn,
          "LOCK TABLE #{Enum.map_join(names ++ @fts_tables ++ ["optimal_fts_totals"], ", ", &quote_name/1)} IN ACCESS EXCLUSIVE MODE",
          []
        )

        Postgrex.query!(
          conn,
          "TRUNCATE #{Enum.map_join(names ++ @fts_tables, ", ", &quote_name/1)}",
          []
        )

        Postgrex.query!(conn, "UPDATE optimal_fts_totals SET docs = 0, tokens = 0", [])

        read_file(source, fn db ->
          Enum.each(plan.tables, &copy_in(conn, db, &1, identity))
        end)

        live = pool_digests(conn, plan)

        case Enum.reject(plan.tables, &(Map.get(live, &1.name) == Map.get(file_digests, &1.name))) do
          [] ->
            Map.new(live, fn {table, {count, _digest}} -> {table, count} end)

          differ ->
            Postgrex.rollback(conn, {:restore_mismatch, Enum.map(differ, & &1.name)})
        end
      end,
      timeout: :infinity
    )
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, {:postgres_restore_failed, Exception.message(error)}}
  end

  defp copy_in(conn, db, table, identity) do
    names = Enum.map(table.columns, & &1.name)
    width = length(names)
    per_statement = max(1, min(@chunk, div(60_000, width)))

    {:ok, select} =
      Exqlite.Sqlite3.prepare(db, "SELECT #{column_list(names)} FROM #{quote_name(table.name)}")

    try do
      select
      |> rows_of(db)
      |> Stream.chunk_every(per_statement)
      |> Enum.each(fn rows ->
        values =
          rows
          |> Enum.with_index()
          |> Enum.map_join(", ", fn {_row, i} ->
            "(" <> Enum.map_join(1..width, ", ", &"$#{i * width + &1}") <> ")"
          end)

        Postgrex.query!(
          conn,
          "INSERT INTO #{quote_name(table.name)} (#{column_list(names)}) VALUES #{values}",
          Enum.concat(rows)
        )
      end)
    after
      Exqlite.Sqlite3.release(db, select)
    end

    case Map.fetch(identity, table.name) do
      {:ok, column} ->
        Postgrex.query!(
          conn,
          "SELECT setval(pg_get_serial_sequence($1, $2), GREATEST(COALESCE(MAX(#{quote_name(column)}), 0), 1), MAX(#{quote_name(column)}) IS NOT NULL) FROM #{quote_name(table.name)}",
          [table.name, column]
        )

      :error ->
        :ok
    end
  end

  defp rows_of(statement, db) do
    Stream.unfold(:go, fn _ ->
      case Exqlite.Sqlite3.step(db, statement) do
        {:row, row} -> {row, :go}
        :done -> nil
        {:error, reason} -> raise "reading the backup failed: #{inspect(reason)}"
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Digests
  # ---------------------------------------------------------------------------

  @doc "The row count and digest of every store table in a backup file."
  @spec file_digests(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def file_digests(path, plan) do
    if File.regular?(path) do
      {:ok,
       read_file(path, fn db ->
         Map.new(plan.tables, fn table ->
           names = Enum.map(table.columns, & &1.name)

           {:ok, select} =
             Exqlite.Sqlite3.prepare(
               db,
               "SELECT #{column_list(names)} FROM #{quote_name(table.name)}"
             )

           try do
             {table.name, digest(rows_of(select, db), table)}
           after
             Exqlite.Sqlite3.release(db, select)
           end
         end)
       end)}
    else
      {:error, {:source_missing, path}}
    end
  end

  @doc "The row count and digest of every store table in the pool's schema."
  @spec digests(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def digests(pool) do
    with {:ok, plan} <- Schema.derive() do
      Postgrex.transaction(
        pool,
        fn conn ->
          Postgrex.query!(
            conn,
            "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ ONLY, DEFERRABLE",
            []
          )

          pool_digests(conn, plan)
        end,
        timeout: :infinity
      )
    end
  end

  defp pool_digests(conn, plan) do
    Map.new(plan.tables, fn table ->
      names = Enum.map(table.columns, & &1.name)

      rows =
        conn
        |> Postgrex.stream("SELECT #{column_list(names)} FROM #{quote_name(table.name)}", [],
          max_rows: 2_000
        )
        |> Stream.flat_map(& &1.rows)

      {table.name, digest(rows, table)}
    end)
  end

  defp digest(rows, table) do
    types = Enum.map(table.columns, & &1.type)

    Enum.reduce(rows, {0, 0}, fn row, {count, sum} ->
      normalised = Enum.zip_with(row, types, &normalise/2)
      <<n::unsigned-size(256)>> = :crypto.hash(:sha256, :erlang.term_to_binary(normalised))
      {count + 1, rem(sum + n, @modulus)}
    end)
  end

  # The value each store gives back for one column type.
  defp normalise(nil, _type), do: nil
  defp normalise(value, "DOUBLE PRECISION") when is_number(value), do: value * 1.0
  defp normalise(value, "BIGINT") when is_float(value) and value == trunc(value), do: trunc(value)
  defp normalise(value, _type), do: value

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp read_file(path, fun) do
    {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

    try do
      fun.(db)
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  defp all(db, sql) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)

    try do
      Enum.to_list(rows_of(statement, db))
    after
      Exqlite.Sqlite3.release(db, statement)
    end
  end

  defp column_list(names), do: Enum.map_join(names, ", ", &quote_name/1)

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
