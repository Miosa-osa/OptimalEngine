defmodule OptimalEngine.Store.Postgres.StepsTest do
  @moduledoc """
  A migration that moves or changes data needs a declared PostgreSQL step once
  it is above the baseline. These tests need no database.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Store.Migrations
  alias OptimalEngine.Store.Postgres.Steps

  defp migration(version), do: Enum.find(Migrations.all(), &(elem(&1, 0) == version))

  defp kinds(version) do
    {^version, _description, statements} = migration(version)
    statements |> Steps.data_statements() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
  end

  test "the engine's migrations need no step above the baseline" do
    assert Steps.check() == :ok
  end

  test "until a PostgreSQL store is deployed the baseline is the newest migration" do
    refute Steps.frozen?()
    assert Steps.baseline() == Migrations.all() |> Enum.map(&elem(&1, 0)) |> Enum.max()
  end

  describe "the data statements already in the migrations are found" do
    test "the nodes rebuild copies, drops and renames" do
      assert "INSERT ... SELECT" in kinds(33)
      assert "DROP TABLE" in kinds(33)
      assert "ALTER TABLE RENAME" in kinds(33)
    end

    test "the memory embeddings rebuild copies, drops and renames" do
      assert "INSERT ... SELECT" in kinds(62)
      assert "DROP TABLE" in kinds(62)
      assert "ALTER TABLE RENAME" in kinds(62)
    end

    test "the backfills update rows" do
      for version <- [39, 42, 43, 44, 72], do: assert("UPDATE" in kinds(version), "#{version}")
    end

    test "the workspace handles backfill copies" do
      assert kinds(71) == ["INSERT ... SELECT"]
    end

    test "with no baseline, each of them would need a step" do
      assert {:error, {:undeclared_postgres_steps, undeclared}} =
               Steps.check(Migrations.all(), baseline: 0, steps: %{})

      versions = Enum.map(undeclared, &elem(&1, 0))

      for version <- [33, 39, 42, 43, 44, 62, 71, 72],
          do: assert(version in versions, "#{version}")
    end
  end

  describe "a new migration" do
    @schema_only {71, "schema only",
                  [
                    {"t", "CREATE TABLE IF NOT EXISTS t (id TEXT PRIMARY KEY, n INTEGER)"},
                    {"t_n", "CREATE INDEX IF NOT EXISTS idx_t_n ON t (n)"},
                    {"t_note", "ALTER TABLE t ADD COLUMN note TEXT"},
                    {"old_index", "DROP INDEX IF EXISTS idx_old"},
                    {"t_trigger",
                     """
                     CREATE TRIGGER IF NOT EXISTS t_fts AFTER INSERT ON t BEGIN
                       INSERT INTO t_fts(rowid, note) VALUES (new.rowid, new.note);
                       DELETE FROM t_fts WHERE rowid = old.rowid;
                     END
                     """}
                  ]}

    @backfill {72, "backfill", [{"fill", "UPDATE t SET n = 0 WHERE n IS NULL"}]}

    test "that only changes the schema needs no step" do
      assert Steps.data_statements(elem(@schema_only, 2)) == []
      assert Steps.check([@schema_only], baseline: 70, steps: %{}) == :ok
    end

    test "with a data statement fails until its step is declared" do
      assert {:error, {:undeclared_postgres_steps, [{72, [{"fill", "UPDATE"}]}]}} =
               Steps.check([@schema_only, @backfill], baseline: 70, steps: %{})

      steps = %{72 => [{"fill", "UPDATE t SET n = 0 WHERE n IS NULL"}]}
      assert Steps.check([@schema_only, @backfill], baseline: 70, steps: steps) == :ok

      none = %{72 => {:none, "the column is new on PostgreSQL"}}
      assert Steps.check([@schema_only, @backfill], baseline: 70, steps: none) == :ok
    end

    test "a step for a version at the baseline or one that does not exist is refused" do
      assert {:error, {:stray_postgres_steps, [70, 99]}} =
               Steps.check([@schema_only], baseline: 70, steps: %{70 => [], 99 => []})
    end

    test "a table built from a query, a rebuild in one entry, and an unknown statement are data" do
      statements = [
        {"copy", "CREATE TABLE t2 AS SELECT * FROM t"},
        {"rebuild",
         "CREATE TABLE t3 (id TEXT); INSERT INTO t3 SELECT id FROM t; ALTER TABLE t3 RENAME TO t"},
        {"pragma", "PRAGMA foreign_keys = OFF"}
      ]

      assert Steps.data_statements(statements) == [
               {"copy", "CREATE TABLE ... AS SELECT"},
               {"rebuild", "INSERT ... SELECT"},
               {"rebuild", "ALTER TABLE RENAME"},
               {"pragma", "PRAGMA"}
             ]
    end
  end
end
