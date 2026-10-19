defmodule OptimalEngine.API.WhoamiTest do
  @moduledoc """
  A client can read its own key metadata, whatever scopes it holds, so it can
  tell a workspace key from an operator key without calling an admin route.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "whoami-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Whoami #{n}"})
    %{tenant: tenant}
  end

  defp call(key \\ nil) do
    conn = conn(:get, "/api/auth/whoami")

    conn =
      if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn

    Router.call(conn, Router.init([]))
  end

  test "returns the caller's scopes and workspace scope, never the secret", %{tenant: tenant} do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "workspace",
        scopes: ["read", "write"],
        workspace_scope: ["ws-1"]
      })

    conn = call(key)
    assert conn.status == 200
    assert {:ok, body} = Jason.decode(conn.resp_body)

    assert body["authenticated"] == true
    assert body["scopes"] == ["read", "write"]
    assert body["workspace_scope"] == ["ws-1"]
    assert body["tenant_id"] == tenant
    refute conn.resp_body =~ key
  end

  test "a read-only key can still read its own metadata", %{tenant: tenant} do
    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "reader", scopes: ["read"], workspace_scope: ["*"]})

    conn = call(key)
    assert conn.status == 200
    assert {:ok, %{"scopes" => ["read"]}} = Jason.decode(conn.resp_body)
  end

  test "without a key it reports unauthenticated" do
    conn = call()
    assert conn.status == 200
    assert {:ok, %{"authenticated" => false}} = Jason.decode(conn.resp_body)
  end
end
