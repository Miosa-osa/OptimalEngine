defmodule OptimalEngine.Store.FailingMigrationTest do
  @moduledoc """
  A failed migration leaves no trace; migrations before it in the same run stay
  applied. The failing migration of the upgrade rollback drill proves the first
  half: it creates a table, writes a row and changes an existing row before it
  fails, and afterwards the store has the same migration counter, schema and
  data as before. The passing-then-failing variant proves the second half.

  Most tests work on a copy of the test store (`VACUUM INTO`), never on the
  store the application has open.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Store.{FailingMigration, Migrations}

  setup do
    path = tmp_db("failing-migration")
    {:ok, _} = Store.raw_query("VACUUM INTO ?1", [path])
    {:ok, db} = Exqlite.Sqlite3.open(path)
    on_exit(fn -> Exqlite.Sqlite3.close(db) end)

    execute!(
      db,
      "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES ('drill-context', 'default', 'default', 'signal', 'Drill', 'Kept through the failed upgrade.', datetime('now'))"
    )

    execute!(
      db,
      "INSERT OR IGNORE INTO tenants (id, name) VALUES ('#{FailingMigration.sentinel_tenant()}', 'Sentinel')"
    )

    %{
      db: db,
      last: Migrations.all() |> List.last() |> elem(0),
      base: FailingMigration.reserved_base()
    }
  end

  test "a normal build has no failing migration", %{last: last} do
    refute FailingMigration.release?()
    assert FailingMigration.migrations(Migrations.all()) == []
    assert last == OptimalEngine.Version.info().expected_migration

    refute Enum.any?(Migrations.all(), fn {_version, description, _} ->
             description =~ "failing-migration"
           end)
  end

  test "the test migrations take reserved numbers no real migration reaches", ctx do
    assert ctx.base == 9_000_000
    assert ctx.last < ctx.base
    assert [{9_000_001, _, _}] = FailingMigration.variant(:failing, Migrations.all())

    assert [{9_000_001, _, _}, {9_000_002, _, _}] =
             FailingMigration.variant(:passing_then_failing, Migrations.all())

    reached = Migrations.all() ++ [{ctx.base, "a real migration at the base", []}]

    assert_raise ArgumentError, ~r/reserved base/, fn ->
      FailingMigration.variant(:failing, reached)
    end
  end

  test "the failing migration writes, fails, and leaves the store as it was", ctx do
    [failing] = FailingMigration.variant(:failing, Migrations.all())
    {version, _description, statements} = failing
    assert version == ctx.base + 1

    # It changes the store, an existing row included, before the statement that fails.
    assert Enum.map(statements, &elem(&1, 0)) == [
             "failing_migration_probe",
             "failing_migration_write",
             "failing_migration_update",
             "failing_migration_fails"
           ]

    before = snapshot(ctx.db)

    error =
      assert_raise RuntimeError, fn -> Migrations.run(ctx.db, Migrations.all() ++ [failing]) end

    assert error.message =~ "migration #{ctx.base + 1} failed and was rolled back"
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

  test "the update reaches only the sentinel tenant" do
    [{_version, _description, statements}] = FailingMigration.variant(:failing, Migrations.all())
    {"failing_migration_update", sql} = List.keyfind(statements, "failing_migration_update", 0)
    assert sql =~ "WHERE id = '#{FailingMigration.sentinel_tenant()}'"
  end

  test "in the passing-then-failing variant the migration before the failure stays", ctx do
    [passing, failing] = FailingMigration.variant(:passing_then_failing, Migrations.all())
    tenants = rows(ctx.db, "SELECT id, name FROM tenants ORDER BY id")

    for _attempt <- 1..2 do
      assert_raise RuntimeError,
                   ~r/migration #{ctx.base + 2} failed and was rolled back/,
                   fn ->
                     Migrations.run(ctx.db, Migrations.all() ++ [passing, failing])
                   end
    end

    # The store is between releases: the passing migration is applied, the
    # failing one left nothing. Only a backup taken before the boot undoes it.
    assert rows(ctx.db, "SELECT max(version) FROM schema_migrations") == [[ctx.base + 1]]
    assert rows(ctx.db, "SELECT count(*) FROM passing_migration_probe") == [[1]]
    refute table?(ctx.db, "failing_migration_probe")
    assert rows(ctx.db, "SELECT id, name FROM tenants ORDER BY id") == tenants
  end

  test "an unrestored passing migration stays, and later migrations still apply", ctx do
    [passing, failing] = FailingMigration.variant(:passing_then_failing, Migrations.all())

    assert_raise RuntimeError, fn ->
      Migrations.run(ctx.db, Migrations.all() ++ [passing, failing])
    end

    # The previous release has nothing pending; the passing migration stays
    # recorded, and its number is the drift the storage audit reports.
    assert Migrations.run(ctx.db) == :ok
    assert rows(ctx.db, "SELECT max(version) FROM schema_migrations") == [[ctx.base + 1]]

    # A later real migration is applied by its number, not skipped as below the counter.
    statements = [{"later_probe", "CREATE TABLE later_probe (id INTEGER)"}]
    later = {ctx.last + 1, "a later real migration", statements}
    assert Migrations.run(ctx.db, Migrations.all() ++ [later]) == :ok
    assert table?(ctx.db, "later_probe")

    sql = "SELECT version FROM schema_migrations WHERE version > ?1 ORDER BY version"
    assert rows(ctx.db, sql, [ctx.last]) == [[ctx.last + 1], [ctx.base + 1]]
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

  test "a migration another runner recorded after this run looked is skipped", ctx do
    # The first migration records the second, as a second runner on the same
    # database would between this run's read of schema_migrations and its turn.
    # The second migration's statement would fail if it ran.
    recorder =
      {ctx.last + 1, "records the next migration",
       [
         {"record_next",
          "INSERT INTO schema_migrations (version, description) VALUES (#{ctx.last + 2}, 'applied by another runner')"}
       ]}

    raced =
      {ctx.last + 2, "already applied", [{"never_runs", "INSERT INTO no_such_table VALUES (1)"}]}

    assert Migrations.run(ctx.db, Migrations.all() ++ [recorder, raced]) == :ok

    assert rows(ctx.db, "SELECT description FROM schema_migrations WHERE version = ?1", [
             ctx.last + 2
           ]) == [["applied by another runner"]]
  end

  test "a throw or an exit inside a migration rolls it back too", ctx do
    before = snapshot(ctx.db)
    version = ctx.last + 1

    for {kind, leave} <- [
          {"throw", fn -> throw(:migration_threw) end},
          {"exit", fn -> exit(:migration_exited) end}
        ] do
      error =
        assert_raise RuntimeError, fn ->
          Migrations.in_transaction(ctx.db, version, fn ->
            execute!(ctx.db, "CREATE TABLE throw_probe (id INTEGER)")
            leave.()
          end)
        end

      assert error.message =~ "migration #{pad(version)} failed and was rolled back"
      assert error.message =~ kind
      assert snapshot(ctx.db) == before
    end
  end

  test "no migration uses a statement a transaction ignores or refuses" do
    for {version, _description, statements} <- Migrations.all(), {label, sql} <- statements do
      refute Regex.match?(~r/\b(PRAGMA|VACUUM|ATTACH|DETACH)\b/i, sql),
             "migration #{version} statement #{label} runs #{sql}"
    end
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

  describe "an older store" do
    test "a store at migration 61 with memory embeddings upgrades with its rows and foreign keys intact" do
      path = tmp_db("store-at-61")
      at_61 = Enum.take_while(Migrations.all(), fn {version, _, _} -> version <= 61 end)
      {:ok, db} = Store.SQLite.open_and_migrate(path, at_61)
      on_exit(fn -> Exqlite.Sqlite3.close(db) end)

      assert rows(db, "SELECT max(version) FROM schema_migrations") == [[61]]

      execute!(
        db,
        "INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES ('mem-61', 'default', 'default', 'kept through the upgrade')"
      )

      execute!(
        db,
        "INSERT INTO memory_embeddings (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash) VALUES ('mem-61', 'default', 'default', 'probe-model', 3, x'000102', 'hash-61')"
      )

      assert rows(db, "PRAGMA foreign_keys") == [[1]]
      assert Migrations.run(db) == :ok

      assert rows(db, "SELECT max(version) FROM schema_migrations") ==
               [[Migrations.all() |> List.last() |> elem(0)]]

      assert rows(db, "SELECT memory_id, model, content_hash FROM memory_embeddings") ==
               [["mem-61", "probe-model", "hash-61"]]

      assert rows(db, "PRAGMA foreign_key_check") == []
      assert rows(db, "PRAGMA integrity_check") == [["ok"]]
    end
  end

  # ---------------------------------------------------------------------------

  defp tmp_db(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    path
  end

  defp pad(version), do: version |> Integer.to_string() |> String.pad_leading(3, "0")

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
