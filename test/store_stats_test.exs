defmodule OptimalEngine.StoreStatsTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Store

  test "stats count durable memories and exclude archived compatibility contexts" do
    suffix = System.unique_integer([:positive])
    memory_id = "stats-memory-#{suffix}"

    assert {:ok, before_stats} = Store.stats()

    assert {:ok, _} =
             Store.raw_query(
               "INSERT INTO memories (id, workspace_id, content, root_memory_id) VALUES (?1, 'stats-test', ?2, ?1)",
               [memory_id, "stats durable memory #{suffix}"]
             )

    on_exit(fn -> Store.raw_query("DELETE FROM memories WHERE id = ?1", [memory_id]) end)

    assert {:ok, after_stats} = Store.stats()
    assert after_stats["total_memories"] == before_stats["total_memories"] + 1
  end
end
