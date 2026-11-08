defmodule OptimalEngine.Test.IndexReads do
  @moduledoc false
  # Whether a statement reads an index, on the Engine's store. SQLite's
  # EXPLAIN QUERY PLAN names the index it uses. PostgreSQL's planner chooses by
  # the table's size, and a test's tables are small enough to scan, so there
  # the plan is taken with sequential scans off: it names the index if one
  # serves the statement. PostgreSQL's index names are SQLite's, cut to 50
  # bytes, with a suffix for their definition.

  import ExUnit.Assertions

  alias OptimalEngine.Store

  @doc "The plan of `sql` on the Engine's store, one line per step."
  def plan(sql, params \\ []) do
    if Store.selected?(OptimalEngine.Store.Postgres) do
      {:ok, rows} =
        Store.transaction(fn txn ->
          {:ok, _} =
            OptimalEngine.Store.Postgres.txn_execute_native(
              txn,
              "SET LOCAL enable_seqscan = off",
              []
            )

          Store.txn_query(txn, "EXPLAIN " <> sql, params)
        end)

      Enum.map_join(rows, "\n", &List.first/1)
    else
      {:ok, rows} = Store.raw_query("EXPLAIN QUERY PLAN " <> sql, params)
      Enum.map_join(rows, "\n", &List.last/1)
    end
  end

  @doc """
  Asserts the plan of `sql` reads `index`. On SQLite the plan must also match
  `sqlite_pattern` (by default, a search using the index). On PostgreSQL,
  with `column`, any index the planner reads `column` through will do: its
  planner picks among the indexes that lead with it by their size, and the
  derived schema has SQLite's.
  """
  def assert_uses_index(sql, params, index, sqlite_pattern \\ nil, column \\ nil) do
    details = plan(sql, params)

    if Store.selected?(OptimalEngine.Store.Postgres) do
      if column do
        assert details =~ ~r/(Index Scan|Index Only Scan|Bitmap Index Scan) (using|on) \S+/, details
        assert details =~ ~r/Index Cond: \(+(\w+\.)?#{column} = /, details
      else
        name = Regex.escape(String.slice(index, 0, 50))

        assert details =~
                 ~r/(Index Scan|Index Only Scan|Bitmap Index Scan) (using|on) #{name}_[0-9a-f]{8}\b/,
               details
      end
    else
      pattern = sqlite_pattern || ~r/USING (COVERING )?INDEX #{Regex.escape(index)}\b/
      assert details =~ pattern, details
    end

    details
  end

  @doc "Asserts a lookup of `table` by `column` reads `index`, and on SQLite does not scan the table."
  def assert_read_by_index(table, column, index) do
    details = assert_uses_index("SELECT 1 FROM #{table} WHERE #{column} = ?1", ["x"], index)

    unless Store.selected?(OptimalEngine.Store.Postgres),
      do: refute(details =~ "SCAN #{table}", details)
  end
end
