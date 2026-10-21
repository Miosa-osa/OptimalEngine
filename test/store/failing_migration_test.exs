defmodule OptimalEngine.Store.FailingMigrationTest do
  @moduledoc """
  A migration applies completely or leaves the store as it was. The failing
  migration of the upgrade rollback drill proves it: it creates a table, writes
  a row and changes existing data before it fails, and afterwards the store has
  the same migration counter, schema and data as before.

  Each test works on a copy of the test store (`VACUUM INTO`), never on the
  store the application has open.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Store.{FailingMigration, Migrations}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "failing-migration-#{System.unique_integer([:positive])}.db"
      )

    {:ok, _} = Store.raw_query("VACUUM INTO ?1", [path])
    {:ok, db} = Exqlite.Sqlite3.open(path)

    on_exit(fn ->
      Exqlite.Sqlite3.close(db)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    execute!(
      db,
      "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES ('drill-context', 'default', 'default', 'signal', 'Drill', 'Kept through the failed upgrade.', datetime('now'))"
    )

    %{db: db, last: Migrations.all() |> List.last() |> elem(0)}
  end

  test "a normal build has no failing migration", %{last: last} do
    refute FailingMigration.release?()
    assert FailingMigration.migrations(Migrations.all()) == []
    assert last == OptimalEngine.Version.info().expected_migration

    refute Enum.any?(Migrations.all(), fn {_version, description, _} ->
             description =~ "failing-migration"
           end)
  end

  test "the failing migration writes, fails, and leaves the store as it was", ctx do
    failing = FailingMigration.migration(Migrations.all())
    {version, _description, statements} = failing
    assert version == ctx.last + 1

    # It changes the store before the statement that fails.
    assert Enum.map(statements, &elem(&1, 0)) == [
             "failing_migration_probe",
             "failing_migration_write",
             "failing_migration_update",
             "failing_migration_fails"
           ]

    before = snapshot(ctx.db)

    error =
      assert_raise RuntimeError, fn -> Migrations.run(ctx.db, Migrations.all() ++ [failing]) end

    padded = ctx.last |> Kernel.+(1) |> Integer.to_string() |> String.pad_leading(3, "0")
    assert error.message =~ "migration #{padded} failed and was rolled back"
    assert error.message =~ "failing_migration_fails"
    assert error.message =~ "NOT NULL constraint failed"

    assert snapshot(ctx.db) == before
    assert rows(ctx.db, "SELECT max(version) FROM schema_migrations") == [[ctx.last]]
    assert rows(ctx.db, "PRAGMA integrity_check") == [["ok"]]

    # A second attempt, as a supervisor restarting the release would make, fails
    # the same way and changes nothing either.
    assert_raise RuntimeError, fn -> Migrations.run(ctx.db, Migrations.all() ++ [failing]) end
    assert snapshot(ctx.db) == before

    # The previous release opens the store with nothing pending.
    assert Migrations.run(ctx.db) == :ok
    assert snapshot(ctx.db) == before
  end

  test "a migration that succeeds commits its changes and its version together", ctx do
    probe =
      {ctx.last + 1, "commit probe",
       [
         {"commit_probe", "CREATE TABLE commit_probe (id INTEGER PRIMARY KEY)"},
         {"commit_probe_row", "INSERT INTO commit_probe DEFAULT VALUES"}
       ]}

    assert Migrations.run(ctx.db, Migrations.all() ++ [probe]) == :ok
    assert rows(ctx.db, "SELECT max(version) FROM schema_migrations") == [[ctx.last + 1]]
    assert rows(ctx.db, "SELECT count(*) FROM commit_probe") == [[1]]
  end

  test "a failure keeps the migrations before it in the same run", ctx do
    probe =
      {ctx.last + 1, "commit probe",
       [{"commit_probe", "CREATE TABLE commit_probe (id INTEGER PRIMARY KEY)"}]}

    {_version, description, statements} =
      FailingMigration.migration(Migrations.all() ++ [probe])

    failing = {ctx.last + 2, description, statements}

    assert_raise RuntimeError, fn ->
      Migrations.run(ctx.db, Migrations.all() ++ [probe, failing])
    end

    assert rows(ctx.db, "SELECT max(version) FROM schema_migrations") == [[ctx.last + 1]]
    assert rows(ctx.db, "SELECT count(*) FROM commit_probe") == [[0]]
    assert table?(ctx.db, "commit_probe")
    refute table?(ctx.db, "failing_migration_probe")
  end

  test "the flag cannot build a release whose version lacks the suffix" do
    previous = System.get_env("OPTIMAL_BUILD_FAILING_MIGRATION")
    System.put_env("OPTIMAL_BUILD_FAILING_MIGRATION", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("OPTIMAL_BUILD_FAILING_MIGRATION", previous),
        else: System.delete_env("OPTIMAL_BUILD_FAILING_MIGRATION")
    end)

    # Compiled under another name, so the loaded module is never touched.
    source =
      "../../lib/optimal_engine/store/failing_migration.ex"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> String.replace(
        "defmodule OptimalEngine.Store.FailingMigration do",
        "defmodule OptimalEngine.Store.FailingMigrationGuardProbe do"
      )

    assert source =~ "FailingMigrationGuardProbe"
    assert_raise CompileError, ~r/-failing-migration/, fn -> Code.compile_string(source) end
  end

  # ---------------------------------------------------------------------------

  defp snapshot(db) do
    %{
      migrations:
        rows(db, "SELECT version, applied_at, description FROM schema_migrations ORDER BY version"),
      schema: rows(db, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"),
      tenants: rows(db, "SELECT id, name, plan, metadata FROM tenants ORDER BY id"),
      context: rows(db, "SELECT id, title, content FROM contexts WHERE id = 'drill-context'")
    }
  end

  defp table?(db, name),
    do: rows(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1", [name]) != []

  defp rows(db, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = collect(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    rows
  end

  defp collect(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> collect(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp execute!(db, sql), do: :ok = Exqlite.Sqlite3.execute(db, sql)
end
