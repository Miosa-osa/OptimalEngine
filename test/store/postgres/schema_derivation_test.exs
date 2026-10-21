defmodule OptimalEngine.Store.Postgres.SchemaDerivationTest do
  @moduledoc """
  The PostgreSQL schema is derived from the schema the SQLite migrations
  produce. These tests need no database: they check the derivation itself.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias OptimalEngine.Store.{Dialect, Migrations}
  alias OptimalEngine.Store.Postgres.{Schema, Steps}

  setup_all do
    {:ok, plan} = Schema.derive()
    %{plan: plan}
  end

  defp table(plan, name), do: Enum.find(plan.tables, &(&1.name == name))
  defp column(table, name), do: Enum.find(table.columns, &(&1.name == name))

  # A fresh in-memory SQLite database with the full schema.
  defp migrated_sqlite do
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")
    capture_log(fn -> :ok = OptimalEngine.Store.SQLite.migrate(db) end)
    db
  end

  defp sqlite_rows(db, sql) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
    Exqlite.Sqlite3.release(db, statement)
    rows
  end

  test "every SQLite table is derived or skipped by name", %{plan: plan} do
    db = migrated_sqlite()

    names =
      sqlite_rows(
        db,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
      )
      |> Enum.map(&hd/1)

    Exqlite.Sqlite3.close(db)

    derived = MapSet.new(plan.tables, & &1.name)
    skipped = MapSet.new(for %{kind: :table, name: name} <- plan.skipped, do: name)

    missing = Enum.reject(names, &(MapSet.member?(derived, &1) or MapSet.member?(skipped, &1)))
    assert missing == []
    assert MapSet.member?(derived, "contexts")
    assert MapSet.member?(skipped, "contexts_fts")
  end

  test "every column type, default, check and index translates", %{plan: plan} do
    assert plan.notes == [], "untranslated schema objects:\n" <> inspect(plan.notes, pretty: true)
  end

  test "the canonical tables keep their keys, defaults and constraints", %{plan: plan} do
    contexts = table(plan, "contexts")
    assert contexts.primary_key == ["id"]
    refute column(contexts, "id").identity
    assert column(contexts, "sn_ratio").type == "DOUBLE PRECISION"
    assert column(contexts, "title").type == ~s(TEXT COLLATE "C")
    assert column(contexts, "node").not_null
    assert column(contexts, "indexed_at").default =~ "to_char("

    entities = table(plan, "entities")
    assert column(entities, "id").identity
    assert ["context_id", "name"] in entities.uniques

    assert Enum.any?(entities.foreign_keys, fn key ->
             key.table == "contexts" and key.columns == ["context_id"] and
               key.references == ["id"] and key.on_delete == "CASCADE"
           end)
  end

  test "every index statement can run again", %{plan: plan} do
    assert plan.indexes != []

    for index <- plan.indexes do
      assert index.sql =~ ~r/\A\s*CREATE\s+(UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s/i, index.sql
    end
  end

  test "indexes, checks and foreign keys are named for their definitions", %{plan: plan} do
    for index <- plan.indexes do
      assert index.name =~ ~r/\A.+_[0-9a-f]{8}\z/
      assert String.starts_with?(index.name, String.slice(index.sqlite_name, 0, 50) <> "_")
      assert byte_size(index.name) <= 63
      assert index.sql =~ ~s("#{index.name}")
    end

    names =
      for statement <- Schema.statements(plan),
          [_, name] <- Regex.scan(~r/ADD CONSTRAINT "([^"]+)"/, statement),
          do: name

    assert names != []
    assert Enum.all?(names, &(&1 =~ ~r/\A(ck|fk)_.+_[0-9a-f]{8}\z/))
    assert names == Enum.uniq(names)

    # The same key on another table, or a changed key, is another name.
    assert Schema.unique_index("a", ["x"]) != Schema.unique_index("b", ["x"])
    assert Schema.unique_index("a", ["x"]) != Schema.unique_index("a", ["x", "y"])
  end

  test "only the triggers that maintain a full-text table are skipped", %{plan: plan} do
    triggers = for %{kind: :trigger} = note <- plan.skipped, do: note
    assert triggers != []
    assert Enum.all?(triggers, &(&1.reason =~ "maintains the full-text table"))
  end

  test "the migration versions are carried in order", %{plan: plan} do
    assert plan.versions == Enum.sort(Enum.map(Migrations.all(), &elem(&1, 0)))
  end

  test "the backward-compatible signals view is derived", %{plan: plan} do
    assert %{sql: sql} = Enum.find(plan.views, &(&1.name == "signals"))
    assert sql =~ "FROM contexts"
  end

  test "every applied migration version is carried as a seed row", %{plan: plan} do
    assert %{rows: rows} = Enum.find(plan.seeds, &(&1.table == "schema_migrations"))
    versions = rows |> Enum.map(&hd/1) |> Enum.sort()

    expected =
      OptimalEngine.Store.Migrations.all()
      |> Enum.map(fn {version, _description, _statements} -> version end)
      |> Enum.sort()

    assert versions == expected
  end

  test "the fingerprint is stable across derivations", %{plan: plan} do
    db = migrated_sqlite()
    again = Schema.from_sqlite(db)
    Exqlite.Sqlite3.close(db)

    assert again.fingerprint == plan.fingerprint
  end

  describe "type affinity" do
    test "follows SQLite's rules in their order" do
      assert Schema.postgres_type("INTEGER") == "BIGINT"
      assert Schema.postgres_type("BIGINT") == "BIGINT"
      assert Schema.postgres_type("BOOLEAN") == "BIGINT"
      assert Schema.postgres_type("TEXT") == ~s(TEXT COLLATE "C")
      assert Schema.postgres_type("VARCHAR(64)") == ~s(TEXT COLLATE "C")
      assert Schema.postgres_type("DATETIME") == ~s(TEXT COLLATE "C")
      assert Schema.postgres_type("JSON") == ~s(TEXT COLLATE "C")
      assert Schema.postgres_type("REAL") == "DOUBLE PRECISION"
      assert Schema.postgres_type("NUMERIC") == "DOUBLE PRECISION"
      assert Schema.postgres_type("BLOB") == "BYTEA"
      assert Schema.postgres_type("") == :unmapped
      assert Schema.postgres_type("GEOMETRY") == :unmapped
    end

    test "defaults are translated and cast to the column type" do
      assert {:ok, nil} = Schema.postgres_default(nil, "BIGINT")
      assert {:ok, nil} = Schema.postgres_default("NULL", "BIGINT")
      assert {:ok, "CAST(('[]') AS TEXT)"} = Schema.postgres_default("'[]'", ~s(TEXT COLLATE "C"))
      assert {:ok, "CAST((0) AS TEXT)"} = Schema.postgres_default("0", ~s(TEXT COLLATE "C"))
      assert {:ok, "CAST((1) AS BIGINT)"} = Schema.postgres_default("TRUE", "BIGINT")

      assert {:ok, now} = Schema.postgres_default("datetime('now')", ~s(TEXT COLLATE "C"))
      assert now =~ "to_char((statement_timestamp() AT TIME ZONE 'utc'), 'YYYY-MM-DD HH24:MI:SS')"

      assert {:ok, ^now} = Schema.postgres_default("CURRENT_TIMESTAMP", ~s(TEXT COLLATE "C"))
    end
  end

  describe "CHECK clauses" do
    test "are read in order with nested parentheses and quoted text" do
      sql = """
      CREATE TABLE t (
        op TEXT NOT NULL CHECK (op IN ('a', 'b)', 'it''s')),
        n INTEGER,
        checked_at TEXT,
        CONSTRAINT positive CHECK ((n > 0) AND (n < 10))
      )
      """

      assert {:ok, ["op IN ('a', 'b)', 'it''s')", "(n > 0) AND (n < 10)"]} =
               Schema.check_clauses(sql)
    end

    test "CHECK inside a literal or an identifier is not a clause" do
      sql = ~s|CREATE TABLE t (note TEXT DEFAULT 'CHECK (x)', "CHECK (y)" TEXT, rechecked INT)|
      assert {:ok, []} = Schema.check_clauses(sql)
    end

    test "an unbalanced clause is an error, not a partial expression" do
      assert {:error, :unbalanced} = Schema.check_clauses("CREATE TABLE t (n INT CHECK (n > (0)")
    end
  end

  test "the CREATE TABLE statement quotes names and keeps the key" do
    table = %{
      name: "items",
      columns: [
        %{name: "id", type: "BIGINT", not_null: false, default: nil, identity: true},
        %{
          name: "label",
          type: ~s(TEXT COLLATE "C"),
          not_null: true,
          default: "CAST(('x') AS TEXT)",
          identity: false
        }
      ],
      primary_key: ["id"],
      uniques: [],
      checks: [],
      foreign_keys: []
    }

    assert Schema.create_table(table) ==
             """
             CREATE TABLE IF NOT EXISTS "items" (
               "id" BIGINT GENERATED BY DEFAULT AS IDENTITY,
               "label" TEXT COLLATE "C" NOT NULL DEFAULT CAST(('x') AS TEXT),
               PRIMARY KEY ("id")
             )\
             """
  end

  describe "failing loudly" do
    test "anything the derivation cannot carry is a fatal note" do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")

      :ok =
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE odd (id INTEGER PRIMARY KEY, shape GEOMETRY, "order" TEXT, "Mixed" TEXT);
        CREATE TABLE audit_log (id INTEGER PRIMARY KEY, note TEXT);
        CREATE TRIGGER odd_audit AFTER INSERT ON odd BEGIN
          INSERT INTO audit_log (note) VALUES ('x');
        END;
        CREATE TABLE keyless (a TEXT);
        INSERT INTO keyless VALUES ('seed');
        CREATE INDEX odd_shape ON odd (shape) WHERE "Mixed" GLOB 'x*';
        """)

      plan = Schema.from_sqlite(db)
      Exqlite.Sqlite3.close(db)

      fatal = plan |> Schema.fatal_notes() |> Enum.map(&{&1.kind, &1.name})

      assert {:column_type, "odd.shape"} in fatal
      assert {:identifier, "odd.order"} in fatal
      assert {:identifier, "odd.Mixed"} in fatal
      assert {:trigger, "odd_audit"} in fatal
      assert {:seed, "keyless"} in fatal
      assert {:index, "odd_shape"} in fatal
      refute Enum.any?(plan.skipped, &(&1.name == "odd_audit"))
    end

    test "the engine's own schema has none, and every data step is declared", %{plan: plan} do
      assert Schema.fatal_notes(plan) == []
      assert Steps.check() == :ok
    end
  end

  describe "every migration through the translator" do
    # The derivation carries the schema the migrations leave. Here every
    # statement of every migration runs through the translator on its own, so
    # a new migration with an index, view, check or trigger PostgreSQL cannot
    # take fails in CI; its data statements need a declared step
    # (OptimalEngine.Store.Postgres.Steps).
    test "every index, view, check and trigger statement translates", %{plan: plan} do
      # A full-text table a later migration removed is still one here.
      created =
        for {_version, _description, statements} <- Migrations.all(),
            {_label, sql} <- statements,
            [_, name] <-
              Regex.scan(~r/CREATE\s+VIRTUAL\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)/i, sql),
            do: name

      full_text =
        for(%{kind: :table, name: name} <- plan.skipped, do: name)
        |> Enum.concat(created)
        |> MapSet.new()

      failures =
        for {version, _description, statements} <- Migrations.all(),
            {label, sql} <- statements,
            failure = untranslatable(String.trim(sql), full_text),
            failure != nil do
          {version, label, failure}
        end

      assert failures == [], inspect(failures, pretty: true)
    end

    test "every other statement is a data statement of a known kind" do
      kinds =
        for {_version, _description, statements} <- Migrations.all(),
            {_label, kind} <- Steps.data_statements(statements),
            into: MapSet.new(),
            do: kind

      known =
        MapSet.new([
          "UPDATE",
          "DELETE",
          "INSERT",
          "INSERT ... SELECT",
          "DROP TABLE",
          "ALTER TABLE RENAME",
          "ALTER TABLE DROP"
        ])

      assert MapSet.subset?(kinds, known), inspect(MapSet.difference(kinds, known))
    end
  end

  defp untranslatable(sql, full_text) do
    cond do
      Regex.match?(~r/\ACREATE\s+(UNIQUE\s+)?INDEX\b/i, sql) ->
        refusal(Dialect.to_postgres(sql))

      match = Regex.run(~r/\ACREATE\s+VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?\S+\s+AS\s+(.*)\z/is, sql) ->
        refusal(Dialect.to_postgres(List.last(match)))

      Regex.match?(~r/\ACREATE\s+TABLE\b/i, sql) ->
        {:ok, clauses} = Schema.check_clauses(sql)
        Enum.find_value(clauses, &refusal(Dialect.to_postgres(&1)))

      Regex.match?(~r/\ACREATE\s+TRIGGER\b/i, sql) ->
        written = Schema.written_tables(sql)

        # An optional full-text table of an earlier release may no longer be
        # created anywhere; it keeps the _fts name.
        full_text? = &(MapSet.member?(full_text, &1) or String.ends_with?(&1, "_fts"))

        if written == [] or not Enum.all?(written, full_text?),
          do: {:trigger_writes, written}

      true ->
        nil
    end
  end

  defp refusal({:ok, _sql}), do: nil
  defp refusal({:error, reason}), do: reason
end
