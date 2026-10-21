defmodule OptimalEngine.Portability.WorkspaceIdRepairCaseTest do
  @moduledoc """
  Two edges of the workspace id check:

    * the steward's repair moves the rows of an unregistered id to a registered
      workspace and writes no file, so the id it names as `source_workspace_id`
      may be one whose directory is not its own (`tenants`, `nodes`): that is
      the id such rows were written under. Nothing else the API takes is
      exempt;
    * a tenant id is lowercase, because it names a directory
      (`tenants/<tenant>/`) and `Acme` and `acme` are one directory on a case
      insensitive file system. A tenant row from before this check keeps
      working, and nothing else may take its name in another case.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.{Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    %{n: System.unique_integer([:positive])}
  end

  defp post(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  describe "the steward's repair" do
    setup %{n: n} do
      {:ok, target} = Workspace.create(%{slug: "repair-#{n}", name: "Repair #{n}"})

      on_exit(fn ->
        Store.raw_query("DELETE FROM contexts WHERE id LIKE ?1", ["ctx-repair-#{n}-%"])
      end)

      %{target: target.id}
    end

    defp orphan!(n, source) do
      id = "ctx-repair-#{n}-#{String.replace(source, ~r/\W/, "")}"

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, path, genre, node)
          VALUES (?1, 'default', ?2, ?3, 't', 'text', NULL, 'note', 'person-operator')
          """,
          [id, source, "optimal://#{source}/#{id}"]
        )

      id
    end

    test "takes rows from an id whose directory is not its own", %{n: n, target: target} do
      for source <- ["tenants", "nodes", "cache"] do
        id = orphan!(n, source)

        conn =
          post("/api/data-steward/workspaces/repair", %{
            "source_workspace_id" => source,
            "target_workspace_id" => target
          })

        assert conn.status == 200, "#{source}: #{conn.status} #{conn.resp_body}"
        assert Jason.decode!(conn.resp_body)["updated_records"] >= 1

        assert {:ok, [[^target]]} =
                 Store.raw_query("SELECT workspace_id FROM contexts WHERE id = ?1", [id])
      end
    end

    test "still refuses such an id in any other field of the request", %{n: n, target: target} do
      orphan!(n, "tenants")

      conn =
        post("/api/data-steward/workspaces/repair", %{
          "source_workspace_id" => "tenants",
          "target_workspace_id" => target,
          "workspace_id" => "nodes"
        })

      assert conn.status == 400
    end

    test "still refuses it as the workspace of any other route" do
      assert post("/api/ingest", %{"text" => "A note.", "workspace" => "tenants"}).status == 400

      assert post("/api/data-steward/workspaces/rename", %{
               "source_workspace_id" => "tenants",
               "target_workspace_id" => "default:elsewhere"
             }).status == 400
    end
  end

  describe "Tenant.create/1" do
    test "refuses an uppercase id", %{n: n} do
      for id <- ["Acme-#{n}", "ACME#{n}", "acme-Co-#{n}"] do
        assert {:error, :invalid_tenant_id} = Tenant.create(%{id: id, name: "x"}), id
      end

      assert {:ok, %{id: id}} = Tenant.create(%{id: "acme_co.#{n}", name: "ok"})
      assert id == "acme_co.#{n}"
    end

    test "refuses an id that differs from a tenant's only in case, and leaves that tenant", %{
      n: n
    } do
      legacy = "Legacy-#{n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO tenants (id, name, plan, metadata) VALUES (?1, ?1, 'default', '{}')",
          [legacy]
        )

      on_exit(fn -> Store.raw_query("DELETE FROM tenants WHERE id = ?1", [legacy]) end)

      assert {:error, :tenant_id_taken} = Tenant.create(%{id: "legacy-#{n}", name: "x"})
      assert {:error, :not_found} = Tenant.get("legacy-#{n}")
      assert {:ok, %{id: ^legacy}} = Tenant.get(legacy)
    end
  end
end
