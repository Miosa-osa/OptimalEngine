defmodule OptimalEngine.Optimality do
  @moduledoc """
  Evidence-based Optimal Engine classification.

  `optimal` is earned by explicit gates and expires as evidence changes. An
  architecture assessment may pass while live operating data remains merely
  qualified or degraded. The evaluator never converts missing evidence into a
  passing result.
  """

  alias OptimalEngine.MemoryCore.{ID, JSON}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Migrations

  @version "optimality-v1"
  @default_thresholds %{
    evaluation_pass_rate: 0.9,
    context_health: 90,
    full_test_failures: 0,
    storage_failures: 0
  }

  @doc "Classifies architecture or whole-system readiness from recorded evidence."
  @spec classify(keyword()) :: {:ok, map()} | {:error, term()}
  def classify(opts \\ []) do
    tenant = Keyword.get(opts, :tenant_id, "default")
    workspace = Keyword.get(opts, :workspace_id, "default")
    assessment_scope = Keyword.get(opts, :assessment_scope, "system") |> to_string()
    thresholds = Map.merge(@default_thresholds, Keyword.get(opts, :thresholds, %{}))
    verification = Keyword.get(opts, :verification, %{})

    with {:ok, storage} <- storage_gate(),
         {:ok, migrations} <- migration_gate(),
         {:ok, evaluation} <- evaluation_gate(workspace, thresholds) do
      gates = %{
        storage: storage,
        migrations: migrations,
        evaluation: evaluation,
        authorization_tests: boolean_gate(verification, :authorization_tests),
        full_tests: test_gate(verification, thresholds),
        documentation: boolean_gate(verification, :documentation_current),
        context_health: context_gate(verification, thresholds, assessment_scope)
      }

      score = gates |> Map.values() |> Enum.map(& &1.score) |> average()
      required = required_gates(gates, assessment_scope)
      classification = classify_gates(required, score)
      id = ID.random_id("optimality")

      result = %{
        id: id,
        tenant_id: tenant,
        workspace_id: workspace,
        assessment_scope: assessment_scope,
        classification: classification,
        score: score,
        gates: gates,
        thresholds: thresholds,
        evaluator_version: @version,
        evidence: Keyword.get(opts, :evidence, [])
      }

      case persist(result) do
        :ok -> {:ok, result}
        error -> error
      end
    end
  end

  defp storage_gate do
    with {:ok, [[integrity]]} <- Store.raw_query("PRAGMA integrity_check"),
         {:ok, foreign_keys} <- Store.raw_query("PRAGMA foreign_key_check") do
      passed = integrity == "ok" and foreign_keys == []

      {:ok,
       gate(
         passed,
         if(passed, do: "SQLite integrity and foreign keys pass", else: "storage integrity failed")
       )}
    end
  end

  defp migration_gate do
    expected = length(Migrations.all())

    case Store.raw_query("SELECT COUNT(*) FROM schema_migrations") do
      {:ok, [[applied]]} ->
        {:ok,
         gate(applied == expected, "#{applied} of #{expected} migrations applied", %{
           applied: applied,
           expected: expected
         })}

      error ->
        error
    end
  end

  defp evaluation_gate(workspace, thresholds) do
    sql = """
    SELECT r.id,
           COALESCE(SUM(CASE WHEN c.status = 'passed' THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(c.id), 0), 0),
           COUNT(c.id)
    FROM evaluation_runs r
    LEFT JOIN evaluation_cases c ON c.evaluation_run_id = r.id
    WHERE r.workspace_id = ?1 AND r.benchmark_name = 'governed_reconstruction'
      AND r.status = 'completed'
    GROUP BY r.id ORDER BY r.completed_at DESC LIMIT 1
    """

    case Store.raw_query(sql, [workspace]) do
      {:ok, [[run_id, rate, cases]]} ->
        passed = cases > 0 and rate >= thresholds.evaluation_pass_rate

        {:ok,
         gate(passed, "latest governed reconstruction evaluation pass rate #{rate}", %{
           run_id: run_id,
           pass_rate: rate,
           cases: cases
         })}

      {:ok, []} ->
        {:ok, gate(false, "no completed governed reconstruction evaluation", %{cases: 0})}

      error ->
        error
    end
  end

  defp boolean_gate(verification, key) do
    passed = Map.get(verification, key) == true
    gate(passed, if(passed, do: "verified", else: "required verification evidence missing"))
  end

  defp test_gate(verification, thresholds) do
    failures = Map.get(verification, :full_test_failures)
    passed = is_integer(failures) and failures <= thresholds.full_test_failures

    gate(
      passed,
      if(passed,
        do: "full suite has #{failures} failures",
        else: "full-suite result missing or failing"
      ),
      %{failures: failures}
    )
  end

  defp context_gate(_verification, _thresholds, "architecture"),
    do: gate(true, "not required for architecture assessment")

  defp context_gate(verification, thresholds, _scope) do
    score = Map.get(verification, :context_health_score)
    passed = is_number(score) and score >= thresholds.context_health

    gate(
      passed,
      if(is_number(score),
        do: "context health score #{score}",
        else: "context health evidence missing"
      ),
      %{context_health_score: score}
    )
  end

  defp required_gates(gates, "architecture"), do: Map.drop(gates, [:context_health]) |> Map.values()
  defp required_gates(gates, _), do: Map.values(gates)

  defp classify_gates(gates, score) do
    cond do
      Enum.all?(gates, & &1.passed) -> "optimal"
      score >= 0.8 -> "qualified"
      score >= 0.5 -> "degraded"
      true -> "unclassified"
    end
  end

  defp gate(passed, detail, evidence \\ %{}),
    do: %{passed: passed, score: if(passed, do: 1.0, else: 0.0), detail: detail, evidence: evidence}

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp persist(result) do
    Store.raw_execute(
      "INSERT INTO optimality_assessments (id, tenant_id, workspace_id, classification, score, gates, evidence, thresholds, evaluator_version) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
      [
        result.id,
        result.tenant_id,
        result.workspace_id,
        result.classification,
        result.score,
        JSON.map(Map.put(result.gates, :assessment_scope, result.assessment_scope)),
        JSON.list(result.evidence),
        JSON.map(result.thresholds),
        result.evaluator_version
      ]
    )
  end
end
