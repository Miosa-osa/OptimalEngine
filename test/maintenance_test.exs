defmodule OptimalEngine.MaintenanceTest do
  @moduledoc """
  Chunk embedding and graph backfills run as durable maintenance jobs: one
  active job per kind and workspace, continuations for long runs, retries
  and dead letters for failures, a deferral (not a failure) when the embedder
  is unavailable, a sweep that only runs while the embedder is healthy, and
  admin routes that stay in the caller's tenant.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Embed.ChunkBackfill
  alias OptimalEngine.{Jobs, Maintenance, MemoryCore, Store}
  alias OptimalEngine.MemoryCore.{AssociativeProjection, ScopeEnvelope}
  alias OptimalEngine.Pipeline.Decomposer.ChunkTree
  alias OptimalEngine.Pipeline.Embedder.Embedding
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  @chunk_kind "maintenance.chunk_embeddings"
  @graph_kind "maintenance.graph_backfill"
  @projection_kind "maintenance.association_projection"
  @actor "user:maintenance-test"

  setup do
    n = System.unique_integer([:positive])
    tenant = "maintenance-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Maintenance tenant"})
    org = "#{tenant}:org"

    {:ok, _} =
      OptimalEngine.Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, ws} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "notes", name: "Notes"})

    {:ok, quiet} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "quiet", name: "Quiet"})

    chunks = for i <- 1..3, do: chunk!(tenant, ws.id, "mnt-#{n}-#{i}", "Chunk #{i}")

    %{n: n, tenant: tenant, org: org, ws: ws.id, quiet: quiet.id, chunks: chunks}
  end

  describe "jobs" do
    test "a workspace has at most one active job of each kind", ctx do
      assert {:ok, first, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)
      assert first.kind == @chunk_kind
      assert {:ok, again, :active} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)
      assert again.id == first.id

      assert {:ok, graph, :queued} = Maintenance.enqueue(:graph_backfill, ctx.ws)
      assert graph.kind == @graph_kind
      assert {:ok, _, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.quiet)

      assert {:ok, %{outcome: :completed}} = drain(ctx.ws)
      assert {:ok, %{outcome: :completed}} = drain(ctx.ws)
      assert {:ok, next, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)
      refute next.id == first.id
    end

    test "an unregistered workspace gets no job" do
      assert {:error, :workspace_not_found} =
               Maintenance.enqueue(:chunk_embeddings, "no-such-workspace")
    end

    test "a chunk job embeds the workspace's missing chunks", ctx do
      {:ok, job, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)

      assert {:ok, %{job: done, outcome: :completed}} = drain(ctx.ws)
      assert done.id == job.id
      assert done.status == "completed"
      assert {:ok, %{missing: 0}} = ChunkBackfill.status(workspace_id: ctx.ws)
      assert {:ok, :idle} = drain(ctx.ws)
    end

    test "a long backlog continues in a new job from where it stopped", ctx do
      {:ok, job, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)

      assert {:ok, %{job: done, outcome: :continued, next_job_id: next_id}} =
               drain(ctx.ws, batch: 2)

      assert done.id == job.id
      assert done.status == "completed"
      assert {:ok, next} = Jobs.get(next_id, ctx.ws)
      assert next.payload == %{"after" => Enum.at(ctx.chunks, 1)}
      assert next.status == "available"
      assert {:ok, %{missing: 1}} = ChunkBackfill.status(workspace_id: ctx.ws)

      assert {:ok, %{job: %{id: ^next_id}, outcome: :completed}} = drain(ctx.ws, batch: 2)
      assert {:ok, %{missing: 0}} = ChunkBackfill.status(workspace_id: ctx.ws)
    end

    test "a limit in the payload caps the chunks the request embeds", ctx do
      {:ok, _job, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws, %{"limit" => 2})

      assert {:ok, %{outcome: :completed}} = drain(ctx.ws)
      assert {:ok, %{missing: 1}} = ChunkBackfill.status(workspace_id: ctx.ws)
      assert {:ok, nil} = Maintenance.active(:chunk_embeddings, ctx.ws)
    end

    test "an unhealthy embedder puts the job back without spending an attempt", ctx do
      {:ok, job, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)

      assert {:ok, %{job: deferred, outcome: :deferred}} =
               drain(ctx.ws, healthy?: fn -> false end, embed: fn _, _ -> flunk("embedded") end)

      assert deferred.id == job.id
      assert deferred.status == "available"
      assert deferred.attempts == 0
      assert deferred.last_error == "deferred: embedder unavailable"
      assert deferred.payload == %{"deferrals" => 1}
      assert deferred.run_at > job.run_at
      assert {:ok, []} = Jobs.dead_letters(ctx.ws)
      assert {:ok, %{missing: 3}} = ChunkBackfill.status(workspace_id: ctx.ws)

      # It waits out its delay, and stays the workspace's one active job.
      assert {:ok, :idle} = drain(ctx.ws)
      assert {:ok, ^deferred, :active} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)
    end

    test "an embedder that goes away mid-run defers the job too", ctx do
      {:ok, _job, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)
      embed = stub(fn _chunk -> :ollama_unavailable end)

      assert {:ok, %{job: deferred, outcome: :deferred}} = drain(ctx.ws, embed: embed)
      assert deferred.status == "available"
      assert deferred.attempts == 0
      assert {:ok, []} = Jobs.dead_letters(ctx.ws)
      assert {:ok, %{missing: 3}} = ChunkBackfill.status(workspace_id: ctx.ws)
    end

    test "deferrals stop at a cap, and then the job fails like any attempt", ctx do
      {:ok, job, :queued} =
        Maintenance.enqueue(:chunk_embeddings, ctx.ws, %{"deferrals" => 24}, max_attempts: 1)

      assert {:ok, %{job: dead, outcome: :dead}} = drain(ctx.ws, healthy?: fn -> false end)
      assert dead.id == job.id
      assert {:ok, [letter]} = Jobs.dead_letters(ctx.ws)
      assert letter.final_error =~ "embedder_unavailable_after_deferrals"
    end

    test "a failure retries with backoff, then dead-letters", ctx do
      raising = fn _tree, _opts -> raise "embedder crashed" end

      {:ok, job, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)
      assert {:ok, %{job: retry, outcome: :retry}} = drain(ctx.ws, embed: raising)
      assert retry.id == job.id
      assert retry.status == "available"
      assert retry.last_error =~ "embedder crashed"
      # The retry waits out its backoff.
      assert {:ok, :idle} = drain(ctx.ws)

      chunk!(ctx.tenant, ctx.quiet, "mnt-#{ctx.n}-quiet", "Quiet chunk")

      {:ok, last, :queued} =
        Maintenance.enqueue(:chunk_embeddings, ctx.quiet, %{}, max_attempts: 1)

      assert {:ok, %{job: dead, outcome: :dead}} = drain(ctx.quiet, embed: raising)
      assert dead.id == last.id
      assert {:ok, [letter]} = Jobs.dead_letters(ctx.quiet)
      assert letter.original_job_id == last.id
    end

    test "a graph job writes the workspace's edges", ctx do
      entity = "entity-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, node, entities, created_at) VALUES (?1, ?2, ?3, 'signal', 'Graph', 'Body', 'inbox', ?4, datetime('now'))",
          ["mnt-ctx-#{ctx.n}", ctx.tenant, ctx.ws, Jason.encode!([entity])]
        )

      {:ok, _job, :queued} = Maintenance.enqueue(:graph_backfill, ctx.ws, %{"claims" => false})
      assert {:ok, %{outcome: :completed}} = drain(ctx.ws)

      assert {:ok, [[1]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM graph_edges WHERE source_id = ?1 AND relation = 'mentioned_in' AND workspace_id = ?2",
                 [entity, ctx.ws]
               )
    end
  end

  describe "graph continuation" do
    test "a graph job that stops at its batch resumes from the context it reached", ctx do
      ids =
        for i <- 1..2 do
          id = "mnt-gctx-#{ctx.n}-#{i}"

          {:ok, _} =
            Store.raw_query(
              "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, node, entities, created_at) VALUES (?1, ?2, ?3, 'signal', 'Graph', 'Body', 'inbox', '[]', datetime('now'))",
              [id, ctx.tenant, ctx.ws]
            )

          id
        end

      {:ok, _job, :queued} = Maintenance.enqueue(:graph_backfill, ctx.ws)

      assert {:ok, %{outcome: :continued, next_job_id: next_id}} = drain(ctx.ws, batch: 1)
      assert {:ok, next} = Jobs.get(next_id, ctx.ws)
      [first | _] = ids

      assert next.payload == %{
               "after" => %{"phase" => "contexts", "id" => first},
               "carried" => %{"contexts" => 1, "claims" => 0, "failed_edges" => 0}
             }

      assert recorded_backfills(ctx.ws) == []

      assert {:ok, %{job: %{id: ^next_id}, outcome: :completed}} = drain(ctx.ws, batch: 5)

      assert {:ok, [[2]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM graph_edges WHERE relation = 'lives_in' AND workspace_id = ?1",
                 [ctx.ws]
               )

      # The last slice records the whole run, as one run over the workspace would.
      assert recorded_backfills(ctx.ws) == [[2, 0]]
    end

    test "a graph continuation an older Engine queued, with no counts, is not recorded", ctx do
      id = "mnt-gold-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, node, entities, created_at) VALUES (?1, ?2, ?3, 'signal', 'Graph', 'Body', 'inbox', '[]', datetime('now'))",
          [id, ctx.tenant, ctx.ws]
        )

      # Nothing tells this slice whether the slices before it wrote every edge.
      {:ok, _job, :queued} =
        Maintenance.enqueue(:graph_backfill, ctx.ws, %{
          "after" => %{"phase" => "contexts", "id" => ""}
        })

      assert {:ok, %{outcome: :completed}} = drain(ctx.ws, batch: 5)
      assert recorded_backfills(ctx.ws) == []
    end
  end

  describe "projection refresh" do
    test "a recall over a projection older than its sources queues one rebuild, which brings it up to date",
         ctx do
      first = "mntfirst#{ctx.n}"
      later = "mntlater#{ctx.n}"

      scope =
        ScopeEnvelope.resolve(%{tenant_id: ctx.tenant, workspace_id: ctx.ws, actor_id: @actor})

      # The first memory was written before the projection was built.
      memory!(ctx, "#{first} kickoff notes", "2026-01-01 00:00:00")
      assert {:ok, %{associations: built}} = AssociativeProjection.rebuild(scope)
      assert built > 0

      {:ok, _} =
        Store.raw_query("UPDATE memory_associations SET updated_at = ?2 WHERE workspace_id = ?1", [
          ctx.ws,
          "2026-01-02 00:00:00"
        ])

      refute AssociativeProjection.stale?(scope)
      assert {:ok, _package} = recall(ctx, first)
      assert {:ok, nil} = Maintenance.active(:association_projection, ctx.ws)

      memory!(ctx, "#{later} follow-up notes", "2026-06-01 00:00:00")
      assert AssociativeProjection.stale?(scope)
      assert {:ok, []} = AssociativeProjection.expand([later], scope)

      # The recall answers from the projection as it is and queues one rebuild.
      assert {:ok, _package} = recall(ctx, first)

      assert {:ok, %{id: job_id, kind: @projection_kind}} =
               Maintenance.active(:association_projection, ctx.ws)

      assert {:ok, _package} = recall(ctx, first)
      assert {:ok, %{id: ^job_id}} = Maintenance.active(:association_projection, ctx.ws)

      assert {:ok, %{job: %{id: ^job_id}, outcome: :completed}} = drain(ctx.ws)
      assert {:ok, [_ | _]} = AssociativeProjection.expand([later], scope)
      refute AssociativeProjection.stale?(scope)
      assert {:ok, nil} = Maintenance.active(:association_projection, ctx.ws)
    end
  end

  describe "sweep" do
    test "never runs while the embedder is unhealthy", ctx do
      assert {:ok, %{embedder: :unavailable, queued: [], active: []}} =
               Maintenance.sweep(tenant_id: ctx.tenant, healthy?: fn -> false end)

      assert {:ok, nil} = Maintenance.active(:chunk_embeddings, ctx.ws)
    end

    test "queues one low-priority chunk job for each workspace with missing chunks", ctx do
      assert {:ok, %{embedder: :healthy, queued: [ws], active: []}} =
               Maintenance.sweep(tenant_id: ctx.tenant, healthy?: fn -> true end)

      assert ws == ctx.ws
      assert {:ok, %{priority: priority}} = Maintenance.active(:chunk_embeddings, ctx.ws)
      assert priority < 0
      assert {:ok, nil} = Maintenance.active(:chunk_embeddings, ctx.quiet)

      assert {:ok, %{queued: [], active: [^ws]}} =
               Maintenance.sweep(tenant_id: ctx.tenant, healthy?: fn -> true end)

      assert {:ok, %{outcome: :completed}} = drain(ctx.ws)

      assert {:ok, %{queued: [], active: []}} =
               Maintenance.sweep(tenant_id: ctx.tenant, healthy?: fn -> true end)
    end

    test "skips workspaces that cannot hold a job, and counts nothing", ctx do
      legacy = "maint-legacy-#{ctx.n}"
      chunk!(ctx.tenant, legacy, "mnt-#{ctx.n}-legacy", "Legacy chunk")

      assert {:ok, %{queued: [ws], skipped: [^legacy]} = result} =
               Maintenance.sweep(tenant_id: ctx.tenant, healthy?: fn -> true end)

      assert ws == ctx.ws
      refute Map.has_key?(result, :missing)
    end
  end

  describe "prune" do
    test "deletes completed maintenance jobs older than the window and keeps the rest", ctx do
      {:ok, old, :queued} = Maintenance.enqueue(:graph_backfill, ctx.quiet)
      {:ok, %{outcome: :completed}} = drain(ctx.quiet)

      {:ok, _} =
        Store.raw_query(
          "UPDATE jobs SET completed_at = ?2 WHERE id = ?1",
          [old.id, days_ago(8)]
        )

      {:ok, recent, :queued} = Maintenance.enqueue(:graph_backfill, ctx.quiet)
      {:ok, %{outcome: :completed}} = drain(ctx.quiet)
      {:ok, queued, :queued} = Maintenance.enqueue(:chunk_embeddings, ctx.ws)

      assert {:ok, pruned} = Maintenance.prune(7)
      assert pruned >= 1
      assert {:error, :not_found} = Jobs.get(old.id, ctx.quiet)
      assert {:ok, %{status: "completed"}} = Jobs.get(recent.id, ctx.quiet)
      assert {:ok, %{status: "available"}} = Jobs.get(queued.id, ctx.ws)
    end
  end

  describe "routes" do
    setup ctx do
      admin = key!(ctx.tenant, ["*"], ["*"])
      reader = key!(ctx.tenant, ["read"], ["*"])
      scoped = key!(ctx.tenant, ["*"], [ctx.ws])

      n = ctx.n
      stranger_tenant = "maintenance-other-#{n}"
      {:ok, _} = Tenant.create(%{id: stranger_tenant, name: "Other tenant"})
      stranger = key!(stranger_tenant, ["*"], ["*"])

      previous = Application.get_env(:optimal_engine, :maintenance_embedder_probe)
      Application.put_env(:optimal_engine, :maintenance_embedder_probe, fn -> true end)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:optimal_engine, :maintenance_embedder_probe, previous),
          else: Application.delete_env(:optimal_engine, :maintenance_embedder_probe)
      end)

      %{admin: admin, reader: reader, scoped: scoped, stranger: stranger}
    end

    test "both POSTs take the workspace from the body or the query", ctx do
      graph = call(:post, "/api/maintenance/graph/backfill?workspace=#{ctx.ws}", ctx.admin, %{})
      assert graph.status == 202
      assert %{"workspace_id" => ws, "kind" => @graph_kind} = Jason.decode!(graph.resp_body)
      assert ws == ctx.ws

      chunks =
        call(:post, "/api/maintenance/embeddings?kind=chunks&workspace=#{ctx.ws}", ctx.admin, %{})

      assert chunks.status == 202
      assert %{"workspace_id" => ^ws, "kind" => @chunk_kind} = Jason.decode!(chunks.resp_body)
    end

    test "POST kind=chunks answers 503 while the embedder does not answer, and queues nothing",
         ctx do
      Application.put_env(:optimal_engine, :maintenance_embedder_probe, fn -> false end)

      refused =
        call(:post, "/api/maintenance/embeddings", ctx.admin, %{
          "kind" => "chunks",
          "workspace" => ctx.ws
        })

      assert refused.status == 503
      assert Jason.decode!(refused.resp_body) == %{"error" => "embedder unavailable"}
      assert {:ok, nil} = Maintenance.active(:chunk_embeddings, ctx.ws)
    end

    test "POST graph/backfill queues one job per workspace and needs admin", ctx do
      assert call(:post, "/api/maintenance/graph/backfill", ctx.reader, %{"workspace" => ctx.ws}).status ==
               403

      queued = call(:post, "/api/maintenance/graph/backfill", ctx.admin, %{"workspace" => ctx.ws})
      assert queued.status == 202

      assert %{"status" => "queued", "job_id" => job_id, "kind" => @graph_kind} =
               Jason.decode!(queued.resp_body)

      again = call(:post, "/api/maintenance/graph/backfill", ctx.admin, %{"workspace" => ctx.ws})
      assert again.status == 202

      assert %{"status" => "already_running", "job_id" => ^job_id, "job_status" => "available"} =
               Jason.decode!(again.resp_body)
    end

    test "another tenant's workspace and the implicit default of a non-default tenant are not found",
         ctx do
      for {method, path, body} <- [
            {:post, "/api/maintenance/graph/backfill", %{"workspace" => ctx.ws}},
            {:post, "/api/maintenance/embeddings", %{"kind" => "chunks", "workspace" => ctx.ws}}
          ] do
        assert call(method, path, ctx.stranger, body).status == 404
      end

      assert call(
               :get,
               "/api/maintenance/embeddings?kind=chunks&workspace=#{ctx.ws}",
               ctx.stranger,
               nil
             ).status ==
               404

      assert call(:post, "/api/maintenance/graph/backfill", ctx.admin, %{}).status == 404
      assert call(:get, "/api/maintenance/embeddings?kind=chunks", ctx.admin, nil).status == 404
      assert {:ok, nil} = Maintenance.active(:graph_backfill, ctx.ws)
    end

    test "a key limited to named workspaces must name one", ctx do
      for {method, path, body} <- [
            {:post, "/api/maintenance/graph/backfill", %{}},
            {:post, "/api/maintenance/embeddings", %{"kind" => "chunks"}},
            {:get, "/api/maintenance/embeddings?kind=chunks", nil}
          ] do
        refused = call(method, path, ctx.scoped, body)
        assert refused.status == 400
        assert Jason.decode!(refused.resp_body) == %{"error" => "workspace_required"}
      end

      named = call(:post, "/api/maintenance/graph/backfill", ctx.scoped, %{"workspace" => ctx.ws})
      assert named.status == 202
    end

    test "kind=chunks reports what is missing and queues the chunk job", ctx do
      status =
        call(:get, "/api/maintenance/embeddings?kind=chunks&workspace=#{ctx.ws}", ctx.admin, nil)

      assert status.status == 200

      assert %{"missing" => 3, "job" => nil, "scope" => %{"workspace_id" => ws}} =
               Jason.decode!(status.resp_body)

      assert ws == ctx.ws

      queued =
        call(:post, "/api/maintenance/embeddings", ctx.admin, %{
          "kind" => "chunks",
          "workspace" => ctx.ws,
          "limit" => 2
        })

      assert queued.status == 202
      assert %{"status" => "queued", "job_id" => job_id} = Jason.decode!(queued.resp_body)
      assert {:ok, %{payload: %{"limit" => 2}}} = Jobs.get(job_id, ctx.ws)

      status =
        call(:get, "/api/maintenance/embeddings?kind=chunks&workspace=#{ctx.ws}", ctx.admin, nil)

      assert %{"job" => %{"id" => ^job_id, "status" => "available"}} =
               Jason.decode!(status.resp_body)

      # Documents stay the default, as before.
      documents = call(:get, "/api/maintenance/embeddings?workspace=#{ctx.ws}", ctx.admin, nil)
      assert documents.status == 200
      refute Map.has_key?(Jason.decode!(documents.resp_body), "job")
    end

    test "an unknown kind is refused", ctx do
      assert call(:get, "/api/maintenance/embeddings?kind=pixels", ctx.admin, nil).status == 422

      assert call(:post, "/api/maintenance/embeddings", ctx.admin, %{"kind" => "pixels"}).status ==
               422
    end
  end

  # A timestamp in the form SQLite's datetime() writes, `days` ago.
  defp days_ago(days) do
    DateTime.utc_now() |> DateTime.add(-days * 86_400) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  # A durable memory, written and last changed at `at`.
  defp memory!(ctx, content, at) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO memories (id, tenant_id, workspace_id, content, root_memory_id, audience, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?1, 'default', ?5, ?5)",
        ["mnt-mem-#{System.unique_integer([:positive])}", ctx.tenant, ctx.ws, content, at]
      )
  end

  defp recall(ctx, query) do
    MemoryCore.retrieve(query,
      tenant_id: ctx.tenant,
      workspace_id: ctx.ws,
      actor_id: @actor,
      strategy: :reconstructive
    )
  end

  defp drain(workspace_id, opts \\ []) do
    Maintenance.drain(
      Keyword.merge(
        [
          workspace_id: workspace_id,
          lease_owner: "maintenance-test",
          healthy?: fn -> true end,
          embed: stub(),
          pause_ms: 0
        ],
        opts
      )
    )
  end

  defp stub(fail \\ fn _chunk -> nil end) do
    fn %ChunkTree{chunks: chunks}, _opts ->
      {ok, rejected} = Enum.split_with(chunks, &is_nil(fail.(&1)))

      embeddings =
        Enum.map(ok, fn chunk ->
          Embedding.new(
            chunk_id: chunk.id,
            tenant_id: chunk.tenant_id,
            model: "stub",
            modality: chunk.modality,
            vector: [0.0, 1.0, 0.0]
          )
        end)

      {:ok, embeddings, %{errors: Enum.map(rejected, &{&1.id, fail.(&1)})}}
    end
  end

  defp call(method, path, key, body) do
    conn =
      if body,
        do:
          Plug.Test.conn(method, path, Jason.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json"),
        else: Plug.Test.conn(method, path)

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> key)
    |> Router.call(Router.init([]))
  end

  defp key!(tenant, scopes, workspace_scope) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "maintenance",
        scopes: scopes,
        workspace_scope: workspace_scope
      })

    key
  end

  defp recorded_backfills(workspace) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT contexts, claims FROM graph_backfills WHERE workspace_id = ?1 ORDER BY id",
        [workspace]
      )

    rows
  end

  defp chunk!(tenant, workspace, id, text) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, modality, workspace_id) VALUES (?1, ?2, ?3, 'chunk', ?4, 'text', ?5)",
        [id, tenant, "signal-" <> id, text, workspace]
      )

    id
  end
end
