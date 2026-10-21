defmodule OptimalEngine.Store.Postgres.SchemaSyncTest do
  @moduledoc """
  The derived schema applied to a real PostgreSQL database: complete,
  idempotent, additive, safe for engines that start together, and seeded with
  the rows the migrations insert.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store.Postgres.{Connection, Schema}
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres

  setup do
    schema = PostgresStore.unique_schema()
    on_exit(fn -> PostgresStore.drop_schema(schema) end)
    %{schema: schema}
  end

  defp start_pool(schema), do: PostgresStore.start_pool(schema)

  defp rows!(pool, sql, params \\ []) do
    {:ok, %{rows: rows}} = Connection.query(pool, sql, params, dialect: :postgres)
    rows
  end

  test "a fresh database gets every derived table and column", %{schema: schema} do
    pool = start_pool(schema)
    {:ok, plan} = Schema.derive()

    assert {:ok, report} = Schema.sync(pool, schema: schema)
    assert report.changed
    assert report.fresh
    assert length(report.created_tables) == length(plan.tables)
    assert {:ok, []} = Schema.drift(pool, schema: schema)

    columns =
      rows!(
        pool,
        "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = $1",
        [schema]
      )
      |> MapSet.new(&List.to_tuple/1)

    missing =
      for table <- plan.tables,
          column <- table.columns,
          not MapSet.member?(columns, {table.name, column.name}),
          do: "#{table.name}.#{column.name}"

    assert missing == []

    # Only the FTS5 tables and their triggers are left out; every index,
    # constraint and view PostgreSQL accepted.
    unexpected = Enum.reject(report.skipped, &(&1.kind in [:table, :trigger]))
    assert unexpected == [], "skipped on PostgreSQL:\n" <> inspect(unexpected, pretty: true)
  end

  test "a second sync changes nothing", %{schema: schema} do
    pool = start_pool(schema)

    assert {:ok, %{changed: true}} = Schema.sync(pool, schema: schema)
    assert {:ok, %{changed: false}} = Schema.sync(pool, schema: schema)
  end

  test "rows the migrations insert are seeded and identities continue after them",
       %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)

    versions = rows!(pool, "SELECT version FROM schema_migrations ORDER BY version")
    assert length(versions) == length(OptimalEngine.Store.Migrations.all())

    {:ok, %{rows: [[id]]}} =
      Connection.query(
        pool,
        "INSERT INTO decisions (title, decision) VALUES (?1, ?2) RETURNING id",
        ["t", "d"]
      )

    assert is_integer(id) and id >= 1
  end

  test "seed rows go in once: rows deleted later stay deleted", %{schema: schema} do
    pool = start_pool(schema)
    {:ok, plan} = Schema.derive()
    {:ok, %{fresh: true}} = Schema.sync(pool, schema: schema)

    referenced =
      for table <- plan.tables, key <- table.foreign_keys, into: MapSet.new(), do: key.table

    seeded =
      Enum.find(plan.seeds, fn seed ->
        seed.table != "schema_migrations" and not MapSet.member?(referenced, seed.table)
      end)

    assert seeded, "no seeded table outside every foreign key"
    rows!(pool, ~s(DELETE FROM "#{seeded.table}"))
    rows!(pool, "DELETE FROM optimal_store_schema")

    assert {:ok, %{changed: true, fresh: false, recorded_versions: []}} =
             Schema.sync(pool, schema: schema)

    assert [[0]] = rows!(pool, ~s|SELECT COUNT(*) FROM "#{seeded.table}"|)
  end

  test "the live catalog is compared with the plan", %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)

    rows!(pool, ~s(ALTER TABLE decisions ALTER COLUMN title TYPE text COLLATE "default"))
    rows!(pool, "ALTER TABLE contexts ALTER COLUMN node DROP NOT NULL")
    rows!(pool, "ALTER TABLE contexts ALTER COLUMN indexed_at SET DEFAULT 'never'")

    assert {:ok, drift} = Schema.drift(pool, schema: schema)
    assert ~s(column decisions.title: collation is "default", expected "C") in drift
    assert "column contexts.node: not_null is false, expected true" in drift
    assert Enum.any?(drift, &String.starts_with?(&1, "column contexts.indexed_at: default is"))

    # A sync applies the plan again, finds the same differences and changes
    # nothing.
    assert {:error, {:schema_drift, ^drift}} = Schema.sync(pool, schema: schema)
  end

  test "checks and unique indexes outside the plan are dropped; other indexes stay",
       %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)

    rows!(pool, "ALTER TABLE decisions ADD CONSTRAINT extra_check CHECK (length(title) < 1000)")
    rows!(pool, "CREATE UNIQUE INDEX extra_unique ON decisions (title, decision)")
    rows!(pool, "CREATE INDEX operator_index ON decisions (decision)")

    assert {:ok, report} = Schema.sync(pool, schema: schema)
    assert "decisions.extra_check" in report.dropped_objects
    assert "extra_unique" in report.dropped_objects
    refute "operator_index" in report.dropped_objects
    assert {:ok, []} = Schema.drift(pool, schema: schema)

    assert [[1]] =
             rows!(
               pool,
               "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = $1 AND indexname = 'operator_index'",
               [schema]
             )
  end

  test "an index an earlier sync created that the plan no longer has is dropped",
       %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)

    rows!(pool, "CREATE INDEX idx_retired_0123abcd ON decisions (title)")

    rows!(
      pool,
      "UPDATE optimal_store_schema SET value = value || E'\\nidx_retired_0123abcd' WHERE key = 'indexes'"
    )

    rows!(pool, "DELETE FROM optimal_store_schema WHERE key = 'fingerprint'")

    assert {:ok, report} = Schema.sync(pool, schema: schema)
    assert "idx_retired_0123abcd" in report.dropped_objects
  end

  test "a database a newer build migrated is refused", %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)

    rows!(
      pool,
      "INSERT INTO schema_migrations (version, description) VALUES (9999, 'from a newer build')"
    )

    assert {:error, {:schema_newer, [9999]}} = Schema.sync(pool, schema: schema)
  end

  test "a database missing a version at or below the baseline is drift, not a fresh start",
       %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)
    rows!(pool, "DELETE FROM schema_migrations WHERE version = 1")

    assert {:error, {:schema_drift, [message]}} = Schema.sync(pool, schema: schema)
    assert message =~ "versions at or below the baseline are not recorded: [1]"
  end

  test "a pool started for another schema cannot apply the plan", %{schema: schema} do
    pool = start_pool(schema)
    other = PostgresStore.unique_schema()
    on_exit(fn -> PostgresStore.drop_schema(other) end)

    assert {:error, {:schema, message}} = Schema.sync(pool, schema: other)
    assert message =~ "not #{other}"
  end

  test "an explicit id moves the identity past it, as SQLite's rowid does", %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)

    explicit = "INSERT INTO decisions (id, title, decision) VALUES (?1, ?2, ?3)"
    generated = "INSERT INTO decisions (title, decision) VALUES (?1, ?2) RETURNING id"

    {:ok, _} = Connection.query(pool, explicit, [500, "t", "d"])
    assert {:ok, %{rows: [[501]]}} = Connection.query(pool, generated, ["t", "d"])

    {:ok, _} =
      Connection.transaction(
        pool,
        &Connection.txn_query(&1, explicit, [900, "t", "d"]),
        5_000
      )

    assert {:ok, %{rows: [[901]]}} = Connection.query(pool, generated, ["t", "d"])

    # A lower explicit id leaves it where it is.
    {:ok, _} = Connection.query(pool, explicit, [42, "t", "d"])
    assert {:ok, %{rows: [[902]]}} = Connection.query(pool, generated, ["t", "d"])
  end

  test "a column missing from an existing table is added", %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)

    rows!(pool, "ALTER TABLE contexts DROP COLUMN metadata")
    rows!(pool, "DELETE FROM optimal_store_schema")

    assert {:ok, report} = Schema.sync(pool, schema: schema)
    assert report.created_tables == []
    assert report.added_columns == ["contexts.metadata"]

    unexpected = Enum.reject(report.skipped, &(&1.kind in [:table, :trigger]))
    assert unexpected == [], "skipped on the second sync:\n" <> inspect(unexpected, pretty: true)

    assert [[_]] =
             rows!(
               pool,
               "SELECT column_default FROM information_schema.columns " <>
                 "WHERE table_schema = $1 AND table_name = 'contexts' AND column_name = 'metadata'",
               [schema]
             )
  end

  test "engines starting together apply the schema once", %{schema: schema} do
    pools = for _ <- 1..3, do: start_pool(schema)

    reports =
      pools
      |> Task.async_stream(&Schema.sync(&1, schema: schema), timeout: 300_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(reports, &match?({:ok, _}, &1)), inspect(reports)
    assert Enum.count(reports, fn {:ok, report} -> report.changed end) == 1
  end

  test "the schema enforces what SQLite enforces", %{schema: schema} do
    pool = start_pool(schema)
    {:ok, _} = Schema.sync(pool, schema: schema)

    {:ok, _} =
      Connection.query(pool, "INSERT INTO contexts (id, title) VALUES (?1, ?2)", ["c1", "one"])

    {:ok, _} =
      Connection.query(pool, "INSERT INTO entities (context_id, name) VALUES (?1, ?2)", [
        "c1",
        "alice"
      ])

    assert {:error, "UNIQUE constraint failed: entities.context_id, entities.name"} =
             Connection.query(pool, "INSERT INTO entities (context_id, name) VALUES (?1, ?2)", [
               "c1",
               "alice"
             ])

    assert {:error, "FOREIGN KEY constraint failed"} =
             Connection.query(pool, "INSERT INTO entities (context_id, name) VALUES (?1, ?2)", [
               "nope",
               "bob"
             ])

    assert [[indexed_at]] = rows!(pool, "SELECT indexed_at FROM contexts WHERE id = 'c1'")
    assert indexed_at =~ ~r/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/

    {:ok, _} = Connection.query(pool, "DELETE FROM contexts WHERE id = ?1", ["c1"])
    assert [[0]] = rows!(pool, "SELECT COUNT(*) FROM entities")
  end
end
