defmodule OptimalEngine.Test.SqlCensusTest do
  @moduledoc """
  The SQL census (test/support/sql_census.ex) lists statement shapes, so its
  allowlist stays stable from run to run.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Test.SqlCensus

  test "statements that differ only in literals, numbers, names or list lengths are one shape" do
    assert SqlCensus.shape("SELECT a FROM t WHERE id IN (?2, ?3, ?4) AND n > 10 LIMIT 50") ==
             SqlCensus.shape("SELECT a\n  FROM t WHERE id IN (?2) AND n > 3 LIMIT 7")

    assert SqlCensus.shape("SELECT * FROM txn_test_23203") ==
             SqlCensus.shape("SELECT * FROM txn_test_9")

    assert SqlCensus.shape(~s|SELECT * FROM "appdata_0a1b" WHERE k = 'x'|) ==
             SqlCensus.shape(~s|SELECT * FROM "appdata_ff00" WHERE k = 'it''s'|)

    assert SqlCensus.shape("SELECT a FROM t WHERE k IN ('a', 'b') AND n IN (1, 2, 3)") ==
             SqlCensus.shape("SELECT a FROM t WHERE k IN ('c') AND n IN (4)")

    refute SqlCensus.shape("SELECT a FROM t") == SqlCensus.shape("SELECT b FROM t")
    assert SqlCensus.shape("SELECT a FROM nodes_v033") =~ "nodes_v033"
  end

  test "a statement run on every table is classified per table and listed once" do
    refute SqlCensus.shape(~s|SELECT COUNT(*) FROM "chunks"|) ==
             SqlCensus.shape(~s|SELECT COUNT(*) FROM "appdata_0a1b"|)

    assert SqlCensus.allowlist_shape(~s|PRAGMA table_info("chunks")|) ==
             SqlCensus.allowlist_shape(~s|PRAGMA table_info("facts")|)
  end

  test "a statement shape not on the allowlist is explained with the line to add" do
    message =
      SqlCensus.explain([
        {["refused", "SELECT a FROM t ORDER BY rowid"],
         {"rowid", "SELECT a FROM t ORDER BY rowid"}},
        {["unordered", "SELECT a FROM t LIMIT N"], {nil, "SELECT a FROM t LIMIT 5"}}
      ])

    assert message =~ "2 statement shapes"
    assert message =~ "\nrefused\tSELECT a FROM t ORDER BY rowid\n"
    assert message =~ "refused: rowid"
    assert message =~ "\nunordered\tSELECT a FROM t LIMIT N\n"
    assert message =~ "e.g. SELECT a FROM t LIMIT 5"

    assert message =~
             "OPTIMAL_TEST_POSTGRES_URL=postgres://... OPTIMAL_SQL_CENSUS=/tmp/sql-census.txt OPTIMAL_SQL_CENSUS_WRITE=1 mix test"

    assert message =~ "@unsupported in lib/optimal_engine/store/dialect.ex"
  end

  test "a LIMIT outside every parenthesis without an ORDER BY there is unordered" do
    assert SqlCensus.unordered?("SELECT id FROM t WHERE x = ?1 LIMIT 1")
    refute SqlCensus.unordered?("SELECT id FROM t ORDER BY id LIMIT 1")
    refute SqlCensus.unordered?("SELECT id FROM t WHERE EXISTS (SELECT 1 FROM u LIMIT 1)")
    assert SqlCensus.unordered?("SELECT id FROM (SELECT id FROM t ORDER BY id) LIMIT 5")
    refute SqlCensus.unordered?("SELECT id FROM t WHERE note = 'LIMIT 1'")
  end

  test "an existence probe is not unordered: every matching row gives the same answer" do
    refute SqlCensus.unordered?(~s|SELECT 1 FROM "chunks" WHERE workspace_id = ?1 LIMIT 1|)

    refute SqlCensus.unordered?(
             "SELECT 1 FROM a WHERE x = ?1 UNION ALL SELECT 1 FROM b WHERE (y = ?2) LIMIT 1"
           )

    assert SqlCensus.unordered?("SELECT 1, id FROM t LIMIT 1")
    assert SqlCensus.unordered?("SELECT 1 FROM a UNION ALL SELECT id FROM b LIMIT 1")
  end
end
