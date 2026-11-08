defmodule OptimalEngine.Store.Postgres.CatalogReplaceTest do
  @moduledoc """
  The store catalog answers alike on both stores, and SQLite's
  `INSERT OR REPLACE` replaces the same rows on PostgreSQL: every row the new
  one conflicts with, on any key, goes, and the new row's unnamed columns take
  their defaults.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Store.{Catalog, Replace}
  alias OptimalEngine.Store.Postgres, as: PgStore
  alias OptimalEngine.Store.Postgres.Schema
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres
  # Reads the SQLite store beside a PostgreSQL store of its own.
  @moduletag :sqlite_store

  setup_all do
    schema = PostgresStore.unique_schema()

    start_supervised!(
      {PgStore, PostgresStore.options(schema, pool_size: 4, full_text_interval_ms: 0)}
    )

    on_exit(fn -> PostgresStore.drop_schema(schema) end)
    {:ok, plan} = Schema.derive()
    %{planned: MapSet.new(plan.tables, & &1.name)}
  end

  defp on_both(fun),
    do: {Catalog.using(OptimalEngine.Store.SQLite, fun), Catalog.using(PgStore, fun)}

  describe "the catalog" do
    test "lists the migrations' tables on both stores, and no bookkeeping table", %{
      planned: planned
    } do
      {{:ok, sqlite}, {:ok, postgres}} = on_both(&Catalog.tables/0)

      assert MapSet.subset?(planned, MapSet.new(sqlite))
      assert MapSet.new(postgres) == planned
      refute Enum.any?(postgres, &String.starts_with?(&1, "optimal_"))
      refute "contexts_fts" in sqlite
    end

    test "gives the same columns and keys", %{} do
      for table <- ~w(contexts workspace_handles memory_embeddings entities viability_reports) do
        {{:ok, sqlite}, {:ok, postgres}} = on_both(fn -> Catalog.columns(table) end)

        assert Enum.map(postgres, &{elem(&1, 0), elem(&1, 2)}) ==
                 Enum.map(sqlite, &{elem(&1, 0), elem(&1, 2)}),
               table
      end

      # SQLite's INTEGER PRIMARY KEY is PostgreSQL's identity column.
      {{:ok, sqlite}, {:ok, postgres}} = on_both(fn -> Catalog.columns("entities") end)
      assert List.keyfind(sqlite, "id", 0) == {"id", "INTEGER", 1}
      assert List.keyfind(postgres, "id", 0) == {"id", "INTEGER", 1}
    end

    test "gives the same foreign keys" do
      for table <- ~w(entities memory_embeddings) do
        {{:ok, sqlite}, {:ok, postgres}} = on_both(fn -> Catalog.foreign_keys(table) end)
        assert Enum.sort(postgres) == Enum.sort(sqlite), table
        assert sqlite != []
      end
    end

    test "finds the same tables indexed by workspace", %{planned: planned} do
      {{:ok, sqlite}, {:ok, postgres}} =
        on_both(fn -> Catalog.tables_indexed_by("workspace_id") end)

      assert MapSet.new(postgres) == MapSet.intersection(MapSet.new(sqlite), planned)
      assert "contexts" in postgres
    end

    test "tells which tables exist, with or without case" do
      {sqlite, postgres} =
        on_both(fn ->
          {Catalog.table_exists?("contexts"), Catalog.table_exists?("CONTEXTS"),
           Catalog.table_exists?("CONTEXTS", case_insensitive: true),
           Catalog.table_exists?("no_such_table")}
        end)

      assert sqlite == {true, false, true, false}
      assert postgres == sqlite
    end

    test "reports integrity and foreign keys" do
      {sqlite, postgres} =
        on_both(fn -> {Catalog.integrity_check(), Catalog.foreign_key_violations()} end)

      assert sqlite == {{:ok, "ok"}, {:ok, []}}
      assert postgres == sqlite
    end
  end

  describe "a replace" do
    @replace """
    INSERT OR REPLACE INTO model_call_operations (id, workspace_id, function_name, model_task_type)
    VALUES (?1, ?2, ?3, ?4)
    """

    @read "SELECT id, workspace_id, function_name, model_task_type, lifecycle_state FROM model_call_operations WHERE workspace_id = ?1 ORDER BY id"

    defp run_both(statements, workspace) do
      sqlite =
        Store.transaction(fn txn ->
          for params <- statements, do: {:ok, _} = Replace.txn_execute(txn, @replace, params)
          {:ok, :done}
        end)

      postgres =
        PgStore.transaction(fn txn ->
          for params <- statements,
              do: {:ok, _} = Replace.as_delete_and_insert(PgStore, txn, @replace, params)

          {:ok, :done}
        end)

      assert sqlite == {:ok, :done}
      assert postgres == {:ok, :done}
      {:ok, sqlite_rows} = Store.raw_query(@read, [workspace])
      {:ok, postgres_rows} = PgStore.raw_query(@read, [workspace])
      {sqlite_rows, postgres_rows}
    end

    test "on the primary key or another unique key replaces the same rows on both stores" do
      ws = "replace-#{System.unique_integer([:positive])}"

      {sqlite, postgres} =
        run_both(
          [
            ["op-1", ws, "summarize", "generation"],
            ["op-2", ws, "classify", "generation"],
            # The same id: op-1 is replaced.
            ["op-1", ws, "summarize", "extraction"],
            # Another id with classify's (workspace_id, function_name): op-2 goes.
            ["op-3", ws, "classify", "routing"]
          ],
          ws
        )

      assert postgres == sqlite
      assert Enum.map(sqlite, &hd/1) == ["op-1", "op-3"]
    end

    test "with a key column given as an expression is refused" do
      assert_raise ArgumentError, fn ->
        Replace.plan(
          "INSERT OR REPLACE INTO viability_reports (tenant_id, scope, period, report) VALUES (lower(?1), ?2, ?3, ?4)",
          ["T", "s", "p", "{}"]
        )
      end
    end

    test "resolves numbered, positional and literal values" do
      {"viability_reports", insert, [{delete, values}]} =
        Replace.plan(
          "INSERT OR REPLACE INTO viability_reports (tenant_id, scope, period, report, backfilled) VALUES (?, 'wide', ?, datetime('now'), 0)",
          ["t1", "2026-11-08"]
        )

      assert insert =~ ~r/\AINSERT INTO viability_reports/
      assert delete =~ ~s(DELETE FROM "viability_reports" WHERE "tenant_id" = ?1)
      assert values == ["t1", "wide", "2026-11-08"]
    end
  end
end
