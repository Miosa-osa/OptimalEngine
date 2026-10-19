defmodule OptimalEngine.API.RecordScopingTest do
  @moduledoc """
  Routes that address a record by id answer only inside the caller's tenant
  and key workspace scope: a memory of another workspace or tenant is not
  found, by id or through any of its sub-routes. The workspace list shows
  only the workspaces the key may see, and health answers any valid key.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.{Memory, Organization, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    tenant = "scoping-#{n}"
    other = "scoping-other-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Scoping #{n}"})
    {:ok, _} = Tenant.create(%{id: other, name: "Other #{n}"})

    {:ok, alpha} = workspace(tenant, "alpha")
    {:ok, beta} = workspace(tenant, "beta")
    {:ok, foreign} = workspace(other, "alpha")

    {:ok, alpha_memory} =
      Memory.create(%{tenant_id: tenant, workspace_id: alpha.id, content: "Alpha keeps this."})

    {:ok, beta_memory} =
      Memory.create(%{tenant_id: tenant, workspace_id: beta.id, content: "Beta keeps this."})

    %{
      n: n,
      tenant: tenant,
      other: other,
      alpha: alpha.id,
      beta: beta.id,
      foreign: foreign.id,
      alpha_memory: alpha_memory,
      beta_memory: beta_memory,
      alpha_key: key(tenant, [alpha.id], ["read", "write"], "agent:alpha-#{n}"),
      beta_key: key(tenant, [beta.id], ["read", "write"], "agent:beta-#{n}"),
      all_key: key(tenant, ["*"], ["read", "write"], "agent:all-#{n}"),
      foreign_key: key(other, [foreign.id], ["read", "write"], "agent:foreign-#{n}")
    }
  end

  defp workspace(tenant, slug) do
    Workspace.create(%{
      tenant_id: tenant,
      organization_id: Organization.default_for(tenant),
      slug: slug,
      name: String.capitalize(slug)
    })
  end

  defp key(tenant, workspaces, scopes, principal) do
    {:ok, _} =
      Principal.upsert(%{id: principal, tenant_id: tenant, kind: :agent, display_name: principal})

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "scoping-test",
        scopes: scopes,
        workspace_scope: workspaces,
        principal_id: principal
      })

    token
  end

  defp request(method, path, token, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "memory routes that take an id" do
    test "another workspace's memory is not found, by id and by every sub-route", ctx do
      id = ctx.beta_memory.id

      for {method, path, body} <- [
            {:get, "/api/memory/#{id}?workspace=#{ctx.alpha}", nil},
            {:get, "/api/memory/#{id}/versions?workspace=#{ctx.alpha}", nil},
            {:get, "/api/memory/#{id}/relations?workspace=#{ctx.alpha}", nil},
            {:post, "/api/memory/#{id}/forget", %{"workspace" => ctx.alpha}},
            {:post, "/api/memory/#{id}/update", %{"workspace" => ctx.alpha, "content" => "x"}},
            {:post, "/api/memory/#{id}/extend", %{"workspace" => ctx.alpha, "content" => "x"}},
            {:post, "/api/memory/#{id}/derive", %{"workspace" => ctx.alpha, "content" => "x"}},
            {:post, "/api/memory/#{id}/promote", %{"workspace" => ctx.alpha, "slug" => "page"}},
            {:delete, "/api/memory/#{id}?workspace=#{ctx.alpha}", nil}
          ] do
        conn = request(method, path, ctx.alpha_key, body)
        assert conn.status == 404, "#{method} #{path}"
        assert json(conn)["error"] == "memory not found"
      end

      assert {:ok, %{content: "Beta keeps this.", is_forgotten: false, is_latest: true}} =
               Memory.get(id)
    end

    test "the owning workspace's key reads and changes it", ctx do
      id = ctx.beta_memory.id
      assert request(:get, "/api/memory/#{id}?workspace=#{ctx.beta}", ctx.beta_key).status == 200

      assert request(:get, "/api/memory/#{id}/versions?workspace=#{ctx.beta}", ctx.beta_key).status ==
               200

      conn =
        request(:post, "/api/memory/#{id}/forget", ctx.beta_key, %{"workspace" => ctx.beta})

      assert conn.status == 204
    end

    test "a named workspace must be the memory's own, even for an unrestricted key", ctx do
      id = ctx.beta_memory.id
      assert request(:get, "/api/memory/#{id}?workspace=#{ctx.alpha}", ctx.all_key).status == 404
      assert request(:get, "/api/memory/#{id}?workspace=#{ctx.beta}", ctx.all_key).status == 200
    end

    test "another tenant's memory is not found", ctx do
      for id <- [ctx.alpha_memory.id, ctx.beta_memory.id] do
        conn = request(:get, "/api/memory/#{id}?workspace=#{ctx.foreign}", ctx.foreign_key)
        assert conn.status == 404

        conn =
          request(:post, "/api/memory/#{id}/forget", ctx.foreign_key, %{
            "workspace" => ctx.foreign
          })

        assert conn.status == 404
      end
    end
  end

  describe "signals by id" do
    test "a context of another tenant is not found through a bare workspace id", ctx do
      bare = "scoping-bare-#{ctx.n}"
      id = "scoping-signal-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at, uri) VALUES (?1, 'default', ?2, 'Default only', 'x', '2026-10-18T10:00:00Z', ?3)",
          [id, bare, "optimal://#{bare}/contexts/#{id}"]
        )

      foreign_all = key(ctx.other, ["*"], ["read"], "agent:foreign-all-#{ctx.n}")
      assert request(:get, "/api/signals/#{id}?workspace=#{bare}", foreign_all).status == 404
      assert request(:get, "/api/signals/#{id}?workspace=#{bare}", nil).status == 200
    end
  end

  describe "GET /api/workspaces" do
    test "a workspace key lists only its workspaces", ctx do
      body = request(:get, "/api/workspaces", ctx.alpha_key) |> json()
      assert Enum.map(body["workspaces"], & &1["id"]) == [ctx.alpha]
      assert body["pagination"]["total"] == 1
    end

    test "an unrestricted key lists every workspace of its tenant", ctx do
      body = request(:get, "/api/workspaces", ctx.all_key) |> json()
      ids = Enum.map(body["workspaces"], & &1["id"])
      assert ctx.alpha in ids and ctx.beta in ids
      refute ctx.foreign in ids
    end
  end

  describe "GET /api/health" do
    test "answers a workspace-scoped key without a workspace", ctx do
      conn = request(:get, "/api/health", ctx.alpha_key)
      assert conn.status == 200
      assert Map.has_key?(json(conn), "live")
    end

    test "full diagnostics still need a workspace the key covers", ctx do
      assert request(:get, "/api/health?full=true", ctx.alpha_key).status == 400

      assert request(:get, "/api/health?full=true&workspace=#{ctx.alpha}", ctx.alpha_key).status ==
               200

      assert request(:get, "/api/health?full=true&workspace=#{ctx.beta}", ctx.alpha_key).status ==
               403
    end
  end
end
