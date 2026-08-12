defmodule OptimalEngine.MemoryReconstructorTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.MemoryReconstructor
  alias OptimalEngine.Store

  setup do
    suffix = System.unique_integer([:positive])
    workspace = "reconstruction-#{suffix}"

    memories = [
      {"mem_reconstruct_comma_#{suffix}",
       "Commas commitment needs customer feedback before the next working session"},
      {"mem_reconstruct_feedback_#{suffix}",
       "Customer feedback changes the Commas onboarding decision and commercial plan"},
      {"mem_reconstruct_session_#{suffix}",
       "Next working session decides the updated Commas commitment owner and timing"}
    ]

    Enum.each(memories, fn {id, content} ->
      assert {:ok, _} =
               Store.raw_query(
                 "INSERT INTO memories (id, workspace_id, content, root_memory_id) VALUES (?1, ?2, ?3, ?1)",
                 [id, workspace, content]
               )
    end)

    on_exit(fn ->
      Store.raw_execute("DELETE FROM memory_consolidation_proposals WHERE workspace_id = ?1", [
        workspace
      ])

      Store.raw_execute("DELETE FROM memory_path_feedback WHERE workspace_id = ?1", [workspace])

      Store.raw_execute("DELETE FROM memory_reconstruction_outcomes WHERE workspace_id = ?1", [
        workspace
      ])

      Store.raw_execute("DELETE FROM memory_reconstruction_runs WHERE workspace_id = ?1", [
        workspace
      ])

      Enum.each(memories, fn {id, _} ->
        Store.raw_execute("DELETE FROM memories WHERE id = ?1", [id])
      end)
    end)

    %{workspace: workspace, memories: memories}
  end

  test "reconstructs cited context and persists its bounded trace", %{workspace: workspace} do
    assert {:ok, result} =
             MemoryReconstructor.reconstruct("current Commas commitment and customer feedback",
               workspace_id: workspace,
               step_budget: 3,
               token_budget: 2_000
             )

    assert result.workspace_id == workspace
    assert result.evidence != []
    assert result.citations != []
    assert result.context =~ "Commas"
    assert length(result.steps) <= 3

    assert result.stop_reason in [
             "sufficient_evidence",
             "frontier_exhausted",
             "step_budget",
             "token_budget"
           ]

    assert Enum.all?(result.evidence, &(&1.workspace_id == workspace))
    assert Enum.all?(result.citations, &(&1.provenance == "canonical_search_projection"))

    assert {:ok, [["completed", steps]]} =
             Store.raw_query(
               "SELECT r.status, COUNT(s.id) FROM memory_reconstruction_runs r JOIN memory_reconstruction_steps s ON s.run_id = r.id WHERE r.id = ?1 GROUP BY r.id",
               [result.run_id]
             )

    assert steps == length(result.steps)
  end

  test "feedback changes path priors without creating facts", %{workspace: workspace} do
    assert {:ok, result} =
             MemoryReconstructor.reconstruct("Commas customer feedback",
               workspace_id: workspace,
               step_budget: 2
             )

    assert {:ok, [[before_facts]]} =
             Store.raw_query("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1", [workspace])

    assert {:ok, feedback} = MemoryReconstructor.feedback(result.run_id, "success")
    assert feedback.evidence_count > 0

    assert {:ok, [[after_facts]]} =
             Store.raw_query("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1", [workspace])

    assert before_facts == after_facts

    assert {:ok, [[observations]]} =
             Store.raw_query(
               "SELECT SUM(observations) FROM memory_path_feedback WHERE workspace_id = ?1",
               [workspace]
             )

    assert observations == feedback.evidence_count
  end

  test "consolidation emits reviewable proposals and quality metrics", %{workspace: workspace} do
    for _ <- 1..2 do
      assert {:ok, result} =
               MemoryReconstructor.reconstruct("Commas customer feedback working session",
                 workspace_id: workspace,
                 step_budget: 2
               )

      assert {:ok, _} = MemoryReconstructor.feedback(result.run_id, "success")
    end

    assert {:ok, proposals} =
             MemoryReconstructor.consolidate(workspace_id: workspace, minimum_observations: 2)

    assert proposals != []
    assert Enum.all?(proposals, &(&1.status == "proposed"))

    assert {:ok, quality} = MemoryReconstructor.quality(workspace_id: workspace)
    assert quality.runs == 2
    assert quality.feedback_count == 2
    assert quality.average_citations > 0
    assert quality.outcome_score == 1.0
  end

  test "workspace scope prevents evidence leakage", %{workspace: workspace} do
    other = workspace <> "-other"
    id = "mem_other_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Store.raw_query(
               "INSERT INTO memories (id, workspace_id, content, root_memory_id) VALUES (?1, ?2, ?3, ?1)",
               [id, other, "Commas secret unrelated workspace evidence"]
             )

    on_exit(fn -> Store.raw_execute("DELETE FROM memories WHERE id = ?1", [id]) end)

    assert {:ok, result} =
             MemoryReconstructor.reconstruct("Commas customer feedback", workspace_id: workspace)

    refute Enum.any?(result.evidence, &(&1.id == id))
  end
end
