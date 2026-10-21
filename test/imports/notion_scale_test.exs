defmodule OptimalEngine.Imports.NotionScaleTest do
  @moduledoc """
  The size criterion: a 100 MB synthetic Notion export, posted to
  `POST /api/import/notion`, is searchable with citations within ten minutes
  and keeps its hierarchy.

  Excluded by default (`:notion_scale`); run it with

      mix test test/imports/notion_scale_test.exs --only notion_scale

  `NOTION_SCALE_MB` sets the Markdown and CSV text in MB (default 100) and
  `NOTION_SCALE_ASSET_MB` adds incompressible attachments (default 0), which
  grow the zip without adding pages. The test prints its timings.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Imports
  alias OptimalEngine.Imports.Notion
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture

  @moduletag :notion_scale
  @moduletag timeout: :infinity

  @budget_ms 600_000
  @sections 20

  test "a 100 MB export is searchable with citations within ten minutes and keeps its hierarchy" do
    mb = env_int("NOTION_SCALE_MB", 100)
    asset_mb = env_int("NOTION_SCALE_ASSET_MB", 0)

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

    text_bytes =
      files
      |> Enum.reject(&String.ends_with?(elem(&1, 0), ".bin"))
      |> Enum.map(&byte_size(elem(&1, 1)))
      |> Enum.sum()

    zip = Fixture.zip(files)
    pages = Enum.filter(files, &String.ends_with?(elem(&1, 0), ".md"))

    started = System.monotonic_time(:millisecond)

    conn =
      conn(:post, "/api/import/notion?" <> URI.encode_query(%{workspace: workspace}), zip)
      |> put_req_header("content-type", "application/zip")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert conn.status == 202
    %{"job_id" => job_id} = Jason.decode!(conn.resp_body)
    accepted = System.monotonic_time(:millisecond)

    {:ok, %{status: "completed"}} = Imports.drain(workspace_id: workspace)
    imported = System.monotonic_time(:millisecond)

    {:ok, status} = Imports.status(job_id, workspace)

    # Every sampled page is found by its own phrase, and the hit cites it.
    sample = pages |> Enum.take_every(max(div(length(pages), 25), 1)) |> Enum.take(25)

    for {path, _body} <- sample do
      id = OptimalEngine.Imports.Notion.Plan.id_of(path)
      phrase = "kestrel" <> binary_part(id, 0, 12)

      results =
        conn(:get, "/api/search?" <> URI.encode_query(%{q: phrase, workspace: workspace}))
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init([]))
        |> Map.get(:resp_body)
        |> Jason.decode!()
        |> Map.fetch!("results")

      assert Enum.any?(results, &(&1["uri"] == Notion.uri(workspace, id))),
             "no citation for #{path}"
    end

    searchable = System.monotonic_time(:millisecond)

    # The hierarchy: the section pages are the only roots, every other page
    # and every row has exactly one parent.
    {:ok, roots} = Notion.tree(workspace, nil, limit: 1_000)
    assert length(roots.pages) == @sections

    {:ok, [[parents]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM edges WHERE workspace_id = ?1 AND relation = 'child_of'",
        [workspace]
      )

    assert parents == status.counts["contexts"] - @sections
    assert status.counts["errors"] == 0

    IO.puts("""

    notion scale: zip #{mb(byte_size(zip))} MB, text #{mb(text_bytes)} MB, attachments #{asset_mb} MB
      pages #{status.counts["pages"]}, databases #{status.counts["databases"]}, rows #{status.counts["rows"]}, contexts #{status.counts["contexts"]}
      edges child_of #{status.counts["edges_child_of"]}, links_to #{status.counts["edges_links_to"]}
      upload accepted in #{secs(accepted - started)} s, import done in #{secs(imported - accepted)} s
      #{length(sample)} sampled pages searchable with citations #{secs(searchable - started)} s after the upload began
    """)

    assert searchable - started < @budget_ms
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
