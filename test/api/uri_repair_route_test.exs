defmodule OptimalEngine.API.UriRepairRouteTest do
  @moduledoc """
  `GET/POST /api/maintenance/uris`: the plan and the run of
  `OptimalEngine.UriRepair`, for administrators, inside their own tenant and
  the workspaces their key covers. And the reads that answer by URI.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Context
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.URI, as: OptimalURI
  alias OptimalEngine.Workspace
  alias OptimalEngine.Workspace.Filesystem

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

    {:ok, other} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "other", name: "Other"})

    mint = fn name, scopes, workspaces ->
      {:ok, %{key: key}} =
        OptimalEngine.Auth.ApiKey.mint(%{
          tenant_id: tenant,
          name: name,
          scopes: scopes,
          workspace_scope: workspaces
        })

      key
    end

    %{
      root: root,
      tenant: tenant,
      ws: ws.id,
      other: other.id,
      admin: mint.("admin", ["*"], ["*"]),
      reader: mint.("reader", ["read"], ["*"]),
      scoped: mint.("scoped admin", ["*"], [ws.id])
    }
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

  defp context(ws, id, path, title, minute, uri \\ nil) do
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

    %Context{
      id: id,
      uri: uri || OptimalURI.from_path(path),
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
      workspace_id: ws,
      metadata: %{}
    }
  end

  # Two contexts on one path, the last writer's text in the file.
  defp seed_pair(ctx, ws \\ nil, tag \\ "") do
    ws = ws || ctx.ws
    folder = Filesystem.path(ctx.root, ws)
    path = Path.join([folder, "route-files#{tag}", "signals", "2026-03-01-review.md"])
    ids = ["aaaa1111aaaa1111#{tag}", "bbbb2222bbbb2222#{tag}"]

    for {id, minute} <- Enum.zip(ids, [0, 5]) do
      :ok = Store.insert_context(context(ws, id, path, "Review", minute))
    end

    File.mkdir_p!(Path.dirname(path))
    {:ok, last} = Store.get_context(List.last(ids))
    File.write!(path, OptimalEngine.Pipeline.Intake.Writer.render(Context.to_signal(last)))

    ids
  end

  defp uris(ids) do
    Enum.map(ids, fn id ->
      {:ok, [[uri]]} = Store.raw_query("SELECT uri FROM contexts WHERE id = ?1", [id])
      uri
    end)
  end

  describe "who may" do
    test "an administrator only", ctx do
      assert call(:get, "/api/maintenance/uris", ctx.reader).status == 403
      assert call(:post, "/api/maintenance/uris", ctx.reader, %{"apply" => true}).status == 403
    end

    test "a key limited to a workspace may plan and repair that workspace only", ctx do
      seed_pair(ctx)

      assert call(:get, "/api/maintenance/uris?workspace=#{ctx.ws}", ctx.scoped).status == 200
      assert call(:get, "/api/maintenance/uris?workspace=#{ctx.other}", ctx.scoped).status == 403

      denied =
        call(:post, "/api/maintenance/uris", ctx.scoped, %{
          "apply" => true,
          "workspace" => ctx.other
        })

      assert denied.status == 403
    end

    test "the whole tenant needs a key for every workspace", ctx do
      ids = seed_pair(ctx)
      before = uris(ids)

      plan = call(:get, "/api/maintenance/uris", ctx.scoped)
      assert plan.status == 403
      assert Jason.decode!(plan.resp_body)["error"] == "workspace_scope_denied"

      run = call(:post, "/api/maintenance/uris", ctx.scoped, %{"apply" => true})
      assert run.status == 403
      assert uris(ids) == before

      assert call(:get, "/api/maintenance/uris", ctx.admin).status == 200
    end

    test "a workspace outside the caller's tenant is not found", ctx do
      assert call(:get, "/api/maintenance/uris?workspace=default", ctx.admin).status == 404

      assert call(:post, "/api/maintenance/uris", ctx.admin, %{
               "apply" => true,
               "workspace" => "default"
             }).status == 404
    end
  end

  describe "GET" do
    test "plans and changes nothing", ctx do
      ids = seed_pair(ctx)
      before = uris(ids)

      conn = call(:get, "/api/maintenance/uris?workspace=#{ctx.ws}&limit=1", ctx.admin)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["dry_run"] == true
      assert body["groups"] == 1
      assert body["groups_remaining"] == 0
      assert body["next_after"] == nil
      assert body["repaired"] == 1
      assert body["files_written"] == 0
      assert body["files_to_write"] == 1
      assert body["files_to_rewrite"] == 1
      assert body["bytes_to_write"] > 0
      assert body["journal"] == nil
      assert [%{"workspace_id" => _, "groups" => 1, "contexts_to_repair" => 1}] = body["workspaces"]

      assert [group] = body["groups_detail"]
      assert group["status"] == "repair"
      assert group["keeper"]["id"] == hd(ids)

      assert [%{"id" => second, "from_uri" => from, "to_uri" => to, "file" => "absent"}] =
               group["contexts"]

      assert second == List.last(ids)
      assert from != to
      assert group["kept_file"]["action"] == "rewrite"

      assert group["references"] == %{
               "acls" => 0,
               "memories" => 0,
               "open_loops" => 0,
               "events" => 0,
               "wiki_citations" => 0
             }

      assert uris(ids) == before
    end

    test "lists every group by default and pages with `after`", ctx do
      seed_pair(ctx, ctx.ws, "-one")
      seed_pair(ctx, ctx.ws, "-two")

      all = call(:get, "/api/maintenance/uris?workspace=#{ctx.ws}", ctx.admin)
      assert length(Jason.decode!(all.resp_body)["groups_detail"]) == 2

      first = call(:get, "/api/maintenance/uris?workspace=#{ctx.ws}&limit=1", ctx.admin)
      first_body = Jason.decode!(first.resp_body)
      assert first_body["groups_remaining"] == 1
      assert is_binary(first_body["next_after"])

      second =
        call(
          :get,
          "/api/maintenance/uris?workspace=#{ctx.ws}&limit=1&after=#{first_body["next_after"]}",
          ctx.admin
        )

      second_body = Jason.decode!(second.resp_body)
      assert second_body["groups_remaining"] == 0

      uris =
        Enum.map(first_body["groups_detail"] ++ second_body["groups_detail"], & &1["uri"])

      assert length(Enum.uniq(uris)) == 2
    end
  end

  describe "POST" do
    test "needs apply: true", ctx do
      seed_pair(ctx)

      conn = call(:post, "/api/maintenance/uris", ctx.admin, %{"workspace" => ctx.ws})

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "apply=true"
    end

    test "separates the contexts, and the next plan is empty", ctx do
      ids = seed_pair(ctx)

      conn =
        call(:post, "/api/maintenance/uris", ctx.admin, %{"apply" => true, "workspace" => ctx.ws})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["dry_run"] == false
      assert body["repaired"] == 1
      assert body["errors"] == []
      assert File.exists?(body["journal"])

      assert ids |> uris() |> Enum.uniq() |> length() == 2

      again = call(:get, "/api/maintenance/uris?workspace=#{ctx.ws}", ctx.admin)
      assert Jason.decode!(again.resp_body)["groups"] == 0
    end

    test "without a workspace the run covers the caller's tenant", ctx do
      ids = seed_pair(ctx)
      other_ids = seed_pair(ctx, ctx.other, "-o")

      conn = call(:post, "/api/maintenance/uris", ctx.admin, %{"apply" => true})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["repaired"] == 2
      assert ids |> uris() |> Enum.uniq() |> length() == 2
      assert other_ids |> uris() |> Enum.uniq() |> length() == 2
    end

    test "takes `limit` groups and answers where to continue", ctx do
      seed_pair(ctx, ctx.ws, "-one")
      seed_pair(ctx, ctx.ws, "-two")

      conn =
        call(:post, "/api/maintenance/uris", ctx.admin, %{
          "apply" => true,
          "workspace" => ctx.ws,
          "limit" => 1
        })

      body = Jason.decode!(conn.resp_body)
      assert body["groups"] == 1
      assert body["groups_remaining"] == 1
    end
  end

  describe "reads by URI when a URI is still shared" do
    test "GET /api/read answers the active context, then the earliest", ctx do
      path = Path.join(ctx.root, "shared.md")
      early = context(ctx.ws, "early00000000001", path, "Early", 0)
      late = context(ctx.ws, "late000000000002", path, "Late", 9)
      for c <- [late, early], do: :ok = Store.insert_context(c)
      uri = early.uri

      :ok =
        Store.raw_execute(
          "UPDATE contexts SET archived_at = '2026-04-01T00:00:00Z' WHERE id = ?1",
          [
            early.id
          ]
        )

      read = fn ->
        conn =
          call(:get, "/api/read?uri=#{URI.encode_www_form(uri)}&workspace=#{ctx.ws}", ctx.reader)

        assert conn.status == 200
        Jason.decode!(conn.resp_body)["id"]
      end

      # The earlier one is archived: the active one answers.
      assert read.() == late.id

      # Both active: the earliest answers, the one the repair leaves the address with.
      :ok = Store.raw_execute("UPDATE contexts SET archived_at = NULL WHERE id = ?1", [early.id])
      assert read.() == early.id
    end

    test "the citation fetch answers the same context", ctx do
      path = Path.join(ctx.root, "shared-cite.md")
      early = context(ctx.ws, "early00000000003", path, "Early", 0)
      late = context(ctx.ws, "late000000000004", path, "Late", 9)
      for c <- [late, early], do: :ok = Store.insert_context(c)

      :ok =
        Store.raw_execute(
          "UPDATE contexts SET archived_at = '2026-04-01T00:00:00Z' WHERE id = ?1",
          [
            early.id
          ]
        )

      assert {:ok, "text of late000000000004"} =
               OptimalEngine.Retrieval.RAG.fetch_context_body(early.uri)

      :ok = Store.raw_execute("UPDATE contexts SET archived_at = NULL WHERE id = ?1", [early.id])

      assert {:ok, "text of early00000000003"} =
               OptimalEngine.Retrieval.RAG.fetch_context_body(early.uri)
    end
  end
end
