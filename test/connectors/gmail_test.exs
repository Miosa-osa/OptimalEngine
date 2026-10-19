defmodule OptimalEngine.Connectors.GmailTest do
  @moduledoc """
  Gmail adapter end to end against a recorded Gmail API recording
  (`test/fixtures/connectors/gmail/routes.json`): token refresh, a two-page
  message list, full-format message fetch, the profile historyId, and an
  incremental history poll. Only the full-format fetch is recorded, so an
  adapter that asks for less finds no message.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.Gmail
  alias OptimalEngine.Signal
  alias OptimalEngine.Test.ConnectorFixtureStub

  @config %{
    "user_email" => "jane@example.com",
    "labels" => ["INBOX"],
    "credentials" => %{
      "oauth_refresh_token" => "1//example-refresh-token",
      "client_id" => "example-client-id.apps.googleusercontent.com",
      "client_secret" => "example-client-secret"
    }
  }

  setup do
    stub = ConnectorFixtureStub.install(:gmail)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "full sync" do
    test "walks every page, transforms each message, and parks the cursor on the profile historyId",
         %{
           stub: stub
         } do
      {:ok, state} = Gmail.init(@config)
      assert {:ok, %{signals: signals, cursor: cursor}} = Gmail.sync(state, nil)

      assert length(signals) == 3
      assert cursor == "900001"

      titles = signals |> Enum.map(& &1.title) |> Enum.sort()
      assert titles == ["Invoice INV-0007 overdue", "Order form for Example Co", "Re: kickoff"]

      # The second page was fetched, not just the first.
      assert length(ConnectorFixtureStub.calls_matching(stub, "pageToken=PAGE2")) == 1

      # Every message fetch carried the refreshed bearer token.
      [message_call | _] = ConnectorFixtureStub.calls_matching(stub, "/messages/msg-0001")

      assert Enum.any?(message_call.headers, fn {k, v} ->
               k == "authorization" and v == "Bearer ya29.example-access-token"
             end)

      # The initial pull is bounded by the lookback window, not by everything,
      # and leaves out Gmail's promotions, social, updates and forums tabs.
      [list_call | _] = ConnectorFixtureStub.calls_matching(stub, "/messages?maxResults=100")
      query = list_call.url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("q")
      assert query =~ ~r/^after:\d+ /

      for category <- ~w(promotions social updates forums) do
        assert query =~ "-category:#{category}"
      end
    end

    test "maps sender, subject, the whole text body and the epoch-millisecond date", %{
      stub: _stub
    } do
      {:ok, state} = Gmail.init(@config)
      {:ok, %{signals: signals}} = Gmail.sync(state, nil)

      [order_form] = Enum.filter(signals, &(&1.title == "Order form for Example Co"))

      assert order_form.genre == "email"
      assert order_form.content =~ "From: Jane Example <jane@example.com>"
      assert order_form.content =~ "To: Ops <ops@example.com>"
      assert order_form.content =~ "Subject: Order form for Example Co"
      # The text/plain body, not Gmail's short snippet.
      assert order_form.content =~ "The second page needs both initials."
      assert "jane@example.com" in order_form.entities
      assert order_form.path == "optimal://connectors/gmail/msg-0001"

      # internalDate is epoch milliseconds in a string, not ISO-8601, and it
      # dates the signal: when the mail arrived, not when it was pulled.
      assert DateTime.to_unix(order_form.modified_at) == 1_793_016_000
      assert DateTime.to_unix(order_form.created_at) == 1_793_016_000
    end

    test "an HTML-only message is reduced to its text", %{stub: _stub} do
      {:ok, state} = Gmail.init(@config)
      {:ok, %{signals: signals}} = Gmail.sync(state, nil)

      [invoice] = Enum.filter(signals, &(&1.title == "Invoice INV-0007 overdue"))
      assert invoice.content =~ "Payment of $1,200 is due 2026-11-01."
      refute invoice.content =~ "<b>"
    end

    test "every message is fetched in full format", %{stub: stub} do
      {:ok, state} = Gmail.init(@config)
      {:ok, _result} = Gmail.sync(state, nil)

      fetches = ConnectorFixtureStub.calls_matching(stub, "/messages/msg-")
      assert length(fetches) == 3
      assert Enum.all?(fetches, &String.contains?(&1.url, "format=full"))
    end

    test "exclude_categories: [] reads every tab", %{stub: stub} do
      {:ok, state} = Gmail.init(Map.put(@config, "exclude_categories", []))
      {:ok, _result} = Gmail.sync(state, nil)

      [list_call | _] = ConnectorFixtureStub.calls_matching(stub, "/messages?maxResults=100")
      refute list_call.url =~ "category"
    end
  end

  describe "incremental sync" do
    test "fetches messages added since the cursor and advances it" do
      {:ok, state} = Gmail.init(@config)

      assert {:ok, %{signals: signals, cursor: cursor}} = Gmail.sync(state, "900001")

      assert cursor == "900002"

      # The poll also added a promotions message and a spam message; neither
      # is kept. Header names are matched without regard to case.
      assert [signal] = signals
      assert signal.title == "Delivery address"
      assert signal.content =~ "Can you confirm the delivery address please? We ship on Thursday."
      assert "jane@example.com" in signal.entities
    end
  end

  describe "errors" do
    test "an expired refresh token is :auth_expired" do
      stub = ConnectorFixtureStub.install(:gmail, status: 401)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Gmail.init(@config)
      assert {:error, :auth_expired} = Gmail.sync(state, nil)
    end

    test "a rate-limited list is :rate_limited" do
      stub = ConnectorFixtureStub.install(:gmail, status: 429)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Gmail.init(@config)
      assert {:error, :rate_limited} = Gmail.sync(state, "900001")
    end

    test "an unreachable endpoint is a transport error, not a crash" do
      stub = ConnectorFixtureStub.install(:gmail, unreachable: true)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Gmail.init(@config)
      assert {:error, _reason} = Gmail.sync(state, nil)
    end

    test "a revoked refresh token is :auth_expired, not a token error" do
      stub =
        ConnectorFixtureStub.install(:gmail,
          status: 400,
          body: %{"error" => "invalid_grant", "error_description" => "Token has been revoked."}
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Gmail.init(@config)
      assert {:error, :auth_expired} = Gmail.sync(state, nil)
    end
  end

  describe "a message that cannot be fetched" do
    test "a failure fails the sync, so the cursor cannot skip past it" do
      stub = ConnectorFixtureStub.install(:gmail, fail: {"/messages/msg-0004", 500})
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Gmail.init(@config)

      # The recorded history poll succeeded and named the message; the fetch is
      # what failed. Reporting it as an empty batch would advance the cursor past
      # a message no later run could find again.
      assert {:error, :transient} = Gmail.sync(state, "900001")
    end

    test "a message deleted between the list and the fetch is skipped, not fatal" do
      stub = ConnectorFixtureStub.install(:gmail, fail: {"/messages/msg-0004", 404})
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Gmail.init(@config)
      assert {:ok, %{signals: [], cursor: "900002"}} = Gmail.sync(state, "900001")
    end
  end

  describe "transform/1" do
    test "a long body is cut to a bounded size" do
      long = String.duplicate("word ", 10_000)

      raw = %{
        "id" => "msg-long",
        "payload" => %{
          "mimeType" => "text/plain",
          "headers" => [%{"name" => "Subject", "value" => "Long"}],
          "body" => %{"data" => Base.url_encode64(long, padding: false)}
        }
      }

      assert {:ok, signal} = Gmail.transform(raw)
      assert String.length(signal.content) <= 20_100
      assert signal.content =~ "Subject: Long"
    end

    test "returns a Signal for a minimal payload" do
      raw = %{"id" => "msg-9", "snippet" => "Hello", "payload" => %{"headers" => []}}

      assert {:ok, %Signal{} = signal} = Gmail.transform(raw)
      assert signal.id =~ "gmail:"
      assert signal.genre == "email"
    end
  end
end
