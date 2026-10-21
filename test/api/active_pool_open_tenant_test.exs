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
    body = if token, do: Map.put(body, "workspace", ctx.workspace), else: body

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
