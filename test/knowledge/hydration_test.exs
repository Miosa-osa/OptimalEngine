defmodule OptimalEngine.Knowledge.HydrationTest do
  @moduledoc """
  Rebuilding the triple store from the durable `edges` table at boot.

  Every edge is loaded, however many there are. A persistent backend (RocksDB)
  keeps what it already holds, so after the first full load it only takes the
  edges written since, and falls back to a full load when its marker is gone
  or the database went backwards.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Graph
  alias OptimalEngine.Knowledge
  alias OptimalEngine.Knowledge.Backend
  alias OptimalEngine.Knowledge.Hydration
  alias OptimalEngine.Store

  setup do
    tmp = Path.join(System.tmp_dir!(), "hydration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp, ws: "hydration-ws-#{System.unique_integer([:positive])}"}
  end

  defp add_edges(ws, n) do
    suffix = System.unique_integer([:positive])

    for i <- 1..n do
      :ok =
        Graph.assert_edge("HydSrc#{suffix}-#{i}", "HydDst#{suffix}-#{i}", "hydrates",
          workspace_id: ws
        )
    end
  end

  defp edge_total do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM edges", [])
    n
  end

  test "without a limit every edge after the starting id is loaded", %{ws: ws} do
    add_edges(ws, 5)
    {:ok, [[max_id]]} = Store.raw_query("SELECT MAX(id) FROM edges", [])

    {:ok, store} = Knowledge.open("hyd-all-#{ws}", backend: Backend.ETS)
    assert {:ok, 5} = Graph.hydrate_triple_store(store, workspace_id: ws, batch_size: 2)
    assert {:ok, 2} = Graph.hydrate_triple_store(store, after_id: max_id - 2, batch_size: 1)
    :ok = Knowledge.close(store)
  end

  test "an in-memory store is loaded in full every time", %{ws: ws} do
    add_edges(ws, 3)
    total = edge_total()

    {:ok, store} = Knowledge.open("hyd-ets-#{ws}", backend: Backend.ETS)
    assert {:ok, %{loaded: ^total}} = Hydration.run(store, Backend.ETS, [])
    assert {:ok, %{loaded: ^total}} = Hydration.run(store, Backend.ETS, [])
    :ok = Knowledge.close(store)
  end

  @tag :rocksdb
  test "a persistent store loads in full once, then only the new edges", %{tmp: tmp, ws: ws} do
    add_edges(ws, 3)
    path = Path.join(tmp, "knowledge-rocksdb")
    opts = [path: path]

    {:ok, store} = Knowledge.open("hyd-rocks-#{ws}", backend: Backend.RocksDB, backend_opts: opts)

    total = edge_total()
    assert {:ok, %{loaded: ^total}} = Hydration.run(store, Backend.RocksDB, opts)

    add_edges(ws, 2)
    assert {:ok, %{loaded: 2}} = Hydration.run(store, Backend.RocksDB, opts)
    assert {:ok, %{loaded: 0}} = Hydration.run(store, Backend.RocksDB, opts)

    # Without its marker the store cannot know what it holds: load in full.
    File.rm!(Hydration.marker_path(opts))
    assert {:ok, %{loaded: loaded}} = Hydration.run(store, Backend.RocksDB, opts)
    assert loaded == edge_total()

    # A marker past the newest edge means the database went backwards (a
    # restore): load in full rather than skip edges.
    File.write!(Hydration.marker_path(opts), Integer.to_string(1_000_000_000))
    assert {:ok, %{loaded: again}} = Hydration.run(store, Backend.RocksDB, opts)
    assert again == edge_total()

    :ok = Knowledge.close(store)
  end
end
