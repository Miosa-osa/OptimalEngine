defmodule OptimalEngine.Storage.QdrantProjectionIsolationTest do
  @moduledoc """
  What the Qdrant projection must never do: touch another Engine's points,
  serve a vector it failed to replace, keep a copy an erasure or a forget
  removed, or drift on rows it mirrors and does not count.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.DerivedData
  alias OptimalEngine.Context
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Embeddings, as: MemoryEmbeddings
  alias OptimalEngine.Storage.Qdrant.{Projection, Sync}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors
  alias OptimalEngine.TestSupport.QdrantStub

  @env ~w(OPTIMAL_QDRANT_URL OPTIMAL_QDRANT_API_KEY OPTIMAL_QDRANT_SERVING OPTIMAL_QDRANT_COLLECTION_PREFIX)
  @other_engine "rep_000000000000000000000000"

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Projection.reset()

    {:ok, stub} = QdrantStub.start()
    System.put_env("OPTIMAL_QDRANT_URL", stub.endpoint)

    on_exit(fn ->
      QdrantStub.stop(stub)
      Projection.reset()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    n = System.unique_integer([:positive])
    %{stub: stub, n: n, ws: "qdrant-iso-#{n}"}
  end

  describe "identity" do
    test "the default prefix comes from this Engine's identity, not a shared name" do
      {:ok, [[replica]]} =
        Store.raw_query("SELECT replica_id FROM sync_identity WHERE id = 1", [])

      assert Projection.engine_id() == replica
      assert Projection.prefix() == "oe_" <> String.replace_prefix(replica, "rep_", "")
      refute Projection.prefix() == "optimal"
    end

    test "an invalid prefix is refused, never replaced", ctx do
      System.put_env("OPTIMAL_QDRANT_COLLECTION_PREFIX", "Bad Prefix/../")

      assert {:error, {:invalid_prefix, _}} = Projection.validate_config()
      refute Projection.enabled?()
      refute Projection.configured?()
      assert Projection.status().config_error == "invalid_prefix"

      assert_raise ArgumentError, ~r/OPTIMAL_QDRANT_COLLECTION_PREFIX/, fn ->
        Projection.init([])
      end

      a = context!("qiinv#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()
      assert QdrantStub.collections(ctx.stub) == %{}
    end

    test "every point carries the engine id", ctx do
      a = context!("qieng#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()

      [point] = Map.values(QdrantStub.points(ctx.stub, Projection.collection(:contexts, 2)))
      assert point["payload"]["engine_id"] == Projection.engine_id()
    end
  end

  describe "a shared prefix" do
    setup ctx do
      # Both Engines were given the same prefix: only the engine id tells them apart.
      System.put_env("OPTIMAL_QDRANT_COLLECTION_PREFIX", "shared")
      a = context!("qishare#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()
      collection = Projection.collection(:contexts, 2)

      foreign = %{
        "id" => "00000000-0000-0000-0000-00000000000b",
        "vector" => [1.0, 0.0],
        "payload" => %{
          "engine_id" => @other_engine,
          "context_id" => a.id,
          "tenant_id" => "default",
          "workspace_id" => ctx.ws
        }
      }

      QdrantStub.put_point(ctx.stub, collection, foreign)
      %{a: a, collection: collection, foreign: foreign["id"]}
    end

    test "another Engine's points survive this Engine's workspace removal and erasure", ctx do
      # The rows are gone (a finalized move), and this Engine removes the workspace.
      {:ok, _} = Store.raw_query("DELETE FROM vectors WHERE context_id = ?1", [ctx.a.id])
      :ok = Projection.remove_workspace(ctx.ws)
      :ok = Projection.flush()
      assert Map.keys(QdrantStub.points(ctx.stub, ctx.collection)) == [ctx.foreign]

      :ok = Vectors.store(ctx.a.id, [1.0, 0.0])
      assert {:ok, _} = DerivedData.delete_derived([ctx.a.id])
      :ok = Projection.flush()
      assert Map.keys(QdrantStub.points(ctx.stub, ctx.collection)) == [ctx.foreign]
    end

    test "the orphan sweep and the count never see another Engine's points", ctx do
      assert {:ok, 1} = Projection.remote_count(ctx.collection, %{workspace_id: ctx.ws})
      assert {:ok, %{deleted: 0, next: nil}} = Sync.run(workspace_id: ctx.ws)
      # The Engine-wide pass reads every workspace while async tests change
      # theirs, so it may sweep their orphans; never the other Engine's point.
      assert {:ok, %{next: nil}} = Sync.run()
      assert Map.has_key?(QdrantStub.points(ctx.stub, ctx.collection), ctx.foreign)
    end
  end

  describe "a re-embed during an outage" do
    test "a vector Qdrant could not replace is never searched there; a sync repairs it", ctx do
      a = context!("qire#{ctx.n}", ctx.ws)
      b = context!("qire2#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Vectors.store(b.id, [0.0, 1.0])
      :ok = Projection.flush()

      # Qdrant blips while `a` is re-embedded: the counts stay equal, and
      # Qdrant still holds `a` at its old vector.
      QdrantStub.set_fail(ctx.stub, :points)
      :ok = Vectors.store(a.id, [0.0, 1.0])
      :ok = Projection.flush()
      QdrantStub.set_fail(ctx.stub, nil)
      Projection.reset_health()

      assert Projection.dirty?(ctx.ws)

      # Both now match; a search served from the stale point would miss `a`.
      opts = [workspace_id: ctx.ws, limit: 5, min_similarity: 0.5]
      assert {:ok, hits} = Vectors.search([0.0, 1.0], opts)
      assert hits |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert Projection.status().counters.searches_served == 0

      assert {:ok, %{next: nil}} = Sync.run(workspace_id: ctx.ws)
      refute Projection.dirty?(ctx.ws)

      assert {:ok, ^hits} = Vectors.search([0.0, 1.0], opts)
      assert Projection.status().counters.searches_served == 1
    end
  end

  describe "erasure with serving off" do
    test "a context erasure still removes its points", ctx do
      a = context!("qierase#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()
      collection = Projection.collection(:contexts, 2)
      assert map_size(QdrantStub.points(ctx.stub, collection)) == 1

      System.put_env("OPTIMAL_QDRANT_SERVING", "off")
      assert {:ok, _} = DerivedData.delete_derived([a.id])
      assert QdrantStub.points(ctx.stub, collection) == %{}
    end

    test "a deleted or forgotten memory leaves Qdrant, serving or not", ctx do
      {:ok, kept} = Versioned.create(%{content: "kept #{ctx.n}", workspace_id: ctx.ws})
      {:ok, gone} = Versioned.create(%{content: "forgotten #{ctx.n}", workspace_id: ctx.ws})
      {:ok, dead} = Versioned.create(%{content: "deleted #{ctx.n}", workspace_id: ctx.ws})

      for m <- [kept, gone, dead], do: :ok = MemoryEmbeddings.put(m, [1.0, 0.0], model: "m")
      :ok = Projection.flush()
      collection = Projection.collection(:memories, 2)
      assert map_size(QdrantStub.points(ctx.stub, collection)) == 3

      System.put_env("OPTIMAL_QDRANT_SERVING", "off")
      :ok = Versioned.forget(gone.id)
      :ok = Versioned.delete(dead.id)
      :ok = Projection.flush()

      assert [%{"payload" => %{"memory_id" => left}}] =
               Map.values(QdrantStub.points(ctx.stub, collection))

      assert left == kept.id
    end
  end

  describe "rows mirrored are rows counted" do
    # Turns SQLite's foreign keys off on the Engine's own connection.
    @tag :sqlite_store
    test "a chunk embedding without its chunk row is not mirrored", ctx do
      # SQLite's foreign key keeps such a row out; a store without one does not.
      {:ok, _} = Store.raw_query("PRAGMA foreign_keys = OFF", [])

      try do
        :ok =
          Store.insert_embeddings([
            %{
              chunk_id: "qinochunk#{ctx.n}",
              tenant_id: "default",
              workspace_id: ctx.ws,
              model: "m",
              modality: :text,
              dim: 2,
              vector: [1.0, 0.0]
            }
          ])

        :ok = Projection.flush()
        assert QdrantStub.points(ctx.stub, Projection.collection(:chunks, 2)) == %{}
      after
        Store.raw_query("DELETE FROM chunk_embeddings WHERE chunk_id = ?1", ["qinochunk#{ctx.n}"])
        {:ok, _} = Store.raw_query("PRAGMA foreign_keys = ON", [])
      end
    end

    test "a row with no workspace is neither mirrored nor counted" do
      blob = <<1.0::float-little-32, 0.0::float-little-32>>
      assert Projection.point(:contexts, ["x", blob, "default", nil]) == []
      assert [{2, _}] = Projection.point(:contexts, ["x", blob, "default", "ws"])
    end

    test "a forgotten memory is not counted, so the counts agree and search reads Qdrant", ctx do
      {:ok, kept} = Versioned.create(%{content: "c kept #{ctx.n}", workspace_id: ctx.ws})
      {:ok, gone} = Versioned.create(%{content: "c gone #{ctx.n}", workspace_id: ctx.ws})
      :ok = MemoryEmbeddings.put(kept, [1.0, 0.0], model: "m")
      :ok = MemoryEmbeddings.put(gone, [1.0, 0.1], model: "m")
      :ok = Versioned.forget(gone.id)
      :ok = Projection.flush()

      assert {:ok, [{found, _}]} =
               MemoryEmbeddings.search([1.0, 0.0], workspace_id: ctx.ws, model: "m", limit: 5)

      assert found.id == kept.id
      assert Projection.status().counters.searches_served == 1
      assert Projection.status().counters.drift == 0
    end
  end

  describe "the write path" do
    test "a write returns before Qdrant answers; the mirror follows", ctx do
      a = context!("qiasync#{ctx.n}", ctx.ws)
      QdrantStub.set_delay(ctx.stub, 300)

      {elapsed, :ok} = :timer.tc(fn -> Vectors.store(a.id, [1.0, 0.0]) end)
      assert elapsed < 250_000

      :ok = Projection.flush()
      assert map_size(QdrantStub.points(ctx.stub, Projection.collection(:contexts, 2))) == 1
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp context!(id, workspace_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      id: id,
      uri: "optimal://inbox/#{id}.md",
      type: :signal,
      path: "/tmp/#{id}.md",
      title: id,
      content: id,
      l0_abstract: "SIGNAL | note | #{id}",
      l1_overview: id,
      signal: nil,
      node: "inbox",
      sn_ratio: 0.7,
      entities: [],
      created_at: now,
      modified_at: now,
      routed_to: [],
      workspace_id: workspace_id,
      metadata: %{}
    }

    :ok = Store.insert_context(ctx)
    ctx
  end
end
