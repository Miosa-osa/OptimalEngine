defmodule OptimalEngine.Portability.ExportSpaceTest do
  @moduledoc """
  An export checks, before it stages anything, that the disk holds what it will
  write (the workspace's rows as JSON lines, its files, and the archive made of
  them) plus a margin for the database's own writes while the export holds its
  snapshot. A disk that cannot is a retryable 507 `insufficient_storage`, from
  the route and from a job, and the check leaves nothing behind.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Organization, Store, Workspace}
  alias OptimalEngine.Portability.{BundleJobs, WorkspaceBundle}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace.Filesystem

  @content_bytes 200_000
  # More than any disk holds.
  @huge_margin 1_000_000_000_000_000_000

  setup do
    drain_all()
    n = System.unique_integer([:positive])
    tenant = "export-space-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Export space #{n}"})

    {:ok, _} =
      Organization.create(%{id: "#{tenant}:org", tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, big} = workspace(tenant, "big")
    {:ok, small} = workspace(tenant, "small")

    for i <- 1..3,
        do: context(tenant, big.id, "big-#{n}-#{i}", String.duplicate("x", @content_bytes))

    context(tenant, small.id, "small-#{n}-1", "a note")

    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "admin", scopes: ["*"], workspace_scope: ["*"]})

    previous = Application.fetch_env(:optimal_engine, :bundle_export_margin_bytes)

    on_exit(fn ->
      restore(:bundle_export_margin_bytes, previous)
      drain_all()
    end)

    %{tenant: tenant, n: n, big: big.id, small: small.id, key: key}
  end

  describe "the size of an export" do
    test "counts the workspace's own rows, not another workspace's", ctx do
      big = WorkspaceBundle.export_bytes(ctx.tenant, ctx.big)
      small = WorkspaceBundle.export_bytes(ctx.tenant, ctx.small)

      assert big >= 3 * @content_bytes
      assert big < 3 * @content_bytes + 50_000
      assert small < 50_000
    end

    test "counts the workspace's files", ctx do
      before = WorkspaceBundle.export_bytes(ctx.tenant, ctx.small)
      dir = Filesystem.path(Application.get_env(:optimal_engine, :root_path), ctx.small)
      File.mkdir_p!(Path.join(dir, "nodes/notes"))
      File.write!(Path.join(dir, "nodes/notes/blob.bin"), :crypto.strong_rand_bytes(300_000))
      on_exit(fn -> File.rm_rf(dir) end)

      assert WorkspaceBundle.export_bytes(ctx.tenant, ctx.small) - before >= 300_000
    end
  end

  describe "POST /api/workspaces/:id/bundle" do
    test "exports when the disk holds the export and the margin", ctx do
      assert export(ctx, ctx.big).status == 201
    end

    test "answers 507 insufficient_storage, retryable, when the disk cannot hold it", ctx do
      Application.put_env(:optimal_engine, :bundle_export_margin_bytes, @huge_margin)
      before = bundles(ctx)
      staged = staging()

      conn = export(ctx, ctx.big)

      assert conn.status == 507
      assert conn.resp_body =~ "insufficient_storage"
      assert get_resp_header(conn, "retry-after") != []
      assert bundles(ctx) == before
      assert staging() == staged
    end

    test "a move is not prepared by an export that was refused", ctx do
      Application.put_env(:optimal_engine, :bundle_export_margin_bytes, @huge_margin)

      assert export(ctx, ctx.big, %{"for_move" => true}).status == 507
      assert pending_moves(ctx) == 0

      Application.delete_env(:optimal_engine, :bundle_export_margin_bytes)
      assert export(ctx, ctx.big, %{"for_move" => true}).status == 201
      assert pending_moves(ctx) == 1
    end
  end

  describe "an export job" do
    test "that finds no room fails retryable, leaves no file, and is tried again", ctx do
      Application.put_env(:optimal_engine, :bundle_export_margin_bytes, @huge_margin)
      before = bundles(ctx)
      staged = staging()

      {:ok, view, :queued} = BundleJobs.submit_export(ctx.tenant, ctx.big, %{})
      {:ok, done} = BundleJobs.drain()

      assert done.job_id == view.job_id
      assert done.status == "retrying"
      assert done.error["code"] == "insufficient_storage"
      assert done.error["retryable"] == true
      assert bundles(ctx) == before
      assert staging() == staged

      # The retry stays queued: cancelled, so no later module's claim takes it.
      assert {:ok, _view, :cancelled} = BundleJobs.cancel(ctx.tenant, view.job_id)
    end
  end

  defp workspace(tenant, slug) do
    Workspace.create(%{
      tenant_id: tenant,
      organization_id: "#{tenant}:org",
      slug: slug,
      name: slug
    })
  end

  defp context(tenant, workspace, id, content) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at, uri) VALUES (?1, ?2, ?3, ?1, ?4, '2026-10-14T10:00:00Z', ?5)",
        [id, tenant, workspace, content, "optimal://#{workspace}/contexts/#{id}"]
      )
  end

  defp export(ctx, workspace_id, body \\ %{}) do
    path = "/api/workspaces/#{URI.encode_www_form(workspace_id)}/bundle"

    with_auth(fn ->
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> ctx.key)
      |> Router.call(Router.init([]))
    end)
  end

  defp pending_moves(ctx) do
    {:ok, [[n]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM uri_redirects WHERE tenant_id = ?1 AND workspace_id = ?2 AND state = 'pending'",
        [ctx.tenant, ctx.big]
      )

    n
  end

  defp bundles(ctx), do: Path.wildcard(Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), "*"))

  # Staging folders of the exports and imports under way or left behind.
  defp staging do
    Path.wildcard(Path.join([WorkspaceBundle.backup_dir(), "staging", "bundle-*"]))
  end

  defp drain_all do
    case BundleJobs.drain() do
      {:ok, :idle} -> :ok
      _ -> drain_all()
    end
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

  defp restore(key, {:ok, value}), do: Application.put_env(:optimal_engine, key, value)
  defp restore(key, :error), do: Application.delete_env(:optimal_engine, key)
end
