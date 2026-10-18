defmodule OptimalEngine.Connectors.GmailTest do
  @moduledoc """
  Gmail adapter end to end against a recorded Gmail API recording
  (`test/fixtures/connectors/gmail/routes.json`): token refresh, a two-page
  message list, message fetch with metadata headers, the profile historyId, and
  an incremental history poll.
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

      # The initial pull is bounded by the lookback window, not by everything.
      [list_call | _] = ConnectorFixtureStub.calls_matching(stub, "/messages?maxResults=100")
      assert String.contains?(list_call.url, "q=after%3A")
    end

    test "maps sender, subject, snippet and the epoch-millisecond date", %{stub: _stub} do
      {:ok, state} = Gmail.init(@config)
      {:ok, %{signals: signals}} = Gmail.sync(state, nil)

      [order_form] = Enum.filter(signals, &(&1.title == "Order form for Example Co"))

      assert order_form.genre == "email"
      assert order_form.content == "Please send the signed order form by Friday."
      assert "jane@example.com" in order_form.entities
      assert order_form.path == "optimal://connectors/gmail/msg-0001"

      # internalDate is epoch milliseconds in a string, not ISO-8601.
      assert DateTime.to_unix(order_form.modified_at) == 1_793_016_000
    end
  end

  describe "incremental sync" do
    test "fetches messages added since the cursor and advances it" do
      {:ok, state} = Gmail.init(@config)

      assert {:ok, %{signals: signals, cursor: cursor}} = Gmail.sync(state, "900001")

      assert cursor == "900002"
      assert [signal] = signals
      assert signal.title == "Delivery address"
      assert signal.content == "Can you confirm the delivery address please?"
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
  end

  describe "transform/1" do
    test "returns a Signal for a minimal payload" do
      raw = %{"id" => "msg-9", "snippet" => "Hello", "payload" => %{"headers" => []}}

      assert {:ok, %Signal{} = signal} = Gmail.transform(raw)
      assert signal.id =~ "gmail:"
      assert signal.genre == "email"
    end
  end
end
