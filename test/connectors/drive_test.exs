defmodule OptimalEngine.Connectors.DriveTest do
  @moduledoc """
  Google Drive adapter end to end against a recorded Drive v3 API recording
  (`test/fixtures/connectors/drive/routes.json`): token refresh, the start page
  token, a two-page file list, `files.export` for Docs, Sheets and Slides, a
  plain-text download, an export refused as too large, and a two-page change
  list that ends in `newStartPageToken`.

  The last group drives the real adapter through the Runner and the intake sink,
  so it proves that what Drive hands over reaches the engine, in the workspace
  the connector was registered against, and that the cursor one run parks is the
  cursor the next run can use.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias OptimalEngine.Connectors.Adapters.Drive
  alias OptimalEngine.Connectors.PullScheduler
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.ConnectorFixtureStub

  @credentials %{
    "oauth_refresh_token" => "1//example-refresh-token",
    "client_id" => "example-client-id.apps.googleusercontent.com",
    "client_secret" => "example-client-secret"
  }

  @config %{"scope" => "my_drive", "credentials" => @credentials}

  @readable_titles [
    "Example Co kickoff notes",
    "Example Co pipeline",
    "Example Co proposal deck",
    "call-notes.txt"
  ]

  setup do
    stub = ConnectorFixtureStub.install(:drive)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "init/1" do
    test "declares the :drive kind with OAuth and a required scope" do
      assert Drive.kind() == :drive
      assert Drive.display_name() == "Google Drive"
      assert Drive.auth_scheme() == :oauth2
      assert Drive.required_config_keys() == [:scope]
    end

    test "rejects a config with no scope or no credentials" do
      assert {:error, {:missing_config, [:scope]}} = Drive.init(%{"credentials" => @credentials})
      assert {:error, {:missing_credentials, _}} = Drive.init(%{"scope" => "my_drive"})
    end

    test "accepts the scope as an atom or a string" do
      assert {:ok, _state} = Drive.init(%{scope: :my_drive, credentials: @credentials})
      assert {:ok, _state} = Drive.init(%{"scope" => "starred", "credentials" => @credentials})
    end

    test "rejects a scope it does not know" do
      assert {:error, {:invalid_config, :scope}} =
               Drive.init(%{"scope" => "everything", "credentials" => @credentials})
    end

    test "a shared drive scope needs the drive id" do
      assert {:error, {:missing_config, [:drive_id]}} =
               Drive.init(%{"scope" => "shared_drive", "credentials" => @credentials})

      assert {:ok, _state} =
               Drive.init(%{
                 "scope" => "shared_drive",
                 "drive_id" => "0Aexample-drive",
                 "credentials" => @credentials
               })
    end
  end

  describe "initial sync" do
    test "walks both pages and returns one Signal per file that has text", %{stub: stub} do
      {:ok, state} = Drive.init(@config)
      assert {:ok, %{signals: signals, cursor: cursor}} = Drive.sync(state, nil)

      assert signals |> Enum.map(& &1.title) |> Enum.sort() == Enum.sort(@readable_titles)
      assert cursor == "7001"

      # The second page was requested, once.
      assert length(ConnectorFixtureStub.calls_matching(stub, "pageToken=FILES-PAGE-2")) == 1
    end

    test "every Signal carries text, so the intake sink does not drop it" do
      {:ok, state} = Drive.init(@config)
      {:ok, %{signals: signals}} = Drive.sync(state, nil)

      assert Enum.all?(signals, fn %Signal{content: content} -> String.trim(content) != "" end)
    end

    test "asks the list for nextPageToken, because Drive returns only the fields named", %{
      stub: stub
    } do
      {:ok, state} = Drive.init(@config)
      {:ok, _result} = Drive.sync(state, nil)

      [first_page, second_page] = list_calls(stub)

      for call <- [first_page, second_page] do
        fields = query(call.url)["fields"]
        assert fields =~ "nextPageToken"
        assert fields =~ "files("
        assert query(call.url)["q"] == "trashed = false"
      end

      assert query(second_page.url)["pageToken"] == "FILES-PAGE-2"
      refute Map.has_key?(query(first_page.url), "pageToken")
    end

    test "takes the start page token before it lists, so a change made mid-walk is not lost", %{
      stub: stub
    } do
      {:ok, state} = Drive.init(@config)
      {:ok, _result} = Drive.sync(state, nil)

      urls = stub |> ConnectorFixtureStub.calls() |> Enum.map(& &1.url)
      start_at = Enum.find_index(urls, &String.contains?(&1, "/changes/startPageToken"))
      list_at = Enum.find_index(urls, &String.contains?(&1, "/drive/v3/files?"))

      assert start_at < list_at
    end

    test "exports each Google type in the format that carries its text", %{stub: stub} do
      {:ok, state} = Drive.init(@config)
      {:ok, _result} = Drive.sync(state, nil)

      assert export_mime(stub, "doc-0001") == "text/markdown"
      assert export_mime(stub, "sheet-0001") == "text/csv"
      assert export_mime(stub, "slides-0001") == "text/plain"

      # A plain-text file has bytes of its own, so it is downloaded, not exported.
      assert [download] = ConnectorFixtureStub.calls_matching(stub, "/files/txt-0001?alt=media")
      assert query(download.url)["alt"] == "media"
      assert [] = ConnectorFixtureStub.calls_matching(stub, "/files/txt-0001/export")
    end

    test "never fetches a folder, a PDF or an image, which have no text to read", %{stub: stub} do
      {:ok, state} = Drive.init(@config)
      {:ok, %{signals: signals}} = Drive.sync(state, nil)

      for id <- ["folder-0001", "pdf-0001", "photo-0001"] do
        assert [] = ConnectorFixtureStub.calls_matching(stub, "/files/#{id}")
      end

      refute Enum.any?(signals, &(&1.title in ["Example Co", "Signed order form.pdf"]))
    end

    test "sends the refreshed bearer token on every Drive call", %{stub: stub} do
      {:ok, state} = Drive.init(@config)
      {:ok, _result} = Drive.sync(state, nil)

      drive_calls =
        stub |> ConnectorFixtureStub.calls() |> Enum.filter(&String.contains?(&1.url, "/drive/v3/"))

      assert drive_calls != []

      for call <- drive_calls do
        assert Enum.any?(call.headers, fn {k, v} ->
                 k == "authorization" and v == "Bearer example-drive-access-token"
               end)
      end

      [token_call] = ConnectorFixtureStub.calls_matching(stub, "oauth2.googleapis.com/token")
      assert token_call.body["grant_type"] == "refresh_token"
      assert token_call.body["refresh_token"] == "1//example-refresh-token"
    end

    test "a file too large to export is skipped and the rest still arrive", %{stub: stub} do
      {:ok, state} = Drive.init(@config)
      {:ok, %{signals: signals}} = Drive.sync(state, nil)

      refute Enum.any?(signals, &(&1.title == "Company handbook"))
      assert length(signals) == 4
      assert [_] = ConnectorFixtureStub.calls_matching(stub, "/files/doc-big/export")
    end

    test "stops at :max_pages, says so, and still parks a cursor the changes feed can use" do
      {:ok, state} = Drive.init(Map.put(@config, "max_pages", 1))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{signals: signals, cursor: "7001"}} = Drive.sync(state, nil)

          assert signals |> Enum.map(& &1.title) |> Enum.sort() == [
                   "Example Co kickoff notes",
                   "Example Co pipeline"
                 ]
        end)

      assert log =~ "max_pages"
    end
  end

  describe "signal mapping" do
    test "maps a Google Doc to a markdown document Signal with its exported text" do
      signal = sync_signals() |> Enum.find(&(&1.title == "Example Co kickoff notes"))

      assert %Signal{} = signal
      assert signal.genre == "document"
      assert signal.mode == :linguistic
      assert signal.format == :markdown
      assert signal.path == "optimal://connectors/drive/doc-0001"
      assert signal.id =~ "drive:"
      assert signal.content =~ "Jane Example will send the signed order form by Friday."
      assert DateTime.to_iso8601(signal.modified_at) == "2026-10-16T09:30:00.000Z"
    end

    test "maps a Google Sheet to a data table Signal holding its CSV" do
      signal = sync_signals() |> Enum.find(&(&1.title == "Example Co pipeline"))

      assert signal.genre == "table"
      assert signal.mode == :data
      assert signal.content =~ "Deal,Stage,Owner"
      assert signal.content =~ "Example Co order,Proposal,Jane Example"
    end

    test "maps a Google Slides deck and a plain-text file" do
      signals = sync_signals()

      deck = Enum.find(signals, &(&1.title == "Example Co proposal deck"))
      assert deck.genre == "slides"
      assert deck.content =~ "Scope: onboarding and delivery"

      note = Enum.find(signals, &(&1.title == "call-notes.txt"))
      assert note.genre == "file"
      assert note.content =~ "confirmed the delivery address"
    end

    test "transform/1 reads the text the adapter fetched, not a field Drive does not return" do
      raw = %{
        "id" => "doc-9",
        "name" => "Notes",
        "mimeType" => "application/vnd.google-apps.document",
        "modifiedTime" => "2026-10-16T09:30:00.000Z",
        "exportedText" => "not a Drive field",
        "content" => "not a Drive field either"
      }

      assert {:ok, %Signal{content: ""}} = Drive.transform(raw)
      assert {:ok, %Signal{content: "Body"}} = Drive.transform(Map.put(raw, "text", "Body"))
    end

    test "transform/1 strips the markup from an HTML file" do
      raw = %{
        "id" => "html-1",
        "name" => "page.html",
        "mimeType" => "text/html",
        "text" => "<html><body><h1>Delivery</h1><p>Thursday</p></body></html>"
      }

      assert {:ok, %Signal{content: "Delivery Thursday"}} = Drive.transform(raw)
    end

    test "transform/1 still returns a Signal for a minimal payload" do
      assert {:ok, %Signal{} = signal} = Drive.transform(%{"id" => "x"})
      assert signal.title == "Untitled"
      assert signal.id =~ "drive:"
    end
  end

  describe "incremental sync" do
    test "follows nextPageToken to the end and parks newStartPageToken", %{stub: stub} do
      {:ok, state} = Drive.init(@config)

      assert {:ok, %{signals: signals, cursor: cursor}} = Drive.sync(state, "7001")

      assert cursor == "7003"

      assert signals |> Enum.map(& &1.title) |> Enum.sort() == [
               "Delivery schedule",
               "Example Co kickoff notes"
             ]

      assert length(ConnectorFixtureStub.calls_matching(stub, "/drive/v3/changes?")) == 2
      assert [_] = ConnectorFixtureStub.calls_matching(stub, "pageToken=7002")
    end

    test "ignores a removed file and a trashed file" do
      {:ok, state} = Drive.init(@config)
      {:ok, %{signals: signals}} = Drive.sync(state, "7001")

      refute Enum.any?(signals, &(&1.title == "Old draft"))
      assert length(signals) == 2
    end

    test "asks the change list for both page tokens and for the file fields", %{stub: stub} do
      {:ok, state} = Drive.init(@config)
      {:ok, _result} = Drive.sync(state, "7001")

      [first | _] = ConnectorFixtureStub.calls_matching(stub, "/drive/v3/changes?")
      fields = query(first.url)["fields"]

      assert fields =~ "nextPageToken"
      assert fields =~ "newStartPageToken"
      assert fields =~ "changes("
      assert fields =~ "modifiedTime"
    end

    test "the cursor the initial sync parks is the one the next sync uses", %{stub: stub} do
      {:ok, state} = Drive.init(@config)

      {:ok, %{cursor: first_cursor}} = Drive.sync(state, nil)
      {:ok, %{cursor: second_cursor}} = Drive.sync(state, first_cursor)

      assert first_cursor == "7001"
      assert second_cursor == "7003"

      changes_calls = ConnectorFixtureStub.calls_matching(stub, "/drive/v3/changes?")
      assert query(hd(changes_calls).url)["pageToken"] == first_cursor
    end

    test "a page that returns nextPageToken alone continues, and the cap parks that token" do
      {:ok, state} = Drive.init(Map.put(@config, "max_pages", 1))

      # One page per sync: the first stops on Drive's nextPageToken, not on a
      # token it invented, and the next run resumes exactly there.
      assert {:ok, %{signals: [first], cursor: "7002"}} = Drive.sync(state, "7001")
      assert first.title == "Example Co kickoff notes"

      assert {:ok, %{signals: [second], cursor: "7003"}} = Drive.sync(state, "7002")
      assert second.title == "Delivery schedule"
    end

    test "a page with neither token keeps the cursor it was given instead of resetting" do
      stub =
        ConnectorFixtureStub.install(:drive,
          body: %{"access_token" => "example-drive-token-x", "changes" => []}
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Drive.init(@config)
      assert {:ok, %{signals: [], cursor: "7001"}} = Drive.sync(state, "7001")
    end
  end

  describe "scope" do
    @shared_config %{
      "scope" => "shared_drive",
      "drive_id" => "0Aexample-drive",
      "credentials" => @credentials
    }

    test "a shared drive lists, and asks for its start token, inside that drive", %{stub: stub} do
      {:ok, state} = Drive.init(@shared_config)
      {:ok, _result} = Drive.sync(state, nil)

      for call <- list_calls(stub) do
        query = query(call.url)
        assert query["corpora"] == "drive"
        assert query["driveId"] == "0Aexample-drive"
        assert query["includeItemsFromAllDrives"] == "true"
        assert query["supportsAllDrives"] == "true"
      end

      [start_call] = ConnectorFixtureStub.calls_matching(stub, "/changes/startPageToken")
      assert query(start_call.url)["driveId"] == "0Aexample-drive"
      assert query(start_call.url)["supportsAllDrives"] == "true"

      # A file in a shared drive is only readable with shared drive support.
      [download] = ConnectorFixtureStub.calls_matching(stub, "/files/txt-0001?alt=media")
      assert query(download.url)["supportsAllDrives"] == "true"
    end

    test "a shared drive polls the change list inside that drive", %{stub: stub} do
      {:ok, state} = Drive.init(@shared_config)
      {:ok, _result} = Drive.sync(state, "7001")

      for call <- ConnectorFixtureStub.calls_matching(stub, "/drive/v3/changes?") do
        assert query(call.url)["driveId"] == "0Aexample-drive"
        assert query(call.url)["includeItemsFromAllDrives"] == "true"
        assert query(call.url)["supportsAllDrives"] == "true"
      end
    end

    test "my drive adds no drive filter", %{stub: stub} do
      {:ok, state} = Drive.init(@config)
      {:ok, _result} = Drive.sync(state, nil)

      for call <- list_calls(stub) do
        refute Map.has_key?(query(call.url), "driveId")
        refute Map.has_key?(query(call.url), "corpora")
      end
    end

    test "starred lists only starred files", %{stub: stub} do
      {:ok, state} = Drive.init(%{@config | "scope" => "starred"})
      {:ok, _result} = Drive.sync(state, nil)

      for call <- list_calls(stub) do
        assert query(call.url)["q"] == "starred = true and trashed = false"
      end
    end

    test "starred keeps only starred files from the change list" do
      {:ok, state} = Drive.init(%{@config | "scope" => "starred"})

      assert {:ok, %{signals: [signal], cursor: "7003"}} = Drive.sync(state, "7001")
      assert signal.title == "Delivery schedule"
    end
  end

  describe "errors" do
    test "an expired refresh token is :auth_expired, whether Google says 401 or invalid_grant" do
      stub = ConnectorFixtureStub.install(:drive, status: 401)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Drive.init(@config)
      assert {:error, :auth_expired} = Drive.sync(state, nil)

      stub = ConnectorFixtureStub.install(:drive, status: 400, body: %{"error" => "invalid_grant"})
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      assert {:error, :auth_expired} = Drive.sync(state, nil)
    end

    test "a rate-limited refresh is :rate_limited and a failing one is :transient" do
      {:ok, state} = Drive.init(@config)

      stub = ConnectorFixtureStub.install(:drive, status: 429)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
      assert {:error, :rate_limited} = Drive.sync(state, nil)

      stub = ConnectorFixtureStub.install(:drive, status: 503)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
      assert {:error, :transient} = Drive.sync(state, nil)
    end

    test "a rate-limited list names Retry-After" do
      {:ok, state} = Drive.init(@config)
      intercept("/drive/v3/files?", 429, "{}", [{"retry-after", "3"}])

      assert {:error, {:rate_limited, 3000}} = Drive.sync(state, nil)
    end

    test "Drive's 403 rate limit is :rate_limited, not a permission failure" do
      {:ok, state} = Drive.init(@config)
      intercept("/drive/v3/files?", 403, reason_body(403, "userRateLimitExceeded"))

      assert {:error, :rate_limited} = Drive.sync(state, nil)
    end

    test "a failing list is :transient and an unknown 4xx names its status" do
      {:ok, state} = Drive.init(@config)

      intercept("/drive/v3/files?", 503, "{}")
      assert {:error, :transient} = Drive.sync(state, nil)

      intercept("/drive/v3/files?", 400, reason_body(400, "badRequest"))
      assert {:error, {:http, 400}} = Drive.sync(state, nil)
    end

    test "a failing start page token or change list is an error, not an empty sync" do
      {:ok, state} = Drive.init(@config)

      intercept("/changes/startPageToken", 500, "{}")
      assert {:error, :transient} = Drive.sync(state, nil)

      intercept("/drive/v3/changes?", 401, "{}")
      assert {:error, :auth_expired} = Drive.sync(state, "7001")

      intercept("/drive/v3/changes?", 429, "{}")
      assert {:error, :rate_limited} = Drive.sync(state, "7001")
    end

    test "an unreachable endpoint is a transport error, not a crash" do
      stub = ConnectorFixtureStub.install(:drive, unreachable: true)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Drive.init(@config)
      assert {:error, _reason} = Drive.sync(state, nil)
    end
  end

  describe "a failure while reading a file" do
    test "an expired token mid-sync is :auth_expired, never a successful empty sync" do
      {:ok, state} = Drive.init(@config)
      intercept("/files/sheet-0001/export", 401, reason_body(401, "authError"))

      assert {:error, :auth_expired} = Drive.sync(state, nil)
    end

    test "a rate limit mid-sync is :rate_limited and a server fault is :transient" do
      {:ok, state} = Drive.init(@config)

      intercept("/files/sheet-0001/export", 429, "{}", [{"retry-after", "2"}])
      assert {:error, {:rate_limited, 2000}} = Drive.sync(state, nil)

      intercept("/files/sheet-0001/export", 403, reason_body(403, "rateLimitExceeded"))
      assert {:error, :rate_limited} = Drive.sync(state, nil)

      intercept("/files/sheet-0001/export", 502, "{}")
      assert {:error, :transient} = Drive.sync(state, nil)
    end

    test "a transport failure mid-sync is an error" do
      {:ok, state} = Drive.init(@config)
      intercept("/files/slides-0001/export", {:error, :closed})

      assert {:error, :closed} = Drive.sync(state, nil)
    end

    test "a permission failure that is not about this one file is an error, not a skip" do
      {:ok, state} = Drive.init(@config)
      intercept("/files/doc-0001/export", 403, reason_body(403, "insufficientPermissions"))

      assert {:error, {:http, 403}} = Drive.sync(state, nil)
    end

    test "a file deleted between the list and the read is skipped, and the rest arrive" do
      {:ok, state} = Drive.init(@config)
      intercept("/files/sheet-0001/export", 404, reason_body(404, "notFound"))

      assert {:ok, %{signals: signals, cursor: "7001"}} = Drive.sync(state, nil)
      refute Enum.any?(signals, &(&1.title == "Example Co pipeline"))
      assert length(signals) == 3
    end

    test "a skipped file is named in the log" do
      {:ok, state} = Drive.init(@config)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _result} = Drive.sync(state, nil)
        end)

      assert log =~ "doc-big"
      assert log =~ "exportSizeLimitExceeded"
    end

    test "a text file over the size cap is not downloaded", %{stub: stub} do
      {:ok, state} = Drive.init(@config)

      intercept_list(%{
        "files" => [
          %{
            "id" => "txt-huge",
            "name" => "huge.txt",
            "mimeType" => "text/plain",
            "modifiedTime" => "2026-10-12T08:15:00.000Z",
            "size" => "524288000"
          }
        ]
      })

      assert {:ok, %{signals: [], cursor: "7001"}} = Drive.sync(state, nil)
      assert [] = ConnectorFixtureStub.calls_matching(stub, "/files/txt-huge")
    end
  end

  describe "the whole path through the Runner and the intake sink" do
    setup do
      key = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      original = System.get_env("CONNECTOR_KEY")
      System.put_env("CONNECTOR_KEY", key)

      on_exit(fn ->
        if original,
          do: System.put_env("CONNECTOR_KEY", original),
          else: System.delete_env("CONNECTOR_KEY")
      end)

      suffix = System.unique_integer([:positive])

      {:ok,
       workspace: "drive-primary-#{suffix}",
       other: "drive-other-#{suffix}",
       bystander: "drive-bystander-#{suffix}",
       connector_id: "drive-connector-#{suffix}"}
    end

    test "the Signals land in the workspace the connector is registered against", ctx do
      assert {:ok, summary} = run_connector(ctx.connector_id, ctx.workspace)

      assert summary.error_count == 0
      assert summary.ingested_count == 4

      for title <- @readable_titles do
        assert contexts_in(ctx.workspace, title) >= 1, "#{title} did not land in the workspace"
        assert contexts_in(ctx.bystander, title) == 0
      end

      # The files with no text never reach the engine as empty shells.
      for title <- ["Signed order form.pdf", "Example Co", "Company handbook", "Site visit.jpg"] do
        assert contexts_in(ctx.workspace, title) == 0
      end
    end

    test "a second connector in another workspace lands its Signals there", ctx do
      assert {:ok, %{error_count: 0}} = run_connector(ctx.connector_id, ctx.workspace)
      assert {:ok, %{error_count: 0}} = run_connector(ctx.connector_id <> "-b", ctx.other)

      for title <- @readable_titles do
        assert contexts_in(ctx.other, title) >= 1
        assert contexts_in(ctx.workspace, title) >= 1
      end
    end

    test "the cursor one run stores is the one the next run reads, and the changes land too", ctx do
      assert {:ok, %{error_count: 0}} = run_connector(ctx.connector_id, ctx.workspace)
      assert stored_cursor(ctx.connector_id) == "7001"

      # Same connector, second tick: the stored cursor drives the change list.
      assert {:ok, summary} = run_connector(ctx.connector_id, ctx.workspace)
      assert summary.error_count == 0
      assert summary.ingested_count == 2
      assert stored_cursor(ctx.connector_id) == "7003"

      assert contexts_in(ctx.workspace, "Delivery schedule") >= 1
    end

    test "the OAuth secret is not stored in the clear", ctx do
      assert {:ok, %{error_count: 0}} = run_connector(ctx.connector_id, ctx.workspace)

      {:ok, [[stored_config]]} =
        Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [ctx.connector_id])

      refute stored_config =~ "example-client-secret"
      refute stored_config =~ "example-refresh-token"
    end

    test "an expired token surfaces as a failed run with the cursor left alone", ctx do
      assert {:ok, %{error_count: 0}} = run_connector(ctx.connector_id, ctx.workspace)

      stub = ConnectorFixtureStub.install(:drive, status: 401)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      assert {:ok, summary} = run_connector(ctx.connector_id, ctx.workspace)
      assert summary.error_count == 1
      assert [%{status: :error, reason: :auth_expired}] = summary.connector_results
      assert stored_cursor(ctx.connector_id) == "7001"
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp run_connector(id, workspace_id) do
    PullScheduler.run_once(
      connectors: [%{kind: :drive, id: id, workspace_id: workspace_id, config: @config}],
      tenant_id: Tenant.default_id()
    )
  end

  defp sync_signals do
    {:ok, state} = Drive.init(@config)
    {:ok, %{signals: signals}} = Drive.sync(state, nil)
    signals
  end

  defp list_calls(stub) do
    stub
    |> ConnectorFixtureStub.calls()
    |> Enum.filter(&String.contains?(&1.url, "/drive/v3/files?"))
  end

  defp export_mime(stub, id) do
    [call] = ConnectorFixtureStub.calls_matching(stub, "/files/#{id}/export")
    query(call.url)["mimeType"]
  end

  defp query(url) do
    case URI.parse(url).query do
      nil -> %{}
      query -> URI.decode_query(query)
    end
  end

  defp reason_body(code, reason) do
    Jason.encode!(%{
      "error" => %{
        "code" => code,
        "message" => reason,
        "errors" => [%{"domain" => "global", "reason" => reason, "message" => reason}]
      }
    })
  end

  # Answers the requests whose URL contains `fragment` with a recorded status,
  # and leaves every other request to the recording. A pair `{:error, reason}`
  # stands for a transport failure.
  defp intercept(fragment, {:error, _reason} = failure) do
    wrap_mock(fragment, fn -> failure end)
  end

  defp intercept(fragment, status, body, headers \\ []) do
    wrap_mock(fragment, fn ->
      charlist_headers =
        Enum.map([{"content-type", "application/json"} | headers], fn {k, v} ->
          {String.to_charlist(k), String.to_charlist(v)}
        end)

      {:ok, {{~c"HTTP/1.1", status, ~c"Error"}, charlist_headers, body}}
    end)
  end

  defp intercept_list(body) do
    wrap_mock("/drive/v3/files?", fn ->
      {:ok,
       {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
        Jason.encode!(body)}}
    end)
  end

  defp wrap_mock(fragment, response) do
    original = Application.get_env(:optimal_engine, :http_mock)

    Application.put_env(:optimal_engine, :http_mock, fn url, opts ->
      if String.contains?(url, fragment), do: response.(), else: original.(url, opts)
    end)
  end

  defp stored_cursor(connector_id) do
    {:ok, [[cursor]]} =
      Store.raw_query("SELECT cursor FROM connectors WHERE id = ?1", [connector_id])

    cursor
  end

  # A Signal routed to several nodes is indexed once per node, so a workspace can
  # hold more than one context per Signal; the title keeps the count meaning
  # "Signals that landed here".
  defp contexts_in(workspace_id, title) do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2 AND title = ?3",
        [Tenant.default_id(), workspace_id, title]
      )

    count
  end
end
