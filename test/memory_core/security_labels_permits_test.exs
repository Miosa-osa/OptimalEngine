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

  describe "metadata_map/1" do
    test "reads an object as Jason does" do
      assert SecurityLabels.metadata_map(~s({"security_labels":["a"],"n":1,"x":{"y":null}})) ==
               %{"security_labels" => ["a"], "n" => 1, "x" => %{"y" => nil}}

      assert SecurityLabels.metadata_map(%{security_labels: ["a"]}) == %{"security_labels" => ["a"]}
    end

    test "is empty for text that is not an object" do
      for text <- [
            "not json",
            "[1,2]",
            ~s("text"),
            "7",
            "",
            ~s({"a":1} trailing),
            ~s({"a":),
            # A lone surrogate escape, and a byte that is not UTF-8.
            ~S({"a":"\ud800"}),
            <<?{, ?", 0xFF, ?", ?:, ?1, ?}>>
          ] do
        assert SecurityLabels.metadata_map(text) == %{}, inspect(text)
      end

      assert SecurityLabels.metadata_map(nil) == %{}
    end

    test "ignores trailing white space only where JSON does" do
      assert SecurityLabels.metadata_map(~s({"a":1} \t\r\n)) == %{"a" => 1}

      # SQLite's json_valid refuses these, so a metadata that has them names nothing
      # in both places.
      for tail <- ["\u00a0", "\u2003", "\u3000", "\u0085", "x"] do
        text = ~s({"security_labels":["restricted"]}) <> tail
        assert SecurityLabels.metadata_map(text) == %{}, inspect(tail)
      end
    end

    test "reads a repeated security_labels or partition_ids as 0, which is unresolved" do
      map = SecurityLabels.metadata_map(~s({"security_labels":["a"],"security_labels":[],"n":1}))
      assert map == %{"security_labels" => 0, "n" => 1}
      assert SecurityLabels.metadata_tokens(map) == [:unresolved]

      map = SecurityLabels.metadata_map(~s({"partition_ids":["a"],"partition_ids":["b"]}))
      assert SecurityLabels.metadata_tokens(map) == [:unresolved_partition]

      # Any other repeated key is the last one, as before.
      assert SecurityLabels.metadata_map(~s({"note":"a","note":"b"})) == %{"note" => "b"}
    end

    test "a repeated key inside a nested object is marked there, and the top level is not" do
      map =
        SecurityLabels.metadata_map(
          ~s({"security_labels":["a"],"x":{"partition_ids":1,"partition_ids":2}})
        )

      assert map == %{"security_labels" => ["a"], "x" => %{"partition_ids" => 0}}
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
