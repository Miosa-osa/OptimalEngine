defmodule OptimalEngine.EvaluationTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{Evaluation, Store}

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
end
