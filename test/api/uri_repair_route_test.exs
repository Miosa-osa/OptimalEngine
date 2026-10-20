defmodule OptimalEngine.API.UriRepairRouteTest do
  @moduledoc """
  `GET/POST /api/maintenance/uris`: the plan and the run of
  `OptimalEngine.UriRepair`, for administrators, inside their own tenant.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Context
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.URI, as: OptimalURI
  alias OptimalEngine.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "optimal_uri_route_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    original_root = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, root)

    on_exit(fn ->
      Application.put_env(:optimal_engine, :root_path, original_root)
      File.rm_rf!(root)
    end)

    n = System.unique_integer([:positive])
    tenant = "uri-route-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "URI route tenant"})
    org = "#{tenant}:org"

    {:ok, _} =
      OptimalEngine.Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, ws} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "notes", name: "Notes"})

    {:ok, %{key: admin}} =
      OptimalEngine.Auth.ApiKey.mint(%{
        tenant_id: tenant,
        name: "admin",
        scopes: ["*"],
        workspace_scope: ["*"]
      })

    {:ok, %{key: reader}} =
      OptimalEngine.Auth.ApiKey.mint(%{
        tenant_id: tenant,
        name: "reader",
        scopes: ["read"],
        workspace_scope: ["*"]
      })

    %{root: root, tenant: tenant, ws: ws.id, admin: admin, reader: reader}
  end

  defp call(method, path, key, body \\ nil) do
    conn =
      if body,
        do:
          Plug.Test.conn(method, path, Jason.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json"),
        else: Plug.Test.conn(method, path)

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> key)
    |> OptimalEngine.API.Router.call(OptimalEngine.API.Router.init([]))
  end

  defp seed_pair(ctx) do
    path = Path.join([ctx.root, "uri-route-files", "team", "signals", "2026-03-01-review.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "the last writer's text\n")

    for {id, title, minute} <- [
          {"aaaa1111aaaa1111", "Review", 0},
          {"bbbb2222bbbb2222", "Review", 5}
        ] do
      created = DateTime.new!(~D[2026-03-01], Time.new!(10, minute, 0))

      signal = %Signal{
        id: id,
        path: path,
        title: title,
        mode: :linguistic,
        genre: "note",
        type: :inform,
        format: :markdown,
        created_at: created,
        modified_at: created,
        node: "team",
        sn_ratio: 0.7,
        entities: [],
        l0_summary: "NOTE | team | #{title}",
        l1_description: "text of #{id}",
        content: "text of #{id}",
        routed_to: ["team"]
      }

      :ok =
        Store.insert_context(%Context{
          id: id,
          uri: OptimalURI.from_path(path),
          type: :signal,
          path: path,
          title: title,
          content: "text of #{id}",
          l0_abstract: signal.l0_summary,
          l1_overview: signal.l1_description,
          signal: signal,
          node: "team",
          sn_ratio: 0.7,
          entities: [],
          created_at: created,
          modified_at: created,
          routed_to: ["team"],
          workspace_id: ctx.ws,
          metadata: %{}
        })
    end

    ["aaaa1111aaaa1111", "bbbb2222bbbb2222"]
  end

  defp uris(ids) do
    Enum.map(ids, fn id ->
      {:ok, [[uri]]} = Store.raw_query("SELECT uri FROM contexts WHERE id = ?1", [id])
      uri
    end)
  end

  test "need admin", ctx do
    assert call(:get, "/api/maintenance/uris", ctx.reader).status == 403
    assert call(:post, "/api/maintenance/uris", ctx.reader, %{"apply" => true}).status == 403
  end

  test "GET plans and changes nothing", ctx do
    ids = seed_pair(ctx)
    before = uris(ids)

    conn = call(:get, "/api/maintenance/uris?workspace=#{ctx.ws}&limit=1", ctx.admin)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["dry_run"] == true
    assert body["groups"] == 1
    assert body["groups_remaining"] == 0
    assert body["repaired"] == 1
    assert body["files_written"] == 0
    assert [%{"id" => "bbbb2222bbbb2222", "kept_by" => "aaaa1111aaaa1111"}] = body["changes"]

    assert uris(ids) == before
  end

  test "POST needs apply: true", ctx do
    seed_pair(ctx)

    conn = call(:post, "/api/maintenance/uris", ctx.admin, %{"workspace" => ctx.ws})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "apply=true"
  end

  test "POST apply separates the contexts, and the next plan is empty", ctx do
    ids = seed_pair(ctx)

    conn =
      call(:post, "/api/maintenance/uris", ctx.admin, %{"apply" => true, "workspace" => ctx.ws})

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["dry_run"] == false
    assert body["repaired"] == 1
    assert body["errors"] == []

    assert ids |> uris() |> Enum.uniq() |> length() == 2

    again = call(:get, "/api/maintenance/uris?workspace=#{ctx.ws}", ctx.admin)
    assert Jason.decode!(again.resp_body)["groups"] == 0
  end

  test "without a workspace the run covers the caller's tenant", ctx do
    ids = seed_pair(ctx)

    conn = call(:post, "/api/maintenance/uris", ctx.admin, %{"apply" => true})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["repaired"] == 1
    assert ids |> uris() |> Enum.uniq() |> length() == 2
  end

  test "a workspace outside the caller's tenant is not found", ctx do
    assert call(:get, "/api/maintenance/uris?workspace=default", ctx.admin).status == 404

    assert call(:post, "/api/maintenance/uris", ctx.admin, %{
             "apply" => true,
             "workspace" => "default"
           }).status == 404
  end
end
