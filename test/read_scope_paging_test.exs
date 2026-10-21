defmodule OptimalEngine.ReadScopePagingTest do
  @moduledoc """
  A page of a list a key's grants cut down is filled from what the key may see,
  not from the first rows read: `scan/4` reads a list a batch at a time and
  `widen/5` re-reads a ranked window at a size that grows, both until the page
  and one more are found, the list ends or the budget is spent.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Identity.ACL
  alias OptimalEngine.ReadScope

  # The list is the integers 1..size; the reader may see the multiples of `step`.
  defp read(size, calls) do
    fn offset, count ->
      send(calls, {:read, offset, count})
      Enum.to_list((offset + 1)..min(offset + count, size)//1)
    end
  end

  defp keep(step), do: fn raw -> Enum.filter(raw, &(rem(&1, step) == 0)) end

  defp reads(acc \\ []) do
    receive do
      {:read, offset, count} -> reads([{offset, count} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "filtering?/1 and grants_cut?/1" do
    # A tenant of its own, so no other test's access lists are in the way.
    defp scope(labels, partitions) do
      %ReadScope{
        tenant_id: "paging-#{System.unique_integer([:positive])}",
        principal: "agent:paging",
        labels: labels,
        partitions: partitions
      }
    end

    test "the operator is not filtered" do
      refute ReadScope.filtering?(nil)
      refute ReadScope.grants_cut?(nil)
    end

    test "a key whose grants cut something filters" do
      for scope <- [scope([], []), scope(["*"], []), scope(["*"], ["team-a"])] do
        assert ReadScope.filtering?(scope)
        assert ReadScope.grants_cut?(scope)
      end
    end

    test "a key granted * is filtered only when the access lists can cut" do
      all = scope(["*"], ["*"])
      refute ReadScope.grants_cut?(all)
      refute ReadScope.filtering?(all)

      # A resource with an access list row can hide from any principal.
      :ok =
        ACL.deny(%{
          resource_uri: "optimal://memory/paging/hidden",
          principal_id: "agent:somebody-else",
          tenant_id: all.tenant_id
        })

      assert ReadScope.filtering?(all)
      refute ReadScope.grants_cut?(all)

      # And a policy that denies what no row governs cuts everything.
      assert ReadScope.filtering?(%{scope(["*"], ["*"]) | acl_absent: :deny})
    end
  end

  describe "scan/4" do
    test "reads on until the page and one more are found" do
      kept = ReadScope.scan(3, read(1_000, self()), keep(10), batch: 5)

      assert kept == [10, 20, 30]
      # 5 at a time: 5, 10, ... 30 is read in the sixth batch.
      assert reads() == [{0, 5}, {5, 5}, {10, 5}, {15, 5}, {20, 5}, {25, 5}]
    end

    test "stops when the list ends, with what it found" do
      assert ReadScope.scan(50, read(40, self()), keep(10), batch: 8) == [10, 20, 30, 40]
      assert reads() == [{0, 8}, {8, 8}, {16, 8}, {24, 8}, {32, 8}, {40, 8}]
    end

    test "stops when the budget is spent, with what it found" do
      assert ReadScope.scan(50, read(1_000, self()), keep(10), batch: 10, budget: 30) == [
               10,
               20,
               30
             ]

      assert reads() == [{0, 10}, {10, 10}, {20, 10}]
    end

    test "a reader who may see everything is read once" do
      assert ReadScope.scan(4, read(1_000, self()), keep(1), batch: 10) == Enum.to_list(1..10)
      assert reads() == [{0, 10}]
    end

    test "a reader who may see nothing reads the list to its end" do
      assert ReadScope.scan(1, read(25, self()), keep(1_000), batch: 10) == []
      assert reads() == [{0, 10}, {10, 10}, {20, 10}]
    end
  end

  describe "widen/5" do
    defp window(size, calls) do
      fn count ->
        send(calls, {:window, count})
        {:ok, Enum.to_list(1..min(count, size)//1)}
      end
    end

    defp windows(acc \\ []) do
      receive do
        {:window, count} -> windows([count | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "doubles the window until the page and one more are found" do
      # Needs 3 multiples of 50: the window reaches 160 items.
      assert {:ok, [50, 100, 150]} = ReadScope.widen(3, 10, 1_000, window(10_000, self()), keep(50))
      assert windows() == [10, 20, 40, 80, 160]
    end

    test "never starts below what the page needs" do
      assert {:ok, [1, 2, 3, 4, 5]} = ReadScope.widen(5, 2, 100, window(100, self()), keep(1))
      assert windows() == [5]
    end

    test "stops when the source returns less than was asked" do
      assert {:ok, [50, 100]} = ReadScope.widen(9, 10, 1_000, window(120, self()), keep(50))
      assert windows() == [10, 20, 40, 80, 160]
    end

    test "stops at the ceiling" do
      assert {:ok, kept} = ReadScope.widen(3, 10, 100, window(10_000, self()), keep(50))
      assert kept == [50, 100]
      assert windows() == [10, 20, 40, 80, 100]
    end

    test "an error from the source is the answer" do
      read = fn _count -> {:error, :busy} end
      assert ReadScope.widen(1, 10, 100, read, keep(1)) == {:error, :busy}
    end
  end
end
