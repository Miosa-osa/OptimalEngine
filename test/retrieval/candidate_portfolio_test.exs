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

  test "keeps the exact fused score beside the rounded one" do
    [selected] = CandidatePortfolio.select([[hit("a")], [hit("a")]], 1)

    assert selected.rank_score == 2 / 61
    assert selected.score == Float.round(2 / 61, 6)
  end

  test "fills the slots the quotas leave by fused score, and a tie goes by uri, then id" do
    # Three rankings of four. At limit 10 and equal weights each reserves its
    # first three (nine in all); the tenth place goes to the best fused
    # candidate left. The fourth of each ranking fuses to the same score, so
    # only the tie-break chooses, and it must choose by uri, not by id.
    ranking = fn label, uri ->
      for rank <- 1..4 do
        %{id: "#{label}#{rank}", uri: if(rank == 4, do: uri, else: "u/#{label}#{rank}"), score: 1.0}
      end
    end

    rankings = [ranking.("a", "u/z"), ranking.("b", "u/y"), ranking.("c", "u/x")]

    for ordering <- [rankings, Enum.reverse(rankings)] do
      selected = CandidatePortfolio.select(ordering, 10, weights: [1, 1, 1])
      assert length(selected) == 10
      assert List.last(selected).uri == "u/x"
    end
  end

  test "handles empty and invalid budgets" do
    assert CandidatePortfolio.select([], 10) == []
    assert CandidatePortfolio.select([[hit("a")]], 0) == []
  end
end
