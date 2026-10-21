defmodule OptimalEngine.Imports.NotionTest do
  @moduledoc """
  `OptimalEngine.Imports.Notion.import_file/3` against the real store: one
  context per page, database and pageless row, stable `optimal://` URIs,
  `child_of` and `links_to` edges, in-place re-imports, and refused archives
  that write nothing. Each test runs in its own tenant and workspace.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Graph
  alias OptimalEngine.Imports.Notion
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture

  @moduletag :tmp_dir

  setup do
    n = System.unique_integer([:positive])
    tenant = "notion-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Notion #{n}"})
    workspace = workspace!(tenant, "docs")
    %{tenant: tenant, workspace: workspace}
  end

  defp workspace!(tenant, slug) do
    id = "#{tenant}:#{slug}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?3, 'active', '{}')",
        [id, tenant, slug]
      )

    id
  end

  defp import!(ctx, bytes, opts \\ []) do
    path = Fixture.write!(ctx.tmp_dir, bytes, "export-#{System.unique_integer([:positive])}.zip")

    Notion.import_file(
      path,
      Keyword.get(opts, :workspace, ctx.workspace),
      Keyword.merge([tenant_id: ctx.tenant, work_dir: ctx.tmp_dir], opts)
    )
  end

  defp contexts(workspace) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT uri, title, content FROM contexts WHERE workspace_id = ?1 AND uri LIKE 'optimal://%/notion/%' ORDER BY uri",
        [workspace]
      )

    Map.new(rows, fn [uri, title, content] -> {uri, %{title: title, content: content}} end)
  end

  defp parent_of(workspace, page_id) do
    {:ok, edges} =
      Graph.edges_for(Notion.context_id(workspace, page_id),
        relation: "child_of",
        workspace_id: workspace
      )

    Enum.map(edges, & &1.target_id)
  end

  defp uri(ctx, id), do: Notion.uri(ctx.workspace, id)

  test "imports every page, database and pageless row with its hierarchy and links", ctx do
    i = Fixture.ids()
    assert {:ok, report} = import!(ctx, Fixture.export())

    assert report["counts"] == %{
             "entries" => 9,
             "parts" => 0,
             "pages" => 5,
             "databases" => 1,
             "rows" => 2,
             "assets" => 1,
             "skipped" => 2,
             "contexts" => 7,
             "unchanged" => 0,
             "edges_child_of" => 5,
             "edges_links_to" => 3,
             "links_unresolved" => 1,
             "errors" => 0
           }

    assert report["progress"] == %{"done" => 7, "total" => 7}

    assert Enum.sort(report["root_uris"]) ==
             Enum.sort([uri(ctx, i.handbook), uri(ctx, i.standalone)])

    stored = contexts(ctx.workspace)
    assert map_size(stored) == 7
    assert stored[uri(ctx, i.first_week)].title == "First Week"
    assert stored[uri(ctx, i.first_week)].content =~ "reconcile the quartz ledger"
    assert stored[uri(ctx, i.standalone)].content == "# Standalone Note\n"
    assert stored[uri(ctx, i.handbook)].content =~ "[Onboarding](#{uri(ctx, i.onboarding)})"
    assert stored[uri(ctx, i.tasks)].content =~ "[Write guide](#{uri(ctx, i.write_guide)})"

    {own_row_uri, own_row} = Enum.find(stored, fn {_uri, c} -> c.title == "Review guide" end)
    assert own_row.content =~ "Status: Open"
    assert own_row.content =~ "Due: 2026-10-09"
    assert stored[uri(ctx, i.tasks)].content =~ "[Review guide](#{own_row_uri})"

    ws = ctx.workspace
    assert parent_of(ws, i.onboarding) == [Notion.context_id(ws, i.handbook)]
    assert parent_of(ws, i.first_week) == [Notion.context_id(ws, i.onboarding)]
    assert parent_of(ws, i.tasks) == [Notion.context_id(ws, i.handbook)]
    assert parent_of(ws, i.write_guide) == [Notion.context_id(ws, i.tasks)]

    assert parent_of(ws, String.replace_prefix(own_row_uri, Notion.uri(ws, ""), "")) == [
             Notion.context_id(ws, i.tasks)
           ]

    assert parent_of(ws, i.handbook) == []

    {:ok, links} =
      Graph.edges_for(Notion.context_id(ws, i.handbook), relation: "links_to", workspace_id: ws)

    assert links |> Enum.map(& &1.target_id) |> Enum.sort() ==
             Enum.sort([Notion.context_id(ws, i.onboarding), Notion.context_id(ws, i.tasks)])
  end

  test "the tree lists roots, then the children of a page", ctx do
    i = Fixture.ids()
    {:ok, _} = import!(ctx, Fixture.export())

    {:ok, roots} = Notion.tree(ctx.workspace, nil)
    assert Enum.map(roots.pages, & &1.title) == ["Standalone Note", "Team Handbook"]

    assert %{page_id: handbook, children: 2} =
             Enum.find(roots.pages, &(&1.title == "Team Handbook"))

    assert handbook == i.handbook

    {:ok, children} = Notion.tree(ctx.workspace, i.handbook)
    assert children.parent == uri(ctx, i.handbook)
    assert Enum.map(children.pages, &{&1.title, &1.children}) == [{"Onboarding", 1}, {"Tasks", 2}]

    assert {:error, :not_found} = Notion.tree(ctx.workspace, "ffffffffffffffffffffffffffffffff")
  end

  test "a re-import updates in place: unchanged pages are skipped and a moved page has one parent",
       ctx do
    i = Fixture.ids()
    {:ok, _} = import!(ctx, Fixture.export())

    {:ok, [[packages_before]]} =
      Store.raw_query("SELECT COUNT(*) FROM source_packages WHERE workspace_id = ?1", [
        ctx.workspace
      ])

    assert {:ok, again} = import!(ctx, Fixture.export())
    assert again["counts"]["contexts"] == 0
    assert again["counts"]["unchanged"] == 7
    assert again["counts"]["edges_child_of"] == 5
    assert map_size(contexts(ctx.workspace)) == 7

    {:ok, [[packages_after]]} =
      Store.raw_query("SELECT COUNT(*) FROM source_packages WHERE workspace_id = ?1", [
        ctx.workspace
      ])

    assert packages_after == packages_before

    handbook = "Team Handbook #{i.handbook}"
    old_path = "#{handbook}/Onboarding #{i.onboarding}/First Week #{i.first_week}.md"

    moved =
      Enum.map(Fixture.files(), fn
        {^old_path, _} ->
          {"#{handbook}/First Week #{i.first_week}.md",
           "# First Week\n\nNow directly under the handbook.\n"}

        other ->
          other
      end)

    assert {:ok, report} = import!(ctx, Fixture.zip(moved))
    assert report["counts"]["contexts"] == 1
    assert report["counts"]["unchanged"] == 6

    assert parent_of(ctx.workspace, i.first_week) == [Notion.context_id(ctx.workspace, i.handbook)]
    assert contexts(ctx.workspace)[uri(ctx, i.first_week)].content =~ "Now directly under"
    assert map_size(contexts(ctx.workspace)) == 7
  end

  test "an import writes only into its own workspace", ctx do
    other = workspace!(ctx.tenant, "elsewhere")
    i = Fixture.ids()

    {:ok, _} = import!(ctx, Fixture.export())
    {:ok, _} = import!(ctx, Fixture.export(), workspace: other)

    assert map_size(contexts(ctx.workspace)) == 7
    assert map_size(contexts(other)) == 7
    assert Map.has_key?(contexts(other), Notion.uri(other, i.handbook))
    refute Notion.context_id(other, i.handbook) == Notion.context_id(ctx.workspace, i.handbook)
    assert parent_of(other, i.onboarding) == [Notion.context_id(other, i.handbook)]
  end

  test "a Notion export split into part zips is read as one export", ctx do
    {first, second} = Enum.split(Fixture.files(), 4)

    outer =
      Fixture.zip([
        {"Export-Part-1.zip", Fixture.zip(first)},
        {"Export-Part-2.zip", Fixture.zip(second)}
      ])

    assert {:ok, report} = import!(ctx, outer)
    assert report["counts"]["parts"] == 2
    assert report["counts"]["pages"] == 5
    assert report["counts"]["contexts"] == 7
    assert report["counts"]["edges_child_of"] == 5
  end

  test "page problems are reported and the import continues", ctx do
    entries = [
      %{name: "Fine aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", data: "# Fine\n\nA normal page."},
      %{
        name: <<"Caf", 0xE9, " bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md">>,
        data: "# Cafe\n\nNot UTF-8 named."
      },
      %{
        name: "Broken cccccccccccccccccccccccccccccccc.md",
        data: <<"# Broken\n\nbad ", 0xFF, 0xFE, " bytes">>
      },
      %{
        name: "Long dddddddddddddddddddddddddddddddd.md",
        data: "# Long\n\n" <> String.duplicate("word ", 100)
      }
    ]

    assert {:ok, report} = import!(ctx, Fixture.raw_zip(entries), limits: %{max_page_bytes: 200})
    reasons = report["errors"] |> Enum.map(& &1["reason"]) |> Enum.sort()
    assert reasons == ["invalid_name", "invalid_utf8", "page_truncated"]
    assert report["counts"]["pages"] == 3
    assert report["counts"]["contexts"] == 3
    assert report["counts"]["errors"] == 3

    stored = contexts(ctx.workspace)
    assert stored[uri(ctx, "cccccccccccccccccccccccccccccccc")].content =~ "bad \uFFFD"
    assert byte_size(stored[uri(ctx, "dddddddddddddddddddddddddddddddd")].content) <= 200
  end

  test "a refused archive stops the import and writes nothing", ctx do
    slip =
      Fixture.raw_zip([
        %{name: "Page aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", data: "# Page"},
        %{name: "../evil.md", data: "x"}
      ])

    assert {:error, {:unsafe_path, "../evil.md"}} = import!(ctx, slip)

    bomb =
      Fixture.raw_zip([
        %{
          name: "Page aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md",
          data: String.duplicate("0", 3_000_000),
          declared_size: 100
        }
      ])

    assert {:error, {:entry_size_mismatch, "Page " <> _}} = import!(ctx, bomb)
    assert {:error, :empty_export} = import!(ctx, Fixture.zip([{"image.png", "not a page"}]))
    assert {:error, :invalid_zip} = import!(ctx, "garbage")

    assert contexts(ctx.workspace) == %{}
    assert Notion.fatal?({:unsafe_path, "x"})
    refute Notion.fatal?({:download_failed, "http 500"})
  end
end
