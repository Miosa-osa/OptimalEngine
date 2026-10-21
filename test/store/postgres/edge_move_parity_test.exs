defmodule OptimalEngine.Store.Postgres.EdgeMoveParityTest do
  @moduledoc """
  A context the corpus organizer moves to another workspace takes its graph
  edges with it, in three statements of portable SQL (`update_edges` and
  `drop_default_copies` in `OptimalEngine.CorpusOrganizer`). They run here on
  SQLite and on PostgreSQL over the same rows, with the same edge ids, and
  must leave the same edges: the ones the move is for.

  The statements must still be at their call site, so a changed statement
  fails here until this case is updated.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Store.Postgres.{Connection, Schema}
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres

  @site "lib/optimal_engine/corpus_organizer.ex"

  @tenant "t1"
  @other_tenant "t2"
  @default "default"
  @context "move-c"
  @other_context "other-o"
  @source "t1:inbox"
  @target "t1:notes"
  @elsewhere "t1:elsewhere"

  # drop_default_copies, then update_edges' two statements, in the order the
  # organizer runs them in one transaction.
  @statements [
    {"""
     DELETE FROM graph_edges
     WHERE workspace_id = ?1 AND tenant_id = ?4
       AND (source_id = ?2 OR target_id = ?2)
       AND EXISTS (
         SELECT 1 FROM graph_edges kept
         WHERE kept.workspace_id = ?1 AND kept.tenant_id = ?3
           AND kept.source_id = graph_edges.source_id
           AND kept.target_id = graph_edges.target_id
           AND kept.relation = graph_edges.relation
       )
       AND NOT EXISTS (
         SELECT 1 FROM contexts other
         WHERE other.id IN (graph_edges.source_id, graph_edges.target_id)
           AND other.id <> ?2 AND other.tenant_id <> ?3
       )
     """, [@source, @context, @tenant, @default]},
    {"""
     DELETE FROM graph_edges
     WHERE workspace_id = ?1 AND tenant_id = ?3
       AND EXISTS (
         SELECT 1 FROM graph_edges moving
         WHERE moving.id <> graph_edges.id
           AND moving.source_id = graph_edges.source_id
           AND moving.target_id = graph_edges.target_id
           AND moving.relation = graph_edges.relation
           AND moving.workspace_id = ?5 AND moving.tenant_id IN (?3, ?4)
           AND (moving.source_id = ?2 OR moving.target_id = ?2)
       )
       AND NOT EXISTS (
         SELECT 1 FROM contexts other
         WHERE other.id IN (graph_edges.source_id, graph_edges.target_id)
           AND other.id <> ?2 AND other.tenant_id <> ?3
       )
     """, [@target, @context, @tenant, @default, @source]},
    {"""
     UPDATE graph_edges SET workspace_id = ?1, tenant_id = ?3
     WHERE (source_id = ?2 OR target_id = ?2) AND workspace_id = ?5 AND tenant_id IN (?3, ?4)
       AND NOT EXISTS (
         SELECT 1 FROM contexts other
         WHERE other.id IN (graph_edges.source_id, graph_edges.target_id)
           AND other.id <> ?2 AND other.tenant_id <> ?3
       )
     """, [@target, @context, @tenant, @default, @source]}
  ]

  # {id, tenant, workspace, source, target}, every edge with the relation "r".
  @edges [
    # the context's own edge in the source workspace: moves
    {1, @tenant, @source, @context, "x"},
    # a default-tenant edge of the context: moves and takes the tenant
    {2, @default, @source, "x", @context},
    # reaches a record of another tenant: stays
    {3, @tenant, @source, @context, @other_context},
    # the target's copy of edge 1: replaced by it
    {4, @tenant, @target, @context, "x"},
    # a default-tenant copy of edge 1 in the source workspace: dropped
    {5, @default, @source, @context, "x"},
    # the context's edge in a third workspace: stays
    {6, @tenant, @elsewhere, @context, "y"},
    # labelled with another tenant: stays
    {7, @other_tenant, @source, @context, "z"},
    # does not reach the context: stays
    {8, @default, @source, "y", "z"},
    # a default-tenant edge in the target that edge 2 does not collide with: stays
    {9, @default, @target, "x", @context}
  ]

  @moved [
    [1, @tenant, @target, @context, "x"],
    [2, @tenant, @target, "x", @context],
    [3, @tenant, @source, @context, @other_context],
    [6, @tenant, @elsewhere, @context, "y"],
    [7, @other_tenant, @source, @context, "z"],
    [8, @default, @source, "y", "z"],
    [9, @default, @target, "x", @context]
  ]

  @read "SELECT id, tenant_id, workspace_id, source_id, target_id FROM graph_edges ORDER BY id"

  setup_all do
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")
    capture_log(fn -> :ok = OptimalEngine.Store.SQLite.migrate(db) end)

    schema = PostgresStore.unique_schema()
    pool = start_supervised!({Connection, PostgresStore.options(schema)})
    {:ok, _} = Schema.sync(pool, schema: schema)
    {:ok, plan} = Schema.derive()

    on_exit(fn ->
      Exqlite.Sqlite3.close(db)
      PostgresStore.drop_schema(schema)
    end)

    contexts = [
      %{"id" => @context, "tenant_id" => @tenant, "workspace_id" => @target, "title" => "moved"},
      %{
        "id" => @other_context,
        "tenant_id" => @other_tenant,
        "workspace_id" => "t2:inbox",
        "title" => "other"
      }
    ]

    for row <- contexts, do: insert!(db, pool, plan, "contexts", row)

    for {id, tenant, workspace, source, target} <- @edges do
      insert!(db, pool, plan, "graph_edges", %{
        "id" => id,
        "tenant_id" => tenant,
        "workspace_id" => workspace,
        "source_id" => source,
        "target_id" => target,
        "relation" => "r"
      })
    end

    %{db: db, pool: pool}
  end

  test "the statements are still the organizer's" do
    site = squash(File.read!(@site))

    for {sql, _params} <- @statements do
      assert String.contains?(site, squash(sql)), "#{@site} no longer has: #{sql}"
    end
  end

  test "both stores leave the edges the move is for", %{db: db, pool: pool} do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN IMMEDIATE")
    for {sql, params} <- @statements, do: sqlite_rows(db, sql, params)
    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")

    assert {:ok, :moved} =
             Connection.transaction(
               pool,
               fn txn ->
                 for {sql, params} <- @statements,
                     do: {:ok, _} = Connection.txn_query(txn, sql, params)

                 {:ok, :moved}
               end,
               10_000
             )

    assert sqlite_rows(db, @read, []) == @moved
    {:ok, %{rows: rows}} = Connection.query(pool, @read)
    assert rows == @moved
  end

  # A row with every column the table requires: the fixture's values, the
  # column default, or a filler of the column's type.
  defp insert!(db, pool, plan, table, values) do
    columns = Enum.find(plan.tables, &(&1.name == table)).columns

    row =
      for column <- columns,
          Map.has_key?(values, column.name) or
            (column.not_null and is_nil(column.default) and not column.identity) do
        {column.name, Map.get_lazy(values, column.name, fn -> filler(column) end)}
      end

    names = Enum.map_join(row, ", ", &elem(&1, 0))
    marks = Enum.map_join(1..length(row), ", ", &"?#{&1}")
    sql = "INSERT INTO #{table} (#{names}) VALUES (#{marks})"
    params = Enum.map(row, &elem(&1, 1))

    sqlite_rows(db, sql, params)
    {:ok, _} = Connection.query(pool, sql, params)
  end

  defp filler(%{type: "BIGINT"}), do: 0
  defp filler(%{type: "DOUBLE PRECISION"}), do: 0.0
  defp filler(%{type: "BYTEA"}), do: {:blob, <<>>}
  defp filler(%{name: name}), do: "#{name}-#{System.unique_integer([:positive])}"

  defp sqlite_rows(db, sql, params) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(statement, params)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
    Exqlite.Sqlite3.release(db, statement)
    rows
  end

  defp squash(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
