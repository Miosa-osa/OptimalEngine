defmodule OptimalEngine.Retrieval.QualityBenchmarkTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Retrieval.{ContextAssembler, Search}
  alias OptimalEngine.Store

  test "current exact workspace memory outranks unrelated historical material" do
    suffix = System.unique_integer([:positive])
    workspace = "benchmark-#{suffix}"
    exact = "mem_benchmark_exact_#{suffix}"
    old = "mem_benchmark_old_#{suffix}"

    for {id, content} <- [
          {exact, "Task: Commas follow up for feedback and schedule the next working session"},
          {old, "Historical ClinicIQ deployment transcript and billing discussion"}
        ] do
      assert {:ok, _} =
               Store.raw_query(
                 "INSERT INTO memories (id, workspace_id, content, root_memory_id) VALUES (?1, ?2, ?3, ?1)",
                 [id, workspace, content]
               )
    end

    on_exit(fn -> Store.raw_query("DELETE FROM memories WHERE id IN (?1, ?2)", [exact, old]) end)

    query = "Commas follow up feedback next working session"
    assert {:ok, [first | _]} = Search.search(query, workspace_id: workspace)
    assert first.id == exact
    assert {:ok, assembled} = ContextAssembler.assemble(query, workspace_id: workspace)
    assert assembled.l2 =~ "Commas"
    refute assembled.l2 =~ "ClinicIQ"
  end
end
