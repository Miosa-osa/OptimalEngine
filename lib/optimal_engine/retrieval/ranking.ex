defmodule OptimalEngine.Retrieval.Ranking do
  @moduledoc """
  The one ordering rule for ranked retrieval results.

  Two Engines that hold the same data must return the same ranked list, and
  one Engine must return the same list every time it is asked. Three things
  used to break that: results were sorted on a score already rounded for
  display, equal scores had no tie-break (their order was whatever the
  database or the map iteration happened to yield), and the time decay read
  the clock once per call. The rule here removes the first two; the third is
  the `:as_of` option of `OptimalEngine.Retrieval.Search`.

  ## The rule

  1. Order by the **exact** score, best first. A result carries two numbers:
     `score`, the exact value rounded for display, and `rank_score`, the exact
     value itself. Ordering reads `rank_score` and never `score`, so two hits
     that print the same four decimals still order by their true scores.
  2. Break ties by `uri`, then by `id`, both ascending. The pair is a total
     order, because a context id is unique and a URI names one context.

  Every module that sorts results for a caller goes through `sort/1` or
  `key/1`, and every SQL `ORDER BY` that feeds a ranked list ends in a unique
  column.

  ## Setting a score

  `put_score/3` is the only place a result's `score` and `rank_score` are
  written together, so they cannot drift:

      Ranking.put_score(context, 5.80524, 4)
      #=> %{context | score: 5.8052, rank_score: 5.80524}

  A result that was never ranked by this module has no `rank_score`; its
  `score` is then taken as exact.
  """

  @type result :: map()

  @doc "The exact score ordering reads: `rank_score`, else `score`, else 0.0."
  @spec exact_score(result()) :: float()
  def exact_score(result) do
    case Map.get(result, :rank_score) || Map.get(result, :score) do
      value when is_number(value) -> value * 1.0
      _ -> 0.0
    end
  end

  @doc """
  Sets a result's exact score and its display rounding together.

  `digits` is how many decimals the displayed `score` keeps.
  """
  @spec put_score(result(), number(), non_neg_integer()) :: result()
  def put_score(result, exact, digits \\ 4) when is_number(exact) do
    exact = exact * 1.0

    result
    |> Map.put(:rank_score, exact)
    |> Map.put(:score, Float.round(exact, digits))
  end

  @doc """
  The `{uri, id}` pair that breaks a score tie.

  A missing value sorts as the empty string, before any real one.
  """
  @spec tie_key(result()) :: {String.t(), String.t()}
  def tie_key(result), do: {tie_text(Map.get(result, :uri)), tie_text(Map.get(result, :id))}

  @doc """
  The sort key of a result: exact score descending, then `uri`, then `id`.

  The score is negated by subtraction from `0.0` so a score of zero never
  becomes `-0.0`.
  """
  @spec key(result()) :: {float(), String.t(), String.t()}
  def key(result) do
    {uri, id} = tie_key(result)
    {0.0 - exact_score(result), uri, id}
  end

  @doc "Sorts results into the total order of this module."
  @spec sort([result()]) :: [result()]
  def sort(results) when is_list(results), do: Enum.sort_by(results, &key/1)

  @doc """
  Merges two lists that are each already best first into one, by the rule of
  this module. A tie between an item of each goes by `uri`, then `id`, so the
  merged list is the same whichever list an item came from.
  """
  @spec merge([result()], [result()]) :: [result()]
  def merge(first, []), do: first
  def merge([], second), do: second

  def merge([a | rest_a] = first, [b | rest_b] = second) do
    if before?(b, a),
      do: [b | merge(first, rest_b)],
      else: [a | merge(rest_a, second)]
  end

  @doc "True when `a` ranks strictly ahead of `b`."
  @spec before?(result(), result()) :: boolean()
  def before?(a, b), do: key(a) < key(b)

  defp tie_text(nil), do: ""
  defp tie_text(value) when is_binary(value), do: value
  defp tie_text(value), do: inspect(value)
end
