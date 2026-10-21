defmodule OptimalEngine.Store.BindErrorsTest do
  @moduledoc """
  The statements #118 left unguarded: a parameter SQLite cannot bind is an
  error for the caller, never a raise. Exqlite raises on an integer outside 64
  bits, on a type it has no mapping for and on the wrong number of parameters.
  Inside a transaction the error is a return value, so the transaction ends and
  rolls back instead of re-raising in the caller; the graph edge insert that
  runs inside the Store skips the edge.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Graph, Store}
  alias OptimalEngine.Store.SQLite

  @too_big 9_223_372_036_854_775_808

  defp store_pid, do: Process.whereis(OptimalEngine.Store.SQLite)

  describe "transaction/1" do
    test "txn_query/3 answers the error, the transaction ends, and the Store keeps running" do
      pid = store_pid()

      for params <- [[@too_big], [%{"a" => 1}], []] do
        assert {:error, :invalid_parameter} =
                 Store.transaction(fn txn -> Store.txn_query(txn, "SELECT ?1", params) end)
      end

      assert store_pid() == pid
      assert {:ok, [[1]]} = Store.raw_query("SELECT 1", [])
    end

    test "txn_execute/3 answers the error and rolls back what the transaction wrote" do
      pid = store_pid()
      id = "bind-errors-#{System.unique_integer([:positive])}"

      assert {:error, :invalid_parameter} =
               Store.transaction(fn txn ->
                 with {:ok, _} <-
                        Store.txn_execute(
                          txn,
                          "INSERT INTO backup_records (id, storage_uri) VALUES (?1, 'x')",
                          [id]
                        ),
                      {:ok, _} <-
                        Store.txn_execute(
                          txn,
                          "UPDATE contexts SET title = title WHERE rowid = ?1",
                          [@too_big]
                        ) do
                   {:ok, :committed}
                 end
               end)

      assert store_pid() == pid
      assert {:ok, []} = Store.raw_query("SELECT id FROM backup_records WHERE id = ?1", [id])
    end

    test "the largest 64-bit integer still binds inside a transaction" do
      assert {:ok, [[9_223_372_036_854_775_807]]} =
               Store.transaction(fn txn ->
                 Store.txn_query(txn, "SELECT ?1", [9_223_372_036_854_775_807])
               end)
    end
  end

  describe "the graph edge insert that runs inside the Store" do
    setup do
      dir = Path.join(System.tmp_dir!(), "bind-errors-#{System.unique_integer([:positive])}")
      {:ok, db} = SQLite.open_and_migrate(Path.join(dir, "store.db"))

      on_exit(fn ->
        Exqlite.Sqlite3.close(db)
        File.rm_rf(dir)
      end)

      %{db: db}
    end

    defp edge_count(db, source) do
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(db, "SELECT COUNT(*) FROM graph_edges WHERE source_id = ?1")

      :ok = Exqlite.Sqlite3.bind(stmt, [source])
      {:row, [count]} = Exqlite.Sqlite3.step(db, stmt)
      :ok = Exqlite.Sqlite3.release(db, stmt)
      count
    end

    test "an edge parameter SQLite cannot hold skips that edge and raises nothing", %{db: db} do
      context = %{
        id: "ctx-bind-1",
        node: nil,
        entities: [],
        routed_to: ["good-node", %{"not" => "text"}, @too_big],
        workspace_id: "default"
      }

      assert :ok = Graph.create_edges_for_context_db(db, context)
      assert edge_count(db, "ctx-bind-1") == 1
    end
  end
end
