defmodule OptimalEngine.Store.PlannerStatisticsTest do
  @moduledoc """
  A store with stale planner statistics still answers a search with one pass
  over the full-text hits. A store ten times larger than when its statistics
  were taken, with none for the workspace indexes migrations had added since,
  made SQLite take a lookup by workspace for about ten rows and put `contexts`
  outside the join. It reran the full-text match once per context of the
  workspace: minutes per search, with the Store answering nothing else
  meanwhile. The search now fixes the join order, and opening a
  store refreshes statistics that have gone stale.
  """

  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias OptimalEngine.Retrieval.Search
  alias OptimalEngine.Store.SQLite

  # Statistics for contexts taken at 3,883 rows, with none for
  # idx_contexts_ws_path, idx_contexts_ws_uri or idx_contexts_workspace_id.
  @stale_contexts_statistics [
    {"sqlite_autoindex_contexts_1", "3883 1"},
    {"idx_contexts_node", "3883 139"},
    {"idx_contexts_type", "3883 1295"},
    {"idx_contexts_genre", "3883 81"},
    {"idx_contexts_modified", "3883 2"},
    {"idx_contexts_tenant_created_by", "3883 486 229"},
    {"idx_contexts_architecture", "3883 486 486"},
    {"idx_contexts_ws_node", "3883 185 63"},
    {"idx_contexts_tenant_node", "3883 486 118"},
    {"idx_contexts_tenant_type", "3883 486 389"}
  ]

  setup do
    path = Path.join(System.tmp_dir!(), "planner-#{System.unique_integer([:positive])}.db")
    {:ok, db} = SQLite.open_and_migrate(path)

    on_exit(fn ->
      Sqlite3.close(db)
      for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
    end)

    %{db: db, path: path}
  end

  test "the search reads the full-text hits first under stale statistics", %{db: db} do
    # ANALYZE creates sqlite_stat1; the stale rows replace what it found, and
    # ANALYZE sqlite_schema makes the planner read them.
    execute!(db, "ANALYZE")
    execute!(db, "DELETE FROM sqlite_stat1 WHERE tbl = 'contexts'")

    for {index, stat} <- @stale_contexts_statistics do
      execute!(
        db,
        "INSERT INTO sqlite_stat1 (tbl, idx, stat) VALUES ('contexts', '#{index}', '#{stat}')"
      )
    end

    execute!(db, "ANALYZE sqlite_schema")

    {sql, params} = Search.build_fts_sql(~s("supplier"), nil, nil, nil, "default:ops", 600, 0)

    assert [outer, inner | _] = plan(db, sql, params)
    assert outer =~ "SCAN contexts_fts"
    assert inner =~ "SEARCH c USING"
  end

  test "opening a store analyzes an index added since its statistics were taken", ctx do
    execute!(ctx.db, "CREATE TABLE planner_probe (id INTEGER PRIMARY KEY, workspace_id TEXT)")

    execute!(
      ctx.db,
      "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200) " <>
        "INSERT INTO planner_probe SELECT i, 'w' || (i % 4) FROM n"
    )

    execute!(ctx.db, "ANALYZE planner_probe")
    execute!(ctx.db, "CREATE INDEX planner_probe_ws ON planner_probe (workspace_id)")
    assert statistics(ctx.db, "planner_probe_ws") == []

    {:ok, reopened} = SQLite.open_and_migrate(ctx.path)
    on_exit(fn -> Sqlite3.close(reopened) end)

    assert statistics(reopened, "planner_probe_ws") == [["200 50"]]
  end

  defp plan(db, sql, params) do
    db
    |> rows("EXPLAIN QUERY PLAN " <> sql, params)
    |> Enum.map(&List.last/1)
  end

  defp statistics(db, index),
    do: rows(db, "SELECT stat FROM sqlite_stat1 WHERE idx = ?1", [index])

  defp rows(db, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, params)
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    rows
  end

  defp execute!(db, sql), do: :ok = Sqlite3.execute(db, sql)
end
