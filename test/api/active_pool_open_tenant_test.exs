defmodule OptimalEngine.API.ActivePoolOpenTenantTest do
  @moduledoc """
  `POST /api/memory-core/active-pools` opens a pool in the caller's tenant: the
  key's, or `default` for a caller with no key. A tenant named in the body or
  the query never chooses another one; naming a different tenant is refused as
  it is for every keyed route (`403 tenant_scope_denied`).
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    suffix = System.unique_integer([:positive])
    other_tenant = "pooltenant-#{suffix}"
    {:ok, _} = Tenant.create(%{id: other_tenant, name: "Pool tenant #{suffix}"})

    {:ok, _} =
      Store.raw_query(
        """
        INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, ?2, 'pool-open', 'Pool open', 'active', '{}')
        """,
        ["#{other_tenant}:pool-open", other_tenant]
      )

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: other_tenant,
        name: "pool open #{suffix}",
        scopes: ["read", "write"],
        workspace_scope: ["*"]
      })

    {:ok,
     suffix: suffix,
     other_tenant: other_tenant,
     workspace: "#{other_tenant}:pool-open",
     token: token,
     task_type: "open_tenant_#{suffix}"}
  end

  describe "a caller with no key" do
    test "opens the pool in the default tenant", ctx do
      conn = open(nil, ctx, %{})

      assert conn.status == 200
      assert pool(conn)["tenant_id"] == "default"
      assert pool_tenants(ctx.task_type) == ["default"]
    end

    test "may name the default tenant", ctx do
      conn = open(nil, ctx, %{"tenant" => "default"})

      assert conn.status == 200
      assert pool(conn)["tenant_id"] == "default"
    end

    for field <- ["tenant", "tenant_id"] do
      test "is refused when the body names another tenant in #{field}", ctx do
        conn = open(nil, ctx, %{unquote(field) => ctx.other_tenant})

        assert conn.status == 403
        assert Jason.decode!(conn.resp_body) == %{"error" => "tenant_scope_denied"}
        assert pool_tenants(ctx.task_type) == []
      end
    end

    test "is refused when the query names another tenant", ctx do
      conn = open(nil, ctx, %{}, "?tenant=#{ctx.other_tenant}")

      assert conn.status == 403
      assert pool_tenants(ctx.task_type) == []
    end

    test "gets the refusal as JSON", ctx do
      conn = open(nil, ctx, %{"tenant" => ctx.other_tenant})

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end
  end

  describe "the workspace the request names" do
    test "a caller with no key may not name a workspace of another tenant", ctx do
      conn = open(nil, ctx, %{"workspace" => ctx.workspace})

      assert conn.status == 404
      assert pool_workspaces(ctx.task_type) == []
    end

    test "a key of another tenant may not name the default workspace", ctx do
      conn = open(ctx.token, ctx, %{"workspace" => "default"})

      assert conn.status == 404
      assert pool_workspaces(ctx.task_type) == []
    end

    test "a key whose scope leaves the named workspace out is refused", ctx do
      other = "#{ctx.other_tenant}:pool-other"

      {:ok, _} =
        Store.raw_query(
          """
          INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name, status, metadata)
          VALUES (?1, ?2, 'pool-other', 'Pool other', 'active', '{}')
          """,
          [other, ctx.other_tenant]
        )

      {:ok, %{key: scoped}} =
        ApiKey.mint(%{
          tenant_id: ctx.other_tenant,
          name: "pool scoped #{ctx.suffix}",
          scopes: ["read", "write"],
          workspace_scope: [ctx.workspace]
        })

      conn = open(scoped, ctx, %{"workspace" => other})

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "workspace_scope_denied"}
      assert pool_workspaces(ctx.task_type) == []

      assert open(scoped, ctx, %{}).status == 200
      assert pool_workspaces(ctx.task_type) == [ctx.workspace]
    end

    test "a blank workspace names none: the default, for a caller with no key", ctx do
      for field <- ["workspace", "workspace_id"] do
        conn = open(nil, ctx, %{field => ""})

        assert conn.status == 200
        assert pool(conn)["workspace_id"] == "default"
      end

      assert pool_workspaces(ctx.task_type) == ["default", "default"]
    end

    test "a blank workspace is no workspace of a key of another tenant either", ctx do
      conn = open(ctx.token, ctx, %{"workspace" => ""})

      assert conn.status == 404
      assert pool_workspaces(ctx.task_type) == []
    end
  end

  describe "a keyed caller" do
    test "opens the pool in the key's tenant without naming it", ctx do
      conn = open(ctx.token, ctx, %{})

      assert conn.status == 200
      assert pool(conn)["tenant_id"] == ctx.other_tenant
      assert pool_tenants(ctx.task_type) == [ctx.other_tenant]
    end

    test "is refused when the body names another tenant", ctx do
      conn = open(ctx.token, ctx, %{"tenant" => "default"})

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "tenant_scope_denied"}
      assert pool_tenants(ctx.task_type) == []
    end
  end

  defp open(token, ctx, extra, query \\ "") do
    body = Map.merge(%{"task_type" => ctx.task_type}, extra)
    # A key of another tenant names a workspace of its own: `default` is not its.
    body = if token, do: Map.put_new(body, "workspace", ctx.workspace), else: body

    conn =
      conn(:post, "/api/memory-core/active-pools" <> query, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    if token do
      conn = put_req_header(conn, "authorization", "Bearer " <> token)
      with_auth_required(fn -> Router.call(conn, @opts) end)
    else
      Router.call(conn, @opts)
    end
  end

  defp pool(conn), do: Jason.decode!(conn.resp_body)["active_memory_pool"]

  # The workspaces of the pools opened with this task type.
  defp pool_workspaces(task_type) do
    {:ok, rows} =
      Store.raw_query("SELECT workspace_id FROM active_memory_pools WHERE task_type = ?1", [
        task_type
      ])

    rows |> List.flatten() |> Enum.sort()
  end

  # The tenants of the pools opened with this task type.
  defp pool_tenants(task_type) do
    {:ok, rows} =
      Store.raw_query("SELECT tenant_id FROM active_memory_pools WHERE task_type = ?1", [task_type])

    rows |> List.flatten() |> Enum.sort()
  end

  defp with_auth_required(fun) do
    original = Application.get_env(:optimal_engine, :auth, [])
    Application.put_env(:optimal_engine, :auth, Keyword.merge(original, auth_required: true))

    try do
      fun.()
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end
end
