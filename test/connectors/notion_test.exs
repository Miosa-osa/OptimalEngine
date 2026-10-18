defmodule OptimalEngine.Connectors.NotionTest do
  @moduledoc """
  Notion adapter end to end against a recorded Notion API recording
  (`test/fixtures/connectors/notion/routes.json`): database search, database
  query with and without a `last_edited_time` filter (a two-page walk, an
  incremental answer, an idle answer), block children, and the errors a
  database can answer with. The last describe drives the real adapter through
  the Runner and the intake sink into a registered workspace.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Connectors.Adapters.Notion
  alias OptimalEngine.Connectors.PullScheduler
  alias OptimalEngine.Connectors.Transform
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.ConnectorFixtureStub

  @projects "0a000000-0000-4000-8000-000000000001"
  @notes "0a000000-0000-4000-8000-000000000002"
  @archive "0a000000-0000-4000-8000-000000000003"
  @private "0a000000-0000-4000-8000-000000000004"
  @limited "0a000000-0000-4000-8000-000000000005"
  @broken "0a000000-0000-4000-8000-000000000006"
  @revoked "0a000000-0000-4000-8000-000000000007"
  @busy "0a000000-0000-4000-8000-000000000008"
  @locked "0a000000-0000-4000-8000-000000000009"

  @launch_plan_id "1b000000-0000-4000-8000-000000000001"

  setup do
    stub = ConnectorFixtureStub.install(:notion)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "pull" do
    test "walks every page of a database and fetches each page's blocks", %{stub: stub} do
      assert {:ok, %{signals: signals, cursor: cursor}} = Notion.sync(state([@projects]), nil)

      titles = signals |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Launch plan", "Pricing review", "Q3 roadmap"]

      # The first request has no filter, so it reads from the beginning, oldest
      # edit first. The second carries Notion's cursor, not a filter.
      assert [first, second] = query_calls(stub, @projects)
      refute Map.has_key?(first.body, "filter")
      refute Map.has_key?(first.body, "start_cursor")
      assert first.body["page_size"] == 100

      assert first.body["sorts"] == [
               %{"timestamp" => "last_edited_time", "direction" => "ascending"}
             ]

      assert second.body["start_cursor"] == "projects-cursor-2"

      # Every request carried the integration token and the pinned API version.
      assert header(first, "authorization") == "Bearer secret_example-token"
      assert header(first, "notion-version") == "2022-06-28"

      # A query answers with properties only; the body is a request per page,
      # and the long page's second block page was fetched too.
      assert length(ConnectorFixtureStub.calls_matching(stub, "/v1/blocks/")) == 4
      assert [_] = ConnectorFixtureStub.calls_matching(stub, "start_cursor=blocks-cursor-2")

      assert marks(cursor) == %{@projects => "2026-10-03T11:00:00.000Z"}
    end

    test "maps each page to a document Signal with its title and flattened blocks" do
      {:ok, %{signals: signals}} = Notion.sync(state([@projects]), nil)

      launch = Enum.find(signals, &(&1.title == "Launch plan"))
      assert %Signal{genre: "document", mode: :linguistic, format: :markdown} = launch
      assert launch.id == Transform.signal_id(:notion, @launch_plan_id)
      assert launch.path == "optimal://connectors/notion/#{@launch_plan_id}"
      assert DateTime.compare(launch.modified_at, ~U[2026-10-01 09:00:00Z]) == :eq

      # Headings, paragraphs and list items; the divider contributes nothing.
      assert launch.content ==
               "# Launch plan\n" <>
                 "Send the signed order form to Example Co by Friday.\n" <>
                 "- Confirm pricing with Jane Example"

      # The title property is called `Task name` here, and its text spans two
      # rich-text fragments. The block list spans two pages.
      roadmap = Enum.find(signals, &(&1.title == "Q3 roadmap"))

      assert roadmap.content ==
               "## Goals\n" <>
                 "1. Ship the connector fixtures\n" <>
                 "- [ ] Review the cursor design\n" <>
                 "> Measure twice, cut once."

      # The title property is called `Title` on this one.
      assert Enum.find(signals, &(&1.title == "Pricing review")).content ==
               "Pricing for Example Co is unchanged."
    end

    test "keeps pages whose body has no paragraph or heading, and pages with no body" do
      {:ok, %{signals: signals}} = Notion.sync(state([@notes]), nil)

      notes = Enum.find(signals, &(&1.title == "Meeting notes"))

      assert notes.content ==
               "- Agenda: kickoff\n" <>
                 "- Action: Jane Example sends the order form\n" <>
                 "- [ ] Book the follow-up call"

      # No blocks at all: the title is the content, so intake does not drop the
      # page as empty.
      empty = Enum.find(signals, &(&1.title == "Empty page"))
      assert empty.content == "Empty page"
    end

    test "with no database ids, lists every database through both search pages", %{stub: stub} do
      assert {:ok, %{signals: signals, cursor: cursor}} = Notion.sync(state([]), nil)

      assert [search_1, search_2] = ConnectorFixtureStub.calls_matching(stub, "/v1/search")
      assert search_1.body["filter"] == %{"value" => "database", "property" => "object"}
      refute Map.has_key?(search_1.body, "start_cursor")
      assert search_2.body["start_cursor"] == "search-cursor-2"

      # All three databases were queried, in search order: 3 + 2 + 0 pages.
      assert length(signals) == 5
      assert [_, _] = query_calls(stub, @projects)
      assert [_] = query_calls(stub, @notes)
      assert [_] = query_calls(stub, @archive)

      # The archive had nothing, so it has no watermark yet.
      assert marks(cursor) == %{
               @projects => "2026-10-03T11:00:00.000Z",
               @notes => "2026-10-04T12:30:00.000Z"
             }
    end

    test "a response that says there is more but names no cursor ends the walk" do
      mock = fn url, _opts ->
        body =
          if String.contains?(url, "/blocks/"),
            do: %{"results" => [], "has_more" => false},
            else: %{"results" => [%{"id" => "pg-1"}], "has_more" => true, "next_cursor" => nil}

        {:ok,
         {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
          Jason.encode!(body)}}
      end

      Application.put_env(:optimal_engine, :http_mock, mock)

      assert {:ok, %{signals: [_one]}} = Notion.sync(state([@projects]), nil)
    end
  end

  describe "cursor" do
    test "an incremental run filters on the cursor, returns the edit, and advances it", %{
      stub: stub
    } do
      {:ok, %{cursor: first_cursor}} = Notion.sync(state([@projects]), nil)

      assert {:ok, %{signals: [edited], cursor: second_cursor}} =
               Notion.sync(state([@projects]), first_cursor)

      assert edited.title == "Q3 roadmap"
      assert DateTime.compare(edited.modified_at, ~U[2026-10-05 08:30:00Z]) == :eq

      # The third query (after the two of the first run) carries the filter.
      assert [_, _, incremental] = query_calls(stub, @projects)

      assert incremental.body["filter"] == %{
               "timestamp" => "last_edited_time",
               "last_edited_time" => %{"after" => "2026-10-03T11:00:00.000Z"}
             }

      assert marks(second_cursor) == %{@projects => "2026-10-05T08:30:00.000Z"}

      # Nothing changed since: no Signals, and the cursor stays where it was.
      assert {:ok, %{signals: [], cursor: ^second_cursor}} =
               Notion.sync(state([@projects]), second_cursor)
    end

    test "keeps one watermark per database, whatever the order or which one ends the list", %{
      stub: stub
    } do
      # The last database here is idle and the one before it has the earlier
      # edit. A single cursor taken from the last database would be the old
      # one (or nil); each database keeps its own.
      databases = [@notes, @projects, @archive]
      {:ok, %{cursor: cursor}} = Notion.sync(state(databases), nil)

      assert marks(cursor) == %{
               @notes => "2026-10-04T12:30:00.000Z",
               @projects => "2026-10-03T11:00:00.000Z"
             }

      assert {:ok, %{signals: [edited], cursor: next}} = Notion.sync(state(databases), cursor)
      assert edited.title == "Q3 roadmap"

      # Each database was filtered by its own watermark, not by one shared one.
      assert after_of(List.last(query_calls(stub, @notes))) == "2026-10-04T12:30:00.000Z"
      assert after_of(List.last(query_calls(stub, @projects))) == "2026-10-03T11:00:00.000Z"

      # The archive has never returned a page, so it is still read from the start.
      refute Map.has_key?(List.last(query_calls(stub, @archive)).body, "filter")

      assert marks(next) == %{
               @notes => "2026-10-04T12:30:00.000Z",
               @projects => "2026-10-05T08:30:00.000Z"
             }
    end

    test "a plain timestamp cursor from before per-database watermarks applies to every database",
         %{stub: stub} do
      cursor = "2026-10-01T00:00:00Z"
      assert {:ok, %{cursor: next}} = Notion.sync(state([@projects, @archive]), cursor)

      for db <- [@projects, @archive] do
        assert after_of(hd(query_calls(stub, db))) == cursor
      end

      # The idle database keeps the old value; the busy one moved forward.
      assert marks(next) == %{
               @projects => "2026-10-03T11:00:00.000Z",
               @archive => cursor
             }
    end

    for {label, bad} <- [
          {"that is not a timestamp", "not-a-timestamp"},
          {"that is broken JSON", "{broken"},
          {"whose marks are not timestamps", ~s({"x": 1})},
          {"that is empty", ""}
        ] do
      test "a cursor #{label} is read as no cursor rather than sent to Notion", %{stub: stub} do
        assert {:ok, %{signals: [_ | _]}} = Notion.sync(state([@projects]), unquote(bad))
        refute Map.has_key?(hd(query_calls(stub, @projects)).body, "filter")
      end
    end
  end

  describe "errors" do
    test "a revoked token is :auth_expired and stops the walk", %{stub: stub} do
      assert {:error, :auth_expired} = Notion.sync(state([@revoked, @notes]), nil)
      assert query_calls(stub, @notes) == []
    end

    test "a token revoked part way through still fails the sync, not just that database" do
      assert {:error, :auth_expired} = Notion.sync(state([@notes, @revoked]), nil)
    end

    test "an expired token on every database is not an empty success" do
      stub = ConnectorFixtureStub.install(:notion, status: 401)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      assert {:error, :auth_expired} = Notion.sync(state([@projects, @notes]), nil)
      assert {:error, :auth_expired} = Notion.sync(state([]), nil)
    end

    test "a rate limit on a page's blocks ends the sync, so the Runner retries the same cursor" do
      assert {:error, {:rate_limited, 5000}} = Notion.sync(state([@busy]), nil)
    end

    test "a page whose body cannot be read is kept with its title" do
      log =
        capture_log(fn ->
          assert {:ok, %{signals: [page], cursor: cursor}} = Notion.sync(state([@locked]), nil)

          assert page.title == "Locked page"
          assert page.content == "Locked page"
          assert marks(cursor) == %{@locked => "2026-10-06T10:00:00.000Z"}
        end)

      assert log =~ "body unreadable"
    end

    test "a rate limit names its Retry-After" do
      assert {:error, {:rate_limited, 3000}} = Notion.sync(state([@notes, @limited]), nil)
    end

    test "a rate limit with no Retry-After is plain :rate_limited" do
      stub = ConnectorFixtureStub.install(:notion, status: 429)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      assert {:error, :rate_limited} = Notion.sync(state([@projects]), nil)
    end

    test "a server error is :transient" do
      assert {:error, :transient} = Notion.sync(state([@broken]), nil)
    end

    test "an unreachable endpoint is a transport error, not a crash" do
      stub = ConnectorFixtureStub.install(:notion, unreachable: true)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      assert {:error, _reason} = Notion.sync(state([@projects]), nil)
      assert {:error, _reason} = Notion.sync(state([]), nil)
    end

    test "a database not shared with the integration is skipped and the others are kept", %{
      stub: stub
    } do
      {{:ok, %{signals: signals, cursor: cursor}}, log} =
        with_log(fn -> Notion.sync(state([@private, @notes]), nil) end)

      assert length(signals) == 2
      assert log =~ "database #{@private} skipped"

      # The skipped database has no watermark, so it is not marked as read.
      assert marks(cursor) == %{@notes => "2026-10-04T12:30:00.000Z"}

      # Once it is shared, its whole history is still ahead of it: the next run
      # filters the notes by their mark and asks for the private one unfiltered.
      capture_log(fn ->
        assert {:ok, %{signals: []}} = Notion.sync(state([@private, @notes]), cursor)
      end)

      assert after_of(List.last(query_calls(stub, @notes))) == "2026-10-04T12:30:00.000Z"
      refute Map.has_key?(List.last(query_calls(stub, @private)).body, "filter")
    end

    test "a skipped database keeps the watermark it already had" do
      cursor = Jason.encode!(%{@private => "2026-10-02T00:00:00.000Z"})

      {{:ok, %{signals: [_, _], cursor: next}}, _log} =
        with_log(fn -> Notion.sync(state([@private, @notes]), cursor) end)

      assert marks(next) == %{
               @private => "2026-10-02T00:00:00.000Z",
               @notes => "2026-10-04T12:30:00.000Z"
             }
    end

    test "when every database is unreadable the sync reports it instead of succeeding empty" do
      capture_log(fn ->
        assert {:error, {:http, 404}} = Notion.sync(state([@private]), nil)
      end)
    end
  end

  describe "transform/1" do
    test "returns a Signal for a minimal payload" do
      assert {:ok, %Signal{} = signal} = Notion.transform(%{"id" => "pg-9"})
      assert signal.id =~ "notion:"
      assert signal.genre == "document"
      assert signal.title == "Untitled"
      assert signal.content == ""
    end

    test "a page with neither a title nor a body stays empty" do
      raw = %{"id" => "pg-10", "properties" => %{"Name" => %{"title" => []}}, "blocks" => []}
      assert {:ok, %Signal{title: "Untitled", content: ""}} = Notion.transform(raw)
    end

    test "reads the title from whichever property holds it, joining its fragments" do
      title = fn name ->
        %{
          "id" => "pg-11",
          "properties" => %{
            "Status" => %{"type" => "select", "select" => %{"name" => "Open"}},
            name => %{
              "type" => "title",
              "title" => [%{"plain_text" => "Q3 "}, %{"plain_text" => "plan"}]
            }
          }
        }
      end

      for name <- ["Name", "title", "Task name", "Título"] do
        assert {:ok, %Signal{title: "Q3 plan"}} = Notion.transform(title.(name))
      end
    end

    test "flattens the text-bearing block types and skips the rest" do
      text = fn type, body, extra ->
        %{"type" => type, type => Map.put(extra, "rich_text", [%{"plain_text" => body}])}
      end

      raw = %{
        "id" => "pg-12",
        "properties" => %{"Name" => %{"title" => [%{"plain_text" => "Kinds"}]}},
        "blocks" => [
          text.("heading_1", "One", %{}),
          text.("heading_2", "Two", %{}),
          text.("heading_3", "Three", %{}),
          text.("paragraph", "Body", %{}),
          text.("bulleted_list_item", "Bullet", %{}),
          text.("numbered_list_item", "Number", %{}),
          text.("to_do", "Open", %{"checked" => false}),
          text.("to_do", "Done", %{"checked" => true}),
          text.("quote", "Quoted", %{}),
          text.("callout", "Noted", %{}),
          %{"type" => "paragraph", "paragraph" => %{"rich_text" => []}},
          %{"type" => "divider", "divider" => %{}},
          %{"type" => "child_page", "child_page" => %{"title" => "Nested"}}
        ]
      }

      assert {:ok, %Signal{content: content}} = Notion.transform(raw)

      assert content ==
               Enum.join(
                 [
                   "# One",
                   "## Two",
                   "### Three",
                   "Body",
                   "- Bullet",
                   "1. Number",
                   "- [ ] Open",
                   "- [x] Done",
                   "> Quoted",
                   "Noted"
                 ],
                 "\n"
               )
    end

    test "refuses a payload that is not a map" do
      assert {:error, :invalid_payload} = Notion.transform("page")
    end
  end

  describe "the whole path into a workspace" do
    setup do
      original = System.get_env("CONNECTOR_KEY")
      System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

      on_exit(fn ->
        if original,
          do: System.put_env("CONNECTOR_KEY", original),
          else: System.delete_env("CONNECTOR_KEY")
      end)

      suffix = System.unique_integer([:positive])
      {:ok, workspace: "notion-workspace-#{suffix}", connector_id: "notion-connector-#{suffix}"}
    end

    test "pulled pages land in the connector's workspace, and the next pull reads only the edit",
         ctx do
      spec = %{
        kind: :notion,
        id: ctx.connector_id,
        workspace_id: ctx.workspace,
        config: config([@projects, @notes])
      }

      {:ok, first} = PullScheduler.run_once(connectors: [spec], tenant_id: "default")

      assert first.error_count == 0
      assert first.ingested_count == 5

      # Every page reached intake with its content, in the connector's own
      # workspace. A page with no body (the title is its content) and one with
      # only list items are among them.
      for title <- ["Launch plan", "Q3 roadmap", "Pricing review", "Meeting notes", "Empty page"] do
        assert contexts_in(ctx.workspace, title) >= 1, "#{title} did not land in the workspace"
        assert contexts_in("default", title) == 0, "#{title} leaked into the default workspace"
      end

      # The Runner stored the per-database cursor on the connector's row.
      assert stored_marks(ctx.connector_id) == %{
               @projects => "2026-10-03T11:00:00.000Z",
               @notes => "2026-10-04T12:30:00.000Z"
             }

      {:ok, second} = PullScheduler.run_once(connectors: [spec], tenant_id: "default")

      assert second.error_count == 0
      assert second.ingested_count == 1

      assert stored_marks(ctx.connector_id) == %{
               @projects => "2026-10-05T08:30:00.000Z",
               @notes => "2026-10-04T12:30:00.000Z"
             }
    end

    test "a revoked token surfaces as an error on the connector, not a quiet empty pull", ctx do
      spec = %{
        kind: :notion,
        id: ctx.connector_id,
        workspace_id: ctx.workspace,
        config: config([@revoked])
      }

      {:ok, summary} = PullScheduler.run_once(connectors: [spec], tenant_id: "default")

      assert summary.error_count == 1
      assert [%{status: :error, reason: :auth_expired, signals: 0}] = summary.connector_results
      assert stored_marks(ctx.connector_id) == nil
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp config(database_ids) do
    %{
      "workspace_name" => "Example Co",
      "database_ids" => database_ids,
      "credentials" => %{"integration_token" => "secret_example-token"}
    }
  end

  defp state(database_ids) do
    {:ok, state} = Notion.init(config(database_ids))
    state
  end

  defp query_calls(stub, database_id) do
    ConnectorFixtureStub.calls_matching(stub, "/databases/#{database_id}/query")
  end

  defp header(call, name) do
    Enum.find_value(call.headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp after_of(call), do: get_in(call.body, ["filter", "last_edited_time", "after"])

  defp marks(cursor), do: Jason.decode!(cursor)

  defp stored_marks(connector_id) do
    {:ok, [[cursor]]} =
      Store.raw_query("SELECT cursor FROM connectors WHERE id = ?1", [connector_id])

    if is_binary(cursor), do: marks(cursor)
  end

  # A Signal routed to several nodes is indexed once per node, so a workspace
  # holds more than one context per page. The title keeps the count meaning
  # "pages that landed here".
  defp contexts_in(workspace_id, title) do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2 AND title = ?3",
        [Tenant.default_id(), workspace_id, title]
      )

    count
  end
end
