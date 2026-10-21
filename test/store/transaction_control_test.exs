defmodule OptimalEngine.Store.TransactionControlTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Store.TransactionControl

  describe "statement/1" do
    test "skips leading whitespace, comments and empty statements" do
      assert TransactionControl.statement("  COMMIT") == "COMMIT"
      assert TransactionControl.statement("-- open one\nROLLBACK") == "ROLLBACK"
      assert TransactionControl.statement("/* note */ SAVEPOINT sp") == "SAVEPOINT sp"
      assert TransactionControl.statement("; ;\n COMMIT") == "COMMIT"
      assert TransactionControl.statement("/* a */ -- b\n ; /* c */ BEGIN") == "BEGIN"
    end

    test "a block comment ends at the first */ after its opening" do
      assert TransactionControl.statement("/*/ x */ COMMIT") == "COMMIT"
      assert TransactionControl.statement("/* never closed COMMIT") == ""
      assert TransactionControl.statement("-- only a comment") == ""
    end

    test "leaves a statement that starts with a keyword as it is" do
      assert TransactionControl.statement("SELECT 1 -- COMMIT") == "SELECT 1 -- COMMIT"
    end
  end

  describe "refuse!/2 outside a transaction" do
    test "raises for every transaction statement, however it is written" do
      for sql <- [
            "BEGIN",
            "begin immediate",
            "BEGIN/**/IMMEDIATE",
            "COMMIT--x",
            "/* x */ COMMIT",
            "; COMMIT",
            "END TRANSACTION",
            "ROLLBACK",
            "ROLLBACK TO sp",
            "SAVEPOINT sp",
            "RELEASE sp",
            "START TRANSACTION",
            "abort"
          ] do
        assert_raise ArgumentError, ~r/OptimalEngine.Store.transaction\/2/, fn ->
          TransactionControl.refuse!(sql, :outside)
        end
      end
    end

    test "names the keyword it refused" do
      assert_raise ArgumentError, ~r/\ACOMMIT is transaction control/, fn ->
        TransactionControl.refuse!("/* x */ commit", :outside)
      end
    end

    test "lets other statements through, keywords inside them included" do
      for sql <- [
            "SELECT 'BEGIN'",
            "SELECT 1 -- COMMIT",
            "/* COMMIT */ SELECT 1",
            ~s|UPDATE spans SET "end" = 2|,
            "INSERT INTO t VALUES (1)",
            ""
          ] do
        assert TransactionControl.refuse!(sql, :outside) == :ok, sql
      end

      assert TransactionControl.refuse!(nil, :outside) == :ok
    end
  end

  describe "refuse!/2 inside a transaction" do
    test "lets savepoints through" do
      for sql <- [
            "SAVEPOINT sp",
            "/* note */ SAVEPOINT sp",
            "RELEASE sp",
            "release savepoint sp",
            "ROLLBACK TO sp",
            "rollback transaction to sp",
            "ROLLBACK\n  TO sp"
          ] do
        assert TransactionControl.refuse!(sql, :inside) == :ok, sql
      end
    end

    test "raises for anything that would end the transaction or open another" do
      for sql <- [
            "COMMIT",
            "Commit",
            "/* x */ COMMIT",
            "END/**/",
            "ROLLBACK",
            "ROLLBACK--x",
            "ROLLBACK -- to",
            "BEGIN DEFERRED",
            "BEGIN/**/IMMEDIATE",
            "START TRANSACTION",
            "ABORT"
          ] do
        assert_raise ArgumentError, fn -> TransactionControl.refuse!(sql, :inside) end
      end
    end
  end
end
