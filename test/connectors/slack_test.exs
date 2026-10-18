defmodule OptimalEngine.Connectors.SlackTest do
  @moduledoc """
  Slack adapter end to end against a recorded Slack Web API recording
  (`test/fixtures/connectors/slack/routes.json`): a two-page channel list,
  `conversations.history` returned newest first with and without `oldest` and
  `latest`, a `has_more` page, and the `{"ok": false, "error": ...}` envelope
  Slack uses for application errors.

  The last describe block drives the real adapter through the Runner and the
  intake sink, to show that the connector's Signals land in the workspace the
  connector is registered against.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Connectors.Adapters.Slack
  alias OptimalEngine.Connectors.PullScheduler
  alias OptimalEngine.Connectors.Transform
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.ConnectorFixtureStub

  @general "C0EXAMPLE1"
  @sales "C0EXAMPLE2"
  @leadership "C0EXAMPLE3"
  @standup "C0FLAKY"

  # Message timestamps in the recording, oldest first.
  @m1 "1793016000.000100"
  @m3 "1793016600.000300"
  @m5 "1793017200.000500"
  @m6 "1793017500.000600"
  @s2 "1793016700.000200"
  @f2 "1793016400.000200"
  @f3 "1793016800.000300"

  @general_texts [
    "Kickoff for Example Co is Monday at 10am.",
    "Draft order form is in the shared folder.",
    "Can you confirm the delivery address please?",
    "Confirmed, the address on file is correct.",
    "Thanks. Invoice INV-0007 will follow on Friday."
  ]

  setup do
    stub = ConnectorFixtureStub.install(:slack)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "initial pull" do
    test "pages back through a channel, oldest first, without overlap", %{stub: stub} do
      assert {:ok, %{signals: signals, cursor: cursor}} = sync(config([@general]), nil)

      assert Enum.map(signals, & &1.content) == @general_texts
      assert signals |> Enum.map(& &1.path) |> Enum.uniq() |> length() == 5

      # Newest page first, then the page older than it: `latest` pages
      # backwards, `oldest` is only a lower bound and is absent on a first pull.
      assert [first, second] = history_urls(stub)
      refute first =~ "oldest="
      refute first =~ "latest="
      assert second =~ "&latest=#{@m3}"
      refute second =~ "oldest="

      assert positions(cursor) == %{@general => %{"oldest" => @m5}}
    end

    test "syncs every configured channel and keeps a position for each" do
      assert {:ok, %{signals: signals, cursor: cursor}} = sync(config([@general, @sales]), nil)

      assert length(signals) == 7

      assert positions(cursor) == %{
               @general => %{"oldest" => @m5},
               @sales => %{"oldest" => @s2}
             }
    end

    test "authenticates every call with the bot token", %{stub: stub} do
      {:ok, _result} = sync(config([@general]), nil)

      calls = ConnectorFixtureStub.calls(stub)
      assert calls != []

      assert Enum.all?(calls, fn call ->
               Enum.any?(call.headers, fn {k, v} ->
                 k == "authorization" and v == "Bearer xoxb-example-token"
               end)
             end)
    end

    test "with no channels configured, follows the channel list's next_cursor", %{stub: stub} do
      assert {:ok, %{signals: signals, cursor: cursor}} = sync(config([]), nil)

      # general (5) + sales (2) from the first page, leadership (1) from the second.
      assert length(signals) == 8

      assert [_first_page, second_page] =
               ConnectorFixtureStub.calls_matching(stub, "conversations.list")

      # The cursor is base64 and ends in "=", which must be URL-encoded.
      assert second_page.url =~ "&cursor=dGVhbTpDMDNFWEFNUExF%3D"

      assert Map.keys(positions(cursor)) |> Enum.sort() == [@general, @sales, @leadership]
    end
  end

  describe "the cursor across runs" do
    test "every channel is read again from its own position, not just one", %{stub: stub} do
      {:ok, %{cursor: first}} = sync(config([@general, @sales]), nil)
      seen = length(ConnectorFixtureStub.calls(stub))

      assert {:ok, %{signals: [signal], cursor: second}} = sync(config([@general, @sales]), first)

      assert signal.content == "Invoice INV-0007 is attached."

      later = stub |> ConnectorFixtureStub.calls() |> Enum.drop(seen) |> Enum.map(& &1.url)
      assert Enum.any?(later, &(&1 =~ "channel=#{@general}&limit=200&oldest=#{@m5}"))
      assert Enum.any?(later, &(&1 =~ "channel=#{@sales}&limit=200&oldest=#{@s2}"))

      assert positions(second) == %{
               @general => %{"oldest" => @m6},
               @sales => %{"oldest" => @s2}
             }
    end

    test "a run with nothing new returns no signals, the same cursor and never re-reads", %{
      stub: stub
    } do
      {:ok, %{cursor: first}} = sync(config([@general, @sales]), nil)
      {:ok, %{cursor: second}} = sync(config([@general, @sales]), first)
      seen = length(ConnectorFixtureStub.calls(stub))

      assert {:ok, %{signals: [], cursor: third}} = sync(config([@general, @sales]), second)
      assert positions(third) == positions(second)

      # Every history call of the idle run is bounded below; none re-reads a channel from the start.
      idle = stub |> ConnectorFixtureStub.calls() |> Enum.drop(seen) |> Enum.map(& &1.url)
      assert length(idle) == 2
      assert Enum.all?(idle, &(&1 =~ "oldest="))
    end

    test "replaying a cursor yields the same batch" do
      {:ok, %{cursor: cursor}} = sync(config([@general, @sales]), nil)

      {:ok, %{signals: once}} = sync(config([@general, @sales]), cursor)
      {:ok, %{signals: twice}} = sync(config([@general, @sales]), cursor)

      assert Enum.map(once, & &1.id) == Enum.map(twice, & &1.id)
    end

    test "a new channel joins an existing cursor from the start" do
      {:ok, %{cursor: first}} = sync(config([@general]), nil)

      assert {:ok, %{signals: signals, cursor: second}} =
               sync(config([@general, @sales]), first)

      # General has the one new message; sales had no position, so it is read in full.
      assert length(signals) == 3
      assert positions(second)[@sales] == %{"oldest" => @s2}
    end

    test "a cursor this adapter did not write starts over instead of crashing" do
      {:ok, %{signals: fresh}} = sync(config([@general]), nil)

      for unreadable <- ["#{@general}:#{@m3}", "#{@general}:", "garbage", "42", "[]", ""] do
        assert {:ok, %{signals: signals}} = sync(config([@general]), unreadable)
        assert length(signals) == length(fresh)
      end
    end
  end

  describe "a channel larger than one run's page budget" do
    test "the first run keeps the newest page and the gap; the next run closes the gap" do
      cfg = config([@general], %{"max_pages" => 1})

      assert {:ok, %{signals: newest, cursor: parked}} = sync(cfg, nil)
      assert Enum.map(newest, & &1.content) == Enum.take(@general_texts, -3)

      # Parked: nothing older than @m3 has been read, and the newest ts seen is kept to
      # become the lower bound once the gap is closed.
      assert positions(parked) == %{@general => %{"latest" => @m3, "head" => @m5}}

      assert {:ok, %{signals: older, cursor: closed}} = sync(cfg, parked)
      assert Enum.map(older, & &1.content) == Enum.take(@general_texts, 2)
      assert positions(closed) == %{@general => %{"oldest" => @m5}}

      # Together the two runs saw every message exactly once.
      all = newest ++ older
      assert length(all) == 5
      assert all |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 5

      # And the run after that reads only what arrived since.
      assert {:ok, %{signals: [new]}} = sync(cfg, closed)
      assert new.content == "Invoice INV-0007 is attached."
    end

    test "a gap that has a lower bound is read between both bounds", %{stub: stub} do
      parked = cursor(%{@general => %{"oldest" => @m1, "latest" => @m3, "head" => @m5}})

      assert {:ok, %{signals: [signal], cursor: closed}} = sync(config([@general]), parked)

      assert signal.content == "Draft order form is in the shared folder."
      assert [url] = history_urls(stub)
      assert url =~ "&oldest=#{@m1}&latest=#{@m3}"
      assert positions(closed) == %{@general => %{"oldest" => @m5}}
    end

    test "an outage on a later page keeps what was read and resumes below it" do
      cfg = config([@standup])

      log =
        capture_log(fn ->
          assert {:ok, %{signals: partial, cursor: parked}} = sync(cfg, nil)

          assert Enum.map(partial, & &1.content) ==
                   ["Standup notes, part two.", "Standup notes, part three."]

          send(self(), {:parked, parked})
        end)

      assert log =~ "stopped early"
      assert_received {:parked, parked}
      assert positions(parked) == %{@standup => %{"latest" => @f2, "head" => @f3}}

      assert {:ok, %{signals: rest, cursor: closed}} = sync(cfg, parked)
      assert Enum.map(rest, & &1.content) == ["Standup notes, part one."]
      assert positions(closed) == %{@standup => %{"oldest" => @f3}}
    end
  end

  describe "errors" do
    for code <- ~w(invalid_auth not_authed token_expired token_revoked account_inactive) do
      test "Slack's #{code} is :auth_expired, not an empty success" do
        install_override(body: %{"ok" => false, "error" => unquote(code)})

        assert {:error, :auth_expired} = sync(config([@general]), nil)
      end
    end

    test "HTTP 401 is :auth_expired" do
      install_override(status: 401)

      assert {:error, :auth_expired} = sync(config([@general]), nil)
    end

    test "an expired token found on a later channel fails the whole sync" do
      assert {:error, :auth_expired} = sync(config([@sales, "C0BADAUTH"]), nil)
    end

    test "a 429 names its Retry-After in milliseconds" do
      assert {:error, {:rate_limited, 3_000}} = sync(config(["C0LIMITED"]), nil)
    end

    test "a 429 without Retry-After, and Slack's ratelimited envelope, are :rate_limited" do
      install_override(status: 429)
      assert {:error, :rate_limited} = sync(config([@general]), nil)

      install_override(body: %{"ok" => false, "error" => "ratelimited"})
      assert {:error, :rate_limited} = sync(config([@general]), nil)
    end

    test "5xx, Slack's transient envelopes and an unreachable endpoint are :transient" do
      assert {:error, :transient} = sync(config(["C0UNAVAIL"]), nil)

      for code <- ~w(internal_error fatal_error service_unavailable request_timeout) do
        install_override(body: %{"ok" => false, "error" => code})
        assert {:error, :transient} = sync(config([@general]), nil)
      end

      install_override(unreachable: true)
      assert {:error, :transient} = sync(config([@general]), nil)
    end

    test "a rate limit part-way through keeps the channels already read and stops", %{stub: stub} do
      log =
        capture_log(fn ->
          assert {:ok, %{signals: signals, cursor: cursor}} =
                   sync(config([@sales, "C0LIMITED", @general]), nil)

          assert length(signals) == 2
          # Sales is parked; limited and general are untouched, so the next run resumes there.
          assert positions(cursor) == %{@sales => %{"oldest" => @s2}}
        end)

      assert log =~ "rate_limited"
      assert ConnectorFixtureStub.calls_matching(stub, "channel=#{@general}") == []
    end

    test "a rate limit before anything was read is an error, so the Runner can back off" do
      assert {:error, {:rate_limited, 3_000}} = sync(config(["C0LIMITED", @sales]), nil)
    end

    test "an unrecognised application error is surfaced, not swallowed" do
      install_override(body: %{"ok" => false, "error" => "missing_scope"})

      assert {:error, {:slack_error, "missing_scope"}} = sync(config([@general]), nil)
    end

    test "a channel the bot cannot read is skipped, and the rest still sync" do
      log =
        capture_log(fn ->
          assert {:ok, %{signals: signals, cursor: cursor}} =
                   sync(config(["C0NOTMEMBER", @sales]), nil)

          assert length(signals) == 2
          assert positions(cursor) == %{@sales => %{"oldest" => @s2}}
        end)

      assert log =~ "C0NOTMEMBER"
      assert log =~ "not_in_channel"
    end

    test "every channel-scoped error code is skipped" do
      for code <-
            ~w(channel_not_found not_in_channel access_denied method_not_supported_for_channel_type) do
        install_override(body: %{"ok" => false, "error" => code})

        capture_log(fn ->
          assert {:ok, %{signals: [], cursor: nil}} = sync(config([@general]), nil)
        end)
      end
    end

    test "a failing channel list fails the sync" do
      install_override(body: %{"ok" => false, "error" => "invalid_auth"})
      assert {:error, :auth_expired} = sync(config([]), nil)

      install_override(status: 429)
      assert {:error, :rate_limited} = sync(config([]), nil)
    end

    test "a channels value that is not a list is a config error" do
      assert {:error, {:invalid_config, :channels}} = sync(config("C0EXAMPLE1"), nil)
    end
  end

  describe "transform/1" do
    test "maps text, author, timestamp and source to a Signal" do
      raw = %{
        "ts" => "1793016000.000100",
        "client_msg_id" => "6f0c1d2e-0001-4a00-8000-000000000001",
        "text" => "Kickoff for Example Co is Monday at 10am.",
        "user" => "U0JANE001"
      }

      assert {:ok, %Signal{} = signal} = Slack.transform(raw)

      assert signal.id == Transform.signal_id(:slack, "6f0c1d2e-0001-4a00-8000-000000000001")
      assert signal.title == "Kickoff for Example Co is Monday at 10am."
      assert signal.content == "Kickoff for Example Co is Monday at 10am."
      assert signal.genre == "message"
      assert signal.entities == ["U0JANE001"]
      assert signal.path == "optimal://connectors/slack/6f0c1d2e-0001-4a00-8000-000000000001"
      assert signal.modified_at == ~U[2026-10-26 12:00:00Z]
    end

    test "falls back to ts for the id when the message has no client_msg_id" do
      raw = %{"ts" => "1793016300.000200", "text" => "Draft order form.", "user" => "U0BOT0001"}

      assert {:ok, signal} = Slack.transform(raw)
      assert signal.id == Transform.signal_id(:slack, "1793016300.000200")
      assert signal.path == "optimal://connectors/slack/1793016300.000200"
    end

    test "dates a message by the whole second of its ts, never the next one" do
      raw = %{"ts" => "1793016000.900000", "text" => "x", "user" => "U0JANE001"}

      assert {:ok, signal} = Slack.transform(raw)
      assert DateTime.to_unix(signal.modified_at) == 1_793_016_000
    end

    test "cuts the title at 80 characters and keeps the whole text as content" do
      text = String.duplicate("a", 200)

      assert {:ok, signal} = Slack.transform(%{"ts" => "1793016000.000100", "text" => text})
      assert String.length(signal.title) == 80
      assert signal.content == text
    end

    test "the same message always gets the same id" do
      raw = %{"ts" => "1793016000.000100", "text" => "x", "user" => "U0JANE001"}

      assert {:ok, a} = Slack.transform(raw)
      assert {:ok, b} = Slack.transform(raw)
      assert a.id == b.id
    end
  end

  describe "through the Runner and the intake sink" do
    setup do
      original_key = System.get_env("CONNECTOR_KEY")

      System.put_env(
        "CONNECTOR_KEY",
        Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      )

      on_exit(fn ->
        if original_key,
          do: System.put_env("CONNECTOR_KEY", original_key),
          else: System.delete_env("CONNECTOR_KEY")
      end)

      suffix = System.unique_integer([:positive])
      {:ok, id: "slack-e2e-#{suffix}", workspace: "slack-ws-#{suffix}"}
    end

    test "the connector's Signals land in the workspace it is registered against", ctx do
      {:ok, summary} = pull(ctx, config([@general, @sales]))

      assert summary.error_count == 0
      assert summary.ingested_count == 7

      # Seven distinct messages, so seven distinct titles in the connector's workspace
      # (a Signal routed to several nodes is indexed once per node).
      assert distinct_titles_in(ctx.workspace) == 7

      # None of them went to the default workspace.
      assert titles_in("default", "Kickoff for Example Co is Monday at 10am.") == 0
    end

    test "the cursor is stored on the connector row, so the next pull ingests only what is new",
         ctx do
      {:ok, first} = pull(ctx, config([@general, @sales]))
      assert first.ingested_count == 7

      {:ok, [[stored]]} =
        Store.raw_query("SELECT cursor FROM connectors WHERE id = ?1", [ctx.id])

      assert positions(stored) == %{
               @general => %{"oldest" => @m5},
               @sales => %{"oldest" => @s2}
             }

      before_second = titles_in(ctx.workspace, "Thanks. Invoice INV-0007 will follow on Friday.")
      assert before_second >= 1

      {:ok, second} = pull(ctx, config([@general, @sales]))
      assert second.ingested_count == 1
      assert distinct_titles_in(ctx.workspace) == 8

      # A message already ingested is not ingested a second time.
      assert titles_in(ctx.workspace, "Thanks. Invoice INV-0007 will follow on Friday.") ==
               before_second

      {:ok, third} = pull(ctx, config([@general, @sales]))
      assert third.ingested_count == 0
      assert distinct_titles_in(ctx.workspace) == 8
    end

    test "an expired bot token flags the run instead of reporting an empty success", ctx do
      install_override(body: %{"ok" => false, "error" => "token_expired"})

      {:ok, summary} = pull(ctx, config([@general]))

      assert summary.error_count == 1
      assert [%{status: :error, reason: :auth_expired, signals: 0}] = summary.connector_results

      {:ok, [[status]]} =
        Store.raw_query(
          "SELECT status FROM connector_runs WHERE connector_id = ?1 ORDER BY id DESC LIMIT 1",
          [ctx.id]
        )

      assert status == "error"
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp config(channels, extra \\ %{}) do
    Map.merge(
      %{
        "workspace_id" => "T0EXAMPLE1",
        "channels" => channels,
        "credentials" => %{"bot_token" => "xoxb-example-token"}
      },
      extra
    )
  end

  defp sync(config, cursor) do
    {:ok, state} = Slack.init(config)
    Slack.sync(state, cursor)
  end

  defp positions(cursor), do: Jason.decode!(cursor)
  defp cursor(positions), do: Jason.encode!(positions)

  defp history_urls(stub) do
    stub
    |> ConnectorFixtureStub.calls_matching("conversations.history")
    |> Enum.map(& &1.url)
  end

  # Replaces the process-wide recording with an answer to every request, for the
  # failure shapes a recording of a healthy workspace does not carry.
  defp install_override(override) do
    stub = ConnectorFixtureStub.install(:slack, override)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    stub
  end

  defp pull(ctx, config) do
    PullScheduler.run_once(
      connectors: [%{kind: :slack, id: ctx.id, workspace_id: ctx.workspace, config: config}],
      tenant_id: "default"
    )
  end

  defp distinct_titles_in(workspace_id) do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(DISTINCT title) FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2",
        [Tenant.default_id(), workspace_id]
      )

    count
  end

  defp titles_in(workspace_id, title) do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2 AND title = ?3",
        [Tenant.default_id(), workspace_id, title]
      )

    count
  end
end
