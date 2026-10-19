defmodule OptimalEngine.API.AuthSelfTest do
  @moduledoc """
  `GET /api/auth/self` (and `/v1/auth/self`) tells a client which tenant,
  principal and workspaces the key it presents covers, so a misconfigured
  client sees its scope instead of an opaque 400, 403 or 404. Without a key
  on an Engine that does not require one, it describes the local operator.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    tenant = "self-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Self #{n}"})
    %{tenant: tenant, n: n}
  end

  defp call(path, key \\ nil) do
    conn = conn(:get, path)
    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    Router.call(conn, @opts)
  end

  defp mint(tenant, attrs) do
    {:ok, %{id: id, key: key}} =
      ApiKey.mint(Map.merge(%{tenant_id: tenant, name: "self-test"}, attrs))

    {id, key}
  end

  defp with_auth_required(fun) do
    original = Application.get_env(:optimal_engine, :auth, [])
    Application.put_env(:optimal_engine, :auth, Keyword.put(original, :auth_required, true))

    try do
      fun.()
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end

  test "a workspace key reads its own tenant, principal, scopes and workspace scope", ctx do
    workspace = "#{ctx.tenant}:sales"

    {:ok, _} =
      Principal.upsert(%{
        id: "agent:sales-#{ctx.n}",
        tenant_id: ctx.tenant,
        kind: :agent,
        display_name: "Sales agent"
      })

    {id, key} =
      mint(ctx.tenant, %{
        scopes: ["read", "write"],
        workspace_scope: [workspace],
        principal_id: "agent:sales-#{ctx.n}"
      })

    for path <- ["/api/auth/self", "/v1/auth/self"] do
      conn = call(path, key)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["authenticated"] == true
      assert body["key_id"] == id
      assert body["tenant_id"] == ctx.tenant
      assert body["principal_id"] == "agent:sales-#{ctx.n}"
      assert body["scopes"] == ["read", "write"]
      assert body["workspace_scope"] == [workspace]
      assert Map.has_key?(body, "expires_at")
      refute conn.resp_body =~ key
    end
  end

  test "a key without a principal acts as its key id", ctx do
    {id, key} = mint(ctx.tenant, %{scopes: ["read"], workspace_scope: ["*"]})

    body = call("/api/auth/self", key) |> Map.get(:resp_body) |> Jason.decode!()
    assert body["principal_id"] == "api_key:" <> id
  end

  test "a key restricted to named workspaces needs no workspace to call it", ctx do
    {_id, key} =
      mint(ctx.tenant, %{scopes: ["read"], workspace_scope: ["#{ctx.tenant}:only"]})

    assert call("/api/auth/self", key).status == 200
  end

  test "it needs the read scope", ctx do
    {_id, key} = mint(ctx.tenant, %{scopes: ["write"], workspace_scope: ["*"]})

    conn = call("/api/auth/self", key)
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "permission_scope_denied"
  end

  test "without a key on a local Engine it describes the local operator" do
    conn = call("/api/auth/self")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["authenticated"] == false
    assert body["key_id"] == nil
    assert body["tenant_id"] == "default"
    assert body["principal_id"] == OptimalEngine.API.Actor.local_operator()
    assert body["scopes"] == ["*"]
    assert body["workspace_scope"] == ["*"]
    assert body["expires_at"] == nil
  end

  test "without a key when auth is required it is 401" do
    with_auth_required(fn ->
      conn = call("/api/auth/self")
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "missing_api_key"
    end)
  end
end
