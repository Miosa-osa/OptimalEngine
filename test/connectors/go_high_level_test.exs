defmodule OptimalEngine.Connectors.GoHighLevelTest do
  @moduledoc """
  GoHighLevel adapter end to end against a recorded API recording
  (`test/fixtures/connectors/go_high_level/routes.json`): a two-page contact
  list, a conversation list with one conversation's messages and one whose
  messages are gone, a two-page opportunity list, and an empty second location.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.GoHighLevel
  alias OptimalEngine.Connectors.Transform
  alias OptimalEngine.Signal
  alias OptimalEngine.Test.ConnectorFixtureStub

  @token "pit-example-location-token"

  @config %{
    "location_ids" => ["loc_0001"],
    "currency" => "usd",
    "credentials" => %{"api_token" => @token}
  }

  setup do
    stub = ConnectorFixtureStub.install(:go_high_level)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "init/1" do
    test "rejects a missing location_ids" do
      config = Map.delete(@config, "location_ids")
      assert {:error, {:missing_config, [:location_ids]}} = GoHighLevel.init(config)
    end

    test "rejects location_ids that name no location" do
      for ids <- [[], [""], ["  "], nil] do
        assert {:error, {:missing_config, [:location_ids]}} =
                 GoHighLevel.init(Map.put(@config, "location_ids", ids))
      end
    end

    test "accepts a location token" do
      assert {:ok, _state} = GoHighLevel.init(@config)
    end

    test "accepts an agency token" do
      config = Map.put(@config, "credentials", %{"agency_token" => "pit-example-agency-token"})
      assert {:ok, _state} = GoHighLevel.init(config)
    end

    test "accepts credentials given at the top level and atom keys" do
      assert {:ok, _state} =
               GoHighLevel.init(%{location_ids: ["loc_0001"], api_token: "pit-example-token"})
    end

    test "rejects a missing or blank token" do
      for credentials <- [%{}, %{"api_token" => ""}, %{"agency_token" => "  "}] do
        assert {:error, {:missing_credentials, [:api_token]}} =
                 GoHighLevel.init(Map.put(@config, "credentials", credentials))
      end
    end

    test "declares the connector identity" do
      assert GoHighLevel.kind() == :go_high_level
      assert GoHighLevel.display_name() == "GoHighLevel"
      assert GoHighLevel.auth_scheme() == :token
      assert GoHighLevel.required_config_keys() == [:location_ids]
    end
  end

  describe "full sync" do
    test "walks every page, transforms each family, and finishes the pass with a nil cursor",
         %{stub: stub} do
      {:ok, state} = GoHighLevel.init(@config)
      assert {:ok, %{signals: signals, cursor: nil}} = GoHighLevel.sync(state, nil)

      assert length(signals) == 8
      assert signals |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 8

      by_genre = Enum.frequencies_by(signals, & &1.genre)
      assert by_genre == %{"contact" => 3, "message" => 2, "opportunity" => 3}

      # Page two of each paged family was fetched, not just the first.
      assert length(ConnectorFixtureStub.calls_matching(stub, "startAfter=contact_0002")) == 1
      assert length(ConnectorFixtureStub.calls_matching(stub, "startAfter=opp_0002")) == 1

      assert length(ConnectorFixtureStub.calls_matching(stub, "startAfterDate=1793019600000")) ==
               1

      # Each listed conversation had its messages fetched.
      assert length(ConnectorFixtureStub.calls_matching(stub, "/conversations/conv_0001/messages")) ==
               1

      assert length(ConnectorFixtureStub.calls_matching(stub, "/conversations/conv_0002/messages")) ==
               1
    end

    test "sends the bearer token and the API version on every call", %{stub: stub} do
      {:ok, state} = GoHighLevel.init(@config)
      {:ok, _result} = GoHighLevel.sync(state, nil)

      calls = ConnectorFixtureStub.calls(stub)
      assert calls != []

      for call <- calls do
        assert call.method == "GET"
        assert {"authorization", "Bearer " <> @token} in call.headers
        assert {"version", "2021-07-28"} in call.headers
      end
    end

    test "an api_token wins over an agency_token", %{stub: stub} do
      config =
        Map.put(@config, "credentials", %{
          "api_token" => @token,
          "agency_token" => "pit-example-agency-token"
        })

      {:ok, state} = GoHighLevel.init(config)
      {:ok, _result} = GoHighLevel.sync(state, "opportunities:loc_0001:opp_0002")

      assert [call] = ConnectorFixtureStub.calls(stub)
      assert {"authorization", "Bearer " <> @token} in call.headers
    end

    test "an agency token is sent as the bearer token", %{stub: stub} do
      config = Map.put(@config, "credentials", %{"agency_token" => "pit-example-agency-token"})

      {:ok, state} = GoHighLevel.init(config)
      {:ok, _result} = GoHighLevel.sync(state, "opportunities:loc_0001:opp_0002")

      assert [call] = ConnectorFixtureStub.calls(stub)
      assert {"authorization", "Bearer pit-example-agency-token"} in call.headers
    end

    test "reads every configured location", %{stub: stub} do
      {:ok, state} = GoHighLevel.init(Map.put(@config, "location_ids", ["loc_0001", "loc_0002"]))
      assert {:ok, %{signals: signals, cursor: nil}} = GoHighLevel.sync(state, nil)

      assert length(signals) == 8
      assert length(ConnectorFixtureStub.calls_matching(stub, "loc_0002")) == 3
    end
  end

  describe "contacts" do
    test "maps name, email, phone, tags, date and path" do
      jane = signal(sync_all(), "contact_0001")

      assert jane.genre == "contact"
      assert jane.title == "Jane Example"
      assert jane.path == "optimal://connectors/go_high_level/contact_0001"
      assert jane.id == Transform.signal_id(:go_high_level, "contact_0001")
      assert jane.entities == ["jane@example.com"]
      assert DateTime.to_unix(jane.modified_at) == 1_793_005_200

      assert jane.content ==
               "Jane Example\nEmail: jane@example.com\nPhone: +15550100\nTags: lead, example\nLocation: loc_0001"
    end

    test "lower-cases the email entity and leaves out what is missing" do
      signals = sync_all()
      pat = signal(signals, "contact_0003")
      sam = signal(signals, "contact_0002")

      assert sam.entities == ["sam@example.com"]

      assert pat.content ==
               "Pat Placeholder\nEmail: pat@example.com\nTags: newsletter\nLocation: loc_0001"
    end
  end

  describe "conversations" do
    test "joins SMS and email bodies oldest first, with the counterparty email" do
      conversation = signal(sync_all(), "conv_0001")

      assert conversation.genre == "message"
      assert conversation.title == "Conversation with Jane Example"
      assert conversation.path == "optimal://connectors/go_high_level/conv_0001"
      assert conversation.entities == ["jane@example.com"]

      # The HTML email is text, the messages are in date order, and the call
      # ("Missed call") is left out because SMS and email bodies exist.
      assert conversation.content ==
               "Hello, can we move the call to Friday.\nFriday works for us.\nGreat, see you then."

      # lastMessageDate is epoch milliseconds.
      assert DateTime.to_unix(conversation.modified_at) == 1_793_014_200
    end

    test "keeps the last message body when the messages are not served" do
      conversation = signal(sync_all(), "conv_0002")

      assert conversation.content == "Thanks, noted."
      assert conversation.entities == ["sam@example.com"]
      assert DateTime.to_unix(conversation.modified_at) == 1_793_019_600
    end

    test "falls back to every body when no message is SMS or email" do
      raw = %{
        "_family" => "conversation",
        "id" => "conv_x",
        "messages" => [
          %{"body" => "second", "dateAdded" => "2026-10-26T10:00:00Z", "type" => "TYPE_CALL"},
          %{"body" => "first", "dateAdded" => "2026-10-26T09:00:00Z", "type" => "TYPE_FACEBOOK"}
        ]
      }

      assert {:ok, signal} = GoHighLevel.transform(raw)
      assert signal.content == "first\nsecond"
    end

    test "takes the counterparty from the inbound sender and the outbound recipient" do
      raw = %{
        "_family" => "conversation",
        "id" => "conv_y",
        "messages" => [
          %{"body" => "hi", "direction" => "inbound", "from" => "Lee Example <lee@example.com>"},
          %{
            "body" => "hello",
            "direction" => "outbound",
            "to" => ["lee@example.com", "kim@example.com"]
          }
        ]
      }

      assert {:ok, signal} = GoHighLevel.transform(raw)
      assert signal.entities == ["lee@example.com", "kim@example.com"]
      assert signal.title == "Conversation with lee@example.com"
    end

    test "a conversation with nothing readable is still a Signal" do
      assert {:ok, signal} = GoHighLevel.transform(%{"_family" => "conversation", "id" => "conv_z"})
      assert signal.title == "Conversation conv_z"
      assert signal.content == ""
      assert signal.entities == []
    end
  end

  describe "opportunities" do
    test "leads the content with a parseable amount line" do
      onboarding = signal(sync_all(), "opp_0001")

      assert onboarding.genre == "opportunity"
      assert onboarding.title == "Example Co onboarding"
      assert onboarding.path == "optimal://connectors/go_high_level/opp_0001"
      assert onboarding.entities == ["jane@example.com"]
      assert DateTime.to_unix(onboarding.modified_at) == 1_793_016_000

      [line, sentence] = String.split(onboarding.content, "\n\n", parts: 2)
      assert line == "amount_minor=12000 currency=usd stage=proposal"

      assert sentence ==
               "Opportunity Example Co onboarding - status open, stage Proposal, value 120.00 usd, contact contact_0001."

      assert structured(onboarding) == %{
               "amount_minor" => "12000",
               "currency" => "usd",
               "stage" => "proposal"
             }
    end

    test "reads the amount in minor units, a record currency, and a multi-word stage" do
      pilot = signal(sync_all(), "opp_0003")

      assert structured(pilot) == %{
               "amount_minor" => "125050",
               "currency" => "eur",
               "stage" => "negotiation_sent"
             }

      assert pilot.content =~ "value 1250.50 eur"
    end

    test "leaves the line out when there is no amount" do
      renewal = signal(sync_all(), "opp_0002")

      assert renewal.content == "Opportunity Example Co renewal - status won, contact contact_0001."
      assert renewal.entities == []
      assert structured(renewal) == %{}
    end

    test "has no currency in the line when none is known" do
      raw = %{"_family" => "opportunity", "id" => "opp_x", "monetaryValue" => "99.99"}

      assert {:ok, signal} = GoHighLevel.transform(raw)
      assert structured(signal) == %{"amount_minor" => "9999"}
    end

    test "ignores a currency that is not a three-letter code" do
      raw = %{
        "_family" => "opportunity",
        "id" => "opp_x",
        "monetaryValue" => 5,
        "currency" => "us dollars"
      }

      assert {:ok, signal} = GoHighLevel.transform(raw)
      assert structured(signal) == %{"amount_minor" => "500"}
    end
  end

  describe "cursor" do
    test "moves forward family by family, one page per run" do
      {:ok, state} = GoHighLevel.init(Map.put(@config, "max_pages", 1))

      {runs, _cursor} =
        Enum.map_reduce(1..6, nil, fn _run, cursor ->
          assert {:ok, %{signals: signals, cursor: next}} = GoHighLevel.sync(state, cursor)
          {{length(signals), next}, next}
        end)

      assert runs == [
               {2, "contacts:loc_0001:contact_0002"},
               {1, "conversations:loc_0001:"},
               {2, "conversations:loc_0001:1793019600000"},
               {0, "opportunities:loc_0001:"},
               {2, "opportunities:loc_0001:opp_0002"},
               {1, nil}
             ]
    end

    test "resumes a family with startAfter instead of fetching it from the top", %{stub: stub} do
      {:ok, state} = GoHighLevel.init(@config)

      assert {:ok, %{signals: [signal], cursor: nil}} =
               GoHighLevel.sync(state, "opportunities:loc_0001:opp_0002")

      assert signal.title == "Sample Pilot"
      assert [call] = ConnectorFixtureStub.calls(stub)
      assert call.url =~ "/opportunities/search?location_id=loc_0001&limit=100&startAfter=opp_0002"
    end

    test "resumes at the named location without refetching the ones before it", %{stub: stub} do
      {:ok, state} = GoHighLevel.init(Map.put(@config, "location_ids", ["loc_0001", "loc_0002"]))

      assert {:ok, %{cursor: nil}} = GoHighLevel.sync(state, "contacts:loc_0002:")

      # The contacts of loc_0001 are behind the cursor; its conversations and
      # opportunities are still ahead.
      refute Enum.any?(
               ConnectorFixtureStub.calls_matching(stub, "/contacts/"),
               &(&1.url =~ "loc_0001")
             )

      assert length(
               ConnectorFixtureStub.calls_matching(
                 stub,
                 "/conversations/search?locationId=loc_0001"
               )
             ) == 2
    end

    test "starts a new pass from a cursor it cannot read" do
      {:ok, state} = GoHighLevel.init(@config)

      for cursor <- [
            "garbage",
            "contacts",
            "widgets:loc_0001:x",
            "contacts::x",
            "contacts:loc_9999:x"
          ] do
        stub = ConnectorFixtureStub.install(:go_high_level)

        assert {:ok, %{signals: signals, cursor: nil}} = GoHighLevel.sync(state, cursor)
        assert length(signals) == 8

        ConnectorFixtureStub.uninstall(stub)
      end
    end
  end

  describe "errors" do
    test "an expired or forbidden token is :auth_expired" do
      {:ok, state} = GoHighLevel.init(@config)

      for status <- [401, 403] do
        stub = ConnectorFixtureStub.install(:go_high_level, status: status)
        assert {:error, :auth_expired} = GoHighLevel.sync(state, nil)
        ConnectorFixtureStub.uninstall(stub)
      end
    end

    test "a rate-limited call is :rate_limited" do
      stub = ConnectorFixtureStub.install(:go_high_level, status: 429)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = GoHighLevel.init(@config)
      assert {:error, :rate_limited} = GoHighLevel.sync(state, nil)
    end

    test "a rate limit that names Retry-After carries the wait in milliseconds" do
      stub =
        ConnectorFixtureStub.install(:go_high_level, status: 429, headers: %{"retry-after" => "3"})

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = GoHighLevel.init(@config)
      assert {:error, {:rate_limited, 3000}} = GoHighLevel.sync(state, nil)
    end

    test "a server error is :transient" do
      stub = ConnectorFixtureStub.install(:go_high_level, status: 503)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = GoHighLevel.init(@config)
      assert {:error, :transient} = GoHighLevel.sync(state, nil)
    end

    test "any other status is reported with the status" do
      stub = ConnectorFixtureStub.install(:go_high_level, status: 422)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = GoHighLevel.init(@config)
      assert {:error, {:http, 422}} = GoHighLevel.sync(state, nil)
    end

    test "an unreachable endpoint is a transport error, not a crash" do
      stub = ConnectorFixtureStub.install(:go_high_level, unreachable: true)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = GoHighLevel.init(@config)
      assert {:error, _reason} = GoHighLevel.sync(state, nil)
    end

    test "a failed call returns the error and no Signals, so the cursor stays put" do
      stub = ConnectorFixtureStub.install(:go_high_level, status: 429)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = GoHighLevel.init(@config)
      assert {:error, :rate_limited} = GoHighLevel.sync(state, "contacts:loc_0001:contact_0002")
    end
  end

  describe "transform/1" do
    test "returns a Signal for a minimal contact" do
      assert {:ok, %Signal{} = signal} =
               GoHighLevel.transform(%{"_family" => "contact", "id" => "c1"})

      assert signal.id =~ "go_high_level:"
      assert signal.title == "c1"
      assert signal.genre == "contact"
      assert signal.entities == []
    end

    test "titles a contact by name, then email, then phone" do
      assert {:ok, signal} =
               GoHighLevel.transform(%{
                 "_family" => "contact",
                 "id" => "c1",
                 "email" => "a@example.com"
               })

      assert signal.title == "a@example.com"

      assert {:ok, signal} =
               GoHighLevel.transform(%{
                 "_family" => "contact",
                 "id" => "c1",
                 "phone" => "+15550102"
               })

      assert signal.title == "+15550102"
    end

    test "rejects a payload without a family or an id" do
      assert {:error, :unrecognised_payload} = GoHighLevel.transform(%{"id" => "c1"})
      assert {:error, :unrecognised_payload} = GoHighLevel.transform(%{"_family" => "contact"})

      assert {:error, :unrecognised_payload} =
               GoHighLevel.transform(%{"_family" => "widget", "id" => "w1"})
    end
  end

  describe "Transform.parse_epoch/2" do
    test "reads an ISO-8601 string as a date, not its leading digits as seconds" do
      assert Transform.parse_epoch("2026-10-26T09:00:00.000Z") ==
               ~U[2026-10-26 09:00:00.000Z]
    end

    test "still reads a string of digits as an epoch" do
      assert Transform.parse_epoch("1793005200000") == ~U[2026-10-26 09:00:00.000Z]
      assert Transform.parse_epoch("1793005200") == ~U[2026-10-26 09:00:00Z]
    end
  end

  # ---- helpers ----------------------------------------------------------------

  defp sync_all do
    {:ok, state} = GoHighLevel.init(@config)
    {:ok, %{signals: signals}} = GoHighLevel.sync(state, nil)
    signals
  end

  defp signal(signals, external_id) do
    path = "optimal://connectors/go_high_level/#{external_id}"
    Enum.find(signals, &(&1.path == path)) || flunk("no Signal at #{path}")
  end

  # The labelled first line of a Signal's content, parsed back into a map.
  defp structured(%Signal{content: content}) do
    [first | _] = String.split(content, "\n\n", parts: 2)

    ~r/\A(?:\w+=\S+)(?: \w+=\S+)*\z/
    |> Regex.match?(first)
    |> case do
      true ->
        ~r/(\w+)=(\S+)/ |> Regex.scan(first) |> Map.new(fn [_, key, value] -> {key, value} end)

      false ->
        %{}
    end
  end
end
