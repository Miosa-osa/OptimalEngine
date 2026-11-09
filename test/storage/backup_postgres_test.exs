defmodule OptimalEngine.Storage.BackupPostgresTest do
  @moduledoc """
  A backup of a PostgreSQL store is a SQLite file holding one consistent
  snapshot of every table, and a restore puts exactly those rows back: every
  table's row count and digest after a restore equal the backup's, whatever
  was written in between, in the same schema or another one.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Backup
  alias OptimalEngine.Backup.Envelope
  alias OptimalEngine.Backup.Postgres, as: PgBackup
  alias OptimalEngine.Store.Postgres.{Connection, FullText, Schema}
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres
  # Each test derives a schema of 144 tables at least once.
  @moduletag timeout: 300_000

  setup do
    schema = PostgresStore.unique_schema("oebk")
    pool = PostgresStore.start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)
    :ok = FullText.ensure(pool)

    dir = Path.join(System.tmp_dir!(), "oe-pg-backup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      PostgresStore.drop_schema(schema)
      File.rm_rf!(dir)
    end)

    %{schema: schema, pool: pool, dir: dir}
  end

  defp write!(pool, sql, params \\ []), do: {:ok, _} = Connection.query(pool, sql, params)

  defp seed!(pool) do
    for n <- 1..25 do
      write!(
        pool,
        "INSERT INTO contexts (id, uri, title, content, sn_ratio) VALUES (?1, ?2, ?3, ?4, ?5)",
        ["c#{n}", "optimal://t/c#{n}", "Title #{n}", "launch plan number #{n} — café", n / 7]
      )

      write!(pool, "INSERT INTO entities (context_id, name) VALUES (?1, ?2)", ["c#{n}", "e#{n}"])

      write!(
        pool,
        "INSERT INTO vectors (context_id, embedding, dimensions) VALUES (?1, ?2, 4)",
        ["c#{n}", {:blob, <<n::float-32-little, 0, 0, 0, 0, 255, 0, 1, 2, 3, 4, 5, 6>>}]
      )
    end

    write!(
      pool,
      "INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES ('m1', 'default', 'default', 'remember the launch')"
    )
  end

  defp digests!(pool) do
    {:ok, digests} = PgBackup.digests(pool)
    digests
  end

  test "a snapshot is a verified SQLite file with every table's rows", %{pool: pool, dir: dir} do
    seed!(pool)
    path = Path.join(dir, "snap.db")

    assert {:ok, %{tables: tables}} = PgBackup.snapshot(pool, path)
    assert tables["contexts"] == 25
    assert tables["vectors"] == 25
    assert {:ok, :ok} = Backup.verify(path)
    refute File.exists?(path <> "-wal")

    {:ok, plan} = Schema.derive()
    assert {:ok, digests} = PgBackup.file_digests(path, plan)
    assert digests == digests!(pool)

    # The file's FTS5 index was filled by its own triggers.
    {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

    {:ok, st} =
      Exqlite.Sqlite3.prepare(
        db,
        "SELECT COUNT(*) FROM contexts_fts WHERE contexts_fts MATCH 'launch'"
      )

    assert {:ok, [[25]]} = Exqlite.Sqlite3.fetch_all(db, st)
    Exqlite.Sqlite3.close(db)
  end

  test "backup, mutate, restore: every table equals the backup again", %{pool: pool, dir: dir} do
    seed!(pool)
    path = Path.join(dir, "before.db")
    {:ok, _} = PgBackup.snapshot(pool, path)
    backed_up = digests!(pool)

    write!(pool, "DELETE FROM contexts WHERE id IN ('c1', 'c2')")
    write!(pool, "UPDATE contexts SET title = 'changed' WHERE id = 'c3'")
    write!(pool, "INSERT INTO contexts (id, uri, title, content) VALUES ('new', 'u', 'n', 'after')")
    write!(pool, "INSERT INTO entities (context_id, name) VALUES ('new', 'later')")
    refute digests!(pool) == backed_up

    assert {:ok, %{tables: tables}} = PgBackup.restore(pool, path)
    assert tables["contexts"] == 25
    assert digests!(pool) == backed_up

    # Identity sequences moved past the restored ids.
    {:ok, %{rows: [[max_id]]}} = Connection.query(pool, "SELECT MAX(id) FROM entities")
    write!(pool, "INSERT INTO entities (context_id, name) VALUES ('c5', 'next')")

    {:ok, %{rows: [[next_id]]}} =
      Connection.query(pool, "SELECT id FROM entities WHERE name = 'next'")

    assert next_id > max_id

    # The full-text index serves the restored rows and not the removed one.
    {:ok, _} = FullText.refresh(pool, ["contexts_fts"])
    assert length(matches(pool, ~s("launch"))) == 25
    assert matches(pool, ~s("after")) == []
  end

  defp matches(pool, query) do
    {:ok, param} = OptimalEngine.Store.FullText.query_param("contexts_fts", query)

    {:ok, %{rows: rows}} =
      Connection.query(pool, "SELECT doc_key FROM optimal_fts_match('contexts_fts', ?1)", [param])

    rows
  end

  test "a backup restores into an empty schema of another name", %{pool: pool, dir: dir} do
    seed!(pool)
    path = Path.join(dir, "move.db")
    {:ok, _} = PgBackup.snapshot(pool, path)

    other = PostgresStore.unique_schema("oebk_other")
    other_pool = PostgresStore.start_pool(other)
    on_exit(fn -> PostgresStore.drop_schema(other) end)

    assert {:ok, _} = PgBackup.restore(other_pool, path, schema: other)
    assert digests!(other_pool) == digests!(pool)
  end

  test "a sealed backup opens to the same file and restores", %{pool: pool, dir: dir} do
    seed!(pool)
    path = Path.join(dir, "sealed.db")
    {:ok, _} = PgBackup.snapshot(pool, path)
    key = :crypto.strong_rand_bytes(32)

    {:ok, sealed} = Envelope.seal_file(path, path <> ".enc", key, backup_id: "b1")
    {:ok, _opened} = Envelope.open_file(path <> ".enc", path <> ".open", key)
    assert File.read!(path <> ".open") == File.read!(path)
    assert sealed.ciphertext_sha256 != nil

    write!(pool, "DELETE FROM contexts")
    assert {:ok, _} = PgBackup.restore(pool, path <> ".open")
    {:ok, plan} = Schema.derive()
    assert {:ok, digests} = PgBackup.file_digests(path, plan)
    assert digests == digests!(pool)
  end

  test "a backup of another schema version is refused and nothing changes", %{pool: pool, dir: dir} do
    seed!(pool)
    path = Path.join(dir, "old.db")
    {:ok, _} = PgBackup.snapshot(pool, path)
    before = digests!(pool)

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "DELETE FROM schema_migrations WHERE version = (SELECT MAX(version) FROM schema_migrations)"
      )

    Exqlite.Sqlite3.close(db)

    assert {:error, {:backup_schema_mismatch, %{missing: [_]}}} = PgBackup.restore(pool, path)
    assert digests!(pool) == before
  end

  test "writers wait while a restore holds the tables", %{pool: pool, dir: dir, schema: schema} do
    seed!(pool)
    path = Path.join(dir, "locked.db")
    {:ok, _} = PgBackup.snapshot(pool, path)
    writer_pool = PostgresStore.start_pool(schema)

    restoring = Task.async(fn -> PgBackup.restore(pool, path) end)

    # The writer either lands before the restore takes its locks (and is then
    # replaced by the backup's rows) or waits for the commit; it never lands in
    # the middle.
    writing =
      Task.async(fn ->
        Connection.query(
          writer_pool,
          "INSERT INTO contexts (id, uri, title, content) VALUES ('during', 'u', 't', 'x')"
        )
      end)

    assert {:ok, _} = Task.await(restoring, 60_000)
    assert {:ok, _} = Task.await(writing, 60_000)

    {:ok, %{rows: [[count]]}} = Connection.query(pool, "SELECT COUNT(*) FROM contexts")
    assert count in [25, 26]
  end

  if OptimalEngine.Store.selected?(OptimalEngine.Store.Postgres) do
    describe "through OptimalEngine.Backup on a PostgreSQL build" do
      test "create catalogs a verified backup and restore puts it into a schema", %{dir: dir} do
        target = Path.join(dir, "engine.db")
        assert {:ok, info} = Backup.create(target)
        assert info.integrity_status == "verified"

        other = PostgresStore.unique_schema("oebk_into")
        on_exit(fn -> PostgresStore.drop_schema(other) end)

        assert {:ok, restored} = Backup.restore(target, schema: other)
        assert restored.target == "postgres:" <> other
        assert restored.archived == nil
        assert restored.checksum_sha256 == info.checksum_sha256

        live = PgBackup.with_pool([], &PgBackup.digests/1)
        into = PgBackup.with_pool([schema: other], &PgBackup.digests/1)
        {:ok, live_digests} = live
        {:ok, into_digests} = into
        # The live store kept being written by the engine after the backup;
        # the tables the engine does not touch on its own match exactly.
        assert into_digests["schema_migrations"] == live_digests["schema_migrations"]
      end

      test "restoring into the live schema is refused while the engine runs", %{dir: dir} do
        target = Path.join(dir, "live.db")
        {:ok, _} = Backup.create(target)
        assert {:error, :supervisor_still_running} = Backup.restore(target)
      end
    end
  end
end
