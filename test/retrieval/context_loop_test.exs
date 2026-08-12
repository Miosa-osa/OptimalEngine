defmodule OptimalEngine.Retrieval.ContextLoopTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Retrieval.{ContextAssembler, Search}
  alias OptimalEngine.Store

  test "search includes exact durable memories from the requested workspace" do
    suffix = System.unique_integer([:positive])
    workspace_id = "context-loop-#{suffix}"
    memory_id = "mem_context_loop_#{suffix}"
    phrase = "repair payment detector smoke #{suffix}"

    assert {:ok, _} =
             Store.raw_query(
               "INSERT INTO memories (id, workspace_id, content, root_memory_id) VALUES (?1, ?2, ?3, ?1)",
               [memory_id, workspace_id, phrase]
             )

    on_exit(fn ->
      Store.raw_query("DELETE FROM memories WHERE id = ?1", [memory_id])
    end)

    assert {:ok, results} = Search.search(phrase, workspace_id: workspace_id)
    assert Enum.any?(results, &(&1.id == memory_id and &1.type == :memory))
  end

  test "context assembly preserves workspace scope through fused search" do
    suffix = System.unique_integer([:positive])
    workspace_id = "assemble-scope-#{suffix}"
    memory_id = "mem_assemble_scope_#{suffix}"
    phrase = "workspace scoped engine truth #{suffix}"

    assert {:ok, _} =
             Store.raw_query(
               "INSERT INTO memories (id, workspace_id, content, root_memory_id) VALUES (?1, ?2, ?3, ?1)",
               [memory_id, workspace_id, phrase]
             )

    on_exit(fn ->
      Store.raw_query("DELETE FROM memories WHERE id = ?1", [memory_id])
    end)

    assert {:ok, assembled} =
             ContextAssembler.assemble(phrase, workspace_id: workspace_id, limit: 5)

    assert memory_id in Enum.map(assembled.search_scores, & &1.id)
    assert assembled.l2 =~ phrase
  end

  test "an exact memory match filters unrelated semantic candidates" do
    suffix = System.unique_integer([:positive])
    workspace_id = "assemble-focus-#{suffix}"
    exact_id = "mem_assemble_exact_#{suffix}"
    noise_id = "mem_assemble_noise_#{suffix}"
    phrase = "Commas follow up for feedback and schedule the next working session #{suffix}"
    query = "Commas follow up feedback next working session #{suffix}"

    for {id, content} <- [
          {exact_id, phrase},
          {noise_id, "casino engineering audit recruiting contributor #{suffix}"}
        ] do
      assert {:ok, _} =
               Store.raw_query(
                 "INSERT INTO memories (id, workspace_id, content, root_memory_id) VALUES (?1, ?2, ?3, ?1)",
                 [id, workspace_id, content]
               )
    end

    on_exit(fn ->
      Store.raw_query("DELETE FROM memories WHERE id IN (?1, ?2)", [exact_id, noise_id])
    end)

    assert {:ok, results} =
             ContextAssembler.fused_search(query, workspace_id: workspace_id, limit: 20)

    assert exact_id in Enum.map(results, & &1.id)
    refute noise_id in Enum.map(results, & &1.id)
  end
end
