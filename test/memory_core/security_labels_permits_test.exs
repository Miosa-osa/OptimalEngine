defmodule OptimalEngine.MemoryCore.SecurityLabelsPermitsTest do
  @moduledoc """
  The reader's rule on the tokens a row carries: the labels it names, one
  partition set for each row it was drawn from, and the partitions an
  aggregate needs in full.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.MemoryCore.SecurityLabels

  defp permits?(grants, tokens), do: SecurityLabels.permits?(grants, MapSet.new(tokens))
  defp grants(labels, partitions), do: SecurityLabels.grants(labels, partitions)

  describe "partition_tokens/1" do
    test "a row's partitions are one sorted set, none when it has none" do
      assert SecurityLabels.partition_tokens("[]") == []
      assert SecurityLabels.partition_tokens(nil) == []
      assert SecurityLabels.partition_tokens(~s(["b","a","a"])) == [{:partition_set, ["a", "b"]}]
    end

    test "a value or an element that cannot be read is unresolved on the partition axis" do
      assert SecurityLabels.partition_tokens("not json") == [:unresolved_partition]

      assert SecurityLabels.partition_tokens(~s(["a", 7])) ==
               [{:partition_set, ["a"]}, :unresolved_partition]

      assert SecurityLabels.partition_tokens("[7]") == [:unresolved_partition]
    end
  end

  describe "permits?/2 on partitions" do
    test "with none granted only what carries no partition is seen" do
      assert permits?(grants([], []), [])
      refute permits?(grants([], []), [{:partition_set, ["a"]}])
    end

    test "with some granted, what carries none is not seen" do
      refute permits?(grants([], ["a"]), [])
    end

    test "a set is seen when the reader shares one of its partitions" do
      assert permits?(grants([], ["a"]), [{:partition_set, ["a", "b"]}])
      assert permits?(grants([], ["b", "c"]), [{:partition_set, ["a", "b"]}])
      refute permits?(grants([], ["c"]), [{:partition_set, ["a", "b"]}])
    end

    test "a row drawn from another row needs a partition of each row, not of their union" do
      tokens = [{:partition_set, ["a"]}, {:partition_set, ["b"]}]

      refute permits?(grants([], ["a"]), tokens)
      refute permits?(grants([], ["b"]), tokens)
      assert permits?(grants([], ["a", "b"]), tokens)

      overlapping = [{:partition_set, ["a", "b"]}, {:partition_set, ["b", "c"]}]
      assert permits?(grants([], ["b"]), overlapping)
      refute permits?(grants([], ["a"]), overlapping)
    end

    test "an aggregate needs every partition it names" do
      tokens = [{:partition_all, "a"}, {:partition_all, "b"}]

      refute permits?(grants([], ["a"]), tokens)
      refute permits?(grants([], []), tokens)
      assert permits?(grants([], ["a", "b", "c"]), tokens)
    end

    test "the wildcard reads every partition, labels still apply" do
      tokens = [{:partition_set, ["a"]}, {:partition_set, ["b"]}, {:partition_all, "c"}]

      assert permits?(grants([], ["*"]), tokens)
      refute permits?(grants([], ["*"]), [{:label, "restricted"} | tokens])
      assert permits?(grants(["restricted"], ["*"]), [{:label, "restricted"} | tokens])
    end

    test "an unresolved token is read by no one but a reader of every label" do
      refute permits?(grants(["internal"], ["a"]), [:unresolved, {:partition_set, ["a"]}])
      assert permits?(grants(["*"], ["a"]), [:unresolved, {:partition_set, ["a"]}])
    end

    test "partitions that cannot be read are read by no one but a reader of every partition" do
      for tokens <- [[:unresolved_partition], [{:partition_set, ["a"]}, :unresolved_partition]] do
        refute permits?(grants(["internal"], ["a"]), tokens)
        refute permits?(grants([], []), tokens)
        # A reader of every label does not see past a partition it cannot read.
        refute permits?(grants(["*"], []), tokens)
        refute permits?(grants(["*"], ["a"]), tokens)
        assert permits?(grants([], ["*"]), tokens)
        assert permits?(grants(["*"], ["*"]), tokens)
      end

      # Labels that cannot be read stay waived by every label, as before.
      assert permits?(grants(["*"], []), [:unresolved])
      refute permits?(grants([], ["*"]), [:unresolved])
    end

    test "both kinds of unresolved rank restricted" do
      assert SecurityLabels.token_rank(MapSet.new([:unresolved])) == 3
      assert SecurityLabels.token_rank(MapSet.new([:unresolved_partition])) == 3
    end
  end
end
