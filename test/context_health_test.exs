defmodule OptimalEngine.ContextHealthTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{ContextHealth, Store}

  test "workspace integrity is scoped to the requested workspace" do
    suffix = System.unique_integer([:positive])
    workspace = "health-registered-#{suffix}"
    unrelated = "health-unrelated-orphan-#{suffix}"
    memory_id = "mem_health_orphan_#{suffix}"

    assert :ok =
             Store.raw_execute(
               "INSERT INTO workspaces (id, tenant_id, slug, name) VALUES (?1, 'default', ?1, ?1)",
               [workspace]
             )

    assert :ok =
             Store.raw_execute(
               "INSERT INTO memories (id, tenant_id, workspace_id, content, root_memory_id) VALUES (?1, 'default', ?2, 'unrelated orphan evidence', ?1)",
               [memory_id, unrelated]
             )

    integrity =
      ContextHealth.run(workspace_id: workspace).checks
      |> Enum.find(&(&1.name == "workspace_integrity"))

    assert integrity.ok
    assert integrity.detail.orphan_workspace_scopes == 0

    Store.raw_execute("DELETE FROM memories WHERE id = ?1", [memory_id])
    Store.raw_execute("DELETE FROM workspaces WHERE id = ?1", [workspace])
  end
end
