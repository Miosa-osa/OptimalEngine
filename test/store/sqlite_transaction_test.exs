defmodule OptimalEngine.Store.SQLiteTransactionTest do
  @moduledoc """
  Every Store transaction checks its COMMIT. A COMMIT that fails leaves
  SQLite's transaction open, and the next BEGIN on the connection would fail
  with "cannot start a transaction within a transaction"; the transaction is
  rolled back instead, so the connection keeps working. Transaction control
  sent as a raw statement is refused.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Pipeline.Decomposer.Chunk
  alias OptimalEngine.Store
  alias OptimalEngine.Store.SQLiteTransaction

  @nested "cannot start a transaction within a transaction"

  describe "SQLiteTransaction.run/3" do
    setup do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")
      :ok = Exqlite.Sqlite3.execute(db, "PRAGMA foreign_keys = ON")
      :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE parent (id INTEGER PRIMARY KEY)")

      # A deferred foreign key is checked at COMMIT, which is how a COMMIT fails.
      :ok =
        Exqlite.Sqlite3.execute(
          db,
          "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)"
        )

      on_exit(fn -> Exqlite.Sqlite3.close(db) end)
      %{db: db}
    end

    test "SQLite keeps a transaction open after a failed COMMIT", %{db: db} do
      :ok = Exqlite.Sqlite3.execute(db, "BEGIN")
      :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO child VALUES (1, 99)")
      assert {:error, _} = Exqlite.Sqlite3.execute(db, "COMMIT")
      assert {:error, @nested} = Exqlite.Sqlite3.execute(db, "BEGIN")
      :ok = Exqlite.Sqlite3.execute(db, "ROLLBACK")
    end

    test "a failed COMMIT is rolled back and the next transaction works", %{db: db} do
      assert {:error, {:commit_failed, reason}} =
               SQLiteTransaction.run(db, fn ->
                 Exqlite.Sqlite3.execute(db, "INSERT INTO child VALUES (1, 99)")
               end)

      assert reason =~ "FOREIGN KEY"

      assert :ok =
               SQLiteTransaction.run(db, fn ->
                 Exqlite.Sqlite3.execute(db, "INSERT INTO parent VALUES (1)")
               end)

      assert count(db, "parent") == 1
      assert count(db, "child") == 0
    end

    test "commits :ok and {:ok, result}, and rolls back everything else", %{db: db} do
      assert {:ok, :kept} =
               SQLiteTransaction.run(db, fn ->
                 :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO parent VALUES (1)")
                 {:ok, :kept}
               end)

      assert {:error, :nope} =
               SQLiteTransaction.run(db, fn ->
                 :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO parent VALUES (2)")
                 {:error, :nope}
               end)

      assert :unexpected =
               SQLiteTransaction.run(db, fn ->
                 :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO parent VALUES (3)")
                 :unexpected
               end)

      assert count(db, "parent") == 1
    end

    test "a raise rolls back, is re-raised, and leaves the connection usable", %{db: db} do
      assert_raise RuntimeError, "boom", fn ->
        SQLiteTransaction.run(db, fn ->
          :ok = Exqlite.Sqlite3.execute(db, "INSERT INTO parent VALUES (1)")
          raise "boom"
        end)
      end

      assert :ok = SQLiteTransaction.run(db, fn -> :ok end)
      assert count(db, "parent") == 0
    end
  end

  describe "the Store" do
    setup do
      n = System.unique_integer([:positive])
      parent = "txn_parent_#{n}"
      child = "txn_child_#{n}"

      :ok = Store.raw_execute("CREATE TABLE #{parent} (id INTEGER PRIMARY KEY)")

      :ok =
        Store.raw_execute(
          "CREATE TABLE #{child} (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES #{parent}(id) DEFERRABLE INITIALLY DEFERRED)"
        )

      on_exit(fn ->
        Store.raw_execute("DROP TABLE IF EXISTS #{child}")
        Store.raw_execute("DROP TABLE IF EXISTS #{parent}")
      end)

      %{n: n, parent: parent, child: child}
    end

    test "a transaction whose COMMIT fails leaves the Store able to open the next one", ctx do
      assert {:error, {:commit_failed, _}} =
               Store.transaction(fn txn ->
                 {:ok, 1} = Store.txn_execute(txn, "INSERT INTO #{ctx.child} VALUES (1, 99)")
                 {:ok, :written}
               end)

      chunk =
        Chunk.new(
          id: "txn-chunk-#{ctx.n}",
          signal_id: "txn-signal-#{ctx.n}",
          scale: :chunk,
          text: "after a failed commit"
        )

      assert :ok = Store.insert_chunks([chunk])
      assert {:ok, [[0]]} = Store.raw_query("SELECT COUNT(*) FROM #{ctx.child}")
      Store.raw_execute("DELETE FROM chunks WHERE id = ?1", [chunk.id])
    end

    test "refuses transaction control sent as a raw statement", ctx do
      for sql <- [
            "BEGIN",
            "begin immediate",
            "  COMMIT",
            "END TRANSACTION",
            "-- open one\nROLLBACK",
            "/* note */ SAVEPOINT sp",
            "RELEASE sp"
          ] do
        assert_raise ArgumentError, ~r/Store.transaction/, fn -> Store.raw_query(sql) end
        assert_raise ArgumentError, ~r/Store.transaction/, fn -> Store.raw_execute(sql) end
      end

      assert {:ok, [["BEGIN"]]} = Store.raw_query("SELECT 'BEGIN'")
      assert {:ok, [[1]]} = Store.raw_query("SELECT 1 -- COMMIT")
      assert :ok = Store.raw_execute("INSERT INTO #{ctx.parent} VALUES (1)")
    end

    test "inside a transaction only savepoints are allowed", ctx do
      assert {:ok, :done} =
               Store.transaction(fn txn ->
                 {:ok, _} = Store.txn_execute(txn, "SAVEPOINT sp")
                 {:ok, 1} = Store.txn_execute(txn, "INSERT INTO #{ctx.parent} VALUES (1)")
                 {:ok, _} = Store.txn_execute(txn, "ROLLBACK TO sp")
                 {:ok, _} = Store.txn_execute(txn, "RELEASE sp")
                 {:ok, :done}
               end)

      for sql <- ["COMMIT", "ROLLBACK", "BEGIN", "END"] do
        assert_raise ArgumentError, ~r/Store.transaction/, fn ->
          Store.transaction(fn txn -> Store.txn_execute(txn, sql) end)
        end
      end

      assert {:ok, [[0]]} = Store.raw_query("SELECT COUNT(*) FROM #{ctx.parent}")
      assert {:ok, :still_works} = Store.transaction(fn _txn -> {:ok, :still_works} end)
    end
  end

  defp count(db, table) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT COUNT(*) FROM #{table}")
    {:row, [n]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    n
  end
end
