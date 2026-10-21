defmodule OptimalEngine.Graph.EdgeProvenanceTest do
  @moduledoc """
  A graph edge records who asserted it (`Graph.assert_edge/4` `:asserted_by`):
  the same asserter keeps it, a second asserter makes it nobody's in
  particular, and `retract_edge/4` with `:asserted_by` retracts only an edge
  that asserter holds alone.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Graph
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "provenance-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Provenance #{n}"})
    ws = "#{tenant}:docs"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'docs', 'docs', 'active', '{}')",
        [ws, tenant]
      )

    %{ws: ws}
  end

  defp edge(ws, relation) do
    {:ok, edges} = Graph.edges_by_relation([relation], workspace_id: ws)
    edges
  end

  test "an asserter keeps its edge until another one asserts it too", %{ws: ws} do
    :ok = Graph.assert_edge("a", "b", "links_to", workspace_id: ws, asserted_by: "importer")
    :ok = Graph.assert_edge("a", "b", "links_to", workspace_id: ws, asserted_by: "importer")
    assert [%{source_id: "a", target_id: "b", asserted_by: "importer"}] = edge(ws, "links_to")

    assert {:ok, [_]} =
             Graph.edges_by_relation(["links_to"], workspace_id: ws, asserted_by: "importer")

    # Someone else asserts the same edge: it is no longer the importer's alone.
    :ok = Graph.assert_edge("a", "b", "links_to", workspace_id: ws)
    assert [%{asserted_by: nil}] = edge(ws, "links_to")

    assert {:ok, []} =
             Graph.edges_by_relation(["links_to"], workspace_id: ws, asserted_by: "importer")

    # And it stays shared when the importer asserts it again.
    :ok = Graph.assert_edge("a", "b", "links_to", workspace_id: ws, asserted_by: "importer")
    assert [%{asserted_by: nil}] = edge(ws, "links_to")
  end

  test "asserting an edge again, or one that is already nobody's, writes nothing" do
    # The insert statement itself on a private database whose graph_edges has
    # the Store's key; a trigger there counts every update. The Store and the
    # SQL census never see this connection.
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")
    on_exit(fn -> Exqlite.Sqlite3.close(db) end)

    for sql <- [
          "CREATE TABLE workspaces (id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL)",
          "CREATE TABLE tenants (id TEXT PRIMARY KEY)",
          """
          CREATE TABLE graph_edges (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            tenant_id TEXT NOT NULL DEFAULT 'default',
            workspace_id TEXT NOT NULL DEFAULT 'default',
            source_id TEXT NOT NULL,
            target_id TEXT NOT NULL,
            relation TEXT NOT NULL DEFAULT 'related',
            weight REAL NOT NULL DEFAULT 1.0,
            valid_from TEXT,
            asserted_by TEXT,
            UNIQUE(tenant_id, workspace_id, source_id, target_id, relation)
          )
          """,
          "CREATE TABLE updates (n INTEGER)",
          "CREATE TRIGGER count_updates AFTER UPDATE ON graph_edges BEGIN INSERT INTO updates VALUES (1); END"
        ],
        do: :ok = Exqlite.Sqlite3.execute(db, sql)

    run = fn sql, params ->
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      result = Exqlite.Sqlite3.step(db, stmt)
      :ok = Exqlite.Sqlite3.release(db, stmt)
      result
    end

    assert_edge = fn by ->
      :done = run.(Graph.edge_insert_sql(), ["a", "b", "links_to", 1.0, "t", "ws", by])
    end

    updates = fn ->
      {:row, [n]} = run.("SELECT COUNT(*) FROM updates", [])
      n
    end

    asserter = fn ->
      {:row, [by]} = run.("SELECT asserted_by FROM graph_edges", [])
      by
    end

    assert_edge.("importer")
    assert_edge.("importer")
    assert {updates.(), asserter.()} == {0, "importer"}

    # A second asserter: the one write that makes the edge nobody's.
    assert_edge.(nil)
    assert {updates.(), asserter.()} == {1, nil}

    # From then on, neither asserter writes anything.
    assert_edge.("importer")
    assert_edge.(nil)
    assert {updates.(), asserter.()} == {1, nil}
  end

  test "a retract by an asserter removes only an edge it holds alone", %{ws: ws} do
    :ok = Graph.assert_edge("a", "b", "child_of", workspace_id: ws, asserted_by: "importer")
    :ok = Graph.assert_edge("c", "d", "child_of", workspace_id: ws, asserted_by: "importer")
    :ok = Graph.assert_edge("c", "d", "child_of", workspace_id: ws)

    :ok = Graph.retract_edge("a", "b", "child_of", workspace_id: ws, asserted_by: "importer")
    :ok = Graph.retract_edge("c", "d", "child_of", workspace_id: ws, asserted_by: "importer")
    assert [%{source_id: "c", target_id: "d"}] = edge(ws, "child_of")

    # Without an asserter the retract removes the edge whoever wrote it.
    :ok = Graph.retract_edge("c", "d", "child_of", workspace_id: ws)
    assert [] = edge(ws, "child_of")
  end
end
