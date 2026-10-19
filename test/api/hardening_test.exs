defmodule OptimalEngine.API.HardeningTest do
  @moduledoc """
  Closes issues found while proving the Engine: workspace ids that are paths,
  server file imports through /api/assets, subscription ids from other
  tenants, keys minted for missing tenants, the tenant of ingested contexts,
  and the verified-key cache.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.{ApiKey, KeyCache}
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "harden-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Harden #{n}"})
    workspace = "#{tenant}:ops"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'ops', 'ops', 'active', '{}')",
        [workspace, tenant]
      )

    %{tenant: tenant, workspace: workspace, n: n}
  end

  defp key(tenant, scopes, workspaces) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "k", scopes: scopes, workspace_scope: workspaces})

    key
  end

  defp call(method, path, token, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, Router.init([]))
  end

  # The request raises after the error handler answered; the test adapter
  # reports the sent response to this process.
  defp error_sent(fun) do
    try do
      fun.()
      flunk("expected the request to raise after sending a response")
    rescue
      _ ->
        receive do
          {ref, {status, headers, body}} when is_reference(ref) -> {status, headers, body}
        after
          0 -> flunk("no response was sent")
        end
    end
  end

  test "a workspace id that is a path is refused", ctx do
    root = key(ctx.tenant, ["*"], ["*"])

    for id <- ["../etc", "a/b", "x:../y", "..", "a\\b"] do
      conn = call(:get, "/api/boot?workspace=#{URI.encode_www_form(id)}", root)
      assert conn.status == 400, "#{id}: #{conn.status}"
    end

    assert call(:get, "/api/boot?workspace=#{ctx.workspace}", root).status == 200
  end

  test "importing a server file needs an admin key and a path inside an import root", ctx do
    root_dir = Application.get_env(:optimal_engine, :root_path)
    inside = Path.join(root_dir, "harden-#{ctx.n}.txt")
    outside_dir = Path.join(System.tmp_dir!(), "harden-outside-#{ctx.n}")
    outside = Path.join(outside_dir, "secret.txt")
    link = Path.join(root_dir, "harden-link-#{ctx.n}")
    File.mkdir_p!(root_dir)
    File.mkdir_p!(outside_dir)
    File.write!(inside, "inside the root")
    File.write!(outside, "outside the root")
    File.ln_s!(outside_dir, link)

    on_exit(fn ->
      File.rm(inside)
      File.rm(link)
      File.rm_rf(outside_dir)
    end)

    admin = key(ctx.tenant, ["*"], ["*"])
    writer = key(ctx.tenant, ["read", "write"], [ctx.workspace])
    body = fn path -> %{"workspace" => ctx.workspace, "path" => path} end

    assert call(:post, "/api/assets", writer, body.(inside)).status == 403
    assert call(:post, "/api/assets", admin, body.(outside)).status == 403
    assert call(:post, "/api/assets", admin, body.(Path.join(link, "secret.txt"))).status == 403

    assert call(
             :post,
             "/api/assets",
             admin,
             body.(Path.join([root_dir, "..", Path.basename(outside_dir), "secret.txt"]))
           ).status == 403

    assert call(:post, "/api/assets", admin, body.(inside)).status == 201

    upload = %{
      "workspace" => ctx.workspace,
      "filename" => "note.txt",
      "content_base64" => Base.encode64("uploaded")
    }

    assert call(:post, "/api/assets", writer, upload).status == 201
  end

  test "subscription ids from another tenant or workspace are not found", ctx do
    {:ok, sub} =
      OptimalEngine.Memory.Subscription.create(%{workspace_id: ctx.workspace, scope: :workspace})

    other_tenant = "harden-other-#{ctx.n}"
    {:ok, _} = Tenant.create(%{id: other_tenant, name: "Other"})
    stranger = key(other_tenant, ["*"], ["*"])
    narrow = key(ctx.tenant, ["read", "write"], ["#{ctx.tenant}:sales"])
    owner = key(ctx.tenant, ["read", "write"], [ctx.workspace])

    for path <- ["/api/subscriptions/#{sub.id}/pause", "/api/subscriptions/#{sub.id}/resume"] do
      assert call(:post, path, stranger, %{}).status == 404
    end

    assert call(:delete, "/api/subscriptions/#{sub.id}", stranger).status == 404
    assert call(:post, "/api/subscriptions/#{sub.id}/test-webhook", stranger, %{}).status == 404

    assert call(:post, "/api/subscriptions/#{sub.id}/pause", owner, %{"workspace" => ctx.workspace}).status ==
             204

    assert call(:delete, "/api/subscriptions/#{sub.id}?workspace=#{ctx.workspace}", narrow).status in [
             403,
             404
           ]

    assert call(:delete, "/api/subscriptions/#{sub.id}?workspace=#{ctx.workspace}", owner).status ==
             204
  end

  test "keys are minted only for tenants that exist", ctx do
    assert {:error, :tenant_not_found} =
             ApiKey.mint(%{tenant_id: "missing-#{ctx.n}", name: "k", scopes: ["*"]})
  end

  test "ingested contexts carry the workspace's tenant", ctx do
    writer = key(ctx.tenant, ["read", "write"], [ctx.workspace])

    conn =
      call(:post, "/api/ingest", writer, %{
        "workspace" => ctx.workspace,
        "title" => "Tenant check",
        "text" => "The renewal call moved to Thursday."
      })

    assert conn.status == 200
    id = Jason.decode!(conn.resp_body)["signal_id"]

    {:ok, [[tenant]]} = Store.raw_query("SELECT tenant_id FROM contexts WHERE id = ?1", [id])
    assert tenant == ctx.tenant
  end

  test "offsite backup routes need an admin key and restore only inside the restore directory",
       ctx do
    writer = key(ctx.tenant, ["read", "write"], ["*"])
    admin = key(ctx.tenant, ["*"], ["*"])

    restore = fn token, target ->
      call(:post, "/api/backup/offsite/restore", token, %{
        "backup_id" => "backup_missing",
        "target" => target
      })
    end

    assert call(:get, "/api/backup/offsite", writer).status == 403
    assert restore.(writer, "drill.db").status == 403

    victim = Path.join(System.tmp_dir!(), "harden-victim-#{ctx.n}.txt")
    File.write!(victim, "keep me")
    on_exit(fn -> File.rm(victim) end)

    restores = Path.join(OptimalEngine.Backup.backup_dir(), "restores")
    File.mkdir_p!(restores)
    link = Path.join(restores, "harden-link-#{ctx.n}.db")
    File.ln_s!(victim, link)
    on_exit(fn -> File.rm(link) end)

    live = Application.get_env(:optimal_engine, :db_path)

    for target <- [victim, "../escape-#{ctx.n}.db", "nested/x.db", "", Path.basename(link), live] do
      assert restore.(admin, target).status == 400, "#{inspect(target)}"
    end

    assert File.read!(victim) == "keep me"
    assert restore.(admin, "drill-#{ctx.n}.db").status == 404
    assert call(:get, "/api/backup/offsite", admin).status == 200
  end

  test "the corpus organization preview needs an admin key", ctx do
    reader = key(ctx.tenant, ["read"], ["*"])
    admin = key(ctx.tenant, ["*"], ["*"])

    assert call(:get, "/api/maintenance/corpus-organization", reader).status == 403
    assert call(:get, "/api/maintenance/corpus-organization", admin).status == 200
  end

  test "a malformed JSON body is a 400 with a JSON error, not an empty 500", ctx do
    writer = key(ctx.tenant, ["read", "write"], [ctx.workspace])

    for body <- [~s({"workspace":), "not json", ~s({"title":"a\\q"})] do
      {status, _headers, resp} =
        error_sent(fn ->
          conn(:post, "/api/ingest", body)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> writer)
          |> Router.call(Router.init([]))
        end)

      assert status == 400
      assert %{"error" => "invalid_json"} = Jason.decode!(resp)
    end
  end

  test "a verified key skips bcrypt but still honors revocation", ctx do
    {:ok, %{id: id, key: token, secret: secret}} =
      ApiKey.mint(%{tenant_id: ctx.tenant, name: "cached", scopes: ["*"], workspace_scope: ["*"]})

    assert {:ok, _} = ApiKey.verify(token)
    {:ok, [[hash]]} = Store.raw_query("SELECT hashed_secret FROM api_keys WHERE id = ?1", [id])
    assert KeyCache.verified?(id, secret, hash)
    refute KeyCache.verified?(id, secret <> "x", hash)
    refute KeyCache.verified?(id, secret, hash <> "x")

    assert {:error, :invalid} = ApiKey.verify("oe_#{id}_wrongsecret")
    :ok = ApiKey.revoke(id)
    assert {:error, :revoked} = ApiKey.verify(token)
  end
end
