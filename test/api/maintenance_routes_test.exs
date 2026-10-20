defmodule OptimalEngine.API.MaintenanceRoutesTest do
  @moduledoc """
  The maintenance routes a client CLI calls for its operator commands when the
  Engine is remote: `index`, `log` and `graph`. Each needs the `admin` scope.
  `index` and `graph` act on one workspace the key may use in the caller's
  tenant. The log is Engine-wide, so only the Engine operator reads it: an
  admin key of the default tenant whose workspace scope is `*`.
  """

  use ExUnit.Case, async: false

  require Logger

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Graph, Organization, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "maint-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Maintenance #{n}"})
    org = "#{tenant}:org"
    {:ok, _} = Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, ws} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "ops", name: "Ops"})

    {:ok, %{key: admin}} =
      ApiKey.mint(%{tenant_id: tenant, name: "admin", scopes: ["*"], workspace_scope: ["*"]})

    {:ok, %{key: reader}} =
      ApiKey.mint(%{tenant_id: tenant, name: "reader", scopes: ["read"], workspace_scope: ["*"]})

    {:ok, %{key: operator}} =
      ApiKey.mint(%{
        tenant_id: Tenant.default_id(),
        name: "operator",
        scopes: ["*"],
        workspace_scope: ["*"]
      })

    # An admin of the default tenant limited to one workspace.
    {:ok, %{key: scoped_admin}} =
      ApiKey.mint(%{
        tenant_id: Tenant.default_id(),
        name: "scoped admin",
        scopes: ["*"],
        workspace_scope: ["default:maint-ops-#{n}"]
      })

    previous = Application.get_env(:optimal_engine, :reindex_fun)
    Application.put_env(:optimal_engine, :reindex_fun, fn -> {:ok, :started} end)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_engine, :reindex_fun, previous)
      else
        Application.delete_env(:optimal_engine, :reindex_fun)
      end
    end)

    %{
      n: n,
      tenant: tenant,
      ws: ws.id,
      admin: admin,
      reader: reader,
      operator: operator,
      scoped_admin: scoped_admin
    }
  end

  defp call(method, path, key, body \\ nil) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn
    |> put_req_header("authorization", "Bearer " <> key)
    |> Router.call(Router.init([]))
  end

  describe "POST /api/maintenance/index" do
    test "is admin only and enqueues the same coalesced reindex job as /api/reindex", ctx do
      denied = call(:post, "/api/maintenance/index", ctx.reader, %{"workspace" => ctx.ws})
      assert denied.status == 403
      assert denied.resp_body =~ "permission_scope_denied"

      queued = call(:post, "/api/maintenance/index", ctx.admin, %{"workspace" => ctx.ws})
      assert queued.status == 202

      assert %{"status" => "queued", "job_id" => job_id, "kind" => "reindex"} =
               Jason.decode!(queued.resp_body)

      again = call(:post, "/api/reindex", ctx.admin, %{"workspace" => ctx.ws})
      assert again.status == 202
      assert %{"status" => "already_running", "job_id" => ^job_id} = Jason.decode!(again.resp_body)
    end

    test "with no workspace it is the implicit default, checked like any other", ctx do
      # Another tenant's admin may not enqueue into the default tenant's workspace.
      foreign = call(:post, "/api/maintenance/index", ctx.admin, %{})
      assert foreign.status == 404

      # A key limited to named workspaces must name one.
      scoped = call(:post, "/api/maintenance/index", ctx.scoped_admin, %{})
      assert scoped.status == 400
      assert scoped.resp_body =~ "workspace_required"
    end
  end

  describe "GET /api/maintenance/log" do
    test "is admin only and serves recent log lines with secrets redacted", ctx do
      marker = "maintenance-log-marker-#{ctx.n}"
      secret = "oe_0123456789abcdef01234567_s3cret-part-#{ctx.n}"
      Logger.warning("#{marker} key=#{secret} header=Bearer tok-#{ctx.n}")

      assert call(:get, "/api/maintenance/log", ctx.reader).status == 403

      resp = call(:get, "/api/maintenance/log?lines=50", ctx.operator)
      assert resp.status == 200

      assert %{"text" => text, "count" => count, "capacity" => capacity} =
               Jason.decode!(resp.resp_body)

      assert count >= 1 and count <= 50
      assert capacity >= count
      [line] = text |> String.split("\n") |> Enum.filter(&String.contains?(&1, marker))
      assert line =~ "[warning]"
      assert line =~ "oe_0123456789abcdef01234567_[redacted]"
      assert line =~ "Bearer [redacted]"
      refute text =~ "s3cret-part-#{ctx.n}"
      refute text =~ "tok-#{ctx.n}"
    end

    test "serves at most `lines` lines, oldest first", ctx do
      for i <- 1..3, do: Logger.warning("maintenance-log-order-#{ctx.n}-#{i}")

      resp = call(:get, "/api/maintenance/log?lines=2", ctx.operator)
      assert %{"count" => 2, "text" => text} = Jason.decode!(resp.resp_body)
      assert length(String.split(text, "\n")) == 2

      %{"text" => recent} =
        Jason.decode!(call(:get, "/api/maintenance/log", ctx.operator).resp_body)

      order =
        recent
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/maintenance-log-order-#{ctx.n}-(\d)/, line) do
            [_, i] -> [i]
            nil -> []
          end
        end)

      assert order == ["1", "2", "3"]
    end
  end

  describe "GET /api/maintenance/log is the Engine operator's" do
    test "another tenant's admin key is refused", ctx do
      refused = call(:get, "/api/maintenance/log", ctx.admin)
      assert refused.status == 403
      assert Jason.decode!(refused.resp_body)["error"] == "operator_only"
    end

    test "a default-tenant admin key limited to one workspace is refused", ctx do
      refused = call(:get, "/api/maintenance/log", ctx.scoped_admin)
      assert refused.status == 403
      assert Jason.decode!(refused.resp_body)["error"] == "operator_only"
    end
  end

  describe "GET /api/maintenance/graph" do
    test "is admin only and reports one workspace in the caller's tenant", ctx do
      :ok =
        Graph.assert_edge("Entity#{ctx.n}", "ctx-#{ctx.n}", "mentioned_in", workspace_id: ctx.ws)

      assert call(:get, "/api/maintenance/graph?workspace=#{ctx.ws}", ctx.reader).status == 403

      resp = call(:get, "/api/maintenance/graph?workspace=#{ctx.ws}", ctx.admin)
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["workspace_id"] == ctx.ws
      assert body["edges"]["total_edges"] == 1
      assert body["edges"]["mentioned_in"] == 1
      assert body["top_entities"] == [%{"id" => "Entity#{ctx.n}", "connections" => 1}]

      assert [%{"source_id" => "Entity" <> _, "relation" => "mentioned_in"}] =
               body["sample_edges"]

      # Another tenant's workspace, or the implicit default one, is not found.
      assert call(:get, "/api/maintenance/graph?workspace=default", ctx.admin).status == 404
      assert call(:get, "/api/maintenance/graph", ctx.admin).status == 404

      # A key limited to named workspaces must name one.
      scoped = call(:get, "/api/maintenance/graph", ctx.scoped_admin)
      assert scoped.status == 400
      assert scoped.resp_body =~ "workspace_required"
    end
  end
end
