defmodule OptimalEngine.Imports.NotionScaleTest do
  @moduledoc """
  The size criterion, run the way MIOSA calls the Engine: a 100 MB synthetic
  Notion export sits behind a presigned-style URL, `POST /api/import/notion`
  names it as `source_url` with an `Idempotency-Key`, the job downloads and
  imports it, and `GET /api/import/notion/:job_id` is polled until it is
  done. Within ten minutes of the POST, sampled pages are searchable with
  citations to their own URIs, and the hierarchy holds: the `child_of` and
  `links_to` edges are all there and point at the right pages.

  Excluded by default (`:notion_scale`); run it with

      mix test test/imports/notion_scale_test.exs --only notion_scale

  `NOTION_SCALE_MB` sets the Markdown and CSV text in MB (default 100),
  `NOTION_SCALE_ASSET_MB` adds incompressible attachments (default 0), which
  grow the zip without adding pages, and `NOTION_SCALE_SOURCE=upload` posts
  the zip as the body instead of a URL. The test prints its timings.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Graph
  alias OptimalEngine.Imports
  alias OptimalEngine.Imports.Notion
  alias OptimalEngine.Imports.Notion.Plan
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture

  @moduletag :notion_scale
  @moduletag timeout: :infinity

  @budget_ms 600_000
  @sections 20
  @samples 25

  defmodule Bucket do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/exports/notion.zip"} = conn, opts),
      do: send_file(conn, 200, opts[:path])

    def call(conn, _opts), do: send_resp(conn, 404, "")
  end

  test "a 100 MB export is searchable with citations within ten minutes and keeps its hierarchy" do
    mb = env_int("NOTION_SCALE_MB", 100)
    asset_mb = env_int("NOTION_SCALE_ASSET_MB", 0)
    source = System.get_env("NOTION_SCALE_SOURCE", "url")

    n = System.unique_integer([:positive])
    tenant = "scale-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Scale #{n}"})
    workspace = "#{tenant}:docs"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'docs', 'docs', 'active', '{}')",
        [workspace, tenant]
      )

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "k",
        scopes: ["read", "write"],
        workspace_scope: [workspace]
      })

    files = Fixture.large_export(mb * 1_048_576, sections: @sections) ++ attachments(asset_mb)
    zip = Fixture.zip(files)
    pages = Enum.filter(files, &String.ends_with?(elem(&1, 0), ".md"))
    topics = Enum.filter(pages, &String.contains?(elem(&1, 0), "/Topic "))

    text_bytes =
      files
      |> Enum.reject(&String.ends_with?(elem(&1, 0), ".bin"))
      |> Enum.map(&byte_size(elem(&1, 1)))
      |> Enum.sum()

    dir = Path.join(System.tmp_dir!(), "notion-scale-#{n}")
    zip_path = Fixture.write!(dir, zip)

    started = System.monotonic_time(:millisecond)
    conn = post(source, workspace, token, zip_path, zip, n)
    assert conn.status == 202, conn.resp_body
    %{"job_id" => job_id} = Jason.decode!(conn.resp_body)
    accepted = System.monotonic_time(:millisecond)

    # The Engine's worker is off in tests; this task stands in for it while
    # the test polls the status route like a client would.
    worker = Task.async(fn -> Imports.drain(workspace_id: workspace) end)
    status = poll(job_id, workspace, token, started)
    {:ok, _} = Task.await(worker, :infinity)
    imported = System.monotonic_time(:millisecond)
    assert status["status"] == "completed", inspect(status)

    for {path, _body} <- sample(pages) do
      id = Plan.id_of(path)
      results = search("kestrel" <> binary_part(id, 0, 12), workspace, token)

      assert Enum.any?(results, &(&1["uri"] == Notion.uri(workspace, id))),
             "no citation for #{path}"
    end

    searchable = System.monotonic_time(:millisecond)

    # The hierarchy: the section pages are the only roots, every other context
    # has one parent, and that parent is the page whose folder holds it. Every
    # topic page after the first links to the one before it.
    counts = status["counts"]
    {:ok, roots} = Notion.tree(workspace, nil, limit: 1_000)
    assert length(roots.pages) == @sections
    assert edge_count(workspace, "child_of") == counts["contexts"] - @sections
    assert counts["edges_child_of"] == counts["contexts"] - @sections
    assert counts["edges_links_to"] == length(topics) - @sections
    assert edge_count(workspace, "links_to") == length(topics) - @sections
    assert counts["errors"] == 0

    for {path, body} <- sample(topics) do
      id = Plan.id_of(path)
      ctx_id = Notion.context_id(workspace, id)
      parent = Plan.id_of(Path.dirname(path))

      assert targets(ctx_id, "child_of", workspace) == [Notion.context_id(workspace, parent)]

      case Regex.run(~r/\[previous\]\([^)]*?([0-9a-f]{32})\.md\)/, body) do
        [_, ^id] ->
          :self_link

        [_, previous] ->
          assert targets(ctx_id, "links_to", workspace) == [Notion.context_id(workspace, previous)]
      end
    end

    IO.puts("""

    notion scale (#{source}): zip #{mb(byte_size(zip))} MB, text #{mb(text_bytes)} MB, attachments #{asset_mb} MB
      pages #{counts["pages"]}, databases #{counts["databases"]}, rows #{counts["rows"]}, contexts #{counts["contexts"]}
      edges child_of #{counts["edges_child_of"]}, links_to #{counts["edges_links_to"]}, roots #{length(roots.pages)}
      POST answered in #{secs(accepted - started)} s, job completed #{secs(imported - started)} s after the POST
      #{@samples} sampled pages searchable with citations #{secs(searchable - started)} s after the POST
    """)

    File.rm_rf(dir)
    assert searchable - started < @budget_ms
  end

  # MIOSA's flow: the zip sits in a bucket behind a presigned URL. The query
  # string stands in for the signature and must never surface.
  defp post("url", workspace, token, zip_path, _zip, n) do
    ref = :"notion_scale_bucket_#{n}"
    {:ok, _} = Plug.Cowboy.http(Bucket, [path: zip_path], port: 0, ref: ref)
    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    previous = Application.get_env(:optimal_engine, :import_url_hosts)
    Application.put_env(:optimal_engine, :import_url_hosts, ["127.0.0.1"])
    on_exit(fn -> Application.put_env(:optimal_engine, :import_url_hosts, previous || []) end)

    url =
      "http://127.0.0.1:#{:ranch.get_port(ref)}/exports/notion.zip?" <>
        "X-Amz-Expires=900&X-Amz-Signature=#{String.duplicate("ab", 32)}"

    conn(:post, "/api/import/notion", Jason.encode!(%{workspace: workspace, source_url: url}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", "notion-scale-#{n}")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  defp post("upload", workspace, token, _zip_path, zip, n) do
    conn(:post, "/api/import/notion?" <> URI.encode_query(%{workspace: workspace}), zip)
    |> put_req_header("content-type", "application/zip")
    |> put_req_header("idempotency-key", "notion-scale-#{n}")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  # Polls until the job ends. The only drain is the test's own, so a failed
  # attempt ("retrying") ends the poll too, and so does three times the
  # budget; the progress shows once a minute.
  defp poll(job_id, workspace, token, started, last_shown \\ 0) do
    status =
      conn(:get, "/api/import/notion/#{job_id}?" <> URI.encode_query(%{workspace: workspace}))
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))
      |> Map.get(:resp_body)
      |> Jason.decode!()

    elapsed = System.monotonic_time(:millisecond) - started
    where = "#{status["status"]} #{inspect(status["progress"])} after #{secs(elapsed)} s"

    cond do
      status["status"] in ["completed", "failed", "retrying"] ->
        status

      elapsed > 3 * @budget_ms ->
        flunk("the import is still " <> where)

      true ->
        shown =
          if elapsed - last_shown >= 60_000 do
            IO.puts("notion scale: " <> where)
            elapsed
          else
            last_shown
          end

        Process.sleep(1_000)
        poll(job_id, workspace, token, started, shown)
    end
  end

  defp search(phrase, workspace, token) do
    conn(:get, "/api/search?" <> URI.encode_query(%{q: phrase, workspace: workspace}))
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
    |> Map.get(:resp_body)
    |> Jason.decode!()
    |> Map.fetch!("results")
  end

  defp sample(list),
    do: list |> Enum.take_every(max(div(length(list), @samples), 1)) |> Enum.take(@samples)

  defp edge_count(workspace, relation) do
    {:ok, edges} = Graph.edges_by_relation([relation], workspace_id: workspace)
    length(edges)
  end

  defp targets(ctx_id, relation, workspace) do
    {:ok, edges} = Graph.edges_for(ctx_id, relation: relation, workspace_id: workspace)
    edges |> Enum.map(& &1.target_id) |> Enum.sort()
  end

  defp attachments(0), do: []

  defp attachments(mb) do
    for n <- 1..mb do
      {"Section 1 #{Fixture.hex_id("section", 1)}/Attachments/file-#{n}.bin",
       :crypto.strong_rand_bytes(1_048_576)}
    end
  end

  defp env_int(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
  defp secs(ms), do: Float.round(ms / 1000, 1)
end
