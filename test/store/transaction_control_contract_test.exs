defmodule OptimalEngine.Store.TransactionControlContractTest do
  @moduledoc """
  Both stores refuse transaction control sent as a statement the same way
  (`OptimalEngine.Store.TransactionControl`): a raw statement raises
  `ArgumentError` before it reaches the database, whatever whitespace,
  comments or empty statements come first, and inside a transaction only
  savepoints may be used. The same checks run against each adapter.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store.Postgres.Schema
  alias OptimalEngine.Test.PostgresStore

  @refused_outside [
    "COMMIT--x",
    "commit--x",
    "ROLLBACK--x",
    "END/**/",
    "/*/ x */ COMMIT",
    "/* x */ COMMIT",
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
    "BEGIN/**/IMMEDIATE",
    "START TRANSACTION",
    "ABORT"
  ]

  @refused_inside [
    "COMMIT--x",
    "ROLLBACK--x",
    "ROLLBACK -- to",
    "END/**/",
    "/*/ x */ COMMIT",
    "/* x */ COMMIT",
    "COMMIT TRANSACTION",
    "Commit",
    "ROLLBACK",
    "END",
    "BEGIN",
    "BEGIN DEFERRED",
    "BEGIN/**/IMMEDIATE",
    "START TRANSACTION",
    "ABORT"
  ]

  describe "the SQLite store" do
    test "refuses transaction control sent as a raw statement" do
      refuses_outside(OptimalEngine.Store.SQLite)
    end

    test "allows only savepoints inside a transaction" do
      savepoints_only_inside(OptimalEngine.Store.SQLite)
    end
  end

  describe "the PostgreSQL store" do
    @describetag :postgres

    setup do
      schema = PostgresStore.unique_schema()
      pool = PostgresStore.start_pool(schema)
      {:ok, _} = Schema.sync(pool, schema: schema)
      GenServer.stop(pool)

      {:ok, store} =
        GenServer.start(OptimalEngine.Store.Postgres, PostgresStore.options(schema))

      on_exit(fn ->
        GenServer.stop(store)
        released()
        PostgresStore.drop_schema(schema)
      end)
    end

    test "refuses transaction control sent as a raw statement" do
      refuses_outside(OptimalEngine.Store.Postgres)
    end

    test "allows only savepoints inside a transaction" do
      savepoints_only_inside(OptimalEngine.Store.Postgres)
    end
  end

  defp refuses_outside(store) do
    for sql <- @refused_outside do
      assert_raise ArgumentError, ~r/Store.transaction/, fn -> store.raw_query(sql, []) end
      assert_raise ArgumentError, ~r/Store.transaction/, fn -> store.raw_execute(sql, []) end
    end

    assert {:ok, [["BEGIN"]]} = store.raw_query("SELECT 'BEGIN'", [])
    assert {:ok, [[1]]} = store.raw_query("SELECT 1 -- COMMIT", [])
    assert {:ok, [[1]]} = store.raw_query("/* COMMIT */ SELECT 1", [])
  end

  defp savepoints_only_inside(store) do
    assert {:ok, :done} =
             store.transaction(fn txn ->
               {:ok, _} = store.txn_execute(txn, "SAVEPOINT sp")
               {:ok, _} = store.txn_execute(txn, "ROLLBACK TO sp")
               {:ok, _} = store.txn_execute(txn, "rollback transaction to sp")
               {:ok, _} = store.txn_execute(txn, "ROLLBACK\n  TO sp")
               {:ok, _} = store.txn_execute(txn, "release savepoint sp")

               # A refused statement never reaches the database, so the
               # transaction goes on.
               assert_raise ArgumentError, fn -> store.txn_execute(txn, "/* x */ COMMIT") end
               {:ok, [[1]]} = store.txn_query(txn, "SELECT 1")
               {:ok, :done}
             end)

    for sql <- @refused_inside do
      assert_raise ArgumentError, ~r/Store.transaction/, fn ->
        store.transaction(fn txn -> store.txn_execute(txn, sql) end)
      end
    end

    assert {:ok, :still_works} = store.transaction(fn _txn -> {:ok, :still_works} end)
    assert {:ok, [[1]]} = store.raw_query("SELECT 1", [])
  end

  # The PostgreSQL store's pool is named; the next test waits until it is gone.
  defp released do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Process.whereis(OptimalEngine.Store.Postgres.Pool),
        do: {:cont, Process.sleep(20)},
        else: {:halt, :ok}
    end)
  end
end
