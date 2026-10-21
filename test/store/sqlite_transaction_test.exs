defmodule OptimalEngine.Store.SQLiteTransactionTest do
  @moduledoc """
  Every Store transaction checks its COMMIT. A COMMIT that fails leaves
  SQLite's transaction open, and the next BEGIN on the connection would fail
  with "cannot start a transaction within a transaction"; the transaction is
  rolled back instead, so the connection keeps working. A connection still in
  a transaction after the ROLLBACK is replaced. Transaction control sent as a
  raw statement is refused.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Context
  alias OptimalEngine.Pipeline.Decomposer.Chunk
  alias OptimalEngine.Store
  alias OptimalEngine.Store.SQLiteTransaction
  alias OptimalEngine.Store.SQLiteTransaction.StillOpenError

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

    test "a BEGIN that fails is begin_failed and runs nothing", %{db: db} do
      :ok = Exqlite.Sqlite3.execute(db, "BEGIN")

      assert {:error, {:begin_failed, @nested}} =
               SQLiteTransaction.run(db, fn -> flunk("ran without its own transaction") end)

      :ok = Exqlite.Sqlite3.execute(db, "ROLLBACK")
    end

    test "a connection still in a transaction after the ROLLBACK is refused", %{db: db} do
      assert :ok = SQLiteTransaction.ensure_ended!(db)

      :ok = Exqlite.Sqlite3.execute(db, "BEGIN")
      assert_raise StillOpenError, fn -> SQLiteTransaction.ensure_ended!(db) end
      :ok = Exqlite.Sqlite3.execute(db, "ROLLBACK")

      assert :ok = SQLiteTransaction.ensure_ended!(db)
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

      base = chunk(n, "base")
      :ok = Store.insert_chunks([base])
      cluster = %{id: "txn-cluster-#{n}", theme: "txn", member_count: 1, centroid: [0.5]}
      :ok = Store.insert_clusters([cluster])

      on_exit(fn ->
        Store.raw_execute("DROP TABLE IF EXISTS #{child}")
        Store.raw_execute("DROP TABLE IF EXISTS #{parent}")
        Store.raw_execute("DELETE FROM clusters WHERE id = ?1", [cluster.id])
        Store.raw_execute("DELETE FROM chunks WHERE signal_id = ?1", ["txn-signal-#{n}"])
        Store.raw_execute("DELETE FROM contexts WHERE id = ?1", ["txn-ctx-#{n}"])
      end)

      %{n: n, parent: parent, child: child, base: base, cluster: cluster}
    end

    test "a transaction whose COMMIT fails leaves the Store able to open the next one", ctx do
      assert {:error, {:commit_failed, _}} =
               Store.transaction(fn txn ->
                 {:ok, 1} = Store.txn_execute(txn, "INSERT INTO #{ctx.child} VALUES (1, 99)")
                 {:ok, :written}
               end)

      chunk = chunk(ctx.n, "after")

      assert :ok = Store.insert_chunks([chunk])
      assert {:ok, [[0]]} = Store.raw_query("SELECT COUNT(*) FROM #{ctx.child}")
    end

    for insert <- ~w(contexts chunks classifications intents embeddings clusters cluster_members)a do
      test "insert_#{insert} reports a COMMIT that fails as commit_failed", ctx do
        %{write: write, table: table, match: match, count: count} =
          insert_case(unquote(insert), ctx)

        fail_commit_on(ctx, table, match)

        assert {:error, {:commit_failed, reason}} = write.()
        assert reason =~ "FOREIGN KEY"
        assert count.() == 0
      end

      test "insert_#{insert} reports a BEGIN that fails as begin_failed", ctx do
        %{write: write, count: count} = insert_case(unquote(insert), ctx)

        assert {:error, {:begin_failed, @nested}} = with_open_transaction(write)
        assert count.() == 0
      end
    end

    test "a context batch that does not commit is not served from the cache", ctx do
      id = "txn-ctx-#{ctx.n}"
      fail_commit_on(ctx, "contexts", "NEW.id = '#{id}'")

      assert {:error, {:commit_failed, _}} = Store.insert_contexts([context(id)])
      assert {:error, :not_found} = Store.get_context(id)
    end

    test "a transaction that cannot be ended restarts the Store on a new connection" do
      before = Process.whereis(OptimalEngine.Store.SQLite)
      ref = Process.monitor(before)

      capture_log(fn ->
        assert {{%StillOpenError{}, _stacktrace}, _call} =
                 catch_exit(Store.transaction(fn _txn -> raise StillOpenError end))

        assert_receive {:DOWN, ^ref, :process, ^before, _reason}, 5_000
      end)

      assert {:ok, [[1]]} = wait_for_store()
      refute Process.whereis(OptimalEngine.Store.SQLite) == before
    end

    test "refuses transaction control sent as a raw statement", ctx do
      for sql <- [
            "COMMIT--x",
            "commit--x",
            "ROLLBACK--x",
            "END/**/",
            "/*/ x */ COMMIT",
            "; COMMIT",
            "COMMIT TRANSACTION",
            "  COMMIT",
            "END TRANSACTION",
            "-- open one\nROLLBACK",
            "ROLLBACK TO sp",
            "rollback transaction to sp",
            "/* note */ SAVEPOINT sp",
            "RELEASE sp",
            "BEGIN",
            "begin immediate",
            "BeGiN DEFERRED",
            "BEGIN/**/IMMEDIATE"
          ] do
        assert_raise ArgumentError, ~r/Store.transaction/, fn -> Store.raw_query(sql) end
        assert_raise ArgumentError, ~r/Store.transaction/, fn -> Store.raw_execute(sql) end
      end

      assert {:ok, [["BEGIN"]]} = Store.raw_query("SELECT 'BEGIN'")
      assert {:ok, [[1]]} = Store.raw_query("SELECT 1 -- COMMIT")
      assert {:ok, [[1]]} = Store.raw_query("/* COMMIT */ SELECT 1")
      assert :ok = Store.raw_execute("INSERT INTO #{ctx.parent} VALUES (1)")
    end

    test "allows statements that only contain transaction keywords", ctx do
      trigger = "txn_trigger_#{ctx.n}"
      spans = "txn_spans_#{ctx.n}"
      on_exit(fn -> Store.raw_execute("DROP TABLE IF EXISTS #{spans}") end)

      # A trigger body is BEGIN .. END inside one CREATE statement.
      assert :ok =
               Store.raw_execute("""
               CREATE TRIGGER #{trigger} AFTER INSERT ON #{ctx.parent}
               BEGIN
                 SELECT 1;
               END
               """)

      assert :ok = Store.raw_execute("INSERT INTO #{ctx.parent} VALUES (1)")
      assert :ok = Store.raw_execute("DROP TRIGGER #{trigger}")

      assert :ok =
               Store.raw_execute(~s|CREATE TABLE #{spans} (id INTEGER PRIMARY KEY, "end" INTEGER)|)

      assert :ok = Store.raw_execute(~s|INSERT INTO #{spans} (id, "end") VALUES (1, 1)|)
      assert :ok = Store.raw_execute(~s|UPDATE #{spans} SET "end" = 2 WHERE id = 1|)
      assert {:ok, [[2]]} = Store.raw_query(~s|SELECT "end" FROM #{spans}|)
    end

    test "inside a transaction only savepoints are allowed", ctx do
      assert {:ok, :done} =
               Store.transaction(fn txn ->
                 {:ok, _} = Store.txn_execute(txn, "SAVEPOINT sp")
                 {:ok, 1} = Store.txn_execute(txn, "INSERT INTO #{ctx.parent} VALUES (1)")
                 {:ok, _} = Store.txn_execute(txn, "ROLLBACK TO sp")
                 {:ok, _} = Store.txn_execute(txn, "rollback transaction to sp")
                 {:ok, _} = Store.txn_execute(txn, "ROLLBACK\n  TO sp")
                 {:ok, _} = Store.txn_execute(txn, "release savepoint sp")
                 {:ok, :done}
               end)

      for sql <- [
            "COMMIT--x",
            "ROLLBACK--x",
            "ROLLBACK -- to",
            "END/**/",
            "/*/ x */ COMMIT",
            "COMMIT TRANSACTION",
            "Commit",
            "COMMIT",
            "ROLLBACK",
            "END",
            "BEGIN",
            "BEGIN DEFERRED",
            "BEGIN/**/IMMEDIATE"
          ] do
        assert_raise ArgumentError, ~r/Store.transaction/, fn ->
          Store.transaction(fn txn -> Store.txn_execute(txn, sql) end)
        end
      end

      assert {:ok, [[0]]} = Store.raw_query("SELECT COUNT(*) FROM #{ctx.parent}")
      assert {:ok, :still_works} = Store.transaction(fn _txn -> {:ok, :still_works} end)
    end
  end

  # One write per Store insert, the table it writes, a trigger condition that
  # matches its row, and a count of that row.
  defp insert_case(:contexts, ctx) do
    id = "txn-ctx-#{ctx.n}"

    %{
      write: fn -> Store.insert_contexts([context(id)]) end,
      table: "contexts",
      match: "NEW.id = '#{id}'",
      count: fn -> rows("contexts", "id", id) end
    }
  end

  defp insert_case(:chunks, ctx) do
    chunk = chunk(ctx.n, "new")

    %{
      write: fn -> Store.insert_chunks([chunk]) end,
      table: "chunks",
      match: "NEW.id = '#{chunk.id}'",
      count: fn -> rows("chunks", "id", chunk.id) end
    }
  end

  defp insert_case(:classifications, ctx) do
    row = %{chunk_id: ctx.base.id, mode: :linguistic, genre: :note, sn_ratio: 0.5}

    %{
      write: fn -> Store.insert_classifications([row]) end,
      table: "classifications",
      match: "NEW.chunk_id = '#{ctx.base.id}'",
      count: fn -> rows("classifications", "chunk_id", ctx.base.id) end
    }
  end

  defp insert_case(:intents, ctx) do
    row = %{chunk_id: ctx.base.id, intent: :record_fact, confidence: 0.9}

    %{
      write: fn -> Store.insert_intents([row]) end,
      table: "intents",
      match: "NEW.chunk_id = '#{ctx.base.id}'",
      count: fn -> rows("intents", "chunk_id", ctx.base.id) end
    }
  end

  defp insert_case(:embeddings, ctx) do
    row = %{chunk_id: ctx.base.id, model: "txn-test", vector: [0.25, 0.5]}

    %{
      write: fn -> Store.insert_embeddings([row]) end,
      table: "chunk_embeddings",
      match: "NEW.chunk_id = '#{ctx.base.id}'",
      count: fn -> rows("chunk_embeddings", "chunk_id", ctx.base.id) end
    }
  end

  defp insert_case(:clusters, ctx) do
    id = "txn-cluster-new-#{ctx.n}"

    %{
      write: fn -> Store.insert_clusters([%{id: id, theme: "txn", centroid: [0.5]}]) end,
      table: "clusters",
      match: "NEW.id = '#{id}'",
      count: fn -> rows("clusters", "id", id) end
    }
  end

  defp insert_case(:cluster_members, ctx) do
    row = %{cluster_id: ctx.cluster.id, chunk_id: ctx.base.id, weight: 1.0}

    %{
      write: fn -> Store.insert_cluster_members([row]) end,
      table: "cluster_members",
      match: "NEW.cluster_id = '#{ctx.cluster.id}'",
      count: fn -> rows("cluster_members", "cluster_id", ctx.cluster.id) end
    }
  end

  # The matching row also writes a child whose deferred foreign key names no
  # parent, so its transaction fails at COMMIT.
  defp fail_commit_on(ctx, table, match) do
    trigger = "txn_fail_#{table}_#{ctx.n}"

    :ok =
      Store.raw_execute("""
      CREATE TRIGGER #{trigger} AFTER INSERT ON #{table} WHEN #{match}
      BEGIN
        INSERT INTO #{ctx.child} (parent_id) VALUES (99);
      END
      """)

    on_exit(fn -> Store.raw_execute("DROP TRIGGER IF EXISTS #{trigger}") end)
  end

  # Opens a transaction on the Store's connection behind its back, so the
  # Store's own BEGIN fails.
  defp with_open_transaction(write) do
    %{db: db} = :sys.get_state(OptimalEngine.Store.SQLite)
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")

    try do
      write.()
    after
      :ok = Exqlite.Sqlite3.execute(db, "ROLLBACK")
    end
  end

  defp wait_for_store(attempts \\ 50) do
    Store.raw_query("SELECT 1")
  catch
    :exit, _ when attempts > 0 ->
      Process.sleep(100)
      wait_for_store(attempts - 1)
  end

  defp rows(table, column, value) do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE #{column} = ?1", [value])
    n
  end

  defp chunk(n, name) do
    Chunk.new(
      id: "txn-chunk-#{name}-#{n}",
      signal_id: "txn-signal-#{n}",
      scale: :chunk,
      text: "a transaction test chunk"
    )
  end

  defp context(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Context{
      id: id,
      uri: "optimal://inbox/#{id}.md",
      type: :signal,
      path: "/tmp/#{id}.md",
      title: id,
      content: id,
      l0_abstract: id,
      l1_overview: id,
      node: "inbox",
      sn_ratio: 0.8,
      entities: [],
      created_at: now,
      modified_at: now,
      routed_to: [],
      workspace_id: "default:knowledge-intake",
      metadata: %{}
    }
  end

  defp count(db, table) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT COUNT(*) FROM #{table}")
    {:row, [n]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    n
  end
end
