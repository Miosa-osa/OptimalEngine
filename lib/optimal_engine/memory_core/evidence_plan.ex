defmodule OptimalEngine.MemoryCore.EvidencePlan do
  @moduledoc """
  Deterministic evidence obligations for governed recall.

  The plan decomposes a request into complementary probes without retrieving
  anything itself. `RetrievalCoordinator` remains responsible for executing
  every probe inside the authorization envelope.
  """

  @question_words ~w[what when where which who why how did does do is are was were]
  @stopwords ~w[
    a an and are as at be by did do does for from had has have how in is it its
    of on or that the this to was were what when where which who why with
  ]
  @temporal ~w[when date dates day days week weeks month months year years before after during
                first last latest earlier later recently yesterday today tomorrow]
  @inference ~w[likely infer inferred suggest suggests indicate indicates reason why probably]
  @comparison ~w[both compare compared difference differences similar similarities together
                 respectively each all list names activities events]
  @planner_version "evidence-plan-v1"

  @type obligation :: %{role: String.t(), probe: String.t(), required: boolean()}

  @spec build(String.t()) :: map()
  def build(query) when is_binary(query) do
    normalized = normalize(query)
    clauses = clauses(query)
    entities = entities(query)
    intent = classify(normalized, clauses)

    obligations =
      [%{role: "primary", probe: query, required: true}]
      |> add_clause_obligations(clauses, query)
      |> add_entity_obligations(entities, normalized)
      |> add_role_obligation("temporal", temporal_probe(normalized), temporal?(normalized))
      |> add_role_obligation("inference", inference_probe(normalized), inference?(normalized))
      |> Enum.uniq_by(&{&1.role, &1.probe})

    %{
      planner_version: @planner_version,
      intent: intent,
      obligations: obligations,
      probes: Enum.map(obligations, & &1.probe),
      required_roles:
        obligations |> Enum.filter(& &1.required) |> Enum.map(& &1.role) |> Enum.uniq()
    }
  end

  @spec classify(String.t()) :: String.t()
  def classify(query) when is_binary(query) do
    normalized = normalize(query)
    classify(normalized, clauses(query))
  end

  defp classify(normalized, clauses) do
    cond do
      inference?(normalized) -> "inference"
      temporal?(normalized) -> "temporal"
      comparison?(normalized) -> "comparison_set"
      length(clauses) > 1 -> "multi_hop"
      true -> "single_hop"
    end
  end

  defp clauses(query) do
    query
    |> String.split(~r/\b(?:and|while|but|then|also)\b|[,;]/iu, trim: true)
    |> Enum.map(&String.trim(&1, " ,?.!"))
    |> Enum.filter(&(length(content_words(&1)) >= 2))
    |> Enum.uniq()
  end

  defp entities(query) do
    Regex.scan(~r/\b[\p{Lu}][\p{L}'-]{2,}\b/u, query)
    |> List.flatten()
    |> Enum.reject(&(String.downcase(&1) in @question_words))
    |> Enum.uniq()
  end

  defp add_clause_obligations(obligations, clauses, query) do
    if length(clauses) > 1 do
      clauses
      |> Enum.with_index(1)
      |> Enum.reduce(obligations, fn {clause, index}, acc ->
        if normalize(clause) == normalize(query),
          do: acc,
          else: acc ++ [%{role: "clause_#{index}", probe: clause, required: true}]
      end)
    else
      obligations
    end
  end

  defp add_entity_obligations(obligations, entities, normalized) do
    Enum.reduce(entities, obligations, fn entity, acc ->
      if String.contains?(normalized, String.downcase(entity)) do
        acc ++ [%{role: "entity:#{String.downcase(entity)}", probe: entity, required: false}]
      else
        acc
      end
    end)
  end

  defp add_role_obligation(obligations, _role, _probe, false), do: obligations

  defp add_role_obligation(obligations, role, probe, true),
    do: obligations ++ [%{role: role, probe: probe, required: true}]

  defp temporal_probe(normalized) do
    normalized |> content_words() |> Enum.reject(&(&1 in @question_words)) |> Enum.join(" ")
  end

  defp inference_probe(normalized) do
    normalized
    |> content_words()
    |> Enum.reject(&(&1 in @inference or &1 in @question_words))
    |> Enum.join(" ")
  end

  defp temporal?(normalized), do: Enum.any?(content_words(normalized), &(&1 in @temporal))
  defp inference?(normalized), do: Enum.any?(content_words(normalized), &(&1 in @inference))
  defp comparison?(normalized), do: Enum.any?(content_words(normalized), &(&1 in @comparison))

  defp content_words(text) do
    text
    |> normalize()
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 3 or &1 in @stopwords))
    |> Enum.uniq()
  end

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}'-]+/u, " ")
    |> String.trim()
  end
end
