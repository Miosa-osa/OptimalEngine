defmodule OptimalEngine.Retrieval.RRFTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Retrieval.ContextAssembler

  describe "fuse/1 (Reciprocal Rank Fusion)" do
    test "a document ranked highly in BOTH lists beats single-list leaders" do
      # list A: a, b, c   list B: b, a, d
      # 'a' and 'b' each appear in both lists; 'b' is rank1 in B + rank2 in A,
      # 'a' is rank1 in A + rank2 in B. Both should outrank c and d (single-list).
      list_a = [%{id: :a, score: 0}, %{id: :b, score: 0}, %{id: :c, score: 0}]
      list_b = [%{id: :b, score: 0}, %{id: :a, score: 0}, %{id: :d, score: 0}]

      fused = ContextAssembler.fuse([list_a, list_b])
      ids = Enum.map(fused, & &1.id)

      assert Enum.take(ids, 2) |> Enum.sort() == [:a, :b]
      # single-list docs land below the cross-list ones
      assert Enum.find_index(ids, &(&1 == :c)) > 1
      assert Enum.find_index(ids, &(&1 == :d)) > 1
    end

    test "fuses two DISTINCT ranked lists without losing any document" do
      list_a = [%{id: 1, score: 0}, %{id: 2, score: 0}]
      list_b = [%{id: 3, score: 0}, %{id: 4, score: 0}]

      fused = ContextAssembler.fuse([list_a, list_b])
      assert length(fused) == 4
      assert Enum.map(fused, & &1.id) |> Enum.sort() == [1, 2, 3, 4]
    end

    test "degrades to a single list cleanly (empty list contributes nothing)" do
      list_a = [%{id: :x, score: 0}, %{id: :y, score: 0}]
      fused = ContextAssembler.fuse([list_a, []])
      assert Enum.map(fused, & &1.id) == [:x, :y]
    end

    test "equal fused scores order by uri, whatever order the lists come in" do
      a = %{id: "id-2", uri: "u/a", score: 0}
      b = %{id: "id-1", uri: "u/b", score: 0}

      assert ContextAssembler.fuse([[b], [a]]) |> Enum.map(& &1.uri) == ["u/a", "u/b"]
      assert ContextAssembler.fuse([[a], [b]]) |> Enum.map(& &1.uri) == ["u/a", "u/b"]
    end

    test "a fused score keeps its exact value beside the rounded one" do
      [fused] = ContextAssembler.fuse([[%{id: :a, score: 0}], [%{id: :a, score: 0}]])

      assert fused.rank_score == 2 / 61
      assert fused.score == Float.round(2 / 61, 6)
    end

    test "fused scores are descending" do
      fused =
        ContextAssembler.fuse([
          [%{id: :a, score: 0}, %{id: :b, score: 0}],
          [%{id: :a, score: 0}, %{id: :c, score: 0}]
        ])

      scores = Enum.map(fused, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end
  end
end
