defmodule OptimalEngine.MemoryCore.ClaimReviewTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{Memory, MemoryCore, Store}

  defp ws, do: "claim-review-#{System.unique_integer([:positive])}"

  test "pending claims from user-facing memory can be promoted to fact and memory object" do
    workspace_id = ws()
    content = "Claim review promotion test #{System.unique_integer([:positive])}"

    assert {:ok, _mem} =
             Memory.create(%{
               content: content,
               workspace_id: workspace_id,
               actor_id: "user:reviewer"
             })

    assert {:ok, [claim]} = MemoryCore.pending_claims(workspace_id: workspace_id)
    assert claim.claim_text == content
    assert claim.review_status == "unreviewed"

    assert {:ok, result} =
             MemoryCore.promote_claim(claim.id,
               workspace_id: workspace_id,
               actor_id: "user:reviewer",
               fact_text: "Accepted: #{content}",
               summary: "Remembered: #{content}",
               memory_type: "reviewed_note"
             )

    assert result.claim.review_status == "accepted"
    assert result.claim.lifecycle_state == "accepted"
    assert result.fact.fact_text == "Accepted: #{content}"
    assert result.memory_object.summary == "Remembered: #{content}"

    assert {:ok, [[1]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM facts WHERE workspace_id = ?1 AND id = ?2",
               [workspace_id, result.fact.id]
             )

    assert {:ok, [[1]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM memory_objects WHERE workspace_id = ?1 AND id = ?2",
               [workspace_id, result.memory_object.id]
             )
  end

  test "rejected claims cannot be promoted" do
    workspace_id = ws()
    content = "Claim review rejection test #{System.unique_integer([:positive])}"

    assert {:ok, _mem} =
             Memory.create(%{
               content: content,
               workspace_id: workspace_id
             })

    assert {:ok, [claim]} = MemoryCore.pending_claims(workspace_id: workspace_id)

    assert {:ok, rejected} =
             MemoryCore.reject_claim(claim.id,
               workspace_id: workspace_id,
               actor_id: "user:reviewer"
             )

    assert rejected.review_status == "rejected"
    assert rejected.lifecycle_state == "rejected"

    assert {:error, :claim_rejected} =
             MemoryCore.promote_claim(claim.id,
               workspace_id: workspace_id,
               actor_id: "user:reviewer"
             )

    assert {:ok, [[0]]} =
             Store.raw_query("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1", [workspace_id])
  end
end
