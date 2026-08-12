defmodule OptimalEngine.OperatingProjectionTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{OperatingProjection, Store}

  test "projects current commitments with evidence and lifecycle status" do
    suffix = System.unique_integer([:positive])
    workspace = "projection-#{suffix}"
    id = "mem_projection_#{suffix}"

    assert {:ok, _} =
             Store.raw_query(
               "INSERT INTO memories (id, workspace_id, content, root_memory_id, metadata) VALUES (?1, ?2, ?3, ?1, ?4)",
               [id, workspace, "Task: Owner: Roberto. Follow up with Commas", ~s({"kind":"task"})]
             )

    on_exit(fn -> Store.raw_query("DELETE FROM memories WHERE id = ?1", [id]) end)

    assert {:ok, projection} = OperatingProjection.workspace(workspace)
    assert [%{id: ^id, status: "active", evidence_uri: evidence}] = projection.commitments
    assert evidence == "optimal://memory/#{workspace}/#{id}"
    assert projection.inventory.memories == 1
    assert projection.inventory.recent_memories_sampled == 1
    assert {:ok, draft} = OperatingProjection.daily_draft(workspace)
    assert draft =~ "Follow up with Commas"
  end
end
