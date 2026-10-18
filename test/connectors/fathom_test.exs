defmodule OptimalEngine.Connectors.FathomTest do
  @moduledoc """
  Fathom adapter end to end against a recorded meetings recording
  (`test/fixtures/connectors/fathom/routes.json`): a two-page meeting list whose
  first page carries a cursor and whose last carries `null`, with a transcript,
  summary and action items on the first meeting.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.Fathom
  alias OptimalEngine.Operating.Loops
  alias OptimalEngine.Signal
  alias OptimalEngine.Test.ConnectorFixtureStub

  @config %{
    "credentials" => %{"api_key" => "example-api-key"}
  }

  setup do
    stub = ConnectorFixtureStub.install(:fathom)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "init/1" do
    test "declares the :fathom kind with token auth and no required config" do
      assert Fathom.kind() == :fathom
      assert Fathom.display_name() == "Fathom"
      assert Fathom.auth_scheme() == :token
      assert Fathom.required_config_keys() == []
    end

    test "rejects a config with no API key" do
      assert {:error, {:missing_credentials, [:api_key]}} = Fathom.init(%{})
      assert {:error, {:missing_credentials, [:api_key]}} = Fathom.init(%{"credentials" => %{}})
    end

    test "accepts the key nested under credentials or at the top level" do
      assert {:ok, _state} = Fathom.init(@config)
      assert {:ok, _state} = Fathom.init(%{"api_key" => "example-api-key"})
    end
  end

  describe "full sync" do
    test "walks every page and transforms every meeting", %{stub: stub} do
      {:ok, state} = Fathom.init(@config)
      assert {:ok, %{signals: signals, cursor: cursor}} = Fathom.sync(state, nil)

      assert length(signals) == 3

      assert signals |> Enum.map(& &1.title) |> Enum.sort() ==
               ["Discovery call", "Quick call with Example Co", "Weekly sync"]

      # Both pages were read, and no more.
      assert length(ConnectorFixtureStub.calls_matching(stub, "/meetings?")) == 2
      assert length(ConnectorFixtureStub.calls_matching(stub, "cursor=example-next-cursor")) == 1

      # The finished walk parks a watermark, not Fathom's page cursor.
      assert "since:" <> since = cursor
      assert {:ok, _datetime, _offset} = DateTime.from_iso8601(since)
    end

    test "sends the API key and asks for the summary, transcript and action items", %{stub: stub} do
      {:ok, state} = Fathom.init(@config)
      {:ok, _result} = Fathom.sync(state, nil)

      for call <- ConnectorFixtureStub.calls(stub) do
        assert Enum.any?(call.headers, fn {name, value} ->
                 String.downcase(name) == "x-api-key" and value == "example-api-key"
               end)

        assert call.method == "GET"
        assert String.starts_with?(call.url, "https://api.fathom.ai/external/v1/meetings?limit=100")
        assert query(call.url)["include_transcript"] == "true"
        assert query(call.url)["include_summary"] == "true"
        assert query(call.url)["include_action_items"] == "true"
      end
    end

    test "bounds the first page by a 90 day lookback", %{stub: stub} do
      {:ok, state} = Fathom.init(@config)
      {:ok, _result} = Fathom.sync(state, nil)

      [first | _] = ConnectorFixtureStub.calls(stub)
      assert_in_lookback(first.url, 90)
    end

    test "honours :lookback_days from the config as a number", %{stub: stub} do
      {:ok, state} = Fathom.init(Map.put(@config, "lookback_days", 7))
      {:ok, _result} = Fathom.sync(state, nil)

      [first | _] = ConnectorFixtureStub.calls(stub)
      assert_in_lookback(first.url, 7)
    end

    test "honours :lookback_days from the config as a numeric string", %{stub: stub} do
      {:ok, state} = Fathom.init(Map.put(@config, "lookback_days", "14"))
      {:ok, _result} = Fathom.sync(state, nil)

      [first | _] = ConnectorFixtureStub.calls(stub)
      assert_in_lookback(first.url, 14)
    end
  end

  describe "transform/1" do
    test "maps title, genre, invitee emails, start time and path" do
      meeting = sync_signals() |> Enum.find(&(&1.path == "optimal://connectors/fathom/100000001"))

      assert %Signal{} = meeting
      assert meeting.title == "Discovery call"
      assert meeting.genre == "meeting"
      assert meeting.mode == :linguistic
      assert meeting.format == :markdown
      assert meeting.entities == ["jane@example.com", "sam@sample.example"]
      assert meeting.id =~ "fathom:"
      assert DateTime.to_iso8601(meeting.modified_at) == "2026-10-14T15:00:00Z"
    end

    test "dates the Signal from the recording, so a relative due date resolves against the meeting" do
      meeting = sync_signals() |> Enum.find(&(&1.path == "optimal://connectors/fathom/100000001"))

      assert meeting.created_at == meeting.modified_at
      assert DateTime.to_date(meeting.created_at) == ~D[2026-10-14]
    end

    test "falls back to the call title when there is no meeting title" do
      meeting = sync_signals() |> Enum.find(&(&1.path == "optimal://connectors/fathom/100000003"))

      assert meeting.title == "Quick call with Example Co"
      assert meeting.entities == []
    end

    test "gives the same id to the same recording" do
      raw = %{"recording_id" => 100_000_009, "title" => "Example call"}

      assert {:ok, first} = Fathom.transform(raw)
      assert {:ok, second} = Fathom.transform(raw)
      assert first.id == second.id
      assert first.path == "optimal://connectors/fathom/100000009"
    end

    test "returns a Signal for a minimal payload" do
      assert {:ok, %Signal{} = signal} = Fathom.transform(%{"recording_id" => 1})

      assert signal.genre == "meeting"
      assert signal.title == "Fathom meeting"
      assert signal.content == ""
      assert signal.entities == []
    end

    test "refuses a payload with no recording id, which would collide with every other one" do
      assert {:error, :missing_recording_id} = Fathom.transform(%{"title" => "Example call"})
      assert {:error, :invalid_payload} = Fathom.transform("not a map")
    end

    test "names a speaker the recording did not identify" do
      raw = %{
        "recording_id" => 2,
        "transcript" => [
          %{"speaker" => %{}, "text" => "Hello there."},
          %{"text" => "Anyone else?"},
          %{"speaker" => %{"display_name" => "Sam Sample"}, "text" => "  "}
        ]
      }

      assert {:ok, signal} = Fathom.transform(raw)
      assert signal.content == "## Transcript\n\nUnknown: Hello there.\nUnknown: Anyone else?"
    end

    test "drops a duplicated or blank invitee email" do
      raw = %{
        "recording_id" => 3,
        "calendar_invitees" => [
          %{"email" => "jane@example.com"},
          %{"email" => "jane@example.com"},
          %{"email" => ""},
          %{"name" => "No Email"}
        ]
      }

      assert {:ok, signal} = Fathom.transform(raw)
      assert signal.entities == ["jane@example.com"]
    end
  end

  describe "content" do
    test "carries the summary, then the transcript, then the action items" do
      meeting = sync_signals() |> Enum.find(&(&1.path == "optimal://connectors/fathom/100000001"))

      assert meeting.content ==
               """
               ## Summary

               Discovery call with Example Co.

               ## Transcript

               Jane Example: We need the proposal by Friday.
               Sam Sample: I will send it tomorrow.

               ## Action items

               - [ ] Send the proposal
               """
               |> String.trim_trailing()
    end

    test "marks a completed action item" do
      meeting = sync_signals() |> Enum.find(&(&1.path == "optimal://connectors/fathom/100000002"))

      assert meeting.content =~ "## Summary\n\nWeekly sync on the rollout plan."
      assert meeting.content =~ "Sam Sample: The rollout is on track."
      assert meeting.content =~ "- [x] Share the rollout plan"
    end

    test "is empty for a meeting with no summary, transcript or action items" do
      meeting = sync_signals() |> Enum.find(&(&1.path == "optimal://connectors/fathom/100000003"))

      assert meeting.content == ""
    end

    test "leaves a commitment spoken in the transcript for the loop detector" do
      meeting = sync_signals() |> Enum.find(&(&1.path == "optimal://connectors/fathom/100000001"))

      assert meeting.content =~ "We need the proposal by Friday."
      assert meeting.content =~ "I will send it tomorrow."

      loops = Loops.detect(meeting.content, DateTime.to_date(meeting.created_at))
      commitments = Enum.filter(loops, &(&1["kind"] == "commitment"))

      assert [commitment] = commitments
      assert commitment["title"] == "Sam Sample: I will send it tomorrow."
      # "tomorrow" is the day after the meeting, not the day after the sync.
      assert commitment["due_at"] == "2026-10-15"
      assert commitment["confidence"] >= 0.7
    end
  end

  describe "cursor" do
    test "reads the next page on Fathom's cursor and parks a watermark after the last", %{
      stub: stub
    } do
      {:ok, state} = Fathom.init(@config)
      assert {:ok, %{cursor: cursor}} = Fathom.sync(state, nil)

      [first, second] = ConnectorFixtureStub.calls_matching(stub, "/meetings?")

      refute Map.has_key?(query(first.url), "cursor")
      assert query(second.url)["cursor"] == "example-next-cursor"

      # The date filter rides along on the next page.
      assert query(second.url)["created_after"] == query(first.url)["created_after"]

      # The watermark is never Fathom's cursor: the last page has `next_cursor: null`.
      assert String.starts_with?(cursor, "since:")
      refute cursor =~ "example-next-cursor"
    end

    test "an incremental sync lists meetings created after the watermark", %{stub: stub} do
      {:ok, state} = Fathom.init(@config)
      watermark = "2026-10-14T12:00:00Z"

      assert {:ok, %{signals: signals, cursor: cursor}} = Fathom.sync(state, "since:" <> watermark)

      assert length(signals) == 3
      [first | _] = ConnectorFixtureStub.calls(stub)
      assert query(first.url)["created_after"] == watermark

      # The watermark moves forward to this run's start.
      assert "since:" <> next = cursor
      assert {:ok, next_at, _} = DateTime.from_iso8601(next)
      assert {:ok, previous_at, _} = DateTime.from_iso8601(watermark)
      assert DateTime.compare(next_at, previous_at) == :gt
    end

    for cursor <- ["garbage", "since:not-a-date", "page:no-separators", "page:a|b|"] do
      test "treats the unrecognised cursor #{inspect(cursor)} as a full sync", %{stub: stub} do
        {:ok, state} = Fathom.init(@config)

        assert {:ok, %{signals: signals}} = Fathom.sync(state, unquote(cursor))
        assert length(signals) == 3

        [first | _] = ConnectorFixtureStub.calls(stub)
        assert_in_lookback(first.url, 90)
        refute Map.has_key?(query(first.url), "cursor")
      end
    end

    test "stops at the page bound and parks a cursor that resumes where it stopped" do
      test = self()

      Application.put_env(:optimal_engine, :http_mock, fn url, _opts ->
        send(test, {:request, url})
        http_response(200, %{"limit" => 100, "next_cursor" => "endless-cursor", "items" => []})
      end)

      {:ok, state} = Fathom.init(@config)
      assert {:ok, %{signals: [], cursor: cursor}} = Fathom.sync(state, nil)

      assert length(requests()) == 20
      assert "page:" <> rest = cursor
      assert [since, created_after, "endless-cursor"] = String.split(rest, "|", parts: 3)

      # The resumed walk picks up on the stored cursor, keeps the same date
      # filter, and on finishing parks the watermark of the walk that began it.
      Application.put_env(:optimal_engine, :http_mock, fn url, _opts ->
        send(test, {:request, url})

        http_response(200, %{
          "limit" => 100,
          "next_cursor" => nil,
          "items" => [%{"recording_id" => 7, "meeting_title" => "Example call"}]
        })
      end)

      assert {:ok, %{signals: [signal], cursor: resumed_cursor}} = Fathom.sync(state, cursor)

      assert signal.title == "Example call"
      assert resumed_cursor == "since:" <> since
      assert [resumed_url] = requests()
      assert query(resumed_url)["cursor"] == "endless-cursor"
      assert query(resumed_url)["created_after"] == created_after
    end
  end

  describe "errors" do
    test "a rejected API key is :auth_expired" do
      for status <- [401, 403] do
        install_override(status: status)
        {:ok, state} = Fathom.init(@config)
        assert {:error, :auth_expired} = Fathom.sync(state, nil)
      end
    end

    test "a rate-limited list is :rate_limited" do
      install_override(status: 429)

      {:ok, state} = Fathom.init(@config)
      assert {:error, :rate_limited} = Fathom.sync(state, nil)
    end

    test "a Retry-After header turns into the wait" do
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        http_response(429, %{}, [{~c"retry-after", ~c"7"}])
      end)

      {:ok, state} = Fathom.init(@config)
      assert {:error, {:rate_limited, 7_000}} = Fathom.sync(state, nil)
    end

    test "a server error is :transient" do
      for status <- [500, 502, 503] do
        install_override(status: status)
        {:ok, state} = Fathom.init(@config)
        assert {:error, :transient} = Fathom.sync(state, nil)
      end
    end

    test "any other status names itself" do
      install_override(status: 404)

      {:ok, state} = Fathom.init(@config)
      assert {:error, {:http, 404}} = Fathom.sync(state, nil)
    end

    test "a 200 that is not a meeting list is a bad response, not a crash" do
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        http_response(200, "not json", [])
      end)

      {:ok, state} = Fathom.init(@config)
      assert {:error, :bad_response} = Fathom.sync(state, nil)
    end

    test "a failure on a later page fails the whole sync, so the cursor does not move" do
      Application.put_env(:optimal_engine, :http_mock, fn url, _opts ->
        if String.contains?(url, "cursor=") do
          http_response(500, %{})
        else
          http_response(200, %{
            "next_cursor" => "example-next-cursor",
            "items" => [%{"recording_id" => 1}]
          })
        end
      end)

      {:ok, state} = Fathom.init(@config)
      assert {:error, :transient} = Fathom.sync(state, nil)
    end

    test "an unreachable endpoint is a transport error, not a crash" do
      install_override(unreachable: true)

      {:ok, state} = Fathom.init(@config)
      assert {:error, _reason} = Fathom.sync(state, nil)
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp sync_signals do
    {:ok, state} = Fathom.init(@config)
    {:ok, %{signals: signals}} = Fathom.sync(state, nil)
    signals
  end

  defp install_override(override) do
    stub = ConnectorFixtureStub.install(:fathom, override)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    stub
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  # The first page's `created_after` is `days` back from now, give or take the
  # seconds the test itself took.
  defp assert_in_lookback(url, days) do
    assert {:ok, created_after, _offset} = DateTime.from_iso8601(query(url)["created_after"])
    age = DateTime.diff(DateTime.utc_now(), created_after, :second)
    assert_in_delta age, days * 86_400, 60
  end

  defp requests(acc \\ []) do
    receive do
      {:request, url} -> requests([url | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The raw `:httpc` reply the HTTP seam's mock hook is expected to return.
  defp http_response(status, body, headers \\ []) do
    payload = if is_binary(body), do: body, else: Jason.encode!(body)
    headers = [{~c"content-type", ~c"application/json"} | headers]

    {:ok, {{~c"HTTP/1.1", status, ~c"OK"}, headers, payload}}
  end
end
