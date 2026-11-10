defmodule OptimalEngine.Storage.QdrantProjectionTest do
  @moduledoc """
  With `OPTIMAL_QDRANT_URL` set, Qdrant is in the Engine's data path: every
  embedding written is mirrored with its workspace, deletes and erasures follow,
  a sync backfills and removes orphans idempotently, and vector search reads
  Qdrant while it holds the whole workspace, giving the same answer as the
  embedded vectors and falling back to them on any failure or difference.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.DerivedData
  alias OptimalEngine.Context
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Embeddings, as: MemoryEmbeddings
  alias OptimalEngine.Storage.Providers
  alias OptimalEngine.Storage.Qdrant.{Projection, Sync}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors
  alias OptimalEngine.TestSupport.QdrantStub
  alias OptimalEngine.{Maintenance, Organization, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @env ~w(OPTIMAL_QDRANT_URL OPTIMAL_QDRANT_API_KEY OPTIMAL_QDRANT_SERVING OPTIMAL_QDRANT_COLLECTION_PREFIX)

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
    %{stub: stub, n: n, ws: "qdrant-proj-#{n}", other: "qdrant-other-#{n}"}
  end

  describe "writes" do
    test "a stored vector is upserted with its workspace, under an id derived from its own", ctx do
      a = context!("qpa#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [0.6, 0.8, 0.0])

      points = pts(ctx, :contexts, 3)
      point = Map.fetch!(points, Projection.point_id(:contexts, a.id))

      assert point["payload"] == %{
               "engine_id" => Projection.engine_id(),
               "context_id" => a.id,
               "tenant_id" => "default",
               "workspace_id" => ctx.ws
             }

      assert_in_delta Enum.at(point["vector"], 1), 0.8, 1.0e-6

      # Storing again replaces the point; it does not add one.
      :ok = Vectors.store(a.id, [0.0, 1.0, 0.0])
      assert map_size(pts(ctx, :contexts, 3)) == 1

      :ok = Vectors.delete(a.id)
      assert pts(ctx, :contexts, 3) == %{}
    end

    test "chunk and memory embeddings are mirrored, and a deleted memory leaves", ctx do
      a = context!("qpc#{ctx.n}", ctx.ws)
      chunk!("qpchunk#{ctx.n}", a.id, ctx.ws)

      :ok =
        Store.insert_embeddings([
          %{
            chunk_id: "qpchunk#{ctx.n}",
            tenant_id: "default",
            workspace_id: ctx.ws,
            model: "test-model",
            modality: :text,
            dim: 2,
            vector: [1.0, 0.0]
          }
        ])

      [chunk] = Map.values(pts(ctx, :chunks, 2))

      assert %{"chunk_id" => "qpchunk" <> _, "context_id" => context_id, "scale" => "chunk"} =
               chunk["payload"]

      assert context_id == a.id

      {:ok, memory} = Versioned.create(%{content: "mirrored #{ctx.n}", workspace_id: ctx.ws})
      :ok = MemoryEmbeddings.put(memory, [0.0, 1.0], model: "test-model")

      [point] = Map.values(pts(ctx, :memories, 2))
      assert point["id"] == Projection.point_id(:memories, {memory.id, "test-model"})
      assert point["payload"]["memory_id"] == memory.id
      assert point["payload"]["workspace_id"] == ctx.ws

      :ok = Versioned.delete(memory.id)
      assert pts(ctx, :memories, 2) == %{}
    end

    test "nothing is sent when the projection is switched off", ctx do
      System.put_env("OPTIMAL_QDRANT_SERVING", "off")
      a = context!("qpoff#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])

      assert QdrantStub.requests(ctx.stub) == []
    end

    test "a Qdrant that fails never fails the canonical write", ctx do
      QdrantStub.set_fail(ctx.stub, :points)
      a = context!("qpfail#{ctx.n}", ctx.ws)

      assert :ok = Vectors.store(a.id, [1.0, 0.0])
      assert Vectors.get(a.id) == {:ok, [1.0, 0.0]}
      :ok = Projection.flush()
      assert Projection.status().counters.write_failures >= 1
    end

    test "an erasure removes the context's points and stops when Qdrant cannot", ctx do
      a = context!("qper#{ctx.n}", ctx.ws)
      b = context!("qper2#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Vectors.store(b.id, [0.0, 1.0])

      assert {:ok, _removed} = DerivedData.delete_derived([a.id])

      assert [%{"payload" => %{"context_id" => remaining}}] =
               Map.values(pts(ctx, :contexts, 2))

      assert remaining == b.id

      QdrantStub.set_fail(ctx.stub, :points)
      assert {:error, {:qdrant_delete_failed, _}} = DerivedData.delete_derived([b.id])
      # The canonical rows stay until the erasure can reach every copy.
      assert {:ok, _} = Vectors.get(b.id)
    end

    test "archiving a workspace removes its points and only its points", ctx do
      tenant = "qparch-t-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Archive tenant"})
      org = "#{tenant}:org"
      {:ok, _} = Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})
      {:ok, ws} = Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "a", name: "A"})

      a = context!("qparch#{ctx.n}", ws.id)
      b = context!("qparch2#{ctx.n}", ctx.other)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Vectors.store(b.id, [1.0, 0.0])

      :ok = Workspace.archive(ws.id) |> archived()

      assert [%{"payload" => %{"workspace_id" => other}}] =
               Map.values(pts(ctx, :contexts, 2))

      assert other == ctx.other
    end
  end

  describe "search" do
    test "reads Qdrant while it holds the workspace, with the embedded answer", ctx do
      ids = seed!(ctx, 6)
      query = [0.9, 0.1, 0.2]
      opts = [workspace_id: ctx.ws, limit: 4, min_similarity: 0.1]

      embedded = embedded(fn -> Vectors.search(query, opts) end)
      QdrantStub.clear_requests(ctx.stub)

      assert {:ok, served} = Vectors.search(query, opts)
      assert served == embedded
      assert length(served) == 4
      assert Enum.all?(served, fn {id, _} -> id in ids end)

      assert {"POST", "/collections/#{Projection.collection(:contexts, 3)}/points/search"} in QdrantStub.requests(
               ctx.stub
             )

      assert Projection.status().counters.searches_served == 1
    end

    test "type and node filters and the workspace decide, not Qdrant's payload", ctx do
      [first | _] = seed!(ctx, 4)
      incoming = context!("qpin#{ctx.n}", ctx.other)
      :ok = Vectors.store(incoming.id, [0.0, 0.0, 1.0])
      opts = [workspace_id: ctx.ws, limit: 10]

      # One context moves out and one moves in, without their vector rows: the
      # counts still agree, and Qdrant still has `first` in the workspace.
      {:ok, _} =
        Store.raw_query("UPDATE contexts SET workspace_id = ?1 WHERE id = ?2", [ctx.other, first])

      {:ok, _} =
        Store.raw_query("UPDATE contexts SET workspace_id = ?1 WHERE id = ?2", [
          ctx.ws,
          incoming.id
        ])

      :ok = Projection.flush()
      assert {:ok, served} = Vectors.search([1.0, 0.0, 0.0], opts)
      refute Enum.any?(served, fn {id, _} -> id == first end)
      assert length(served) == 3
      assert Projection.status().counters.searches_served == 1

      typed_opts = opts ++ [type_filter: "resource"]
      assert {:ok, typed} = Vectors.search([1.0, 0.0, 0.0], typed_opts)
      refute Enum.any?(typed, fn {id, _} -> id == first end)
      assert Enum.all?(typed, fn {id, _} -> id in elem(Enum.unzip(served), 0) end)
    end

    test "a context moved without its vector is a difference, read from the embedded vectors",
         ctx do
      [first | _] = seed!(ctx, 3)

      {:ok, _} =
        Store.raw_query("UPDATE contexts SET workspace_id = ?1 WHERE id = ?2", [ctx.other, first])

      opts = [workspace_id: ctx.ws, limit: 10]
      embedded = embedded(fn -> Vectors.search([1.0, 0.0, 0.0], opts) end)
      assert {:ok, ^embedded} = Vectors.search([1.0, 0.0, 0.0], opts)
      assert Projection.status().counters.drift == 1
    end

    test "falls back to the embedded vectors when the search fails", ctx do
      seed!(ctx, 3)
      opts = [workspace_id: ctx.ws, limit: 3]
      embedded = embedded(fn -> Vectors.search([1.0, 0.0, 0.0], opts) end)

      QdrantStub.set_fail(ctx.stub, :search)
      assert {:ok, ^embedded} = Vectors.search([1.0, 0.0, 0.0], opts)
      assert Projection.status().counters.searches_fallback >= 1
      assert Projection.status().health == "unreachable"
    end

    test "falls back and queues a sync when the counts differ", ctx do
      tenant = "qdrant-t-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Qdrant tenant"})
      org = "#{tenant}:org"
      {:ok, _} = Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

      {:ok, ws} =
        Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "vec", name: "Vec"})

      seed!(%{ctx | ws: ws.id}, 3)

      # A row whose mirror never happened: Qdrant holds one point fewer.
      lost = context!("qpdrift#{ctx.n}", ws.id)
      blob = for v <- [0.0, 0.0, 1.0], into: <<>>, do: <<v::float-little-32>>

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO vectors (context_id, embedding, dimensions, tenant_id, workspace_id) " <>
            "VALUES (?1, ?2, 3, ?3, ?4)",
          [lost.id, {:blob, blob}, tenant, ws.id]
        )

      opts = [workspace_id: ws.id, limit: 10]
      embedded = embedded(fn -> Vectors.search([1.0, 0.0, 0.0], opts) end)

      assert {:ok, ^embedded} = Vectors.search([1.0, 0.0, 0.0], opts)
      assert Projection.status().counters.drift == 1
      assert {:ok, %{kind: "maintenance.qdrant_sync"}} = Maintenance.active(:qdrant_sync, ws.id)

      # The job brings Qdrant level, and the next search reads it.
      assert {:ok, %{outcome: :completed}} =
               Maintenance.drain(workspace_id: ws.id, lease_owner: "qdrant-test", pause_ms: 0)

      assert {:ok, ^embedded} = Vectors.search([1.0, 0.0, 0.0], opts)
      assert Projection.status().counters.searches_served == 1
    end

    test "memory search reads Qdrant and keeps forgotten memories out", ctx do
      {:ok, keep} = Versioned.create(%{content: "kept #{ctx.n}", workspace_id: ctx.ws})
      {:ok, gone} = Versioned.create(%{content: "forgotten #{ctx.n}", workspace_id: ctx.ws})
      {:ok, other} = Versioned.create(%{content: "elsewhere #{ctx.n}", workspace_id: ctx.other})

      :ok = MemoryEmbeddings.put(keep, [1.0, 0.1], model: "m")
      :ok = MemoryEmbeddings.put(gone, [1.0, 0.0], model: "m")
      :ok = MemoryEmbeddings.put(other, [1.0, 0.0], model: "m")
      :ok = Versioned.forget(gone.id)

      opts = [workspace_id: ctx.ws, model: "m", limit: 5]
      :ok = Projection.flush()
      assert {:ok, [{found, score}]} = MemoryEmbeddings.search([1.0, 0.0], opts)
      assert found.id == keep.id
      assert Projection.status().counters.searches_served == 1

      assert embedded(fn -> MemoryEmbeddings.search([1.0, 0.0], opts) end) == [{found, score}]
    end
  end

  describe "sync" do
    test "backfills what was written before, idempotently, and removes orphans", ctx do
      System.put_env("OPTIMAL_QDRANT_SERVING", "off")
      ids = seed!(ctx, 5)
      {:ok, memory} = Versioned.create(%{content: "backfilled #{ctx.n}", workspace_id: ctx.ws})
      :ok = MemoryEmbeddings.put(memory, [0.5, 0.5], model: "m")
      System.delete_env("OPTIMAL_QDRANT_SERVING")
      assert QdrantStub.collections(ctx.stub) == %{}

      assert {:ok, %{upserted: 6, deleted: 0, next: nil}} =
               Sync.run(workspace_id: ctx.ws, limit: 2)
               |> loop()

      contexts = pts(ctx, :contexts, 3)

      assert contexts |> Map.values() |> Enum.map(& &1["payload"]["context_id"]) |> Enum.sort() ==
               Enum.sort(ids)

      assert map_size(pts(ctx, :memories, 2)) == 1

      # Again: the same points, none added.
      assert {:ok, %{upserted: 6, deleted: 0}} = loop(Sync.run(workspace_id: ctx.ws))
      assert pts(ctx, :contexts, 3) == contexts

      # A row gone without its point (a cascade the Engine did not follow).
      {:ok, _} = Store.raw_query("DELETE FROM vectors WHERE context_id = ?1", [hd(ids)])
      assert {:ok, %{deleted: 1}} = loop(Sync.run(workspace_id: ctx.ws))
      assert map_size(pts(ctx, :contexts, 3)) == 4
    end

    test "the mix task runs the sync and reports; without Qdrant it fails", ctx do
      System.put_env("OPTIMAL_QDRANT_SERVING", "off")
      seed!(ctx, 2)
      System.delete_env("OPTIMAL_QDRANT_SERVING")

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Mix.Tasks.Optimal.QdrantSync.main(["--workspace", ctx.ws, "--batch", "1"])
        end)

      assert out =~ "Done. Upserted: 2"
      assert map_size(pts(ctx, :contexts, 3)) == 2

      System.delete_env("OPTIMAL_QDRANT_URL")
      assert {:error, "the Qdrant projection is off" <> _} = Mix.Tasks.Optimal.QdrantSync.main([])
    end
  end

  describe "inventory" do
    test "qdrant is active while it serves, available when switched off" do
      assert {:ok, provider} = Providers.get("qdrant", probe: true)
      assert provider.lifecycle_state == "active"
      assert provider.data_path == "serving"
      assert provider.serves == ~w(embedding_projection vector_search memory_search)
      assert provider.serving.enabled
      assert provider.serving.collection_prefix == Projection.prefix()
      assert provider.serving.collection_prefix =~ ~r/^oe_[0-9a-f]+$/
      refute inspect(provider) =~ "127.0.0.1"

      System.put_env("OPTIMAL_QDRANT_SERVING", "off")

      assert {:ok, %{lifecycle_state: "available", data_path: "standby"}} =
               Providers.get("qdrant", probe: true)
    end
  end

  describe "collections" do
    test "the prefix names the collections, and an invalid one names none", ctx do
      System.put_env("OPTIMAL_QDRANT_COLLECTION_PREFIX", "engine-a")
      a = context!("qppre#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()
      assert Map.has_key?(QdrantStub.collections(ctx.stub), "engine-a_contexts_2")

      System.put_env("OPTIMAL_QDRANT_COLLECTION_PREFIX", "Bad Prefix/../")
      assert Projection.prefix() == nil
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp loop({:ok, %{next: nil}} = done), do: done

  defp loop({:ok, %{next: next} = result}) do
    {:ok, rest} = loop(Sync.run(workspace_id: result.workspace_id, after: next, limit: 2))

    {:ok,
     %{
       rest
       | upserted: rest.upserted + result.upserted,
         deleted: rest.deleted + result.deleted,
         skipped: rest.skipped + result.skipped
     }}
  end

  defp loop(other), do: other

  # What Qdrant holds of a kind, once every queued mirror has been applied.
  defp pts(ctx, kind, dims) do
    :ok = Projection.flush()
    QdrantStub.points(ctx.stub, Projection.collection(kind, dims))
  end

  # The embedded answer for the same call: the projection switched off.
  defp embedded(fun) do
    :ok = Projection.flush()
    System.put_env("OPTIMAL_QDRANT_SERVING", "off")

    try do
      case fun.() do
        {:ok, result} -> result
        other -> other
      end
    after
      System.delete_env("OPTIMAL_QDRANT_SERVING")
    end
  end

  defp archived(:ok), do: :ok
  defp archived({:error, {:cache_purge_failed, _}}), do: :ok

  # Contexts with three-dimensional vectors in the workspace, the first half of
  # type resource.
  defp seed!(ctx, count) do
    for i <- 1..count do
      id = "qps#{ctx.n}x#{i}"
      type = if i <= div(count, 2), do: :resource, else: :signal
      context!(id, ctx.ws, type)
      :ok = Vectors.store(id, [1.0 - i * 0.1, i * 0.1, rem(i, 2) * 0.3])
      id
    end
    |> tap(fn _ -> :ok = Projection.flush() end)
  end

  defp context!(id, workspace_id, type \\ :signal) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      id: id,
      uri: "optimal://inbox/#{id}.md",
      type: type,
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

  defp chunk!(chunk_id, context_id, workspace_id) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO chunks (id, tenant_id, signal_id, scale, text, workspace_id)
        VALUES (?1, 'default', ?2, 'chunk', ?3, ?4)
        """,
        [chunk_id, context_id, context_id, workspace_id]
      )
  end
end
