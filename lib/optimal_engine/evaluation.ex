defmodule OptimalEngine.Evaluation do
  @moduledoc """
  Durable benchmark and evaluation records.

  This module stores benchmark runs and per-case results as governed engine data.
  It does not run judges itself yet; it records the configuration, outputs, scores,
  and context package links produced by an evaluation pipeline.
  """

  alias OptimalEngine.MemoryCore.{ID, JSON}
  alias OptimalEngine.Store

  @type run :: map()
  @type evaluation_case :: map()

  @spec record_run(keyword() | map()) :: {:ok, run()} | {:error, term()}
  def record_run(attrs) when is_list(attrs), do: attrs |> Map.new() |> record_run()

  def record_run(attrs) when is_map(attrs) do
    now = timestamp()
    tenant_id = string(Map.get(attrs, :tenant_id) || Map.get(attrs, "tenant_id") || "default")

    workspace_id =
      string(Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id") || "default")

    benchmark_name = string(Map.get(attrs, :benchmark_name) || Map.get(attrs, "benchmark_name"))

    run = %{
      id:
        string(
          Map.get(attrs, :id) || Map.get(attrs, "id") ||
            ID.content_id("evalrun", [tenant_id, ":", workspace_id, ":", benchmark_name, ":", now])
        ),
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      benchmark_name: benchmark_name,
      dataset_name: string_or_nil(Map.get(attrs, :dataset_name) || Map.get(attrs, "dataset_name")),
      dataset_version:
        string_or_nil(Map.get(attrs, :dataset_version) || Map.get(attrs, "dataset_version")),
      dataset_size: int_or_nil(Map.get(attrs, :dataset_size) || Map.get(attrs, "dataset_size")),
      question_count:
        int_or_nil(Map.get(attrs, :question_count) || Map.get(attrs, "question_count")),
      answer_model: string_or_nil(Map.get(attrs, :answer_model) || Map.get(attrs, "answer_model")),
      judge_model: string_or_nil(Map.get(attrs, :judge_model) || Map.get(attrs, "judge_model")),
      judge_strategy:
        string_or_nil(Map.get(attrs, :judge_strategy) || Map.get(attrs, "judge_strategy")),
      retrieval_top_k:
        int_or_nil(Map.get(attrs, :retrieval_top_k) || Map.get(attrs, "retrieval_top_k")),
      run_config: Map.get(attrs, :run_config) || Map.get(attrs, "run_config") || %{},
      retrieval_config:
        Map.get(attrs, :retrieval_config) || Map.get(attrs, "retrieval_config") || %{},
      judge_config: Map.get(attrs, :judge_config) || Map.get(attrs, "judge_config") || %{},
      aggregate_scores:
        Map.get(attrs, :aggregate_scores) || Map.get(attrs, "aggregate_scores") || %{},
      status: string(Map.get(attrs, :status) || Map.get(attrs, "status") || "recorded"),
      started_at: string_or_nil(Map.get(attrs, :started_at) || Map.get(attrs, "started_at")),
      completed_at: string_or_nil(Map.get(attrs, :completed_at) || Map.get(attrs, "completed_at")),
      created_by: string_or_nil(Map.get(attrs, :created_by) || Map.get(attrs, "created_by")),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    }

    sql = """
    INSERT INTO evaluation_runs (
      id, tenant_id, workspace_id, benchmark_name, dataset_name, dataset_version,
      dataset_size, question_count, answer_model, judge_model, judge_strategy,
      retrieval_top_k, run_config, retrieval_config, judge_config, aggregate_scores,
      status, started_at, completed_at, created_by, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10, ?11,
      ?12, ?13, ?14, ?15, ?16,
      ?17, ?18, ?19, ?20, ?21
    )
    """

    params = [
      run.id,
      run.tenant_id,
      run.workspace_id,
      run.benchmark_name,
      run.dataset_name,
      run.dataset_version,
      run.dataset_size,
      run.question_count,
      run.answer_model,
      run.judge_model,
      run.judge_strategy,
      run.retrieval_top_k,
      JSON.map(run.run_config),
      JSON.map(run.retrieval_config),
      JSON.map(run.judge_config),
      JSON.map(run.aggregate_scores),
      run.status,
      run.started_at,
      run.completed_at,
      run.created_by,
      JSON.map(run.metadata)
    ]

    with :ok <- Store.raw_execute(sql, params) do
      {:ok, run}
    end
  end

  @spec record_case(String.t(), keyword() | map()) :: {:ok, evaluation_case()} | {:error, term()}
  def record_case(run_id, attrs) when is_binary(run_id) and is_list(attrs),
    do: record_case(run_id, Map.new(attrs))

  def record_case(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    with {:ok, run} <- get_run(run_id) do
      now = timestamp()
      case_id = string(Map.get(attrs, :case_id) || Map.get(attrs, "case_id"))

      evaluation_case = %{
        id:
          string(
            Map.get(attrs, :id) || Map.get(attrs, "id") ||
              ID.content_id("evalcase", [run_id, ":", case_id, ":", now])
          ),
        tenant_id: run.tenant_id,
        workspace_id: run.workspace_id,
        evaluation_run_id: run_id,
        case_id: case_id,
        conversation_id:
          string_or_nil(Map.get(attrs, :conversation_id) || Map.get(attrs, "conversation_id")),
        question: string(Map.get(attrs, :question) || Map.get(attrs, "question")),
        expected_answer:
          string_or_nil(Map.get(attrs, :expected_answer) || Map.get(attrs, "expected_answer")),
        actual_answer:
          string_or_nil(Map.get(attrs, :actual_answer) || Map.get(attrs, "actual_answer")),
        context_package_id:
          string_or_nil(Map.get(attrs, :context_package_id) || Map.get(attrs, "context_package_id")),
        retrieved_object_links:
          Map.get(attrs, :retrieved_object_links) || Map.get(attrs, "retrieved_object_links") || [],
        scores: Map.get(attrs, :scores) || Map.get(attrs, "scores") || %{},
        judge_output: Map.get(attrs, :judge_output) || Map.get(attrs, "judge_output") || %{},
        status: string(Map.get(attrs, :status) || Map.get(attrs, "status") || "recorded"),
        error_reason:
          string_or_nil(Map.get(attrs, :error_reason) || Map.get(attrs, "error_reason")),
        metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
      }

      sql = """
      INSERT INTO evaluation_cases (
        id, tenant_id, workspace_id, evaluation_run_id, case_id, conversation_id,
        question, expected_answer, actual_answer, context_package_id,
        retrieved_object_links, scores, judge_output, status, error_reason, metadata
      ) VALUES (
        ?1, ?2, ?3, ?4, ?5, ?6,
        ?7, ?8, ?9, ?10,
        ?11, ?12, ?13, ?14, ?15, ?16
      )
      """

      params = [
        evaluation_case.id,
        evaluation_case.tenant_id,
        evaluation_case.workspace_id,
        evaluation_case.evaluation_run_id,
        evaluation_case.case_id,
        evaluation_case.conversation_id,
        evaluation_case.question,
        evaluation_case.expected_answer,
        evaluation_case.actual_answer,
        evaluation_case.context_package_id,
        JSON.list(evaluation_case.retrieved_object_links),
        JSON.map(evaluation_case.scores),
        JSON.map(evaluation_case.judge_output),
        evaluation_case.status,
        evaluation_case.error_reason,
        JSON.map(evaluation_case.metadata)
      ]

      with :ok <- Store.raw_execute(sql, params) do
        {:ok, evaluation_case}
      end
    end
  end

  @spec get_run(String.t()) :: {:ok, run()} | {:error, :not_found | term()}
  def get_run(run_id) when is_binary(run_id) do
    sql = """
    SELECT id, tenant_id, workspace_id, benchmark_name, dataset_name, dataset_version,
           dataset_size, question_count, answer_model, judge_model, judge_strategy,
           retrieval_top_k, run_config, retrieval_config, judge_config, aggregate_scores,
           status, started_at, completed_at, created_by, metadata
    FROM evaluation_runs
    WHERE id = ?1
    """

    case Store.raw_query(sql, [run_id]) do
      {:ok, [row]} -> {:ok, run_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  @spec summarize(String.t()) :: {:ok, map()} | {:error, term()}
  def summarize(run_id) when is_binary(run_id) do
    with {:ok, run} <- get_run(run_id),
         {:ok, rows} <-
           Store.raw_query(
             "SELECT status, scores FROM evaluation_cases WHERE evaluation_run_id = ?1",
             [run_id]
           ) do
      scores = Enum.map(rows, fn [_status, scores] -> decode_map(scores) end)

      {:ok,
       %{
         run_id: run.id,
         benchmark_name: run.benchmark_name,
         dataset_name: run.dataset_name,
         case_count: length(rows),
         passed_count: Enum.count(rows, fn [status, _scores] -> status == "passed" end),
         failed_count: Enum.count(rows, fn [status, _scores] -> status == "failed" end),
         aggregate_scores: aggregate_scores(scores)
       }}
    end
  end

  defp run_from_row([
         id,
         tenant_id,
         workspace_id,
         benchmark_name,
         dataset_name,
         dataset_version,
         dataset_size,
         question_count,
         answer_model,
         judge_model,
         judge_strategy,
         retrieval_top_k,
         run_config,
         retrieval_config,
         judge_config,
         aggregate_scores,
         status,
         started_at,
         completed_at,
         created_by,
         metadata
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      benchmark_name: benchmark_name,
      dataset_name: dataset_name,
      dataset_version: dataset_version,
      dataset_size: dataset_size,
      question_count: question_count,
      answer_model: answer_model,
      judge_model: judge_model,
      judge_strategy: judge_strategy,
      retrieval_top_k: retrieval_top_k,
      run_config: decode_map(run_config),
      retrieval_config: decode_map(retrieval_config),
      judge_config: decode_map(judge_config),
      aggregate_scores: decode_map(aggregate_scores),
      status: status,
      started_at: started_at,
      completed_at: completed_at,
      created_by: created_by,
      metadata: decode_map(metadata)
    }
  end

  defp aggregate_scores([]), do: %{}

  defp aggregate_scores(scores) do
    scores
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn key, acc ->
      values =
        scores
        |> Enum.map(&Map.get(&1, key))
        |> Enum.filter(&is_number/1)

      if values == [] do
        acc
      else
        Map.put(acc, key, %{
          count: length(values),
          average: Enum.sum(values) / length(values),
          min: Enum.min(values),
          max: Enum.max(values)
        })
      end
    end)
  end

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_map(value) when is_map(value), do: value
  defp decode_map(_), do: %{}

  defp int_or_nil(nil), do: nil
  defp int_or_nil(value) when is_integer(value), do: value

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp int_or_nil(_), do: nil

  defp string(nil), do: ""
  defp string(value) when is_binary(value), do: value
  defp string(value), do: to_string(value)

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: string(value)

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
