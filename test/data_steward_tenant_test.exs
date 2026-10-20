defmodule OptimalEngine.DataStewardTenantTest do
  @moduledoc """
  The steward's id repairs act inside the caller's tenant. A source or target
  workspace of another tenant is refused as if it were absent, an archived
  workspace of another tenant is never an unregistered source, rows another
  tenant wrote under an id both use stay where they are, and the HTTP
  routes authorize the source and target ids they name like any workspace.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{DataSteward, Organization, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    a = "stew-a-#{n}"
    b = "stew-b-#{n}"

    for tenant <- [a, b] do
      {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

      {:ok, _} =
        Workspace.create(%{
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "ops",
          name: "Ops"
        })
    end

    %{n: n, a: a, b: b, a_ws: "#{a}:ops", b_ws: "#{b}:ops"}
  end

  defp context(tenant, workspace, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, ?4, 'Row', 'Row.', '2026-10-20T09:00:00Z', '{}')",
        [id, tenant, workspace, "optimal://inbox/#{id}.md"]
      )
  end

  defp holder(id) do
    {:ok, [[workspace, tenant]]} =
      Store.raw_query("SELECT workspace_id, tenant_id FROM contexts WHERE id = ?1", [id])

    {tenant, workspace}
  end

  defp steward(tenant), do: [tenant_id: tenant, actor_id: "user:steward"]

  describe "rename_workspace" do
    test "a source workspace of another tenant is not found, and nothing moves",
         %{a: a, b: b, b_ws: b_ws, n: n} do
      context(b, b_ws, "b-row-#{n}")

      assert {:error, :source_workspace_not_found} =
               DataSteward.rename_workspace(b_ws, "#{b}:ops", steward(a))

      {:ok, _} = Workspace.update(b_ws, %{slug: "ops-b-new"})

      assert {:error, :source_workspace_not_found} =
               DataSteward.rename_workspace(b_ws, "#{b}:ops-b-new", steward(a))

      assert {:ok, %{id: ^b_ws}} = Workspace.get(b_ws)
      assert holder("b-row-#{n}") == {b, b_ws}
    end

    test "moves the caller's rows only, even from an id another tenant wrote to",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      context(a, a_ws, "a-row-#{n}")
      context(b, a_ws, "stray-row-#{n}")

      {:ok, _} = Workspace.update(a_ws, %{slug: "ops-a-new"})
      target = "#{a}:ops-a-new"
      assert {:ok, _} = DataSteward.rename_workspace(a_ws, target, steward(a))

      assert holder("a-row-#{n}") == {a, target}
      assert holder("stray-row-#{n}") == {b, a_ws}
    end
  end

  describe "repair_orphan_scope" do
    test "a target workspace of another tenant is not registered for the caller",
         %{a: a, b_ws: b_ws, n: n} do
      orphan = "orphan-#{n}"
      context(a, orphan, "a-orphan-#{n}")

      assert {:error, :target_workspace_not_registered} =
               DataSteward.repair_orphan_scope(orphan, b_ws, steward(a))

      assert holder("a-orphan-#{n}") == {a, orphan}
    end

    test "an archived workspace of another tenant is registered, never an orphan source",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      {:ok, archived} =
        Workspace.create(%{
          tenant_id: b,
          organization_id: Organization.default_for(b),
          slug: "gone",
          name: "Gone"
        })

      context(b, archived.id, "b-archived-#{n}")
      :ok = Workspace.archive(archived.id)

      assert {:error, :source_workspace_is_registered} =
               DataSteward.repair_orphan_scope(archived.id, a_ws, steward(a))

      assert holder("b-archived-#{n}") == {b, archived.id}
    end

    test "an archived workspace of the caller's own tenant can still be repaired from",
         %{a: a, a_ws: a_ws, n: n} do
      {:ok, archived} =
        Workspace.create(%{
          tenant_id: a,
          organization_id: Organization.default_for(a),
          slug: "gone",
          name: "Gone"
        })

      context(a, archived.id, "a-archived-#{n}")
      :ok = Workspace.archive(archived.id)

      assert {:ok, %{updated_records: updated}} =
               DataSteward.repair_orphan_scope(archived.id, a_ws, steward(a))

      assert updated >= 1
      assert holder("a-archived-#{n}") == {a, a_ws}
    end

    test "moves the caller's rows only from an id two tenants used",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      shared = "shared-orphan-#{n}"
      context(a, shared, "a-shared-#{n}")
      context(b, shared, "b-shared-#{n}")

      assert {:ok, _} = DataSteward.repair_orphan_scope(shared, a_ws, steward(a))

      assert holder("a-shared-#{n}") == {a, a_ws}
      assert holder("b-shared-#{n}") == {b, shared}
    end
  end

  describe "tables with no tenant column" do
    setup do
      :ok =
        Store.raw_execute(
          "CREATE TABLE IF NOT EXISTS steward_tenantless_test (workspace_id TEXT NOT NULL, note TEXT)",
          []
        )

      on_exit(fn -> Store.raw_execute("DROP TABLE IF EXISTS steward_tenantless_test", []) end)
    end

    defp tenantless(workspace) do
      {:ok, [[count]]} =
        Store.raw_query(
          "SELECT COUNT(*) FROM steward_tenantless_test WHERE workspace_id = ?1",
          [workspace]
        )

      count
    end

    defp tenantless_row(workspace) do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO steward_tenantless_test (workspace_id, note) VALUES (?1, 'x')",
          [workspace]
        )
    end

    test "an orphan repair leaves them where they are and says so",
         %{a: a, a_ws: a_ws, n: n} do
      orphan = "orphan-#{n}"
      context(a, orphan, "a-orphan-#{n}")
      tenantless_row(orphan)
      tenantless_row(orphan)

      assert {:ok, result} = DataSteward.repair_orphan_scope(orphan, a_ws, steward(a))

      assert result.unscoped_tables == [%{table: "steward_tenantless_test", rows: 2}]
      assert tenantless(orphan) == 2
      assert tenantless(a_ws) == 0
      assert holder("a-orphan-#{n}") == {a, a_ws}
    end

    test "a rename moves them, because the source is registered to the caller",
         %{a: a, a_ws: a_ws} do
      tenantless_row(a_ws)
      {:ok, _} = Workspace.update(a_ws, %{slug: "ops-moved"})
      target = "#{a}:ops-moved"

      assert {:ok, _} = DataSteward.rename_workspace(a_ws, target, steward(a))
      assert tenantless(target) == 1
      assert tenantless(a_ws) == 0
    end
  end

  describe "the dashboard" do
    test "lists the caller's orphan scopes only", %{a: a, b: b, n: n} do
      context(a, "orphan-a-#{n}", "a-dash-#{n}")
      context(b, "orphan-b-#{n}", "b-dash-#{n}")

      assert {:ok, scopes} = DataSteward.orphan_scopes(a)
      ids = Enum.map(scopes, & &1.workspace_id)
      assert "orphan-a-#{n}" in ids
      refute "orphan-b-#{n}" in ids
    end
  end

  describe "over HTTP" do
    defp key(tenant, workspaces) do
      {:ok, %{key: key}} =
        ApiKey.mint(%{
          tenant_id: tenant,
          name: "steward",
          scopes: ["topology:write"],
          workspace_scope: workspaces
        })

      key
    end

    defp post(path, body, token) do
      response =
        conn(:post, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init([]))

      {response.status, Jason.decode!(response.resp_body)}
    end

    test "a source or target of another tenant is refused as absent, and nothing moves",
         %{a: a, b: b, a_ws: a_ws, b_ws: b_ws, n: n} do
      context(b, "#{b}:orphan-#{n}", "b-http-#{n}")
      context(b, b_ws, "b-http-ws-#{n}")
      token = key(a, ["*"])

      assert {404, _} =
               post(
                 "/api/data-steward/workspaces/repair",
                 %{
                   workspace: a_ws,
                   source_workspace_id: "#{b}:orphan-#{n}",
                   target_workspace_id: a_ws
                 },
                 token
               )

      assert {404, _} =
               post(
                 "/api/data-steward/workspaces/repair",
                 %{workspace: a_ws, source_workspace_id: "orphan-#{n}", target_workspace_id: b_ws},
                 token
               )

      assert {404, _} =
               post(
                 "/api/data-steward/workspaces/rename",
                 %{workspace: a_ws, source_workspace_id: b_ws, target_workspace_id: "#{b}:ops"},
                 token
               )

      assert holder("b-http-#{n}") == {b, "#{b}:orphan-#{n}"}
      assert holder("b-http-ws-#{n}") == {b, b_ws}
    end

    test "a key restricted to some workspaces must hold the source and the target",
         %{a: a, a_ws: a_ws, n: n} do
      orphan = "#{a}:orphan-#{n}"
      context(a, orphan, "a-http-#{n}")
      body = %{source_workspace_id: orphan, target_workspace_id: a_ws}

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post("/api/data-steward/workspaces/repair", body, key(a, [a_ws]))

      assert holder("a-http-#{n}") == {a, orphan}

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post("/api/data-steward/workspaces/repair", body, key(a, [orphan]))

      assert {200, %{"updated_records" => updated}} =
               post("/api/data-steward/workspaces/repair", body, key(a, [orphan, a_ws]))

      assert updated >= 1
      assert holder("a-http-#{n}") == {a, a_ws}
    end

    test "a keyed caller in a tenant other than the default can use the routes at all",
         %{a: a, a_ws: a_ws} do
      {:ok, _} = Workspace.update(a_ws, %{slug: "ops-http-new"})
      target = "#{a}:ops-http-new"

      assert {200, %{"target_workspace_id" => ^target}} =
               post(
                 "/api/data-steward/workspaces/rename",
                 %{source_workspace_id: a_ws, target_workspace_id: target},
                 key(a, ["*"])
               )
    end
  end
end
