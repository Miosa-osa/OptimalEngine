defmodule OptimalEngine.API.NotionImportAPITest do
  @moduledoc """
  `POST /api/import/notion`, `GET /api/import/notion/:job_id` and
  `GET /api/import/notion/tree` end to end: upload or URL, the durable job,
  the status report, search and read with citations, the hierarchy, scopes,
  limits and refusals. Each test runs in its own tenant.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Imports
  alias OptimalEngine.Imports.Notion
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/export.zip"} = conn, opts), do: send_resp(conn, 200, opts[:body])
    def call(conn, _opts), do: send_resp(conn, 404, "missing")
  end

  setup do
    n = System.unique_integer([:positive])
    tenant = "import-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Import #{n}"})
    workspace = workspace!(tenant, "docs")
    other = workspace!(tenant, "other")

    %{
      tenant: tenant,
      workspace: workspace,
      other: other,
      writer: key(tenant, ["read", "write"], [workspace]),
      reader: key(tenant, ["read"], [workspace]),
      outsider: key(tenant, ["read", "write"], [other]),
      root: key(tenant, ["*"], ["*"])
    }
  end

  defp workspace!(tenant, slug, status \\ "active") do
    id = "#{tenant}:#{slug}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?3, ?4, '{}')",
        [id, tenant, slug, status]
      )

    id
  end

  defp key(tenant, scopes, workspaces) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "k", scopes: scopes, workspace_scope: workspaces})

    key
  end

  defp upload(workspace, bytes, token, headers \\ []) do
    conn(:post, "/api/import/notion?" <> URI.encode_query(%{workspace: workspace}), bytes)
    |> put_req_header("content-type", "application/zip")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(fn conn -> Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end) end)
    |> Router.call(Router.init([]))
  end

  defp post_json(body, token) do
    conn(:post, "/api/import/notion", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  defp get(path, params, token) do
    conn(:get, path <> "?" <> URI.encode_query(params))
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp drain(workspace), do: Imports.drain(workspace_id: workspace)

  defp put_env(key, value) do
    previous = Application.get_env(:optimal_engine, key)
    Application.put_env(:optimal_engine, key, value)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:optimal_engine, key),
        else: Application.put_env(:optimal_engine, key, previous)
    end)
  end

  test "an uploaded export becomes a job, then searchable and readable pages with citations", ctx do
    i = Fixture.ids()
    conn = upload(ctx.workspace, Fixture.export(), ctx.writer)

    assert conn.status == 202

    assert %{"job_id" => "job_" <> _ = job_id, "status" => "queued", "duplicate" => false} =
             accepted = body(conn)

    assert accepted["kind"] == "import.notion"

    assert accepted["status_url"] ==
             "/api/import/notion/#{job_id}?workspace=#{URI.encode_www_form(ctx.workspace)}"

    queued = body(get("/api/import/notion/#{job_id}", %{workspace: ctx.workspace}, ctx.reader))
    assert queued["status"] == "queued"
    assert queued["source"]["kind"] == "upload"
    assert queued["source"]["bytes"] == byte_size(Fixture.export())

    assert {:ok, %{status: "completed"}} = drain(ctx.workspace)

    status = body(get("/api/import/notion/#{job_id}", %{workspace: ctx.workspace}, ctx.reader))
    assert status["status"] == "completed"
    assert status["attempts"] == 1
    assert status["counts"]["pages"] == 5
    assert status["counts"]["contexts"] == 7
    assert status["counts"]["edges_child_of"] == 5
    assert status["counts"]["edges_links_to"] == 3
    assert status["progress"] == %{"done" => 7, "total" => 7}
    assert status["errors"] == []
    assert status["started_at"] && status["finished_at"]

    write_guide = Notion.uri(ctx.workspace, i.write_guide)
    search = body(get("/api/search", %{q: "zephyr", workspace: ctx.workspace}, ctx.reader))
    assert Enum.any?(search["results"], &(&1["uri"] == write_guide))

    first_week = Notion.uri(ctx.workspace, i.first_week)

    read =
      body(get("/api/read", %{uri: first_week, workspace: ctx.workspace, tier: "full"}, ctx.reader))

    assert read["title"] == "First Week"
    assert read["text"] =~ "quartz ledger"

    # The staged source is gone; the report stays.
    {:ok, job} = OptimalEngine.Jobs.get(job_id, ctx.workspace)
    folder = Path.join(Imports.dir(), job.payload["import_id"])
    assert File.ls!(folder) == ["report.json"]
  end

  test "the tree route shows the imported hierarchy", ctx do
    i = Fixture.ids()
    assert upload(ctx.workspace, Fixture.export(), ctx.writer).status == 202
    {:ok, _} = drain(ctx.workspace)

    roots = body(get("/api/import/notion/tree", %{workspace: ctx.workspace}, ctx.reader))
    assert roots["parent"] == nil
    assert Enum.map(roots["pages"], & &1["page_id"]) == [i.standalone, i.handbook]

    children =
      body(
        get(
          "/api/import/notion/tree",
          %{workspace: ctx.workspace, parent: i.onboarding},
          ctx.reader
        )
      )

    assert [%{"page_id" => first_week, "title" => "First Week", "children" => 0}] =
             children["pages"]

    assert first_week == i.first_week

    assert get("/api/import/notion/tree", %{workspace: ctx.workspace, parent: "../etc"}, ctx.reader).status ==
             400

    missing =
      get(
        "/api/import/notion/tree",
        %{workspace: ctx.workspace, parent: String.duplicate("f", 32)},
        ctx.reader
      )

    assert missing.status == 404
  end

  test "a repeated Idempotency-Key returns the first job", ctx do
    headers = [{"idempotency-key", "export-2026-10-20"}]
    first = body(upload(ctx.workspace, Fixture.export(), ctx.writer, headers))
    second = upload(ctx.workspace, Fixture.export(), ctx.writer, headers)

    assert second.status == 202
    assert %{"job_id" => same, "duplicate" => true} = body(second)
    assert same == first["job_id"]

    {:ok, jobs} = OptimalEngine.Jobs.list(ctx.workspace)
    assert length(Enum.filter(jobs, &(&1.kind == "import.notion"))) == 1
  end

  test "a refused archive fails at once with its code", ctx do
    slip =
      Fixture.raw_zip([
        %{name: "Page aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", data: "# Page"},
        %{name: "../evil.md", data: "x"}
      ])

    %{"job_id" => job_id} = body(upload(ctx.workspace, slip, ctx.writer))

    {:ok, _} = drain(ctx.workspace)
    status = body(get("/api/import/notion/#{job_id}", %{workspace: ctx.workspace}, ctx.reader))

    assert status["status"] == "failed"
    assert status["attempts"] == 1
    assert status["last_error"] == "unsafe_path: ../evil.md"
    assert status["failure"] == %{"code" => "unsafe_path", "detail" => "../evil.md"}
  end

  test "a presigned source URL is downloaded by the job and its signature is never logged, stored or returned",
       ctx do
    i = Fixture.ids()
    ref = :"notion_export_#{System.unique_integer([:positive])}"
    {:ok, _} = Plug.Cowboy.http(Server, [body: Fixture.export()], port: 0, ref: ref)
    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    port = :ranch.get_port(ref)
    put_env(:import_url_hosts, ["127.0.0.1"])

    signature = "sig#{System.unique_integer([:positive])}deadbeef"
    query = "X-Amz-Credential=key%2F20261020&X-Amz-Signature=#{signature}"
    url = "http://127.0.0.1:#{port}/export.zip?#{query}"
    missing = "http://127.0.0.1:#{port}/gone.zip?#{query}"

    {{job_id, retry_id}, log} =
      with_log(fn ->
        conn =
          conn(
            :post,
            "/api/import/notion",
            Jason.encode!(%{workspace: ctx.workspace, source_url: url})
          )
          |> put_req_header("content-type", "application/json")
          |> put_req_header("idempotency-key", "notion-#{System.unique_integer([:positive])}")
          |> put_req_header("authorization", "Bearer " <> ctx.writer)
          |> Router.call(Router.init([]))

        assert conn.status == 202
        %{"job_id" => job_id} = body(conn)
        {:ok, _} = drain(ctx.workspace)

        # A URL that answers 404 is a failed attempt that will be retried.
        %{"job_id" => retry_id} =
          body(post_json(%{workspace: ctx.workspace, source_url: missing}, ctx.writer))

        {:ok, _} = drain(ctx.workspace)
        {job_id, retry_id}
      end)

    status = get("/api/import/notion/#{job_id}", %{workspace: ctx.workspace}, ctx.reader)
    assert body(status)["status"] == "completed"

    assert body(status)["source"] == %{
             "kind" => "url",
             "url" => "http://127.0.0.1:#{port}/export.zip"
           }

    assert body(status)["counts"]["contexts"] == 7

    retry = get("/api/import/notion/#{retry_id}", %{workspace: ctx.workspace}, ctx.reader)
    assert body(retry)["status"] == "retrying"
    assert body(retry)["last_error"] == "download_failed: http 404"

    {:ok, job} = OptimalEngine.Jobs.get(job_id, ctx.workspace)
    {:ok, retry_job} = OptimalEngine.Jobs.get(retry_id, ctx.workspace)
    jobs = get("/api/jobs", %{workspace: ctx.workspace}, ctx.reader).resp_body
    report = File.read!(Path.join([Imports.dir(), job.payload["import_id"], "report.json"]))

    for {where, text} <- [
          log: log,
          job_row: inspect(job),
          retry_row: inspect(retry_job),
          job_list: jobs,
          status: status.resp_body,
          retry_status: retry.resp_body,
          report: report
        ] do
      refute text =~ signature, "the signature appears in #{where}"
      refute text =~ "X-Amz-Credential", "the query string appears in #{where}"
    end

    # The URL file goes once the zip is down; the retrying job still has its own.
    refute File.exists?(Path.join([Imports.dir(), job.payload["import_id"], "source.url"]))
    assert File.exists?(Path.join([Imports.dir(), retry_job.payload["import_id"], "source.url"]))

    read =
      get(
        "/api/read",
        %{uri: Notion.uri(ctx.workspace, i.handbook), workspace: ctx.workspace},
        ctx.reader
      )

    assert read.status == 200
  end

  test "source URLs that are not public https are refused before a job exists", ctx do
    for {url, code} <- [
          {"https://127.0.0.1/export.zip", "source_url_refused"},
          {"https://10.1.2.3/export.zip", "source_url_refused"},
          {"http://example.com/export.zip", "invalid_source_url"},
          {"ftp://example.com/export.zip", "invalid_source_url"},
          {"https://169.254.169.254/latest/meta-data", "source_url_refused"},
          {"https://user:secret@example.com/export.zip", "invalid_source_url"},
          {"/local/export.zip", "invalid_source_url"}
        ] do
      conn = post_json(%{workspace: ctx.workspace, source_url: url}, ctx.writer)
      assert {conn.status, body(conn)} == {400, %{"error" => code}}, url
    end

    # With allowed hosts configured, no other host is fetched.
    put_env(:import_url_hosts, ["storage.internal"])

    conn =
      post_json(
        %{workspace: ctx.workspace, source_url: "https://93.184.216.34/export.zip"},
        ctx.writer
      )

    assert {conn.status, body(conn)} == {400, %{"error" => "source_url_refused"}}

    assert body(post_json(%{workspace: ctx.workspace}, ctx.writer)) == %{
             "error" => "source_required"
           }

    {:ok, jobs} = OptimalEngine.Jobs.list(ctx.workspace)
    assert jobs == []
  end

  test "uploads over the limit and empty uploads are refused and leave nothing staged", ctx do
    put_env(:import_max_bytes, 100)
    before = if File.dir?(Imports.dir()), do: File.ls!(Imports.dir()), else: []

    conn = upload(ctx.workspace, Fixture.export(), ctx.writer)
    assert conn.status == 413
    assert body(conn) == %{"error" => "import_too_large", "max_bytes" => 100}

    conn = upload(ctx.workspace, "", ctx.writer)
    assert {conn.status, body(conn)} == {400, %{"error" => "empty_upload"}}

    after_ = if File.dir?(Imports.dir()), do: File.ls!(Imports.dir()), else: []
    assert Enum.sort(after_) == Enum.sort(before)
  end

  test "scopes, workspace scope and tenants are enforced", ctx do
    assert body(upload(ctx.workspace, Fixture.export(), ctx.reader)) == %{
             "error" => "permission_scope_denied"
           }

    assert body(upload(ctx.workspace, Fixture.export(), ctx.outsider)) == %{
             "error" => "workspace_scope_denied"
           }

    stranger = "stranger-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.create(%{id: stranger, name: "Stranger"})
    foreign = workspace!(stranger, "docs")
    assert upload(foreign, Fixture.export(), ctx.root).status == 404

    archived = workspace!(ctx.tenant, "archived", "archived")
    assert upload(archived, Fixture.export(), ctx.root).status == 404

    %{"job_id" => job_id} = body(upload(ctx.workspace, Fixture.export(), ctx.writer))
    assert get("/api/import/notion/#{job_id}", %{workspace: ctx.other}, ctx.root).status == 404

    assert get("/api/import/notion/job_missing", %{workspace: ctx.workspace}, ctx.root).status ==
             404

    {:ok, reindex, _} = OptimalEngine.Reindex.enqueue(ctx.workspace)

    assert get("/api/import/notion/#{reindex.id}", %{workspace: ctx.workspace}, ctx.root).status ==
             404
  end
end
