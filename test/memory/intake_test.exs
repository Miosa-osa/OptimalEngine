defmodule OptimalEngine.Memory.IntakeTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Memory

  defp ws, do: "test-intake-#{:erlang.unique_integer([:positive])}"

  describe "remember/2 versioned intake" do
    test "skips low-salience filler before writing" do
      assert {:ok, result} = Memory.remember(%{content: "ok", workspace_id: ws()})

      assert result.action == :skip
      assert result.memory == nil
      assert result.gate.should_encode == false
      assert result.dedup == nil
    end

    test "adds a salient memory with intake metadata" do
      workspace_id = ws()

      assert {:ok, result} =
               Memory.remember(%{
                 content: "Decision: Finance lead owns pricing renewal for Q4 at $2000.",
                 workspace_id: workspace_id
               })

      assert result.action == :add
      assert result.gate.should_encode == true
      assert result.memory.content =~ "Finance lead"
      assert result.memory.workspace_id == workspace_id

      assert get_in(result.memory.metadata, ["memory_intake", "gate", "should_encode"]) == true
      assert get_in(result.memory.metadata, ["memory_intake", "dedup", "action"]) == "add"
    end

    test "skips semantic duplicates and returns the existing memory" do
      workspace_id = ws()

      assert {:ok, first} =
               Memory.remember(%{
                 content: "Decision: Finance lead owns pricing renewal for Q4 at $2000.",
                 workspace_id: workspace_id
               })

      assert {:ok, second} =
               Memory.remember(%{
                 content: "Decision: Finance lead owns pricing renewal for Q4 at $2000.",
                 workspace_id: workspace_id
               })

      assert second.action == :skip
      assert second.memory.id == first.memory.id
      assert second.memory.was_existing == true
      assert second.dedup.action == :skip
    end

    test "updates a similar memory when the new memory supersedes it" do
      workspace_id = ws()

      assert {:ok, first} =
               Memory.remember(%{
                 content: "Decision: Finance lead owns pricing renewal for Q4.",
                 workspace_id: workspace_id
               })

      assert {:ok, second} =
               Memory.remember(%{
                 content:
                   "Correction: Operations lead now owns pricing renewal for Q4 instead of Finance lead.",
                 workspace_id: workspace_id
               })

      assert second.action == :update
      assert second.memory.version == 2
      assert second.memory.parent_memory_id == first.memory.id
      assert second.memory.content =~ "Operations lead"
      assert get_in(second.memory.metadata, ["memory_intake", "dedup", "action"]) == "update"
    end
  end
end
