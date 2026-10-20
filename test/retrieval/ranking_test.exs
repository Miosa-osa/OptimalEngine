defmodule OptimalEngine.Retrieval.RankingTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Context
  alias OptimalEngine.Retrieval.Ranking

  defp hit(id, uri, score), do: %{id: id, uri: uri, score: score}

  describe "exact_score/1" do
    test "reads rank_score ahead of score" do
      assert Ranking.exact_score(%{score: 5.8052, rank_score: 5.80524}) == 5.80524
    end

    test "falls back to score, then to zero" do
      assert Ranking.exact_score(%{score: 2}) == 2.0
      assert Ranking.exact_score(%{score: nil}) == 0.0
      assert Ranking.exact_score(%{}) == 0.0
    end

    test "reads a context that was never ranked" do
      assert Ranking.exact_score(%Context{score: 1.5}) == 1.5
      assert Ranking.exact_score(%Context{}) == 0.0
    end
  end

  describe "put_score/3" do
    test "sets the exact value and its display rounding together" do
      ranked = Ranking.put_score(%Context{id: "a"}, 5.80524, 4)

      assert ranked.rank_score == 5.80524
      assert ranked.score == 5.8052
    end

    test "rounds to the digits asked for" do
      assert Ranking.put_score(%{}, 0.0163934426, 6).score == 0.016393
      assert Ranking.put_score(%{}, 0.0163934426, 2).score == 0.02
    end

    test "turns an integer into a float" do
      ranked = Ranking.put_score(%{}, 3, 4)
      assert ranked.rank_score === 3.0
      assert ranked.score === 3.0
    end
  end

  describe "sort/1" do
    test "orders by exact score, best first" do
      sorted = Ranking.sort([hit("a", "u/a", 1.0), hit("b", "u/b", 3.0), hit("c", "u/c", 2.0)])
      assert Enum.map(sorted, & &1.id) == ["b", "c", "a"]
    end

    test "breaks a tie by uri, then by id" do
      hits = [
        hit("2", "u/same", 1.0),
        hit("1", "u/same", 1.0),
        hit("9", "u/early", 1.0),
        hit("0", "u/late", 1.0)
      ]

      assert hits |> Ranking.sort() |> Enum.map(& &1.id) == ["9", "0", "1", "2"]
    end

    test "gives the same order whatever order the hits arrive in" do
      hits = for n <- 1..20, do: hit("id-#{n}", "u/#{rem(n, 4)}", 1.0 + rem(n, 3))
      expected = Ranking.sort(hits)

      for _ <- 1..10 do
        assert hits |> Enum.shuffle() |> Ranking.sort() == expected
      end
    end

    test "orders by the exact score when the displayed scores are equal" do
      older = Ranking.put_score(hit("older", "u/a", nil), 5.80518, 4)
      newer = Ranking.put_score(hit("newer", "u/b", nil), 5.80524, 4)

      assert older.score == newer.score

      assert [older, newer] |> Ranking.sort() |> Enum.map(& &1.id) == ["newer", "older"]
      assert [newer, older] |> Ranking.sort() |> Enum.map(& &1.id) == ["newer", "older"]
    end

    test "never reads the rounded score once an exact one is present" do
      low_exact = %{id: "x", uri: "u/x", score: 9.0, rank_score: 1.0}
      high_exact = %{id: "y", uri: "u/y", score: 2.0, rank_score: 8.0}

      assert Enum.map(Ranking.sort([low_exact, high_exact]), & &1.id) == ["y", "x"]
    end

    test "treats a missing score as zero and a missing uri or id as empty" do
      sorted = Ranking.sort([%{id: "b"}, %{id: "a"}, %{id: "top", score: 0.5}])
      assert Enum.map(sorted, & &1.id) == ["top", "a", "b"]
    end

    test "sorts atoms and integers used as ids" do
      sorted = Ranking.sort([%{id: 3, score: 1}, %{id: 1, score: 1}, %{id: 2, score: 1}])
      assert Enum.map(sorted, & &1.id) == [1, 2, 3]
    end

    test "a zero score is not negative zero" do
      assert {0.0, "", ""} === Ranking.key(%{score: 0.0})
    end
  end

  describe "before?/2" do
    test "is true only for a strictly better rank" do
      assert Ranking.before?(hit("a", "u/a", 2.0), hit("b", "u/b", 1.0))
      refute Ranking.before?(hit("b", "u/b", 1.0), hit("a", "u/a", 2.0))
      assert Ranking.before?(hit("a", "u/a", 1.0), hit("b", "u/b", 1.0))
      refute Ranking.before?(hit("a", "u/a", 1.0), hit("a", "u/a", 1.0))
    end
  end
end
