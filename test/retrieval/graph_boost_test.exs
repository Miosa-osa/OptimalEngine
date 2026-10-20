defmodule OptimalEngine.Retrieval.GraphBoostTest do
  @moduledoc """
  The graph boost changes scores, never positions, and it works from the exact
  score: only the score shown is rounded.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Bridge.Knowledge
  alias OptimalEngine.Context
  alias OptimalEngine.Store

  setup do
    token = "boosttoken#{System.unique_integer([:positive])}"
    entity = "Entity#{token}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO edges (source_id, target_id, relation) VALUES (?1, ?2, 'related')",
        [token, entity]
      )

    on_exit(fn -> Store.raw_query("DELETE FROM edges WHERE source_id = ?1", [token]) end)

    {:ok, token: token, entity: entity}
  end

  defp result(id, entities, exact) do
    %Context{
      id: id,
      uri: "optimal://nodes/boost/#{id}",
      entities: entities,
      score: Float.round(exact, 4),
      rank_score: exact
    }
  end

  test "multiplies the exact score and rounds only the score shown", ctx do
    [boosted] = Knowledge.graph_boost([result("a", [ctx.entity], 5.80524)], ctx.token)

    expected = 5.80524 * (1.0 + 1 * 0.1)
    assert boosted.rank_score == expected
    assert boosted.score == Float.round(expected, 4)
  end

  test "keeps the order of the results it is given", ctx do
    results = [
      result("plain", [], 5.0),
      result("connected", [ctx.entity], 4.0),
      result("other", ["Unrelated"], 3.0)
    ]

    boosted = Knowledge.graph_boost(results, ctx.token)

    assert Enum.map(boosted, & &1.id) == ["plain", "connected", "other"]
    assert Enum.map(boosted, & &1.score) == [5.0, 4.4, 3.0]
  end

  test "leaves the results alone when nothing in the graph matches the query" do
    results = [result("a", ["Anything"], 5.80524)]
    assert Knowledge.graph_boost(results, "nomatch#{System.unique_integer([:positive])}") == results
  end
end
