defmodule OptimalEngine.Store.WorkspaceHandlesMigrationTest do
  @moduledoc """
  Migration 71 moves the slugs a workspace holds into `workspace_handles`:
  its current slug and every slug it held before a rename, which earlier
  releases kept in `metadata.previous_slugs`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Migrations
  alias OptimalEngine.Workspace

  test "backfills current and previously held slugs, once" do
    n = System.unique_integer([:positive])
    id = "default:handles-old-#{n}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, 'default', ?2, 'Handles', 'active', ?3)",
        [id, "handles-new-#{n}", Jason.encode!(%{"previous_slugs" => ["handles-old-#{n}"]})]
      )

    {71, _description, statements} = Enum.find(Migrations.all(), &(elem(&1, 0) == 71))

    for _run <- 1..2, {_label, sql} <- statements do
      {:ok, _} = Store.raw_query(sql, [])
    end

    assert Enum.sort(Workspace.handles(id)) == ["handles-new-#{n}", "handles-old-#{n}"]
    assert {:ok, %{id: ^id}} = Workspace.get_by_handle("handles-old-#{n}", "default")
  end

  test "a workspace's handles go with it" do
    n = System.unique_integer([:positive])
    {:ok, workspace} = Workspace.create(%{slug: "handles-gone-#{n}", name: "Gone"})
    assert Workspace.handles(workspace.id) == ["handles-gone-#{n}"]

    {:ok, _} = Store.raw_query("DELETE FROM workspaces WHERE id = ?1", [workspace.id])
    assert Workspace.handles(workspace.id) == []
  end

  describe "when two workspaces held the same slug" do
    # A scratch database holding only what the backfill reads, so the outcome
    # does not depend on what other tests left in the shared store.
    setup do
      {:ok, db} = Exqlite.Sqlite3.open(":memory:")

      :ok =
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE workspaces (
          id TEXT PRIMARY KEY,
          tenant_id TEXT NOT NULL,
          slug TEXT NOT NULL,
          name TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'active',
          created_at TEXT,
          metadata TEXT NOT NULL DEFAULT '{}',
          UNIQUE (tenant_id, slug)
        )
        """)

      on_exit(fn -> Exqlite.Sqlite3.close(db) end)
      %{db: db}
    end

    defp workspace(db, id, slug, created_at, previous) do
      :ok =
        Exqlite.Sqlite3.execute(
          db,
          "INSERT INTO workspaces (id, tenant_id, slug, created_at, metadata) VALUES ('#{id}', 't', '#{slug}', '#{created_at}', '#{Jason.encode!(%{"previous_slugs" => previous})}')"
        )
    end

    defp backfill(db) do
      {71, _description, statements} = Enum.find(Migrations.all(), &(elem(&1, 0) == 71))
      for {_label, sql} <- statements, do: :ok = Exqlite.Sqlite3.execute(db, sql)
    end

    defp handles(db) do
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          db,
          "SELECT slug, workspace_id FROM workspace_handles WHERE tenant_id = 't' ORDER BY slug"
        )

      rows = collect(db, stmt, [])
      Exqlite.Sqlite3.release(db, stmt)
      rows
    end

    defp collect(db, stmt, acc) do
      case Exqlite.Sqlite3.step(db, stmt) do
        {:row, [slug, id]} -> collect(db, stmt, [{slug, id} | acc])
        :done -> Enum.reverse(acc)
      end
    end

    test "the older holder keeps the slug, whatever order the rows are stored in", %{db: db} do
      # Stored newest first, so a backfill that follows storage order would
      # give "shared" to t:b.
      workspace(db, "t:b", "beta", "2026-02-01T00:00:00Z", ["shared"])
      workspace(db, "t:a", "alpha", "2026-01-01T00:00:00Z", ["shared", "gone-a"])

      backfill(db)

      assert handles(db) == [
               {"alpha", "t:a"},
               {"beta", "t:b"},
               {"gone-a", "t:a"},
               {"shared", "t:a"}
             ]
    end

    test "a tie in creation time goes to the lower id", %{db: db} do
      workspace(db, "t:e", "echo", "2026-03-01T00:00:00Z", ["tie"])
      workspace(db, "t:d", "delta", "2026-03-01T00:00:00Z", ["tie"])

      backfill(db)

      assert {"tie", "t:d"} in handles(db)
    end

    test "a current slug beats an older workspace's earlier claim to it", %{db: db} do
      # t:c is the oldest and once held "alpha"; t:a holds it now.
      workspace(db, "t:c", "gamma", "2025-12-01T00:00:00Z", ["alpha"])
      workspace(db, "t:a", "alpha", "2026-01-01T00:00:00Z", [])

      backfill(db)

      assert {"alpha", "t:a"} in handles(db)
      refute {"alpha", "t:c"} in handles(db)
    end

    test "every slug it could not give is logged with who holds it", %{db: db} do
      workspace(db, "t:c", "gamma", "2025-12-01T00:00:00Z", ["alpha", "kept"])
      workspace(db, "t:a", "alpha", "2026-01-01T00:00:00Z", [])
      workspace(db, "t:b", "beta", "2026-02-01T00:00:00Z", ["shared"])
      workspace(db, "t:d", "delta", "2026-01-15T00:00:00Z", ["shared"])

      backfill(db)

      log = capture_log(fn -> assert length(Migrations.report_skipped_handles(db)) == 2 end)

      assert log =~ "t:c"
      assert log =~ "\"alpha\""
      assert log =~ "t:a"
      assert log =~ "t:b"
      assert log =~ "\"shared\""
      assert log =~ "t:d"
      refute log =~ "kept"
    end

    test "nothing is logged when no slug was skipped", %{db: db} do
      workspace(db, "t:a", "alpha", "2026-01-01T00:00:00Z", ["old-a"])
      backfill(db)

      assert capture_log(fn -> assert Migrations.report_skipped_handles(db) == [] end) == ""
    end
  end
end
