defmodule OptimalEngine.Portability.WorkspaceIdFollowupsTest do
  @moduledoc """
  What the workspace id check left out (#152):

    * `POST /api/workspaces` answers a workspace id it cannot give with 400,
      not 500;
    * the data steward's rename takes a target id only if `Workspace.check_id/2`
      does;
    * an unregistered workspace id whose directory is not its own (a bare
      `tenants`, `nodes` or `cache`, or `default:tenants`) is refused at the
      API, as ingest and asset storage would write into the Engine root's own
      directories under it;
    * `WorkspaceBundle.inspect_bundle/1` refuses a file path that leaves the
      workspace, as an import does;
    * `Tenant.create/1` takes only an id that can be a workspace id's prefix.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Authority.CanonicalJSON
  alias OptimalEngine.{DataSteward, Organization, Store, Workspace}
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace.Filesystem

  setup do
    n = System.unique_integer([:positive])
    tenant = "wsid2-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{n}"})

    %{n: n, tenant: tenant, root: Application.get_env(:optimal_engine, :root_path)}
  end

  defp post(path, body) do
    :post
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  defp get(path), do: :get |> conn(path) |> Router.call(Router.init([]))

  describe "POST /api/workspaces" do
    test "answers 400 invalid_workspace_id for a tenant that has no workspace ids", %{n: n} do
      conn =
        post("/api/workspaces", %{
          "slug" => "derived-#{n}",
          "name" => "W",
          "tenant" => "col:on-#{n}"
        })

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_workspace_id"}
    end
  end

  describe "DataSteward.rename_workspace/3" do
    test "refuses a target id that is not a workspace id", %{tenant: tenant, n: n} do
      # A workspace from before ids were checked, whose slug is a directory of
      # the Engine root: the id it would be renamed to is not one.
      legacy = "#{tenant}-legacy"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, organization_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, 'nodes', 'Legacy', 'active', '{}')",
          [legacy, tenant, Organization.default_for(tenant)]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspace_handles (tenant_id, slug, workspace_id) VALUES (?1, 'nodes', ?2)",
          [tenant, legacy]
        )

      assert {:error, :invalid_workspace_id} =
               DataSteward.rename_workspace(legacy, "#{tenant}:nodes",
                 tenant_id: tenant,
                 actor_id: "test:#{n}"
               )

      assert {:ok, %{id: ^legacy}} = Workspace.get(legacy)
      assert {:error, :not_found} = Workspace.get("#{tenant}:nodes")
    end
  end

  describe "an unregistered workspace id whose directory is not its own" do
    test "is refused at ingest and wherever a request names it", %{n: n} do
      for id <- ~w(tenants nodes cache assets architectures default:tenants default:nodes) do
        conn = post("/api/ingest", %{"text" => "A note for #{id} #{n}.", "workspace" => id})
        assert conn.status == 400, "#{id}: #{conn.status} #{conn.resp_body}"

        assert get("/api/memory?workspace=#{id}").status == 400, id
      end
    end

    test "does not make an ordinary bare id refused", %{n: n} do
      conn =
        post("/api/ingest", %{"text" => "A note for a bare id #{n}.", "workspace" => "bare-ok-#{n}"})

      assert conn.status == 200
    end
  end

  describe "WorkspaceBundle.inspect_bundle/1" do
    setup %{tenant: tenant, n: n, root: root} do
      {:ok, source} =
        Workspace.create(%{
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "src",
          name: "Source"
        })

      dir = Filesystem.path(root, source.id)
      File.mkdir_p!(Path.join(dir, "nodes/notes"))
      File.write!(Path.join(dir, "nodes/notes/one.md"), "# One\n")

      path = Path.join(System.tmp_dir!(), "wsid2-bundle-#{n}.tar.gz")
      on_exit(fn -> File.rm(path) end)

      {:ok, _manifest} = WorkspaceBundle.export(tenant, source.id, path)
      %{path: path}
    end

    # Adds a file entry whose path leaves the workspace, with the file where
    # the verifier would read it, and signs the manifest again.
    defp escaping(path, n) do
      dir = Path.join(System.tmp_dir!(), "wsid2-craft-#{n}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      :ok =
        :erl_tar.extract(String.to_charlist(path), [:compressed, {:cwd, String.to_charlist(dir)}])

      File.write!(Path.join(dir, "escape.md"), "outside")

      entry = %{
        "path" => "../escape.md",
        "bytes" => 7,
        "sha256" => :crypto.hash(:sha256, "outside") |> Base.encode16(case: :lower)
      }

      manifest =
        dir
        |> Path.join("manifest.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.delete("bundle_sha256")
        |> Map.update!("files", &(&1 ++ [entry]))

      manifest = Map.put(manifest, "bundle_sha256", CanonicalJSON.hash(manifest))
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest, pretty: true))

      files =
        for f <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
            File.regular?(f),
            do: {String.to_charlist(Path.relative_to(f, dir)), String.to_charlist(f)}

      :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])
    end

    test "refuses a file path that leaves the workspace", %{path: path, n: n} do
      assert {:ok, _manifest} = WorkspaceBundle.inspect_bundle(path)

      escaping(path, n)

      assert {:error, :file_path_outside_workspace} = WorkspaceBundle.inspect_bundle(path)
    end
  end

  describe "Tenant.create/1" do
    test "takes only an id that can be a workspace id's prefix", %{n: n} do
      for id <- ["a:b-#{n}", "a/b-#{n}", ".hid-#{n}", "-dash-#{n}", "a b #{n}", "a..b-#{n}", ""] do
        assert {:error, :invalid_tenant_id} = Tenant.create(%{id: id, name: "x"}), inspect(id)
      end

      assert {:error, :not_found} = Tenant.get("a:b-#{n}")

      for id <- ["acme-#{n}", "acme_co.#{n}", "9-#{n}"] do
        assert {:ok, %{id: ^id}} = Tenant.create(%{id: id, name: "ok"}), id
      end
    end
  end
end
