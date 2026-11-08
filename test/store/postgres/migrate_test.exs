defmodule OptimalEngine.Store.Postgres.MigrateTest do
  @moduledoc """
  An SQLite Engine moves to PostgreSQL with every row, proved before the
  commit: counts, checksums and parity queries match, the replica keeps its
  identity, full-text search ranks as FTS5 did on the source, and a copy that
  does not match commits nothing.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store.FullText
  alias OptimalEngine.Store.Postgres.{Connection, Migrate}
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres

  setup do
    dir = Path.join(System.tmp_dir!(), "oe-migrate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "index.db")
    build_source(path)
    schema = PostgresStore.unique_schema("oe_migrate")

    on_exit(fn ->
      PostgresStore.drop_schema(schema)
      File.rm_rf!(dir)
    end)

    %{path: path, schema: schema}
  end

  defp build_source(path) do
    {:ok, db} = Exqlite.Sqlite3.open(path)
    :ok = OptimalEngine.Store.SQLite.migrate(db)

    statements = [
      "INSERT INTO tenants (id, name) VALUES ('acme', 'Acme')",
      "INSERT INTO workspaces (id, tenant_id, slug, name) VALUES ('acme:ops', 'acme', 'ops', 'Ops')",
      "UPDATE sync_identity SET replica_id = 'replica-from-sqlite' WHERE id = 1",
      """
      INSERT INTO contexts (id, uri, type, title, content, node, sn_ratio, metadata, workspace_id, tenant_id, created_at, modified_at)
      VALUES ('c1', 'optimal://acme/c1', 'resource', 'Launch plan', 'The platform launch plan, launch week', 'ops', 0.75, '{"k": 1}', 'acme:ops', 'acme', '2026-10-01T09:00:00Z', '2026-10-02T09:00:00Z'),
             ('c2', 'optimal://acme/c2', 'signal', 'Retro', 'what went wrong with the go-live', 'ops', 0.25, '{}', 'acme:ops', 'acme', '2026-10-03T09:00:00Z', '2026-10-04T09:00:00Z'),
             ('c3', 'optimal://default/c3', 'resource', 'Café', 'naïve résumé, launch', 'inbox', 0.5, '{}', 'default', 'default', '2026-10-05T09:00:00Z', NULL)
      """,
      "INSERT INTO entities (context_id, name, type, workspace_id, tenant_id) VALUES ('c1', 'Ana', 'person', 'acme:ops', 'acme'), ('c2', 'Ana', 'person', 'acme:ops', 'acme')",
      "INSERT INTO graph_edges (tenant_id, workspace_id, source_id, target_id, relation, weight) VALUES ('acme', 'acme:ops', 'c1', 'c2', 'cross_ref', 0.5), ('acme', 'acme:ops', 'c2', 'c1', 'co_occurs', 1.25)",
      # An AUTOINCREMENT id deleted at the top: PostgreSQL must not hand it out again.
      "INSERT INTO graph_edges (id, tenant_id, workspace_id, source_id, target_id) VALUES (900, 'acme', 'acme:ops', 'c1', 'c3')",
      "DELETE FROM graph_edges WHERE id = 900",
      "INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES ('m1', 'acme', 'acme:ops', 'running the launch runbook'), ('m2', 'acme', 'acme:ops', 'connections connected')",
      "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash) VALUES ('sp1', 'acme', 'acme:ops', 'h1')",
      "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, claim_text) VALUES ('cl1', 'acme', 'acme:ops', 'sp1', 'launch is on friday')",
      "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, accepted_claim_ids) VALUES ('f1', 'acme', 'acme:ops', 'launch is on friday', '[\"cl1\"]')",
      "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, length_bytes, workspace_id) VALUES ('ch1', 'acme', 'c1', 'section', 'The platform launch plan', 24, 'acme:ops')"
    ]

    for sql <- statements, do: :ok = Exqlite.Sqlite3.execute(db, sql)

    {:ok, insert} =
      Exqlite.Sqlite3.prepare(
        db,
        "INSERT INTO chunk_embeddings (chunk_id, tenant_id, model, modality, dim, vector) VALUES ('ch1', 'acme', 'm', 'text', 3, ?1)"
      )

    vector = <<1.0::float-32-little, -2.5::float-32-little, 0.0::float-32-little, 0, 255>>
    :ok = Exqlite.Sqlite3.bind(insert, [{:blob, vector}])
    :done = Exqlite.Sqlite3.step(db, insert)
    :ok = Exqlite.Sqlite3.release(db, insert)
    :ok = Exqlite.Sqlite3.close(db)
  end

  defp sqlite_rows(path, sql, params \\ []) do
    {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
      :ok = Exqlite.Sqlite3.bind(statement, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
      rows
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  defp with_pool(schema, fun) do
    {:ok, pool} = Connection.start_link(url: PostgresStore.url(), schema: schema, pool_size: 1)

    try do
      fun.(pool)
    after
      Process.unlink(pool)
      GenServer.stop(pool)
    end
  end

  defp pg_rows(pool, sql, params \\ []) do
    {:ok, %{rows: rows}} = Connection.query(pool, sql, params)
    rows
  end

  defp migrate(path, schema, opts \\ []) do
    Migrate.run([source: path, url: PostgresStore.url(), schema: schema] ++ opts)
  end

  test "every row moves, and the report proves it", %{path: path, schema: schema} do
    before = File.read!(path)
    assert {:ok, report} = migrate(path, schema)

    # The Engine's own file is only read.
    assert File.read!(path) == before
    assert report.dry_run == false
    assert byte_size(report.snapshot.sha256) == 64
    assert report.parity.workspaces >= 2
    assert report.parity.queries == 20 * report.parity.workspaces
    assert report.full_text == ["contexts_fts", "memories_fts"]
    refute inspect(report) =~ "postgres://"

    rows = Map.new(report.tables, &{&1.table, &1.rows})
    assert rows["contexts"] == 3
    assert rows["entities"] == 2
    assert rows["graph_edges"] == 2
    assert rows["memories"] == 2
    assert rows["claims"] == 1
    assert rows["chunk_embeddings"] == 1

    with_pool(schema, fn pool ->
      for {table, count} <- rows do
        assert pg_rows(pool, ~s[SELECT COUNT(*) FROM "#{table}"]) == [[count]], table
      end

      # The replica keeps the identity it had on SQLite.
      assert pg_rows(pool, "SELECT replica_id FROM sync_identity") == [["replica-from-sqlite"]]

      # Blobs are bytes, byte for byte.
      [[vector]] = sqlite_rows(path, "SELECT vector FROM chunk_embeddings")
      assert pg_rows(pool, "SELECT vector FROM chunk_embeddings") == [[vector]]

      # The next edge id passes SQLite's AUTOINCREMENT high-water mark.
      :ok =
        with(
          {:ok, _} <-
            Connection.query(
              pool,
              "INSERT INTO graph_edges (tenant_id, workspace_id, source_id, target_id) VALUES ('acme', 'acme:ops', 'c3', 'c1')"
            ),
          do: :ok
        )

      [[next]] = pg_rows(pool, "SELECT MAX(id) FROM graph_edges")
      assert next > 900

      # Full-text search ranks as FTS5 ranked on the source.
      for {index, join, match} <- [
            {"contexts_fts", "JOIN contexts c ON c.id = contexts_fts.id",
             ~s("launch" OR "platform")},
            {"contexts_fts", "JOIN contexts c ON c.id = contexts_fts.id", ~s("cafe" OR "go-live")},
            {"memories_fts", "JOIN memories c ON c.rowid = memories_fts.rowid",
             ~s("run" OR "connect")}
          ] do
        expected =
          sqlite_rows(
            path,
            "SELECT c.id, -bm25(#{index}) FROM #{index} #{join} WHERE #{index} MATCH ?1 ORDER BY c.id",
            [match]
          )

        {:ok, param} = FullText.query_param(index, match)

        actual =
          pg_rows(
            pool,
            "SELECT doc_key, score FROM optimal_fts_match(?1, ?2) ORDER BY doc_key",
            [index, param]
          )

        assert Enum.map(actual, &hd/1) == Enum.map(expected, &hd/1), match
        assert expected != []

        for {[_, a], [_, e]} <- Enum.zip(actual, expected),
            do: assert(abs(a - e) <= 1.0e-12 * max(1.0, abs(e)), match)
      end
    end)
  end

  test "a target that already holds tables is refused, unless replaced", %{
    path: path,
    schema: schema
  } do
    assert {:ok, _} = migrate(path, schema)
    assert {:error, {:target_not_empty, ^schema}} = migrate(path, schema)
    assert {:ok, report} = migrate(path, schema, replace: true)
    assert Enum.find(report.tables, &(&1.table == "contexts")).rows == 3

    with_pool(schema, fn pool ->
      assert pg_rows(pool, "SELECT COUNT(*) FROM contexts") == [[3]]
      assert pg_rows(pool, "SELECT COUNT(*) FROM contexts_fts") == [[3]]
    end)
  end

  test "a copy that does not match the source rolls back and commits nothing", %{
    path: path,
    schema: schema
  } do
    tamper = fn txn ->
      {:ok, _} =
        Connection.txn_query(txn, "UPDATE contexts SET title = 'changed' WHERE id = 'c2'", [])

      :ok
    end

    assert {:error, {:verification_failed, %{table: "contexts"} = detail}} =
             migrate(path, schema, after_import: tamper)

    assert detail.sqlite.rows == detail.postgres.rows
    assert detail.sqlite.checksum != detail.postgres.checksum

    lost_row = fn txn ->
      {:ok, _} = Connection.txn_query(txn, "DELETE FROM memories WHERE id = 'm2'", [])
      :ok
    end

    assert {:error, {:verification_failed, %{table: "memories"}}} =
             migrate(path, schema, after_import: lost_row, replace: true)

    with_pool(schema, fn pool ->
      assert pg_rows(pool, "SELECT COUNT(*) FROM contexts") == [[0]]
      assert pg_rows(pool, "SELECT COUNT(*) FROM memories") == [[0]]
    end)
  end

  test "a dry run verifies and commits nothing", %{path: path, schema: schema} do
    assert {:ok, %{dry_run: true, tables: tables}} = migrate(path, schema, dry_run: true)
    assert Enum.find(tables, &(&1.table == "contexts")).rows == 3

    with_pool(schema, fn pool ->
      assert pg_rows(pool, "SELECT COUNT(*) FROM contexts") == [[0]]
    end)
  end

  test "tables and columns this build does not know are refused unless left behind", %{
    path: path,
    schema: schema
  } do
    {:ok, db} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE local_extra (id TEXT PRIMARY KEY)")
    :ok = Exqlite.Sqlite3.execute(db, "ALTER TABLE contexts ADD COLUMN local_note TEXT")
    :ok = Exqlite.Sqlite3.close(db)

    assert {:error, {:unknown_tables, ["local_extra"]}} = migrate(path, schema)

    assert {:ok, report} = migrate(path, schema, ignore_unknown: true)
    assert report.ignored == %{tables: ["local_extra"], columns: ["contexts.local_note"]}
  end

  test "an Engine that replicates is refused before anything is written", %{
    path: path,
    schema: schema
  } do
    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "INSERT INTO sync_workspaces (tenant_id, workspace_id, enabled_by) VALUES ('default', 'default', 'test')"
      )

    :ok = Exqlite.Sqlite3.close(db)

    assert {:error, {:unsupported_in_use, ["replication"]}} = migrate(path, schema)
  end

  test "the mix task copies with the URL from the environment and never prints it", %{
    path: path,
    schema: schema
  } do
    previous = System.get_env("OPTIMAL_POSTGRES_URL")
    System.put_env("OPTIMAL_POSTGRES_URL", PostgresStore.url())

    try do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Optimal.Postgres.Migrate.run(["--source", path, "--schema", schema])
        end)

      assert output =~ "copied and verified into schema #{schema}"
      assert output =~ "contexts: 3 rows"
      assert output =~ "parity: "
      refute output =~ "postgres://"
      refute output =~ PostgresStore.url()
    after
      if previous,
        do: System.put_env("OPTIMAL_POSTGRES_URL", previous),
        else: System.delete_env("OPTIMAL_POSTGRES_URL")
    end
  end

  test "a missing source is refused", %{schema: schema} do
    assert {:error, {:source_not_found, _}} = migrate("/nonexistent/index.db", schema)
  end
end
