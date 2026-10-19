defmodule OptimalEngine.ReindexTest do
  @moduledoc """
  Reindex requests are durable jobs that coalesce while one is active, run
  through the indexer, and are admin-only over HTTP.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Jobs, Reindex, Store}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "reindex-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Reindex #{n}"})
    workspace = "#{tenant}:root"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'root', 'root', 'active', '{}')",
        [workspace, tenant]
      )

    previous = Application.get_env(:optimal_engine, :reindex_fun)

    Application.put_env(:optimal_engine, :reindex_fun, fn ->
      send(self(), :index_started)
      {:ok, :started}
    end)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_engine, :reindex_fun, previous)
      else
        Application.delete_env(:optimal_engine, :reindex_fun)
      end
    end)

    %{tenant: tenant, workspace: workspace}
  end

  test "repeated requests coalesce onto one active job", %{workspace: workspace} do
    assert {:ok, first, :queued} = Reindex.enqueue(workspace)
    assert first.kind == "reindex"
    assert first.status == "available"

    assert {:ok, second, :already_running} = Reindex.enqueue(workspace)
    assert second.id == first.id

    assert {:ok, jobs} = Jobs.list(workspace, status: "available")
    assert Enum.map(jobs, & &1.id) == [first.id]
  end

  test "draining runs the indexer once and completes the job", %{workspace: workspace} do
    {:ok, job, :queued} = Reindex.enqueue(workspace)

    # Scope the claim to this test's workspace: the production worker drains
    # every workspace, so an unscoped claim in a shared test database can take
    # a job another test enqueued.
    assert {:ok, completed} =
             Reindex.drain(lease_owner: "test-worker", workspace_id: workspace)

    assert completed.id == job.id
    assert completed.status == "completed"
    assert_received :index_started

    assert {:ok, :idle} = Reindex.drain(lease_owner: "test-worker", workspace_id: workspace)
  end

  test "a completed reindex does not block the next one", %{workspace: workspace} do
    {:ok, first, :queued} = Reindex.enqueue(workspace)
    {:ok, _} = Reindex.drain(lease_owner: "test-worker", workspace_id: workspace)

    assert {:ok, second, :queued} = Reindex.enqueue(workspace)
    refute second.id == first.id
  end

  test "an indexer that is already running counts as success" do
    previous = Application.get_env(:optimal_engine, :reindex_fun)
    Application.put_env(:optimal_engine, :reindex_fun, fn -> {:error, :already_running} end)
    on_exit(fn -> Application.put_env(:optimal_engine, :reindex_fun, previous) end)

    assert Reindex.perform(%{}) == :ok
  end

  describe "POST /api/reindex" do
    test "is admin only and returns the coalesced job", ctx do
      {:ok, %{key: root}} =
        ApiKey.mint(%{tenant_id: ctx.tenant, name: "r", scopes: ["*"], workspace_scope: ["*"]})

      {:ok, %{key: reader}} =
        ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "k",
          scopes: ["read"],
          workspace_scope: [ctx.workspace]
        })

      call = fn key, body ->
        conn(:post, "/api/reindex", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> key)
        |> Router.call(Router.init([]))
      end

      denied = call.(reader, %{"workspace" => ctx.workspace})
      assert denied.status == 403
      assert denied.resp_body =~ "permission_scope_denied"

      queued = call.(root, %{"workspace" => ctx.workspace})
      assert queued.status == 202
      assert {:ok, %{"status" => "queued", "job_id" => job_id}} = Jason.decode(queued.resp_body)

      again = call.(root, %{"workspace" => ctx.workspace})
      assert again.status == 202

      assert {:ok, %{"status" => "already_running", "job_id" => same_id}} =
               Jason.decode(again.resp_body)

      assert same_id == job_id
    end
  end
end
