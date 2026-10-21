defmodule OptimalEngine.API.ActivePoolOwnershipTest do
  @moduledoc """
  A pool id names a row, and the row names its tenant and workspace. Every
  `/api/memory-core/active-pools/:id` route answers 404 for a pool the caller's
  tenant or workspace scope does not cover, exactly as for one that does not
  exist, and leaves that pool untouched.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.MemoryCore
  alias OptimalEngine.MemoryCore.ActiveMemoryPool
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  # Close is last: a closed pool refuses the routes after it.
  @routes [
    {:get, "", nil},
    {:post, "/retrieve", %{"query" => "launch"}},
    {:post, "/refresh-context", %{}},
    {:post, "/observations",
     %{
       "observation" => "An observation that must not land.",
       "claim_text" => "A claim that must not land.",
       "subject_anchor" => "pool_ownership",
       "action_class" => "observed",
       "object_anchor" => "pool"
     }},
    {:post, "/close", %{"reason" => "ownership test"}}
  ]

  setup do
    suffix = System.unique_integer([:positive])

    foreign_tenant = "pooltenant-#{suffix}"
    {:ok, _} = Tenant.create(%{id: foreign_tenant, name: "Pool tenant #{suffix}"})

    ws_a = insert_workspace("default:pool-a-#{suffix}", "default", "pool-a-#{suffix}")
    ws_b = insert_workspace("default:pool-b-#{suffix}", "default", "pool-b-#{suffix}")
    ws_f = insert_workspace("#{foreign_tenant}:pool-f", foreign_tenant, "pool-f")

    {:ok,
     suffix: suffix,
     foreign_tenant: foreign_tenant,
     ws_a: ws_a,
     ws_b: ws_b,
     ws_f: ws_f,
     pool_a: open_pool!("default", ws_a, "a-#{suffix}"),
     pool_b: open_pool!("default", ws_b, "b-#{suffix}"),
     pool_f: open_pool!(foreign_tenant, ws_f, "f-#{suffix}"),
     key_a: mint_key!("default", [ws_a]),
     key_all: mint_key!("default", ["*"]),
     key_f: mint_key!(foreign_tenant, ["*"])}
  end

  describe "a pool the caller may use" do
    test "a key scoped to the pool's workspace uses it on every route without naming it", ctx do
      for {method, suffix, body} <- @routes do
        conn = call(method, ctx.pool_a, suffix, ctx.key_a, body)
        assert conn.status == 200, "#{method} #{suffix} answered #{conn.status}"
      end
    end

    test "naming the pool's own workspace is fine", ctx do
      conn = call(:get, ctx.pool_a, "?workspace=#{ctx.ws_a}", ctx.key_all, nil)
      assert conn.status == 200
    end

    test "retrieve recalls in the pool's workspace when the body names none", ctx do
      conn = call(:post, ctx.pool_a, "/retrieve", ctx.key_a, %{"query" => "launch"})

      assert conn.status == 200
      package = Jason.decode!(conn.resp_body)["context_package"]
      assert package["workspace_id"] == ctx.ws_a
      assert package["tenant_id"] == "default"
    end

    test "a caller with no key is the default tenant's local operator", ctx do
      assert call(:get, ctx.pool_a, "", nil, nil).status == 200
      assert call(:get, ctx.pool_f, "", nil, nil).status == 404
    end
  end

  describe "a pool the caller may not use answers 404 and stays untouched" do
    test "another workspace of the caller's tenant", ctx do
      assert_hidden(ctx.pool_b, ctx.key_a)
    end

    test "another tenant's pool, for a key of every workspace", ctx do
      assert_hidden(ctx.pool_f, ctx.key_all)
    end

    test "a pool of the default tenant, for another tenant's key", ctx do
      assert_hidden(ctx.pool_a, ctx.key_f)
    end

    test "a request that names another workspace than the pool's", ctx do
      for {method, suffix, body} <- @routes do
        {suffix, body} =
          case method do
            :get -> {"?workspace=#{ctx.ws_b}", nil}
            :post -> {suffix, Map.put(body, "workspace", ctx.ws_b)}
          end

        conn = call(method, ctx.pool_a, suffix, ctx.key_all, body)
        assert conn.status == 404, "#{method} #{suffix} answered #{conn.status}"
      end

      assert_untouched(ctx.pool_a)
    end

    test "an id that is no pool", ctx do
      for {method, suffix, body} <- @routes do
        conn = call(method, "amp_missing_#{ctx.suffix}", suffix, ctx.key_all, body)
        assert conn.status == 404
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp assert_hidden(pool_id, token) do
    for {method, suffix, body} <- @routes do
      conn = call(method, pool_id, suffix, token, body)
      assert conn.status == 404, "#{method} #{suffix} answered #{conn.status}"
      assert Jason.decode!(conn.resp_body) == %{"error" => "active pool not found"}
    end

    assert_untouched(pool_id)
  end

  defp assert_untouched(pool_id) do
    assert {:ok, pool} = ActiveMemoryPool.get(pool_id)
    assert pool.lifecycle_state == "open"
    assert pool.archive_state == "active"
    assert pool.context_package_links == []
    assert pool.promotion_candidate_links == []
    assert pool.source_package_links == []
  end

  defp open_pool!(tenant_id, workspace_id, label) do
    {:ok, pool} =
      MemoryCore.open_active_pool(
        tenant_id: tenant_id,
        workspace_id: workspace_id,
        task_type: "pool_ownership_#{label}"
      )

    pool.id
  end

  defp insert_workspace(id, tenant_id, slug) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, ?2, ?3, ?4, 'active', '{}')
        """,
        [id, tenant_id, slug, "WS #{slug}"]
      )

    id
  end

  defp mint_key!(tenant_id, workspace_scope) do
    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: tenant_id,
        name: "pool ownership #{System.unique_integer([:positive])}",
        scopes: ["read", "write"],
        workspace_scope: workspace_scope
      })

    token
  end

  defp call(method, pool_id, suffix, token, body) do
    path = "/api/memory-core/active-pools/#{pool_id}#{suffix}"

    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    if token do
      conn = put_req_header(conn, "authorization", "Bearer " <> token)
      with_auth_required(fn -> Router.call(conn, @opts) end)
    else
      Router.call(conn, @opts)
    end
  end

  # A keyed call is made with authentication on, as in production; a call with
  # no key is the local operator's, made with it off.
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
