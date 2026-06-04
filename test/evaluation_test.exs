defmodule OptimalEngine.EvaluationTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{Evaluation, MemoryCore, Store}

  test "records benchmark runs and per-case judge scores" do
    workspace_id = "evaluation-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Store.raw_execute("DELETE FROM evaluation_runs WHERE workspace_id = ?1", [workspace_id])
    end)

    assert {:ok, run} =
             Evaluation.record_run(
               workspace_id: workspace_id,
               benchmark_name: "long_memory_recall",
               dataset_name: "synthetic-company-memory",
               dataset_size: 35,
               question_count: 700,
               answer_model: "answer-model",
               judge_model: "judge-model",
               judge_strategy: "3x_majority",
               retrieval_top_k: 100,
               run_config: %{temperature: 0},
               retrieval_config: %{mode: "context_package"},
               judge_config: %{votes: 3}
             )

    assert {:ok, passed} =
             Evaluation.record_case(run.id,
               case_id: "case-001",
               conversation_id: "conv-001",
               question: "What happened in the launch review?",
               expected_answer: "The launch was approved.",
               actual_answer: "The launch was approved.",
               retrieved_object_links: [%{type: "fact", id: "fact_001"}],
               scores: %{accuracy: 1.0, grounding: 0.9},
               judge_output: %{votes: ["pass", "pass", "pass"]},
               status: "passed"
             )

    assert passed.retrieved_object_links == [%{type: "fact", id: "fact_001"}]

    assert {:ok, _failed} =
             Evaluation.record_case(run.id,
               case_id: "case-002",
               question: "What was the budget?",
               actual_answer: "Unknown.",
               scores: %{accuracy: 0.0, grounding: 0.2},
               status: "failed",
               error_reason: "missing_ground_truth"
             )

    assert {:ok, summary} = Evaluation.summarize(run.id)
    assert summary.case_count == 2
    assert summary.passed_count == 1
    assert summary.failed_count == 1
    assert_in_delta summary.aggregate_scores["accuracy"].average, 0.5, 0.001
    assert_in_delta summary.aggregate_scores["grounding"].average, 0.55, 0.001

    assert {:ok, [[1]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM evaluation_runs WHERE workspace_id = ?1 AND benchmark_name = 'long_memory_recall'",
               [workspace_id]
             )

    assert {:ok, [[2]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM evaluation_cases WHERE workspace_id = ?1 AND evaluation_run_id = ?2",
               [workspace_id, run.id]
             )
  end

  test "runs a benchmark through retrieval, deterministic judging, and persisted cases" do
    workspace_id = "evaluation-runner-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Store.raw_execute("DELETE FROM evaluation_runs WHERE workspace_id = ?1", [workspace_id])
    end)

    source =
      MemoryCore.source_package_from_text("The launch was approved after final review.",
        workspace_id: workspace_id,
        source_type: "meeting_note",
        security_labels: ["internal"],
        partition_ids: ["ops"]
      )

    assert {:ok, claim} =
             MemoryCore.extract_claim(source,
               claim_text: "The launch was approved after final review.",
               subject_anchor: "launch",
               action_class: "approval",
               object_anchor: "final_review",
               aggregate_confidence: 0.95,
               aggregate_precision: 0.9
             )

    assert {:ok, fact} =
             MemoryCore.promote_claim_to_fact(claim,
               fact_text: "The launch was approved.",
               aggregate_confidence: 0.96,
               aggregate_precision: 0.92
             )

    assert {:ok, _memory} =
             MemoryCore.build_memory_object(fact,
               summary: "The launch approval unblocked the release plan."
             )

    assert {:ok, result} =
             Evaluation.run_benchmark(
               [
                 %{
                   case_id: "launch-001",
                   conversation_id: "conv-launch",
                   question: "approved",
                   expected_answer: "launch was approved"
                 }
               ],
               workspace_id: workspace_id,
               benchmark_name: "governed_recall_smoke",
               dataset_name: "local-memory-smoke",
               retrieval_top_k: 5,
               retrieval_opts: [
                 allowed_partitions: ["ops"],
                 allowed_security_labels: ["internal"]
               ]
             )

    assert result.run.status == "completed"
    assert result.summary.case_count == 1
    assert result.summary.passed_count == 1
    assert [recorded_case] = result.cases
    assert recorded_case.status == "passed"
    assert recorded_case.context_package_id
    assert [%{type: "fact"} | _] = recorded_case.retrieved_object_links
    assert_in_delta result.summary.aggregate_scores["accuracy"].average, 1.0, 0.001

    assert {:ok, [[1]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM evaluation_cases WHERE workspace_id = ?1 AND status = 'passed'",
               [workspace_id]
             )
  end
end
