defmodule OptimalEngine.Retrieval.CandidatePortfolioTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Retrieval.CandidatePortfolio

  defp hit(id, score \\ 1.0), do: %{id: id, score: score}

  test "preserves bounded representation from complementary adapters" do
    dominant = Enum.map(1..20, &hit("shared-#{&1}"))
    complementary = [hit("lexical-only")] ++ dominant

    ids = CandidatePortfolio.select([dominant, complementary], 6) |> Enum.map(& &1.id)

    assert "lexical-only" in ids
    assert length(ids) == 6
  end

  test "deduplicates identities and rewards agreement by reciprocal rank" do
    selected =
      CandidatePortfolio.select(
        [[hit("shared", 0.2), hit("a")], [hit("shared", 0.9), hit("b")]],
        3
      )

    assert Enum.count(selected, &(&1.id == "shared")) == 1
    assert hd(selected).id == "shared"
    assert hd(selected).score > Enum.at(selected, 1).score
  end

  test "accepts measured adapter weights as representation budgets" do
    lexical = Enum.map(1..10, &hit("lexical-#{&1}"))
    semantic = Enum.map(1..10, &hit("semantic-#{&1}"))

    ids =
      CandidatePortfolio.select([lexical, semantic], 10, weights: [80, 20])
      |> Enum.map(& &1.id)

    assert Enum.count(ids, &String.starts_with?(&1, "lexical-")) == 8
    assert Enum.count(ids, &String.starts_with?(&1, "semantic-")) == 2
  end

  test "is deterministic for tied rankings" do
    rankings = [[hit("b"), hit("a")], [hit("d"), hit("c")]]
    assert CandidatePortfolio.select(rankings, 4) == CandidatePortfolio.select(rankings, 4)
  end

  test "handles empty and invalid budgets" do
    assert CandidatePortfolio.select([], 10) == []
    assert CandidatePortfolio.select([[hit("a")]], 0) == []
  end
end
