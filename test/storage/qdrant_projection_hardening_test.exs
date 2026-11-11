defmodule OptimalEngine.Storage.QdrantProjectionHardeningTest do
  @moduledoc """
  The Qdrant projection keeps no point a row no longer has and never loses one
  to another Engine: point ids name the Engine, removals are recorded in the
  transaction that deletes the rows (an erasure, a peer's delete, an archive),
  the gate notices an emptied or a drifted scope, and one removal that keeps
  failing, a dead job or an unhealthy spell never keeps a workspace stale.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Context
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Embeddings, as: MemoryEmbeddings
  alias OptimalEngine.Storage.Qdrant.{Projection, Removals, Sync}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors
  alias OptimalEngine.Sync, as: PeerSync
  alias OptimalEngine.Test.StoreDDL
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
    tenant = "qhard-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Qdrant hardening"})
    org = "#{tenant}:org"
    {:ok, _} = Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})
    {:ok, ws} = Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "h", name: "H"})

    %{stub: stub, n: n, ws: ws.id, tenant: tenant, org: org}
  end

  describe "point ids" do
    test "name the Engine: another Engine's point with the same row key is never overwritten",
         ctx do
      a = context!("qhid#{ctx.n}", ctx.ws)
      collection = Projection.collection(:contexts, 2)

      # What another Engine sharing the prefix wrote for the same (peer-synced) row.
      foreign = %{
        "id" => legacy_id("contexts\0#{a.id}"),
        "vector" => [0.0, 1.0],
        "payload" => %{
          "engine_id" => "rep_another_engine",
          "context_id" => a.id,
          "tenant_id" => ctx.tenant,
          "workspace_id" => ctx.ws
        }
      }

      QdrantStub.put_point(ctx.stub, collection, foreign)
      :ok = Vectors.store(a.id, [1.0, 0.0])

      points = pts(ctx, :contexts, 2)
      assert Map.has_key?(points, foreign["id"])
      assert points[foreign["id"]]["payload"]["engine_id"] == "rep_another_engine"
      assert map_size(points) == 2
    end

    test "a full sync re-mirrors this Engine's points under the new id and sweeps the old ones",
         ctx do
      a = context!("qhmig#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      collection = Projection.collection(:contexts, 2)
      [current] = Map.values(pts(ctx, :contexts, 2))

      # A point an earlier build wrote for the same row, under the id without the Engine.
      legacy = %{current | "id" => legacy_id("contexts\0#{a.id}")}
      QdrantStub.put_point(ctx.stub, collection, legacy)
      assert map_size(pts(ctx, :contexts, 2)) == 2

      assert {:ok, %{next: nil}} = Sync.run(workspace_id: ctx.ws)
      assert Map.keys(pts(ctx, :contexts, 2)) == [Projection.point_id(:contexts, a.id)]
    end
  end

  describe "an erasure whose removal cannot be recorded" do
    test "is not done at all: a forget leaves the memory as it was", ctx do
      {:ok, m} = Versioned.create(%{content: "keep #{ctx.n}", workspace_id: ctx.ws})
      :ok = MemoryEmbeddings.put(m, [1.0, 0.0], model: "m")
      :ok = Projection.flush()

      without_removals(fn ->
        assert {:error, {:memory_erasure_failed, :qdrant_removal, _}} = Versioned.forget(m.id)
      end)

      assert {:ok, [[content, 0]]} =
               Store.raw_query("SELECT content, is_forgotten FROM memories WHERE id = ?1", [m.id])

      assert content == "keep #{ctx.n}"
    end

    test "is not done at all: a hard delete leaves the rows, so a retry records it", ctx do
      {:ok, m} = Versioned.create(%{content: "del #{ctx.n}", workspace_id: ctx.ws})
      :ok = MemoryEmbeddings.put(m, [1.0, 0.0], model: "m")
      :ok = Projection.flush()

      without_removals(fn ->
        assert {:error, {:memory_erasure_failed, :qdrant_removal, _}} = Versioned.delete(m.id)
      end)

      assert {:ok, [[1]]} = Store.raw_query("SELECT COUNT(*) FROM memories WHERE id = ?1", [m.id])
      assert :ok = Versioned.delete(m.id)
      assert pts(ctx, :memories, 2) == %{}
    end
  end

  describe "deletes outside the Engine's own erasure" do
    test "a context a peer deleted leaves Qdrant, recorded in the apply's transaction", ctx do
      a = context!("qhpeer#{ctx.n}", ctx.ws, ctx.tenant)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      assert map_size(pts(ctx, :contexts, 2)) == 1
      {:ok, _} = PeerSync.enable(ctx.tenant, ctx.ws, "user:owner")

      QdrantStub.set_fail(ctx.stub, :points)

      delete = %{
        "id" => "mut_remote_#{System.unique_integer([:positive])}",
        "device_id" => "rep_remote",
        "entity_type" => "contexts",
        "entity_id" => a.id,
        "operation" => "delete",
        "occurred_at" => "2099-01-01T00:00:00.000",
        "payload" => %{"row" => %{"id" => a.id}, "blobs" => %{}}
      }

      assert {:ok, %{applied: 1}} = PeerSync.apply_changes(ctx.tenant, ctx.ws, [delete])
      :ok = Projection.flush()
      assert pending() >= 1

      QdrantStub.set_fail(ctx.stub, nil)
      Projection.reset_health()
      :ok = Projection.retry_pending()
      assert pts(ctx, :contexts, 2) == %{}
    end

    test "Store.delete_context removes the context's points", ctx do
      a = context!("qhdel#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      assert map_size(pts(ctx, :contexts, 2)) == 1

      assert :ok = Store.delete_context(a.id)
      assert pts(ctx, :contexts, 2) == %{}
    end
  end

  describe "an archive whose removal cannot be recorded" do
    test "fails, and the workspace stays active", ctx do
      without_removals(fn -> assert {:error, _} = Workspace.archive(ctx.ws) end)

      assert {:ok, [["active"]]} =
               Store.raw_query("SELECT status FROM workspaces WHERE id = ?1", [ctx.ws])
    end
  end

  describe "the gate" do
    test "a scope emptied behind the Engine's back queues a sync that removes its points", ctx do
      a = context!("qhempty#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      assert map_size(pts(ctx, :contexts, 2)) == 1

      {:ok, _} = Store.raw_query("DELETE FROM vectors WHERE context_id = ?1", [a.id])
      refute Projection.in_sync?(:contexts, %{workspace_id: ctx.ws})
      assert {:ok, %{kind: "maintenance.qdrant_sync"}} = Maintenance.active(:qdrant_sync, ctx.ws)
    end

    test "equal counts are verified by a sync once the workspace's verification is due", ctx do
      put_setting(:verify_interval_ms, 0)
      a = context!("qhver#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()

      Projection.in_sync?(:contexts, %{workspace_id: ctx.ws})
      assert {:ok, %{kind: "maintenance.qdrant_sync"}} = Maintenance.active(:qdrant_sync, ctx.ws)
    end
  end

  describe "health" do
    test "a search of a dimension Qdrant has no collection for falls back, and Qdrant stays healthy",
         ctx do
      a = context!("qh404#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()
      opts = [workspace_id: ctx.ws, limit: 3, min_similarity: 0.0]

      assert {:ok, _} = Vectors.search([1.0, 0.0], opts)
      assert {:ok, _} = Vectors.search([1.0, 0.0, 0.0], opts)
      assert Projection.status().health == "healthy"
    end

    test "a sync after an unhealthy spell runs once Qdrant answers its health check", ctx do
      a = context!("qhspell#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()

      Projection.mark_unhealthy(:econnrefused)
      assert {:ok, %{next: nil}} = Sync.run(workspace_id: ctx.ws)
    end
  end

  describe "a workspace that stays stale" do
    test "a dirty mark whose job is gone gets a new one from the retry timer", ctx do
      put_setting(:retry_interval_ms, 50)
      :ok = Projection.mark_dirty(ctx.ws)
      {:ok, job} = Maintenance.active(:qdrant_sync, ctx.ws)
      {:ok, _} = Store.raw_query("DELETE FROM jobs WHERE id = ?1", [job.id])
      assert {:ok, nil} = Maintenance.active(:qdrant_sync, ctx.ws)

      Projection.schedule_retry()
      assert eventually(fn -> match?({:ok, %{}}, Maintenance.active(:qdrant_sync, ctx.ws)) end)
    end

    test "a removal that keeps failing is dead-lettered and never blocks a sync", ctx do
      put_setting(:max_removal_attempts, 2)
      a = context!("qhdead#{ctx.n}", ctx.ws)
      :ok = Vectors.store(a.id, [1.0, 0.0])
      :ok = Projection.flush()

      # A record no Qdrant request can satisfy.
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO qdrant_pending_removals (id, kind, field, ids, attempts, created_at) " <>
            "VALUES ('qpr_bad#{ctx.n}', 'contexts', 'no_such_field', '[\"x\"]', 0, '2026-01-01T00:00:00Z')",
          []
        )

      assert {:ok, %{next: nil}} = Sync.run(workspace_id: ctx.ws)
      assert {:ok, %{next: nil}} = Sync.run(workspace_id: ctx.ws)
      assert Removals.pending_count() == 0
      assert Removals.dead_count() == 1
      assert Projection.status().dead_removals == 1
    end

    test "dropped mirrors of a workspace already dirty do not each queue a job", ctx do
      put_setting(:max_queue, 0)
      a = context!("qhdrop#{ctx.n}", ctx.ws)
      :ok = Projection.mirror(:contexts, [a.id], workspace_id: ctx.ws)
      {:ok, job} = Maintenance.active(:qdrant_sync, ctx.ws)
      {:ok, _} = Store.raw_query("DELETE FROM jobs WHERE id = ?1", [job.id])

      for _ <- 1..5, do: :ok = Projection.mirror(:contexts, [a.id], workspace_id: ctx.ws)
      assert Projection.dirty?(ctx.ws)
      assert {:ok, nil} = Maintenance.active(:qdrant_sync, ctx.ws)
    end

    test "chunk embeddings of two workspaces in one insert mark each workspace", ctx do
      {:ok, other} =
        Workspace.create(%{tenant_id: ctx.tenant, organization_id: ctx.org, slug: "h2", name: "H2"})

      put_setting(:max_queue, 0)

      rows =
        for {ws, i} <- [{ctx.ws, 1}, {other.id, 2}] do
          chunk = "qhch#{ctx.n}x#{i}"

          {:ok, _} =
            Store.raw_query(
              "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, workspace_id) " <>
                "VALUES (?1, ?2, ?3, 'chunk', 't', ?4)",
              [chunk, ctx.tenant, "ctx-#{chunk}", ws]
            )

          %{
            chunk_id: chunk,
            tenant_id: ctx.tenant,
            workspace_id: ws,
            model: "m",
            modality: :text,
            dim: 2,
            vector: [1.0, 0.0]
          }
        end

      :ok = Store.insert_embeddings(rows)
      assert Projection.dirty?(ctx.ws)
      assert Projection.dirty?(other.id)
    end
  end

  describe "identity" do
    test "a rotated replica id is noticed: the cached Engine id expires", _ctx do
      real = Projection.engine_id()
      Projection.store(:engine_id, System.monotonic_time(:millisecond) - 1, "rep_rotated_away")
      assert Projection.engine_id() == real
    end
  end

  describe "boot" do
    test "an invalid collection prefix with no Qdrant URL does not stop the projection", _ctx do
      System.delete_env("OPTIMAL_QDRANT_URL")
      System.put_env("OPTIMAL_QDRANT_COLLECTION_PREFIX", "Not A Prefix!")
      child = Projection

      try do
        :ok = Supervisor.terminate_child(OptimalEngine.Supervisor, child)
        assert {:ok, _pid} = Supervisor.restart_child(OptimalEngine.Supervisor, child)
        assert Projection.status().config_error == "invalid_prefix"
      after
        System.delete_env("OPTIMAL_QDRANT_COLLECTION_PREFIX")

        unless match?({:ok, _}, Supervisor.restart_child(OptimalEngine.Supervisor, child)) do
          Supervisor.terminate_child(OptimalEngine.Supervisor, child)
          {:ok, _} = Supervisor.restart_child(OptimalEngine.Supervisor, child)
        end
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # The point id an earlier build gave a row: no Engine in it.
  defp legacy_id(text) do
    <<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6, _::binary>> =
      :crypto.hash(:sha256, text)

    [a, b, c, d, e] |> Enum.map(&Base.encode16(&1, case: :lower)) |> Enum.join("-")
  end

  # Runs `fun` while no removal can be recorded: a trigger refuses every
  # insert into the records, on either store (`StoreDDL`).
  defp without_removals(fun) do
    StoreDDL.execute!(
      "CREATE TRIGGER qpr_refuse_insert BEFORE INSERT ON qdrant_pending_removals " <>
        "BEGIN SELECT RAISE(ABORT, 'removal refused by the test'); END"
    )

    try do
      fun.()
    after
      StoreDDL.execute!("DROP TRIGGER IF EXISTS qpr_refuse_insert")
    end
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

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  defp context!(id, workspace_id, tenant_id \\ nil) do
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
      tenant_id: tenant_id || "default",
      metadata: %{}
    }

    :ok = Store.insert_context(ctx)
    ctx
  end
end
