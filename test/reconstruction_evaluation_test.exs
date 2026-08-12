defmodule OptimalEngine.ReconstructionEvaluationTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{Optimality, ReconstructionEvaluation, Store}

  setup do
    suffix = System.unique_integer([:positive])
    workspace = "reconstruction-eval-#{suffix}"
    fact_id = "fact_eval_#{suffix}"
    source_id = "sp_eval_#{suffix}"

    assert :ok =
             Store.raw_execute(
               "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text, trust_label) VALUES (?1, 'default', ?2, ?3, ?4, 'verified')",
               [
                 source_id,
                 workspace,
                 "hash-#{suffix}",
                 "Commas commitment changed after customer feedback"
               ]
             )

    assert :ok =
             Store.raw_execute(
               "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, lifecycle_state, verification_status, aggregate_confidence, aggregate_precision, supporting_evidence_links) VALUES (?1, 'default', ?2, ?3, 'accepted', 'verified', 0.95, 0.95, ?4)",
               [
                 fact_id,
                 workspace,
                 "Commas commitment changed after customer feedback",
                 Jason.encode!([%{type: "source_package", id: source_id}])
               ]
             )

    on_exit(fn ->
      Store.raw_execute("DELETE FROM optimality_assessments WHERE workspace_id = ?1", [workspace])
      Store.raw_execute("DELETE FROM evaluation_runs WHERE workspace_id = ?1", [workspace])

      Store.raw_execute("DELETE FROM memory_reconstruction_runs WHERE workspace_id = ?1", [
        workspace
      ])

      Store.raw_execute("DELETE FROM memory_associations WHERE workspace_id = ?1", [workspace])
      Store.raw_execute("DELETE FROM facts WHERE workspace_id = ?1", [workspace])
      Store.raw_execute("DELETE FROM source_packages WHERE workspace_id = ?1", [workspace])
    end)

    %{workspace: workspace, fact_id: fact_id}
  end

  test "evaluation judges grounding, canonical recall, safety, and token use", %{
    workspace: workspace,
    fact_id: fact_id
  } do
    cases = [
      %{
        case_id: "commas-evolution",
        question: "What changed in the Commas commitment after customer feedback?",
        required_terms: ["Commas", "customer feedback"],
        forbidden_terms: ["ClinicIQ secret"],
        expected_object_links: [%{type: "fact", id: fact_id}],
        max_tokens: 2_000
      }
    ]

    assert {:ok, result} =
             ReconstructionEvaluation.run(cases,
               tenant_id: "default",
               workspace_id: workspace,
               actor_id: "user:evaluator"
             )

    assert result.summary.passed_count == 1
    assert hd(result.cases).scores.policy_safety == 1.0
    assert hd(result.cases).scores.canonical_recall == 1.0
  end

  test "optimal classification requires every architecture gate", %{
    workspace: workspace,
    fact_id: fact_id
  } do
    assert {:ok, _} =
             ReconstructionEvaluation.run(
               [
                 %{
                   case_id: "gold",
                   question: "Commas customer feedback",
                   required_terms: ["Commas"],
                   expected_object_links: [%{type: "fact", id: fact_id}]
                 }
               ],
               tenant_id: "default",
               workspace_id: workspace,
               actor_id: "user:evaluator"
             )

    assert {:ok, assessment} =
             Optimality.classify(
               tenant_id: "default",
               workspace_id: workspace,
               assessment_scope: "architecture",
               verification: %{
                 authorization_tests: true,
                 full_test_failures: 0,
                 documentation_current: true
               },
               evidence: ["focused tests", "full suite"]
             )

    assert assessment.classification == "optimal"
    assert assessment.score == 1.0

    assert {:ok, missing_evidence} =
             Optimality.classify(
               tenant_id: "default",
               workspace_id: workspace,
               assessment_scope: "architecture",
               verification: %{}
             )

    refute missing_evidence.classification == "optimal"
  end
end
