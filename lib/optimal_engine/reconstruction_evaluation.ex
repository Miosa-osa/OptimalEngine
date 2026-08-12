defmodule OptimalEngine.ReconstructionEvaluation do
  @moduledoc """
  Reconstruction Adapter for the governed Evaluation lifecycle.

  Cases may define required terms, forbidden terms, expected object links,
  abstention, and maximum token use. Results remain evaluation records and do
  not pollute operational outcome learning.
  """

  alias OptimalEngine.{Evaluation, MemoryCore}

  @doc "Runs versioned reconstruction cases through the existing Evaluation module."
  @spec run([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(cases, opts \\ []) do
    Evaluation.run_benchmark(
      cases,
      Keyword.merge(opts,
        benchmark_name: "governed_reconstruction",
        dataset_name: Keyword.get(opts, :dataset_name, "reconstruction-gold"),
        dataset_version: Keyword.get(opts, :dataset_version, "1"),
        retrieval_config: %{strategy: "reconstructive", policy: "fail_closed"},
        retriever: &retrieve/2,
        judge: &judge/3
      )
    )
  end

  defp retrieve(query, opts),
    do: MemoryCore.retrieve(query, Keyword.put(opts, :strategy, :reconstructive))

  defp judge(case_attrs, actual_answer, package) do
    required = list(case_attrs, :required_terms)
    forbidden = list(case_attrs, :forbidden_terms)
    expected_links = list(case_attrs, :expected_object_links)
    abstain? = value(case_attrs, :expect_abstention) == true
    normalized = String.downcase(actual_answer)
    returned = Map.get(package, :returned_object_links, [])
    required_hits = Enum.count(required, &String.contains?(normalized, String.downcase(&1)))
    forbidden_hits = Enum.count(forbidden, &String.contains?(normalized, String.downcase(&1)))
    link_hits = Enum.count(expected_links, &link_present?(returned, &1))
    total_tokens = get_in(package.sections, [:total_tokens]) || 0
    max_tokens = value(case_attrs, :max_tokens) || 8_000
    answered? = String.trim(actual_answer) != ""

    scores = %{
      completeness: ratio(required_hits, length(required)),
      citation_precision:
        if(package.source_package_links == [] and package.evidence_links == [], do: 0.0, else: 1.0),
      canonical_recall: ratio(link_hits, length(expected_links)),
      policy_safety: if(forbidden_hits == 0, do: 1.0, else: 0.0),
      abstention: if(abstain?, do: bool(not answered?), else: 1.0),
      token_efficiency: if(total_tokens <= max_tokens, do: 1.0, else: max_tokens / total_tokens)
    }

    pass? = Enum.all?(scores, fn {_name, score} -> score >= 0.8 end)

    %{
      status: if(pass?, do: "passed", else: "failed"),
      scores: scores,
      judge_output: %{
        required_hits: required_hits,
        required_total: length(required),
        forbidden_hits: forbidden_hits,
        expected_link_hits: link_hits,
        expected_link_total: length(expected_links),
        total_tokens: total_tokens,
        max_tokens: max_tokens,
        strategy: "governed-reconstruction-v2"
      },
      error_reason: if(pass?, do: nil, else: "reconstruction_quality_threshold_failed")
    }
  end

  defp link_present?(returned, expected) do
    expected_type = value(expected, :type)
    expected_id = value(expected, :id)
    Enum.any?(returned, &(value(&1, :type) == expected_type and value(&1, :id) == expected_id))
  end

  defp list(map, key), do: List.wrap(value(map, key))
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp ratio(_hits, 0), do: 1.0
  defp ratio(hits, total), do: hits / total
  defp bool(true), do: 1.0
  defp bool(false), do: 0.0
end
