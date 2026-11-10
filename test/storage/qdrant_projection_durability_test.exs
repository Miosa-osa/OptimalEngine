defmodule OptimalEngine.Storage.QdrantProjectionDurabilityTest do
  @moduledoc """
  Removals from the Qdrant projection are durable and never on the request
  path: a removal Qdrant refused is recorded and retried until it succeeds,
  an erasure fails closed (never crashes) when Qdrant is slow, an archived
  workspace never comes back through a sync, and a workspace marked dirty is
  always repaired by a job.
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
  alias OptimalEngine.{Maintenance, Organization, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @env ~w(OPTIMAL_QDRANT_URL OPTIMAL_QDRANT_API_KEY OPTIMAL_QDRANT_SERVING OPTIMAL_QDRANT_COLLECTION_PREFIX)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    settings = Application.get_env(:optimal_engine, :qdrant_projection)
    Enum.each(@env, &System.delete_env/1)
    Projection.reset()
    {:ok, _} = Store.raw_query("DELETE FROM qdrant_pending_removals", [])

    {:ok, stub} = QdrantStub.start()
    System.put_env("OPTIMAL_QDRANT_URL", stub.endpoint)

    on_exit(fn ->
      QdrantStub.stop(stub)

      if settings,
        do: Application.put_env(:optimal_engine, :qdrant_projection, settings),
        else: Application.delete_env(:optimal_engine, :qdrant_projection)

      Projection.reset()
      Store.raw_query("DELETE FROM qdrant_pending_removals", [])

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    n = System.unique_integer([:positive])
    tenant = "qdur-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Qdrant durability"})
    org = "#{tenant}:org"
    {:ok, _} = Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})
    {:ok, ws} = Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "v", name: "V"})

    %{stub: stub, n: n, ws: ws.id, tenant: tenant}
  end

  defp put_setting(key, value) do
    current = Application.get_env(:optimal_engine, :qdrant_projection, [])
    Application.put_env(:optimal_engine, :qdrant_projection, Keyword.put(current, key, value))
  end

  defp pts(ctx, kind, dims) do
    :ok = Projection.flush()
    QdrantStub.points(ctx.stub, Projection.collection(kind, dims))
  end

  defp pending do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM qdrant_pending_removals", [])
    n
  end

  describe "an archived workspace" do
    test "is neither re-uploaded by a sync nor kept by the orphan sweep", ctx do
      a = context!("qdarch#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      assert map_size(pts(ctx, :contexts, 2)) == 1

      :ok = Workspace.archive(ctx.ws) |> archived()
      assert pts(ctx, :contexts, 2) == %{}

      assert {:ok, %{upserted: 0, next: nil}} = Sync.run(workspace_id: ctx.ws)
      # A sync of every workspace mirrors the others' rows, never this one's.
      assert {:ok, %{next: nil}} = Sync.run()

      refute Enum.any?(
               Map.values(pts(ctx, :contexts, 2)),
               &(&1["payload"]["workspace_id"] == ctx.ws)
             )

      # A point left from before the archive (its removal never ran): the
      # sweep takes it, though its row still exists.
      collection = Projection.collection(:contexts, 2)
      [{_dims, point}] = Projection.point(:contexts, [a.id, blob([1.0, 0.0]), ctx.tenant, ctx.ws])

      QdrantStub.put_point(ctx.stub, collection, %{
        "id" => point.id,
        "vector" => point.vector,
        "payload" => point.payload
      })

      assert {:ok, %{deleted: 1}} = Sync.run(workspace_id: ctx.ws)

      refute Enum.any?(
               Map.values(pts(ctx, :contexts, 2)),
               &(&1["payload"]["workspace_id"] == ctx.ws)
             )
    end
  end

  describe "a removal Qdrant refuses" do
    test "is recorded, and the sync retries it until it succeeds", ctx do
      a = context!("qdrm#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      assert map_size(pts(ctx, :contexts, 2)) == 1

      QdrantStub.set_fail(ctx.stub, :points)
      :ok = Vectors.delete(a.id)
      :ok = Projection.flush()
      assert pending() == 1
      assert map_size(QdrantStub.points(ctx.stub, Projection.collection(:contexts, 2))) == 1

      # Still refused: the sync fails, and the record stays.
      assert {:error, {:qdrant_unavailable, _}} = Sync.run(workspace_id: ctx.ws)
      assert pending() == 1

      QdrantStub.set_fail(ctx.stub, nil)
      Projection.reset_health()
      assert {:ok, %{next: nil}} = Sync.run(workspace_id: ctx.ws)
      assert pending() == 0
      assert pts(ctx, :contexts, 2) == %{}
    end

    test "is retried on its own, without a sync", ctx do
      put_setting(:retry_interval_ms, 50)
      {:ok, m} = Versioned.create(%{content: "retry #{ctx.n}", workspace_id: ctx.ws})
      :ok = MemoryEmbeddings.put(m, [1.0, 0.0], model: "m")
      assert map_size(pts(ctx, :memories, 2)) == 1

      QdrantStub.set_fail(ctx.stub, :points)
      :ok = Versioned.forget(m.id)
      :ok = Projection.flush()
      assert pending() == 1

      QdrantStub.set_fail(ctx.stub, nil)
      Projection.reset_health()
      assert eventually(fn -> pending() == 0 end)
      assert pts(ctx, :memories, 2) == %{}
    end

    test "for an archived workspace, and for a memory delete and a superseded version", ctx do
      {:ok, m} = Versioned.create(%{content: "del #{ctx.n}", workspace_id: ctx.ws})
      :ok = MemoryEmbeddings.put(m, [1.0, 0.0], model: "m")
      a = context!("qdrw#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()

      QdrantStub.set_fail(ctx.stub, :points)
      :ok = Versioned.delete(m.id)
      :ok = Workspace.archive(ctx.ws) |> archived()
      :ok = Projection.flush()
      assert pending() >= 2

      QdrantStub.set_fail(ctx.stub, nil)
      Projection.reset_health()
      :ok = Projection.retry_pending()
      assert pending() == 0
      assert pts(ctx, :memories, 2) == %{}
      assert pts(ctx, :contexts, 2) == %{}
    end

    test "remove_memory/1 is durable: the memory's points go once Qdrant answers", ctx do
      {:ok, m} = Versioned.create(%{content: "hard #{ctx.n}", workspace_id: ctx.ws})
      :ok = MemoryEmbeddings.put(m, [1.0, 0.0], model: "m")
      :ok = MemoryEmbeddings.put(m, [0.0, 1.0], model: "m2")
      :ok = Projection.flush()

      # The rows go first, as a hard erasure deletes them.
      {:ok, _} = Store.raw_query("DELETE FROM memory_embeddings WHERE memory_id = ?1", [m.id])
      QdrantStub.set_fail(ctx.stub, :points)
      assert :ok = Projection.remove_memory(m.id)
      :ok = Projection.flush()
      assert pending() == 1

      QdrantStub.set_fail(ctx.stub, nil)
      Projection.reset_health()
      :ok = Projection.retry_pending()
      assert pts(ctx, :memories, 2) == %{}
      assert pending() == 0
    end
  end

  describe "the request path" do
    test "a delete returns at once while Qdrant is slow", ctx do
      a = context!("qdslow#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()
      QdrantStub.set_delay(ctx.stub, 400)

      {elapsed, :ok} = :timer.tc(fn -> Vectors.delete(a.id) end)
      assert elapsed < 200_000
    end

    test "an erasure that times out fails closed and does not crash", ctx do
      put_setting(:timeout, 150)
      a = context!("qdto#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()
      QdrantStub.set_delay(ctx.stub, 600)

      assert {:error, {:qdrant_delete_failed, _}} = DerivedData.delete_derived([a.id])
      assert {:ok, _} = Vectors.get(a.id)
    end

    test "an erasure deletes again after its commit, catching a mirror that raced it", ctx do
      a = context!("qdrace#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()
      QdrantStub.clear_requests(ctx.stub)

      assert {:ok, _} = DerivedData.delete_derived([a.id])
      :ok = Projection.flush()

      deletes =
        Enum.count(QdrantStub.requests(ctx.stub), fn {method, path} ->
          method == "POST" and
            path == "/collections/#{Projection.collection(:contexts, 2)}/points/delete"
        end)

      assert deletes >= 2
      assert pending() == 0
    end

    test "a mirror past the queue limit is dropped and its workspace marked dirty", ctx do
      put_setting(:max_queue, 0)
      a = context!("qdover#{ctx.n}", ctx.ws)
      QdrantStub.set_delay(ctx.stub, 400)

      {elapsed, :ok} = :timer.tc(fn -> Vectors.store(a.id, [1.0, 0.0], workspace_id: ctx.ws) end)
      assert elapsed < 200_000
      assert Projection.dirty?(ctx.ws)
      assert {:ok, %{kind: "maintenance.qdrant_sync"}} = Maintenance.active(:qdrant_sync, ctx.ws)
    end
  end

  describe "dirty marks" do
    test "a mark made while a sync runs gets a follow-up job", ctx do
      started = Projection.stamp() - 1_000
      :ok = Projection.mark_dirty(ctx.ws)
      {:ok, _} = Maintenance.active(:qdrant_sync, ctx.ws)

      job = %{
        kind: Maintenance.kind(:qdrant_sync),
        workspace_id: ctx.ws,
        tenant_id: ctx.tenant,
        payload: %{"after" => %{"phase" => "contexts", "started" => started}}
      }

      assert {:continue, payload, _result} = Maintenance.perform(job, pause_ms: 0)
      refute Map.has_key?(payload, "after")
      assert Projection.dirty?(ctx.ws)
    end

    test "the all-workspaces mark marks each active workspace and queues its job", ctx do
      :ok = Projection.mark_dirty(:all)
      assert Projection.dirty?(ctx.ws)
      assert {:ok, %{kind: "maintenance.qdrant_sync"}} = Maintenance.active(:qdrant_sync, ctx.ws)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  defp blob(values), do: for(v <- values, into: <<>>, do: <<v::float-little-32>>)

  defp archived(:ok), do: :ok
  defp archived({:error, {:cache_purge_failed, _}}), do: :ok

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
