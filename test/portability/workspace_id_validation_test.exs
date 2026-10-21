defmodule OptimalEngine.Portability.WorkspaceIdValidationTest do
  @moduledoc """
  A workspace id is `default`, or `<tenant_id>:<suffix>` where the suffix is a
  slug the Engine accepts, and the id of a tenant's workspace names that
  tenant. The id decides which directory the workspace owns, so one that names
  another tenant, or a directory the Engine root uses for itself, would write
  into files that are not the workspace's.

  The check holds where the Engine makes or takes a workspace id: `Workspace.create/1`,
  a workspace entry of a topology document, and a workspace bundle (the id the
  manifest carries and the id the importer asks for). A bundle also never writes a file
  outside the workspace's own directory, and never exports or removes a
  directory that holds more than the workspace.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Organization, Store, Workspace}
  alias OptimalEngine.Authority.CanonicalJSON
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Topology.Portable
  alias OptimalEngine.Workspace.Filesystem

  setup do
    n = System.unique_integer([:positive])
    tenant = "wsid-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{n}"})
    root = Application.get_env(:optimal_engine, :root_path)

    %{n: n, tenant: tenant, root: root}
  end

  defp create(tenant, attrs) do
    Workspace.create(
      Map.merge(
        %{tenant_id: tenant, organization_id: Organization.default_for(tenant), name: "W"},
        attrs
      )
    )
  end

  # A tenant row from before tenant ids were checked, which `Tenant.create/1`
  # no longer makes.
  defp legacy_tenant(id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO tenants (id, name, plan, metadata) VALUES (?1, ?1, 'default', '{}')",
        [id]
      )

    on_exit(fn -> Store.raw_query("DELETE FROM tenants WHERE id = ?1", [id]) end)
  end

  describe "Workspace.check_id/2" do
    test "accepts default and the tenant's own prefixed ids" do
      assert :ok = Workspace.check_id("default", "default")
      assert :ok = Workspace.check_id("default:sales", "default")
      assert :ok = Workspace.check_id("acme:sales", "acme")
      assert :ok = Workspace.check_id("acme:default", "acme")
      assert :ok = Workspace.check_id("acme:a1-b2", "acme")
    end

    test "refuses the rest" do
      for {id, tenant} <- [
            # another tenant's namespace
            {"default:sales", "acme"},
            {"beta:sales", "acme"},
            {"default", "acme"},
            # no prefix
            {"sales", "acme"},
            {"sales", "default"},
            {"", "acme"},
            # a suffix that is not a slug
            {"acme:", "acme"},
            {"acme:Sales", "acme"},
            {"acme:a b", "acme"},
            {"acme:a/b", "acme"},
            {"acme:..", "acme"},
            {"acme:a:b", "acme"},
            # a directory of the Engine root
            {"default:nodes", "default"},
            {"default:tenants", "default"},
            {"default:cache", "default"},
            {"acme:assets", "acme"},
            # the root itself
            {"default:default", "default"}
          ] do
        assert {:error, :invalid_workspace_id} = Workspace.check_id(id, tenant),
               inspect({id, tenant})
      end

      assert {:error, :invalid_workspace_id} = Workspace.check_id(nil, "acme")
      assert {:error, :invalid_workspace_id} = Workspace.check_id(42, "acme")
    end

    test "a tenant id with a colon names no prefix" do
      assert {:error, :invalid_workspace_id} = Workspace.check_id("a:b:sales", "a:b")
    end
  end

  describe "Workspace.create/1" do
    test "takes an id that is the tenant's own", %{tenant: tenant} do
      assert {:ok, %{id: id}} = create(tenant, %{id: "#{tenant}:explicit", slug: "explicit"})
      assert id == "#{tenant}:explicit"
    end

    test "refuses an id outside the tenant's namespace, and writes nothing", ctx do
      %{tenant: tenant, n: n, root: root} = ctx

      for id <- [
            "default:claimed-#{n}",
            "default:tenants",
            "other-#{n}:claimed",
            "claimed-#{n}",
            "#{tenant}:nodes",
            "#{tenant}:Not-A-Slug",
            "#{tenant}:a:b"
          ] do
        assert {:error, :invalid_workspace_id} = create(tenant, %{id: id, slug: "claimed-#{n}"}),
               id

        assert {:error, :not_found} = Workspace.get(id)
      end

      refute File.exists?(Path.join(root, "claimed-#{n}"))

      # `default` is the default tenant's workspace and no other tenant's.
      assert {:error, :invalid_workspace_id} = create(tenant, %{id: "default", slug: "claimed"})
    end

    test "the default tenant cannot take the root or a directory of it", %{n: n} do
      for id <- ["default:default", "default:tenants", "default:nodes"] do
        assert {:error, :invalid_workspace_id} = create("default", %{id: id, slug: "d-#{n}"}), id
      end
    end

    test "a tenant whose id holds a colon cannot derive an id", %{n: n} do
      tenant = "col:on-#{n}"
      legacy_tenant(tenant)

      assert {:error, :invalid_workspace_id} = create(tenant, %{slug: "derived"})
    end
  end

  describe "a topology document" do
    test "an entry id outside the tenant's namespace is not used", ctx do
      %{tenant: tenant, n: n} = ctx

      document = %{
        "schema_version" => 1,
        "organizations" => [
          %{
            "slug" => "org-#{n}",
            "name" => "Org",
            "workspaces" => [
              %{"slug" => "one-#{n}", "id" => "#{tenant}:nodes"},
              %{"slug" => "two-#{n}", "id" => "#{tenant}:Two"},
              %{"slug" => "three-#{n}", "id" => "#{tenant}:ok-three-#{n}"}
            ]
          }
        ]
      }

      assert {:ok, %{workspaces_created: 3}} = Portable.import(tenant, document)

      # The first two derive their id from the slug; the third keeps its own.
      assert {:ok, %{id: id_one}} = Workspace.get("#{tenant}:one-#{n}")
      assert id_one == "#{tenant}:one-#{n}"
      assert {:ok, _} = Workspace.get("#{tenant}:two-#{n}")
      assert {:ok, _} = Workspace.get("#{tenant}:ok-three-#{n}")
      assert {:error, :not_found} = Workspace.get("#{tenant}:nodes")
      assert {:error, :not_found} = Workspace.get("#{tenant}:Two")
    end

    test "the default tenant's entry cannot name a directory of the root", %{n: n} do
      document = %{
        "schema_version" => 1,
        "organizations" => [
          %{
            "slug" => "org-#{n}",
            "name" => "Org",
            "workspaces" => [
              %{"slug" => "ported-#{n}", "id" => "default:tenants"},
              %{"slug" => "ported-b-#{n}", "id" => "default:default"}
            ]
          }
        ]
      }

      assert {:ok, %{workspaces_created: 2}} = Portable.import("default", document)

      assert {:error, :not_found} = Workspace.get("default:tenants")
      assert {:error, :not_found} = Workspace.get("default:default")
      assert {:ok, _} = Workspace.get("default:ported-#{n}")
    end
  end

  describe "a workspace bundle" do
    setup %{tenant: tenant, n: n, root: root} do
      {:ok, source} = create(tenant, %{slug: "src", name: "Source"})

      dir = Filesystem.path(root, source.id)
      File.mkdir_p!(Path.join(dir, "nodes/notes"))
      File.write!(Path.join(dir, "nodes/notes/one.md"), "# One\n")

      path = Path.join(System.tmp_dir!(), "wsid-bundle-#{n}.tar.gz")
      on_exit(fn -> File.rm(path) end)

      {:ok, manifest} = WorkspaceBundle.export(tenant, source.id, path)
      %{source: source.id, path: path, manifest: manifest}
    end

    # Rewrites the exported bundle with `fun.(manifest, dir)` (which may add
    # files to `dir`) and signs the manifest again, as anyone who can write a
    # bundle can.
    defp craft(ctx, fun) do
      dir =
        Path.join(System.tmp_dir!(), "wsid-craft-#{ctx.n}-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      :ok =
        :erl_tar.extract(String.to_charlist(ctx.path), [
          :compressed,
          {:cwd, String.to_charlist(dir)}
        ])

      manifest =
        dir
        |> Path.join("manifest.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.delete("bundle_sha256")
        |> fun.(dir)

      manifest = Map.put(manifest, "bundle_sha256", CanonicalJSON.hash(manifest))
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest, pretty: true))

      files =
        for f <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
            File.regular?(f),
            do: {String.to_charlist(Path.relative_to(f, dir)), String.to_charlist(f)}

      :ok = :erl_tar.create(String.to_charlist(ctx.path), files, [:compressed])
    end

    defp as_workspace(manifest, id, slug) do
      Map.update!(manifest, "workspace", &Map.merge(&1, %{"id" => id, "slug" => slug}))
    end

    test "a manifest id outside the tenant's namespace is not used", ctx do
      %{tenant: tenant} = ctx

      for id <- ["#{tenant}:nodes", "#{tenant}:Imported", "#{tenant}:a:b", "default:claimed"] do
        slug = "imported-#{System.unique_integer([:positive])}"
        craft(ctx, fn manifest, _dir -> as_workspace(manifest, id, slug) end)

        assert {:ok, %{workspace_id: workspace_id}} = WorkspaceBundle.import(ctx.path, tenant)
        assert workspace_id == "#{tenant}:#{slug}", id
        assert {:error, :not_found} = Workspace.get(id)
      end

      refute File.exists?(Path.join([ctx.root, "tenants", tenant, "nodes"]))
    end

    test "the default tenant cannot take a directory of the root from a manifest id", ctx do
      for {id, index} <- Enum.with_index(["default:tenants", "default:nodes", "default:default"]) do
        slug = "imported-d-#{ctx.n}-#{index}"
        craft(ctx, fn manifest, _dir -> as_workspace(manifest, id, slug) end)

        assert {:ok, %{workspace_id: "default:" <> ^slug}} =
                 WorkspaceBundle.import(ctx.path, "default", cross_tenant: true)

        assert {:error, :not_found} = Workspace.get(id)
      end
    end

    test "a requested workspace id is checked like a new workspace's", ctx do
      %{tenant: tenant} = ctx

      for requested <- [
            "#{tenant}:nodes",
            "#{tenant}:Big",
            "#{tenant}:a:b",
            "nodes",
            "Big",
            "tenants"
          ] do
        assert {:error, :invalid_workspace_id} =
                 WorkspaceBundle.import(ctx.path, tenant, workspace_id: requested),
               requested
      end

      assert {:error, :workspace_id_not_in_tenant} =
               WorkspaceBundle.import(ctx.path, tenant, workspace_id: "default:claimed")

      assert {:error, :not_found} = Workspace.get("#{tenant}:nodes")
    end

    test "a file path that leaves the workspace refuses the bundle, and writes nothing", ctx do
      %{tenant: tenant, n: n, root: root} = ctx
      escape = "escape-#{n}.md"
      slug = "escaping-#{n}"

      craft(ctx, fn manifest, dir ->
        File.write!(Path.join(dir, escape), "outside")

        entry = %{
          "path" => "../" <> escape,
          "bytes" => 7,
          "sha256" => :crypto.hash(:sha256, "outside") |> Base.encode16(case: :lower)
        }

        manifest
        |> as_workspace("#{tenant}:#{slug}", slug)
        |> Map.update!("files", &(&1 ++ [entry]))
      end)

      assert {:error, :file_path_outside_workspace} = WorkspaceBundle.import(ctx.path, tenant)

      assert {:error, :not_found} = Workspace.get("#{tenant}:#{slug}")
      refute File.exists?(Path.join([root, "tenants", tenant, escape]))
    end

    test "a directory that holds more than the workspace is not written to", ctx do
      %{n: n, root: root} = ctx

      # A tenant whose id is a hidden name: its directory is not its own.
      hidden = ".hid-#{n}"
      legacy_tenant(hidden)

      assert {:error, :workspace_directory_shared} =
               WorkspaceBundle.import(ctx.path, hidden, cross_tenant: true)

      assert {:error, :not_found} = Workspace.get("#{hidden}:src")
      refute File.exists?(Path.join([root, "tenants", hidden]))
    end

    test "an id that maps to the root or a directory of it exports no files", ctx do
      %{root: root, n: n} = ctx

      secret = Path.join([root, "tenants", "someone-else-#{n}", "secret.md"])
      File.mkdir_p!(Path.dirname(secret))
      File.write!(secret, "not this workspace's")

      for id <- ["default:default", "default:tenants"] do
        legacy_workspace("default", id, "legacy-#{String.replace(id, ":", "-")}-#{n}")

        out =
          Path.join(System.tmp_dir!(), "wsid-export-#{n}-#{String.replace(id, ":", "-")}.tar.gz")

        on_exit(fn -> File.rm(out) end)

        assert {:ok, %{"files" => []}} = WorkspaceBundle.export("default", id, out), id
      end
    end

    # A workspace row written before ids were checked.
    defp legacy_workspace(tenant, id, slug) do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, organization_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?4, 'Legacy', 'active', '{}')",
          [id, tenant, Organization.default_for(tenant), slug]
        )

      on_exit(fn -> Store.raw_query("DELETE FROM workspaces WHERE id = ?1", [id]) end)
    end
  end

  describe "WorkspaceBundle.remove_files/1" do
    test "removes the workspace's own directory and nothing else", %{root: root, n: n} do
      dir = Filesystem.path(root, "default:removable-#{n}")
      File.mkdir_p!(Path.join(dir, "nodes"))
      File.write!(Path.join(dir, "nodes/x.md"), "x")
      keep = Path.join(root, "keep-#{n}.md")
      File.write!(keep, "keep")
      on_exit(fn -> File.rm(keep) end)

      assert :ok = WorkspaceBundle.remove_files("default:removable-#{n}")

      refute File.exists?(dir)
      assert File.exists?(keep)
    end

    test "refuses the root and a directory the root uses", %{root: root, n: n} do
      marker = Path.join(root, "remove-marker-#{n}.md")
      File.write!(marker, "keep")
      on_exit(fn -> File.rm(marker) end)

      for id <- ["default", "default:default", "default:tenants", "default:nodes"] do
        assert {:error, :workspace_directory_shared} = WorkspaceBundle.remove_files(id), id
      end

      assert File.exists?(marker)
    end
  end
end
