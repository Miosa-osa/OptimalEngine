defmodule OptimalEngine.Retrieval.CandidatePortfolio do
  @moduledoc """
  Builds a calibrated candidate pool from independent retrieval adapters.

  Every non-empty adapter receives a bounded representation quota before the
  remaining budget is filled by reciprocal-rank fusion. This prevents an
  uncalibrated score from one projection from erasing complementary lexical or
  semantic evidence. Authorization remains the responsibility of each adapter,
  before its candidates enter the portfolio.
  """

  @version "candidate-portfolio-v1"
  @rrf_constant 60

  @doc "Returns the candidate selection policy version."
  @spec version() :: String.t()
  def version, do: @version

  @spec select([[map()]], pos_integer(), keyword()) :: [map()]
  def select(rankings, limit, opts \\ [])

  def select(rankings, limit, opts) when is_list(rankings) and is_integer(limit) and limit > 0 do
    rankings = Enum.reject(rankings, &(&1 == []))

    case rankings do
      [] ->
        []

      rankings ->
        quotas = representation_quotas(rankings, limit, Keyword.get(opts, :weights))
        fused = reciprocal_rank_scores(rankings)

        reserved_ids =
          rankings
          |> Enum.zip(quotas)
          |> Enum.flat_map(fn {ranking, quota} -> Enum.take(ranking, quota) end)
          |> Enum.map(& &1.id)
          |> Enum.uniq()

        ordered_ids =
          (reserved_ids ++ Enum.map(fused, &elem(&1, 0)))
          |> Enum.uniq()
          |> Enum.take(limit)

        contexts = rankings |> List.flatten() |> Map.new(&{&1.id, &1})
        scores = Map.new(fused)

        Enum.map(ordered_ids, fn id ->
          %{Map.fetch!(contexts, id) | score: Float.round(Map.fetch!(scores, id), 6)}
        end)
    end
  end

  def select(_rankings, _limit, _opts), do: []

  defp representation_quotas(rankings, limit, weights)
       when is_list(weights) and length(weights) == length(rankings) do
    total = Enum.sum(weights)

    if total > 0 do
      Enum.map(weights, &max(floor(limit * &1 / total), 1))
    else
      representation_quotas(rankings, limit, nil)
    end
  end

  defp representation_quotas(rankings, limit, _weights) do
    quota = max(div(limit, length(rankings)), 1)
    List.duplicate(quota, length(rankings))
  end

  defp reciprocal_rank_scores(rankings) do
    rankings
    |> Enum.reduce(%{}, fn ranking, scores ->
      ranking
      |> Enum.with_index(1)
      |> Enum.reduce(scores, fn {candidate, rank}, acc ->
        Map.update(acc, candidate.id, 1.0 / (@rrf_constant + rank), fn score ->
          score + 1.0 / (@rrf_constant + rank)
        end)
      end)
    end)
    |> Enum.sort_by(fn {id, score} -> {-score, id} end)
  end
end
