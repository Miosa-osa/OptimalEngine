defmodule OptimalEngine.Imports.NotionTest do
  @moduledoc """
  `OptimalEngine.Imports.Notion.import_file/3` against the real store: one
  context per page, database and pageless row, stable `optimal://` URIs,
  `child_of` and `links_to` edges, in-place re-imports that leave other edges
  alone, the row and context limits, part zips, and refused archives that
  write nothing. Each test runs in its own tenant and workspace.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Graph
  alias OptimalEngine.Imports.Notion
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture
  alias OptimalEngine.Topology.Node

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

  defp reasons(report), do: report["errors"] |> Enum.map(& &1["reason"]) |> Enum.sort()

  defp csv_export(rows) do
    db = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    csv = "Name,Notes\n" <> Enum.map_join(1..rows, "", &"Row #{&1},note #{&1}\n")
    Fixture.zip([{"Ledger #{db}.csv", csv}])
  end

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

    # Another tenant reads nothing here.
    assert {:ok, %{pages: []}} = Notion.tree(ctx.workspace, nil, tenant_id: "someone-else")
    assert {:ok, %{pages: [_, _]}} = Notion.tree(ctx.workspace, nil, tenant_id: ctx.tenant)
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

    me = self()
    assert {:ok, report} = import!(ctx, outer, heartbeat: fn -> send(me, :heartbeat) end)
    assert_received :heartbeat
    assert report["counts"]["parts"] == 2
    assert report["counts"]["pages"] == 5
    assert report["counts"]["contexts"] == 7
    assert report["counts"]["edges_child_of"] == 5
  end

  test "a CSV of N + 1 rows imports N rows and reports the cut", ctx do
    assert {:ok, report} = import!(ctx, csv_export(4), limits: %{max_rows_per_csv: 3})

    assert report["counts"]["rows"] == 3
    assert report["counts"]["contexts"] == 4
    assert reasons(report) == ["csv_truncated"]

    stored = contexts(ctx.workspace)
    assert map_size(stored) == 4
    assert stored[uri(ctx, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")].content =~ "the first 3 rows"
    refute Enum.any?(stored, fn {_uri, c} -> c.title == "Row 4" end)
  end

  test "an import past the context limit is refused", ctx do
    # The plan alone (5 pages and a database) is over the limit: nothing is
    # read or written.
    assert {:error, {:too_many_contexts, _}} =
             import!(ctx, Fixture.export(), limits: %{max_contexts: 5})

    # The rows of a database take it over the limit.
    assert {:error, {:too_many_contexts, _}} =
             import!(ctx, csv_export(5), limits: %{max_contexts: 4})

    assert contexts(ctx.workspace) == %{}
    assert Notion.fatal?({:too_many_contexts, "x"})
  end

  test "row and database texts are held to the page limit", ctx do
    db = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    long = String.duplicate("long note ", 100)
    zip = Fixture.zip([{"Ledger #{db}.csv", "Name,Notes\nRow 1,#{long}\n"}])

    assert {:ok, _report} = import!(ctx, zip, limits: %{max_page_bytes: 300})

    for {_uri, context} <- contexts(ctx.workspace) do
      assert byte_size(context.content) <= 300
    end
  end

  test "a 2 MiB line with an unterminated link is imported and never stops the import", ctx do
    line = "[a link that never closes](" <> String.duplicate("x", 2 * 1024 * 1024)

    zip =
      Fixture.zip([
        {"Huge aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", "# Huge\n\n" <> line},
        {"Small bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md", "# Small\n\nFine."}
      ])

    # The link pattern is bounded, so the line costs a bounded scan; a page
    # that failed anyway would be reported as page_unreadable, not crash.
    assert {:ok, report} = import!(ctx, zip)
    assert reasons(report) == ["page_truncated"]
    assert report["counts"]["contexts"] == 2

    stored = contexts(ctx.workspace)

    assert byte_size(stored[uri(ctx, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")].content) <=
             2 * 1024 * 1024

    assert stored[uri(ctx, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")].content =~ "Fine."
  end

  test "two entries with the same name import once and the second is reported", ctx do
    zip =
      Fixture.raw_zip([
        %{name: "Page aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", data: "# Page\n\nfirst copy"},
        %{name: "Page aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", data: "# Page\n\nsecond copy"}
      ])

    assert {:ok, report} = import!(ctx, zip)
    assert report["counts"]["contexts"] == 1
    assert reasons(report) == ["duplicate_page"]
    assert map_size(contexts(ctx.workspace)) == 1
  end

  test "a zip at the root that is not an archive is one reported error", ctx do
    {first, second} = Enum.split(Fixture.files(), 4)

    outer =
      Fixture.zip([
        {"Export-Part-1.zip", Fixture.zip(first)},
        {"Broken.zip", "this is not a zip archive at all"}
        | second
      ])

    assert {:ok, report} = import!(ctx, outer)
    assert report["counts"]["parts"] == 1
    assert report["counts"]["contexts"] == 7
    assert [%{"path" => "Broken.zip", "reason" => "part_unreadable"}] = report["errors"]
  end

  test "a part zip's own bytes count against the total", ctx do
    {first, _second} = Enum.split(Fixture.files(), 4)
    part = Fixture.zip(first)
    inner = first |> Enum.map(fn {_path, content} -> byte_size(content) end) |> Enum.sum()
    outer = Fixture.zip([{"Export-Part-1.zip", part}])

    assert {:error, :archive_too_large} =
             import!(ctx, outer, limits: %{max_total_bytes: byte_size(part) + inner - 1})

    assert {:ok, _report} = import!(ctx, outer, limits: %{max_total_bytes: byte_size(part) + inner})
  end

  test "a traversal or a bomb inside a part zip refuses the whole import", ctx do
    slip = Fixture.raw_zip([%{name: "../../evil.md", data: "x"}])

    assert {:error, {:unsafe_path, "../../evil.md"}} =
             import!(ctx, Fixture.zip([{"Part-1.zip", slip}]))

    nul = Fixture.raw_zip([%{name: <<"evil", 0, ".md">>, data: "x"}])
    assert {:error, {:unsafe_path, _}} = import!(ctx, Fixture.zip([{"Part-1.zip", nul}]))

    bomb =
      Fixture.raw_zip([
        %{
          name: "Page aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md",
          data: String.duplicate("0", 3_000_000),
          declared_size: 100
        }
      ])

    assert {:error, {:entry_size_mismatch, "Page " <> _}} =
             import!(ctx, Fixture.zip([{"Part-1.zip", bomb}]))

    assert contexts(ctx.workspace) == %{}
  end

  test "two tenants that share a bare workspace id never retract each other's edges", ctx do
    n = System.unique_integer([:positive])
    other = "notion-other-#{n}"
    {:ok, _} = Tenant.create(%{id: other, name: "Other #{n}"})

    # A bare id names no workspace and no tenant: each tenant's rows and edges
    # in it are its own.
    ws = "shared-#{n}"
    i = Fixture.ids()

    # The other tenant's export: the same pages under different Notion ids.
    swap = Map.new(Map.values(i), &{&1, String.reverse(&1)})
    assert MapSet.disjoint?(MapSet.new(Map.keys(swap)), MapSet.new(Map.values(swap)))

    rename = fn text ->
      Enum.reduce(swap, text, fn {from, to}, t -> String.replace(t, from, to) end)
    end

    theirs = Enum.map(Fixture.files(), fn {path, body} -> {rename.(path), rename.(body)} end)

    ours_handbook = Notion.context_id(ws, i.handbook)
    their_handbook = Notion.context_id(ws, swap[i.handbook])

    links = fn handbook, tenant ->
      {:ok, edges} =
        Graph.edges_for(handbook, relation: "links_to", workspace_id: ws, tenant_id: tenant)

      edges |> Enum.map(& &1.target_id) |> Enum.sort()
    end

    parent = fn page, tenant ->
      {:ok, edges} =
        Graph.edges_for(page, relation: "child_of", workspace_id: ws, tenant_id: tenant)

      Enum.map(edges, & &1.target_id)
    end

    {:ok, _} = import!(ctx, Fixture.export(), workspace: ws)
    {:ok, _} = import!(ctx, Fixture.zip(theirs), workspace: ws, tenant_id: other)

    ours_before = links.(ours_handbook, ctx.tenant)
    theirs_before = links.(their_handbook, other)
    assert length(ours_before) == 2 and length(theirs_before) == 2

    # Each re-imports an export whose handbook links to nothing: each loses
    # only its own links, and every child_of edge of the other stays.
    unlink = fn files, id ->
      Enum.map(files, fn {path, body} ->
        if String.ends_with?(path, "Team Handbook #{id}.md"),
          do: {path, "# Team Handbook\n\nNo links now.\n"},
          else: {path, body}
      end)
    end

    {:ok, _} = import!(ctx, Fixture.zip(unlink.(Fixture.files(), i.handbook)), workspace: ws)
    assert links.(ours_handbook, ctx.tenant) == []
    assert links.(their_handbook, other) == theirs_before
    assert parent.(Notion.context_id(ws, swap[i.onboarding]), other) == [their_handbook]

    {:ok, _} =
      import!(ctx, Fixture.zip(unlink.(theirs, swap[i.handbook])), workspace: ws, tenant_id: other)

    assert links.(their_handbook, other) == []
    assert parent.(Notion.context_id(ws, i.onboarding), ctx.tenant) == [ours_handbook]

    # Restoring our links touches nothing of theirs.
    {:ok, _} = import!(ctx, Fixture.export(), workspace: ws)
    assert links.(ours_handbook, ctx.tenant) == ours_before
    assert links.(their_handbook, other) == []
  end

  test "a re-import retracts only the edges the importer owns", ctx do
    i = Fixture.ids()
    ws = ctx.workspace
    {:ok, _} = import!(ctx, Fixture.export())

    handbook = Notion.context_id(ws, i.handbook)
    onboarding = Notion.context_id(ws, i.onboarding)

    tasks = Notion.context_id(ws, i.tasks)

    # A user's edges: a link from a Notion page to a context that did not come
    # from Notion, another relation between two Notion pages, and the very
    # link the importer wrote from the handbook to onboarding.
    :ok = Graph.assert_edge(handbook, "ctx-written-by-hand", "links_to", workspace_id: ws)
    :ok = Graph.assert_edge(handbook, onboarding, "related", workspace_id: ws)
    :ok = Graph.assert_edge(handbook, onboarding, "links_to", workspace_id: ws)

    # The handbook no longer links to anything.
    handbook_path = "Team Handbook #{i.handbook}.md"

    files =
      Enum.map(Fixture.files(), fn
        {^handbook_path, _} -> {handbook_path, "# Team Handbook\n\nNo links now.\n"}
        other -> other
      end)

    assert {:ok, _} = import!(ctx, Fixture.zip(files))

    # The importer's own link to Tasks goes; the one the user also asserted
    # stays, with the user's.
    {:ok, links} = Graph.edges_for(handbook, relation: "links_to", workspace_id: ws)

    assert links |> Enum.map(& &1.target_id) |> Enum.sort() ==
             Enum.sort(["ctx-written-by-hand", onboarding])

    refute tasks in Enum.map(links, & &1.target_id)

    {:ok, related} = Graph.edges_for(handbook, relation: "related", workspace_id: ws)
    assert Enum.map(related, & &1.target_id) == [onboarding]
  end

  test "the upgrade gives edges written before provenance to the importer that wrote them", ctx do
    i = Fixture.ids()
    ws = ctx.workspace
    {:ok, _} = import!(ctx, Fixture.export())
    handbook = Notion.context_id(ws, i.handbook)

    # As an Engine before the migration left them: no asserter on any edge.
    {:ok, _} =
      Store.raw_query("UPDATE graph_edges SET asserted_by = NULL WHERE workspace_id = ?1", [ws])

    :ok = Graph.assert_edge(handbook, "ctx-written-by-hand", "links_to", workspace_id: ws)

    # Near misses the backfill must not take: a context whose URI has the
    # notion segment one level too deep, and one of another tenant.
    first_week = Notion.context_id(ws, i.first_week)
    write_guide = Notion.context_id(ws, i.write_guide)

    {:ok, _} =
      Store.raw_query("UPDATE contexts SET uri = ?2 WHERE id = ?1", [
        first_week,
        "optimal://#{ws}/elsewhere/notion/#{i.first_week}"
      ])

    other = "notion-near-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.create(%{id: other, name: "Near miss"})

    {:ok, _} =
      Store.raw_query("UPDATE contexts SET tenant_id = ?2 WHERE id = ?1", [write_guide, other])

    {_version, _description, statements} =
      Enum.find(OptimalEngine.Store.Migrations.all(), fn {_v, description, _s} ->
        description == "graph edges record who asserted them"
      end)

    for {label, sql} <- statements, label != "graph_edges_asserted_by" do
      {:ok, _} = Store.raw_query(sql, [])
    end

    {:ok, owned} =
      Graph.edges_by_relation(["child_of", "links_to"],
        workspace_id: ws,
        asserted_by: "import.notion"
      )

    # 5 child_of and 3 links_to, less the child_of edges of the two near misses.
    assert length(owned) == 5 + 3 - 2
    refute Enum.any?(owned, &(&1.source_id in [first_week, write_guide]))

    {:ok, all} = Graph.edges_by_relation(["child_of", "links_to"], workspace_id: ws)
    assert %{asserted_by: nil} = Enum.find(all, &(&1.target_id == "ctx-written-by-hand"))
    assert %{asserted_by: nil} = Enum.find(all, &(&1.source_id == first_week))
    assert %{asserted_by: nil} = Enum.find(all, &(&1.source_id == write_guide))
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

  test "a long page's entities are read within the classification limit, and the import finishes",
       ctx do
    # 676 known names the page never mentions, each starting like "planned",
    # so no quick check rules one out: reading the whole 1.9 MB page for them
    # takes seconds, far past a 200 ms limit, while mode and genre, read from
    # the page's first 64 KiB, take a small part of it. The limit, not the
    # order in which a page's detections spend its budget, stops the read.
    prefix = "notion-absent-#{System.unique_integer([:positive])}-"

    for a <- ?a..?z, b <- ?a..?z do
      {:ok, _} =
        Node.upsert(%{slug: prefix <> <<a, b>>, name: "Plannx" <> <<a, b>>, kind: :project})
    end

    on_exit(fn ->
      Store.raw_query("DELETE FROM nodes WHERE slug LIKE ?1", [prefix <> "%"])
    end)

    previous = Application.fetch_env(:optimal_engine, :classification_timeout_ms)
    Application.put_env(:optimal_engine, :classification_timeout_ms, 200)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:optimal_engine, :classification_timeout_ms, value)
        :error -> Application.delete_env(:optimal_engine, :classification_timeout_ms)
      end
    end)

    page =
      "# Long\n\n" <> String.duplicate("The rollout continues as planned for the week.\n", 40_000)

    zip =
      Fixture.zip([
        {"Long aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.md", page},
        {"Small bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.md", "# Small\n\nFine."}
      ])

    {{ms, result}, stopped} = timeouts(fn -> elapsed_ms(fn -> import!(ctx, zip) end) end)

    assert {:ok, report} = result
    assert report["counts"]["contexts"] == 2
    assert report["errors"] == []
    assert "entity extraction" in stopped
    assert ms < 10_000, "the import took #{ms} ms"

    assert byte_size(contexts(ctx.workspace)[uri(ctx, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")].content) >
             1_900_000
  end

  defp elapsed_ms(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds, 1000), result}
  end

  # The result of `fun` and the labels of the steps the time limit stopped.
  defp timeouts(fun) do
    id = {__MODULE__, make_ref()}
    event = [:optimal_engine, :signal, :classification_timeout]
    :ok = :telemetry.attach(id, event, &__MODULE__.send_timeout/4, self())

    try do
      result = fun.()
      {result, collect_timeouts([])}
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def send_timeout(_event, _measurements, %{label: label}, test),
    do: send(test, {:stopped, label})

  defp collect_timeouts(labels) do
    receive do
      {:stopped, label} -> collect_timeouts([label | labels])
    after
      0 -> labels
    end
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
    refute Notion.fatal?({:download_failed, "http_500"})
  end
end
