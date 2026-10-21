defmodule OptimalEngine.Sync.GateReaderCostTest do
  @moduledoc """
  What it costs the reader's gate to decide for many rows. A keyed export of a
  workspace classifies every memory by its source; the gate reads the rows and
  what they link to a chunk at a time, so the number of reads follows the
  number of chunks, not the number of rows.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Gate
  alias OptimalEngine.Workspace

  @rows 10_000

  setup do
    n = System.unique_integer([:positive])
    {:ok, workspace} = Workspace.create(%{slug: "cost-#{n}", name: "Cost #{n}"})
    ws = workspace.id

    # Ten thousand source packages and a memory staged from each, written in
    # two statements.
    {:ok, _} =
      Store.raw_query(
        """
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < #{@rows})
        INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text)
        SELECT 'sp-cost-' || ?1 || '-' || i, 'default', ?2, 'h-' || ?1 || '-' || i, 'Note ' || i FROM n
        """,
        [n, ws]
      )

    {:ok, _} =
      Store.raw_query(
        """
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < #{@rows})
        INSERT INTO memories (id, tenant_id, workspace_id, content, metadata)
        SELECT 'mem-cost-' || ?1 || '-' || i, 'default', ?2, 'Memory ' || i,
               json_object('memory_core_source_package_id', 'sp-cost-' || ?1 || '-' || i)
        FROM n
        """,
        [n, ws]
      )

    {:ok, rows} = Store.raw_query("SELECT id FROM memories WHERE workspace_id = ?1", [ws])
    %{n: n, ws: ws, ids: Enum.map(rows, &hd/1)}
  end

  test "ten thousand memories are classified in a number of reads that follows the chunks", ctx do
    assert length(ctx.ids) == @rows

    # A hundred of the sources are restricted.
    {:ok, _} =
      Store.raw_query(
        "UPDATE source_packages SET security_labels = '[\"restricted\"]' WHERE workspace_id = ?1 AND id GLOB ?2",
        [ctx.ws, "sp-cost-#{ctx.n}-1[0-9][0-9]"]
      )

    {allowed, reads} =
      counting_reads(fn ->
        Gate.with_reader("default", ctx.ws, SecurityLabels.grants(["internal"], []), fn gate ->
          Gate.readable_ids(gate, "memories", ctx.ids)
        end)
      end)

    assert MapSet.size(allowed) == @rows - 100
    refute MapSet.member?(allowed, "mem-cost-#{ctx.n}-150")
    assert MapSet.member?(allowed, "mem-cost-#{ctx.n}-1000")

    # Twenty chunks of 500 rows: the rows, their sources, and the index built
    # once. One read per row would be more than ten thousand.
    assert reads < 150, "the gate made #{reads} reads"
    IO.puts("gate reads for #{@rows} memories: #{reads}")
  end

  test "a workspace with nothing labelled is classified in the same few reads", ctx do
    {_allowed, reads} =
      counting_reads(fn ->
        Gate.with_reader("default", ctx.ws, SecurityLabels.grants([], []), fn gate ->
          Gate.readable_ids(gate, "memories", ctx.ids)
        end)
      end)

    assert reads < 150, "the gate made #{reads} reads"
  end

  defp counting_reads(fun) do
    id = {:gate_reads, System.unique_integer([:positive])}
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:optimal_engine, :sync, :gate_query],
        fn _event, _measurements, _meta, _config -> send(parent, :gate_read) end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(id)
      end

    {result, drain(0)}
  end

  defp drain(count) do
    receive do
      :gate_read -> drain(count + 1)
    after
      0 -> count
    end
  end
end
