defmodule OptimalEngine.API.TenantAPITest do
  @moduledoc """
  `POST /api/tenants` and `POST /api/tenants/:id/keys`: the operator makes a
  tenant per organization and mints keys in it, and nobody else can, nor can
  the route mint into a tenant it did not make.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  defp call(method, path, body, key \\ nil) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_peer_data(%{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil})

    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    conn = Router.call(conn, @opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp with_auth_required(fun) do
    original = Application.get_env(:optimal_engine, :auth, [])

    Application.put_env(
      :optimal_engine,
      :auth,
      Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
    )

    try do
      fun.()
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end

  defp key(tenant, scopes, workspaces \\ ["*"]) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "test", scopes: scopes, workspace_scope: workspaces})

    key
  end

  defp org_id, do: "org-#{System.unique_integer([:positive])}"

  describe "trusted local caller (authentication not required)" do
    test "creates an organization's tenant, answers it again, and mints a key that works in it" do
      id = org_id()

      assert {201, %{"id" => ^id, "name" => "Agency", "organization_id" => org}} =
               call(:post, "/api/tenants", %{"id" => id, "name" => "Agency"})

      assert org == id <> ":org"
      assert {:ok, %Tenant{metadata: %{"created_via" => "api"}}} = Tenant.get(id)
      assert {200, %{"id" => ^id}} = call(:post, "/api/tenants", %{"id" => id, "name" => "Agency"})

      assert {201, %{"key" => minted, "tenant_id" => ^id}} =
               call(:post, "/api/tenants/#{id}/keys", %{"name" => "laptop", "scopes" => ["*"]})

      assert {:ok, record} = ApiKey.verify(minted)
      assert record.tenant_id == id

      # The tenant comes with its organization, so a workspace can be made in it.
      assert {:ok, ws} =
               OptimalEngine.Workspace.create(%{
                 tenant_id: id,
                 organization_id: id <> ":org",
                 slug: "agency",
                 name: "Agency"
               })

      assert ws.id == id <> ":agency"
    end

    test "refuses the default tenant, a bad id and a missing id" do
      assert {400, _} = call(:post, "/api/tenants", %{"id" => "default"})
      assert {400, _} = call(:post, "/api/tenants", %{"id" => "Bad/Id"})
      assert {400, %{"error" => "id is required"}} = call(:post, "/api/tenants", %{})
    end

    test "never mints into a tenant this route did not make" do
      id = org_id()
      {:ok, _} = Tenant.create(%{id: id, name: "made elsewhere"})

      assert {409, %{"error" => "tenant_exists"}} = call(:post, "/api/tenants", %{"id" => id})

      assert {403, %{"error" => "tenant_not_created_here"}} =
               call(:post, "/api/tenants/#{id}/keys", %{"name" => "x", "scopes" => ["*"]})

      assert {404, %{"error" => "tenant_not_found"}} =
               call(:post, "/api/tenants/#{org_id()}/keys", %{"name" => "x", "scopes" => ["*"]})
    end

    test "a key request must name its scopes" do
      id = org_id()
      {201, _} = call(:post, "/api/tenants", %{"id" => id})

      assert {400, %{"error" => "scopes_required"}} =
               call(:post, "/api/tenants/#{id}/keys", %{"name" => "laptop"})
    end
  end

  describe "authentication required" do
    test "the default tenant's root key over every workspace is the operator" do
      with_auth_required(fn ->
        operator = key("default", ["*"])
        id = org_id()

        assert {201, _} = call(:post, "/api/tenants", %{"id" => id}, operator)

        assert {201, %{"tenant_id" => ^id}} =
                 call(
                   :post,
                   "/api/tenants/#{id}/keys",
                   %{"name" => "l", "scopes" => ["read"]},
                   operator
                 )
      end)
    end

    test "an admin key that is not root, a pinned root key and another tenant's root key are refused" do
      with_auth_required(fn ->
        other = org_id()
        {:ok, _} = Tenant.create(%{id: other, name: "other"})

        assert {403, %{"error" => "operator_only"}} =
                 call(:post, "/api/tenants", %{"id" => org_id()}, key("default", ["admin"]))

        # The workspace checks refuse these two before the route runs: a pinned key
        # names no workspace (400), another tenant does not hold the default one (404).
        assert {400, _} =
                 call(
                   :post,
                   "/api/tenants",
                   %{"id" => org_id()},
                   key("default", ["*"], ["default:one"])
                 )

        assert {404, _} = call(:post, "/api/tenants", %{"id" => org_id()}, key(other, ["*"]))

        assert {403, %{"error" => "operator_only"}} =
                 call(
                   :post,
                   "/api/tenants/#{other}/keys",
                   %{"name" => "x", "scopes" => ["*"]},
                   key("default", ["admin"])
                 )
      end)
    end

    test "an anonymous caller is refused" do
      with_auth_required(fn ->
        assert {401, _} = call(:post, "/api/tenants", %{"id" => org_id()})
      end)
    end
  end
end
