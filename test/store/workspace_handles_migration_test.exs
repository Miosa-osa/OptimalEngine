defmodule OptimalEngine.Store.WorkspaceHandlesMigrationTest do
  @moduledoc """
  Migration 71 moves the slugs a workspace holds into `workspace_handles`:
  its current slug and every slug it held before a rename, which earlier
  releases kept in `metadata.previous_slugs`.
  """

  use ExUnit.Case, async: false

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
end
