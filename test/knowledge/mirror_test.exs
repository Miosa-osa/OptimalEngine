defmodule OptimalEngine.Knowledge.MirrorTest do
  @moduledoc """
  The triple store follows `graph_edges` whatever path changes an edge: a
  delete or a move that never goes through `Graph` is recorded by the
  triggers and applied by the default store, and a persistent store that
  cannot be trusted to hold only live edges is emptied before it opens.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Graph
  alias OptimalEngine.Knowledge
  alias OptimalEngine.Knowledge.Backend
  alias OptimalEngine.Knowledge.DefaultStore
  alias OptimalEngine.Knowledge.Hydration
  alias OptimalEngine.Knowledge.Mirror
  alias OptimalEngine.Knowledge.Store, as: KnowledgeStore
  alias OptimalEngine.Store
  alias OptimalEngine.TestSupport.TripleStore

  import TripleStore, only: [held?: 4]

  setup do
    TripleStore.wait_until_hydrated()
    n = System.unique_integer([:positive])
    %{n: n, ws: "mirror-ws-#{n}", other_ws: "mirror-other-#{n}"}
  end

  test "an edge deleted without Graph leaves the default store", %{n: n, ws: ws} do
    :ok = Graph.assert_edge("MirSrc#{n}", "MirDst#{n}", "mirrors", workspace_id: ws)
    assert held?(ws, "MirSrc#{n}", "mirrors", "MirDst#{n}")

    :ok =
      Store.raw_execute("DELETE FROM graph_edges WHERE workspace_id = ?1 AND source_id = ?2", [
        ws,
        "MirSrc#{n}"
      ])

    assert :ok = DefaultStore.drain()
    refute held?(ws, "MirSrc#{n}", "mirrors", "MirDst#{n}")
  end

  test "an edge moved to another workspace moves in the default store", ctx do
    %{n: n, ws: ws, other_ws: other_ws} = ctx
    :ok = Graph.assert_edge("MirMove#{n}", "MirTo#{n}", "mirrors", workspace_id: ws)

    :ok =
      Store.raw_execute(
        "UPDATE graph_edges SET workspace_id = ?1 WHERE workspace_id = ?2 AND source_id = ?3",
        [other_ws, ws, "MirMove#{n}"]
      )

    assert :ok = DefaultStore.drain()
    refute held?(ws, "MirMove#{n}", "mirrors", "MirTo#{n}")
    assert held?(other_ws, "MirMove#{n}", "mirrors", "MirTo#{n}")
  end

  test "a triple stays while another tenant's edge in the workspace holds it", %{n: n, ws: ws} do
    for tenant <- ["default", "mirror-tenant-#{n}"] do
      :ok =
        Graph.assert_edge("MirShared#{n}", "MirKept#{n}", "mirrors",
          workspace_id: ws,
          tenant_id: tenant
        )
    end

    delete = fn tenant ->
      :ok =
        Store.raw_execute(
          "DELETE FROM graph_edges WHERE tenant_id = ?1 AND workspace_id = ?2 AND source_id = ?3",
          [tenant, ws, "MirShared#{n}"]
        )
    end

    delete.("default")
    assert :ok = DefaultStore.drain()
    assert held?(ws, "MirShared#{n}", "mirrors", "MirKept#{n}")

    delete.("mirror-tenant-#{n}")
    assert :ok = DefaultStore.drain()
    refute held?(ws, "MirShared#{n}", "mirrors", "MirKept#{n}")
  end

  test "an update that keeps the edge's key records nothing", %{n: n, ws: ws} do
    :ok = Graph.assert_edge("MirWeight#{n}", "MirSame#{n}", "mirrors", workspace_id: ws)
    before = Mirror.newest_change()

    :ok =
      Store.raw_execute(
        "UPDATE graph_edges SET weight = 0.5 WHERE workspace_id = ?1 AND source_id = ?2",
        [ws, "MirWeight#{n}"]
      )

    {:ok, [[recorded]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM triple_mirror_changes WHERE id > ?1 AND subject = ?2",
        [before, "MirWeight#{n}"]
      )

    assert recorded == 0
  end

  test "installing the triggers twice leaves one of each" do
    assert :ok = Mirror.install()
    assert :ok = Mirror.install()

    {:ok, rows} =
      Store.raw_query(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'triple_mirror_%' ORDER BY name",
        []
      )

    assert rows == [["triple_mirror_edge_deleted"], ["triple_mirror_edge_moved"]]
  end

  defp store_with_stale_triple(opts, n) do
    {:ok, store} =
      Knowledge.open("mirror-rocks-#{n}", backend: Backend.RocksDB, backend_opts: opts)

    :ok = KnowledgeStore.assert(store, "mirror-ws", "MirStale#{n}", "mirrors", "Gone#{n}")
    :ok = Knowledge.close(store)
  end

  defp triple_count(opts, n) do
    {:ok, store} =
      Knowledge.open("mirror-rocks-count-#{n}", backend: Backend.RocksDB, backend_opts: opts)

    {:ok, count} = KnowledgeStore.count(store)
    :ok = Knowledge.close(store)
    count
  end

  describe "a persistent store" do
    @describetag :rocksdb

    setup %{n: n} do
      path = Path.join(System.tmp_dir!(), "mirror-rocksdb-#{n}")
      on_exit(fn -> File.rm_rf!(path) end)
      %{opts: [path: path]}
    end

    test "that never followed the changes is emptied before it opens", %{n: n, opts: opts} do
      store_with_stale_triple(opts, n)
      File.write!(Hydration.marker_path(opts), "0")

      assert Mirror.prepare(Backend.RocksDB, opts) == :empty
      assert triple_count(opts, n) == 0
      refute File.exists?(Hydration.marker_path(opts))
    end

    test "that follows the changes and has a marker keeps what it holds", %{n: n, opts: opts} do
      store_with_stale_triple(opts, n)
      File.write!(Hydration.marker_path(opts), "0")
      :ok = Mirror.mark_following(opts)

      assert Mirror.prepare(Backend.RocksDB, opts) == :kept
      assert triple_count(opts, n) == 1
    end

    test "that follows the changes but lost its marker is emptied", %{n: n, opts: opts} do
      store_with_stale_triple(opts, n)
      :ok = Mirror.mark_following(opts)

      assert Mirror.prepare(Backend.RocksDB, opts) == :empty
      assert triple_count(opts, n) == 0
      refute Mirror.following?(opts)
    end
  end
end
