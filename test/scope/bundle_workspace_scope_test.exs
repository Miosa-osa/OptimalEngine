defmodule OptimalEngine.BundleWorkspaceScopeTest do
  @moduledoc """
  A bundle holds one workspace's data. A key downloads or imports a stored
  bundle only when its workspace scope covers the workspace the bundle was
  exported from, and a bundle's name cannot be guessed from its workspace and
  the time of the export.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Organization, Workspace}
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "bundle-scope-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Bundle scope #{n}"})

    {:ok, _} =
      Organization.create(%{id: "#{tenant}:org", tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, open} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "open",
        name: "Open"
      })

    {:ok, private} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "private",
        name: "Private"
      })

    copy = "#{tenant}:copy"

    ctx = %{
      tenant: tenant,
      open: open.id,
      private: private.id,
      copy: copy,
      all: mint(tenant, ["*"]),
      only_open: mint(tenant, [open.id]),
      only_private: mint(tenant, [private.id]),
      open_and_copy: mint(tenant, [open.id, copy])
    }

    Map.merge(ctx, %{
      open_bundle: export!(ctx, open.id),
      private_bundle: export!(ctx, private.id)
    })
  end

  describe "the name of an export" do
    test "holds a random part, so two exports in one second differ", ctx do
      second = export!(ctx, ctx.open)

      assert ctx.open_bundle != second

      for name <- [ctx.open_bundle, second] do
        assert name =~ ~r/\A[a-z0-9-]+-\d{10}-[0-9a-f]{16}\.tar\.gz\z/
      end
    end
  end

  describe "downloading a stored bundle" do
    test "needs a workspace scope that covers the workspace it came from", ctx do
      assert download(ctx.only_open, ctx.open_bundle).status == 200
      assert download(ctx.only_private, ctx.private_bundle).status == 200
      assert download(ctx.all, ctx.open_bundle).status == 200
      assert download(ctx.all, ctx.private_bundle).status == 200

      for {key, name} <- [{ctx.only_open, ctx.private_bundle}, {ctx.only_private, ctx.open_bundle}] do
        refused = download(key, name)

        assert refused.status == 404
        assert Jason.decode!(refused.resp_body) == %{"error" => "bundle not found"}
      end
    end
  end

  describe "importing a stored bundle by name" do
    test "needs a workspace scope that covers the workspace it came from", ctx do
      body = %{"workspace_id" => ctx.copy, "organization_id" => "#{ctx.tenant}:org"}

      refused = import_by_name(ctx.open_and_copy, Map.put(body, "bundle", ctx.private_bundle))

      assert refused.status == 404
      assert {:error, :not_found} = Workspace.get(ctx.copy)

      imported = import_by_name(ctx.open_and_copy, Map.put(body, "bundle", ctx.open_bundle))

      assert imported.status == 201
      assert {:ok, _workspace} = Workspace.get(ctx.copy)
    end
  end

  describe "importing a stored bundle by name, as a job" do
    test "needs a workspace scope that covers the workspace it came from", ctx do
      body = %{"workspace_id" => ctx.copy, "organization_id" => "#{ctx.tenant}:org"}

      refused = import_job(ctx.open_and_copy, Map.put(body, "bundle", ctx.private_bundle))

      assert refused.status == 404
      assert Jason.decode!(refused.resp_body)["error"] == "bundle_not_found"
      assert {:error, :not_found} = Workspace.get(ctx.copy)

      # The target is covered but the bundle's workspace is not: nothing is queued.
      listed = call(:get, "/api/bundles/jobs", ctx.all, nil)
      assert Jason.decode!(listed.resp_body)["count"] == 0

      accepted = import_job(ctx.open_and_copy, Map.put(body, "bundle", ctx.open_bundle))
      assert accepted.status == 202

      # Nothing runs it here; leave the workspace free for the next test.
      job_id = Jason.decode!(accepted.resp_body)["job_id"]
      assert call(:post, "/api/bundles/jobs/#{job_id}/cancel", ctx.all, nil).status == 200
    end
  end

  describe "deleting a stored bundle" do
    test "needs the workspace scope that covers its workspace, and removes the file", ctx do
      private_path = stored(ctx, ctx.private_bundle)

      refused = delete(ctx.only_open, ctx.private_bundle)
      assert refused.status == 404
      assert Jason.decode!(refused.resp_body) == %{"error" => "bundle not found"}
      assert File.regular?(private_path)

      gone = delete(ctx.only_open, ctx.open_bundle)
      assert gone.status == 204
      assert gone.resp_body == ""
      refute File.exists?(stored(ctx, ctx.open_bundle))

      assert download(ctx.all, ctx.open_bundle).status == 404
      assert delete(ctx.only_open, ctx.open_bundle).status == 404
      assert File.regular?(private_path)
    end

    test "is for the admin grant", ctx do
      {:ok, %{key: writer}} =
        ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "writer",
          scopes: ["read", "write"],
          workspace_scope: ["*"]
        })

      assert delete(writer, ctx.open_bundle).status == 403
      assert File.regular?(stored(ctx, ctx.open_bundle))
    end

    test "never reaches another tenant's bundle", ctx do
      other = "bundle-other-#{System.unique_integer([:positive])}"
      {:ok, _} = Tenant.create(%{id: other, name: "Other"})
      intruder = mint(other, ["*"])

      assert delete(intruder, ctx.open_bundle).status == 404
      assert File.regular?(stored(ctx, ctx.open_bundle))

      # Copied into the other tenant's folder it still names its own tenant.
      copy = Path.join(WorkspaceBundle.bundle_dir(other), ctx.open_bundle)
      File.cp!(stored(ctx, ctx.open_bundle), copy)

      assert delete(intruder, ctx.open_bundle).status == 404
      assert File.regular?(copy)
    end

    test "a name that is no bundle is not found", ctx do
      assert delete(ctx.all, "no-such-bundle.tar.gz").status == 404
      assert delete(ctx.all, "not-a-bundle").status == 404
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp stored(ctx, name), do: Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), name)

  defp delete(key, name), do: call(:delete, "/api/bundles/#{name}", key, nil)

  defp mint(tenant, workspace_scope) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "bundle scope #{System.unique_integer([:positive])}",
        scopes: ["admin"],
        workspace_scope: workspace_scope
      })

    key
  end

  defp export!(ctx, workspace_id) do
    conn =
      call(:post, "/api/workspaces/#{URI.encode_www_form(workspace_id)}/bundle", ctx.all, %{})

    assert conn.status == 201
    Jason.decode!(conn.resp_body)["bundle"]
  end

  defp download(key, name), do: call(:get, "/api/bundles/#{name}", key, nil)

  defp import_by_name(key, body), do: call(:post, "/api/bundles/import", key, body)

  defp import_job(key, body), do: call(:post, "/api/bundles/jobs/import", key, body)

  defp call(method, path, key, body) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    with_auth(fn ->
      conn |> put_req_header("authorization", "Bearer " <> key) |> Router.call(Router.init([]))
    end)
  end

  defp with_auth(fun) do
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
end
