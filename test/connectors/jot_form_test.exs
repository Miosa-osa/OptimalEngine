defmodule OptimalEngine.Connectors.JotFormTest do
  @moduledoc """
  JotForm adapter end to end against a recorded JotForm API recording
  (`test/fixtures/connectors/jot_form/routes.json`): a two-page form list and
  per-form submission lists, one of them two pages and one empty. The API key
  travels as a query parameter and the body's `responseCode` carries the real
  outcome.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.JotForm
  alias OptimalEngine.Signal
  alias OptimalEngine.Test.ConnectorFixtureStub

  @credentials %{"api_key" => "example-api-key"}

  # Every form the key can see.
  @config %{"form_ids" => [], "credentials" => @credentials}

  # Two named forms.
  @named %{"form_ids" => ["form_0001", "form_0002"], "credentials" => @credentials}

  setup do
    stub = ConnectorFixtureStub.install(:jot_form)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "init/1" do
    test "rejects a config without the form ids" do
      assert {:error, {:missing_config, [:form_ids]}} =
               JotForm.init(%{"credentials" => @credentials})
    end

    test "rejects a config without the api key" do
      assert {:error, {:missing_credentials, [:api_key]}} = JotForm.init(%{"form_ids" => []})
    end

    test "accepts an empty form list, which means every form" do
      assert {:ok, _state} = JotForm.init(@config)
    end
  end

  describe "full sync" do
    test "lists the forms, walks every page of each and transforms each submission", %{stub: stub} do
      {:ok, state} = JotForm.init(@config)
      assert {:ok, %{signals: signals, cursor: cursor}} = JotForm.sync(state, nil)

      # form_0001 has three submissions over two pages, form_0002 has one and
      # form_0003 has none. A finished walk parks the cursor on nil.
      assert length(signals) == 4
      assert cursor == nil

      assert signals |> Enum.map(& &1.path) |> Enum.sort() == [
               "optimal://connectors/jot_form/sub_0000001",
               "optimal://connectors/jot_form/sub_0000002",
               "optimal://connectors/jot_form/sub_0000003",
               "optimal://connectors/jot_form/sub_0000004"
             ]

      urls = stub |> ConnectorFixtureStub.calls() |> Enum.map(& &1.url)

      assert urls == [
               "https://api.jotform.com/user/forms?apiKey=example-api-key&limit=100",
               "https://api.jotform.com/user/forms?apiKey=example-api-key&limit=100&offset=2",
               "https://api.jotform.com/form/form_0001/submissions?apiKey=example-api-key&limit=100&offset=0",
               "https://api.jotform.com/form/form_0001/submissions?apiKey=example-api-key&limit=100&offset=2",
               "https://api.jotform.com/form/form_0002/submissions?apiKey=example-api-key&limit=100&offset=0",
               "https://api.jotform.com/form/form_0003/submissions?apiKey=example-api-key&limit=100&offset=0"
             ]
    end

    test "reads only the configured forms and does not list the rest", %{stub: stub} do
      {:ok, state} = JotForm.init(@named)
      assert {:ok, %{signals: signals, cursor: nil}} = JotForm.sync(state, nil)

      assert length(signals) == 4
      assert ConnectorFixtureStub.calls_matching(stub, "/user/forms") == []
      assert ConnectorFixtureStub.calls_matching(stub, "form_0003") == []
    end

    test "passes the api key as the apiKey parameter and sends no bearer header", %{stub: stub} do
      {:ok, state} = JotForm.init(@named)
      {:ok, _result} = JotForm.sync(state, nil)

      calls = ConnectorFixtureStub.calls(stub)
      assert calls != []
      assert Enum.all?(calls, &String.contains?(&1.url, "apiKey=example-api-key"))

      refute Enum.any?(calls, fn call ->
               Enum.any?(call.headers, fn {k, _v} -> String.downcase(k) == "authorization" end)
             end)
    end

    test "accepts the form ids as a comma-separated string", %{stub: stub} do
      {:ok, state} =
        JotForm.init(%{"form_ids" => "form_0002, form_0003", "credentials" => @credentials})

      assert {:ok, %{signals: [signal], cursor: nil}} = JotForm.sync(state, nil)

      assert signal.path == "optimal://connectors/jot_form/sub_0000004"
      assert ConnectorFixtureStub.calls_matching(stub, "form_0001") == []
    end
  end

  describe "cursor" do
    test "advances by form and offset when the page bound is reached" do
      {:ok, state} = JotForm.init(Map.put(@named, "max_pages", 1))

      assert {:ok, %{signals: first, cursor: "form_0001:2"}} = JotForm.sync(state, nil)
      assert length(first) == 2

      # Resuming at offset 2 finishes form_0001 and parks on the next form.
      assert {:ok, %{signals: [third], cursor: "form_0002:0"}} = JotForm.sync(state, "form_0001:2")
      assert third.path == "optimal://connectors/jot_form/sub_0000003"

      assert {:ok, %{signals: [fourth], cursor: nil}} = JotForm.sync(state, "form_0002:0")
      assert fourth.path == "optimal://connectors/jot_form/sub_0000004"
    end

    test "resumes by the same cursor when forms come from the account listing" do
      {:ok, state} = JotForm.init(Map.put(@config, "max_pages", 1))

      assert {:ok, %{signals: [signal], cursor: "form_0003:0"}} = JotForm.sync(state, "form_0002:0")
      assert signal.path == "optimal://connectors/jot_form/sub_0000004"

      assert {:ok, %{signals: [], cursor: nil}} = JotForm.sync(state, "form_0003:0")
    end

    test "a cursor naming a form that is gone, or an unreadable one, starts over", %{stub: stub} do
      {:ok, state} = JotForm.init(@named)

      assert {:ok, %{signals: gone}} = JotForm.sync(state, "form_9999:40")
      assert length(gone) == 4

      assert {:ok, %{signals: unreadable}} = JotForm.sync(state, "not-a-cursor")
      assert length(unreadable) == 4

      assert Enum.all?(ConnectorFixtureStub.calls(stub), fn call ->
               not String.contains?(call.url, "offset=40")
             end)
    end

    test "stops at the page bound when the API keeps returning full pages" do
      stub =
        ConnectorFixtureStub.install(:jot_form,
          status: 200,
          body: %{
            "responseCode" => 200,
            "content" => [%{"id" => "sub_9999", "answers" => %{}}],
            "resultSet" => %{"offset" => 0, "limit" => 1, "count" => 1}
          }
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} =
        JotForm.init(%{
          "form_ids" => ["form_0001"],
          "max_pages" => 3,
          "credentials" => @credentials
        })

      assert {:ok, %{signals: signals, cursor: "form_0001:3"}} = JotForm.sync(state, nil)
      assert length(signals) == 3
      assert length(ConnectorFixtureStub.calls(stub)) == 3
    end

    test "stops at the first page shorter than the limit when the response omits the result set" do
      stub =
        ConnectorFixtureStub.install(:jot_form,
          status: 200,
          body: %{"responseCode" => 200, "content" => [%{"id" => "sub_9999", "answers" => %{}}]}
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(%{"form_ids" => ["form_0001"], "credentials" => @credentials})

      assert {:ok, %{signals: [_one], cursor: nil}} = JotForm.sync(state, nil)
      assert length(ConnectorFixtureStub.calls(stub)) == 1
    end
  end

  describe "errors" do
    test "an unauthorized key is :auth_expired" do
      stub = ConnectorFixtureStub.install(:jot_form, status: 401)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(@config)
      assert {:error, :auth_expired} = JotForm.sync(state, nil)
    end

    test "a forbidden key is :auth_expired" do
      stub = ConnectorFixtureStub.install(:jot_form, status: 403)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(@named)
      assert {:error, :auth_expired} = JotForm.sync(state, nil)
    end

    test "a rate-limited list is :rate_limited" do
      stub = ConnectorFixtureStub.install(:jot_form, status: 429)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(@named)
      assert {:error, :rate_limited} = JotForm.sync(state, nil)
    end

    test "a server error is :transient" do
      stub = ConnectorFixtureStub.install(:jot_form, status: 503)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(@named)
      assert {:error, :transient} = JotForm.sync(state, nil)
    end

    test "an HTTP 200 whose responseCode is 429 is :rate_limited" do
      stub =
        ConnectorFixtureStub.install(:jot_form,
          status: 200,
          body: %{"responseCode" => 429, "message" => "Too many requests", "content" => []}
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(@named)
      assert {:error, :rate_limited} = JotForm.sync(state, nil)

      # The same answer while listing forms.
      {:ok, state} = JotForm.init(@config)
      assert {:error, :rate_limited} = JotForm.sync(state, nil)
    end

    test "an HTTP 200 whose responseCode is 401 or 403 is :auth_expired" do
      for code <- [401, 403] do
        stub =
          ConnectorFixtureStub.install(:jot_form,
            status: 200,
            body: %{"responseCode" => code, "message" => "Unauthorized"}
          )

        on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

        {:ok, state} = JotForm.init(@named)
        assert {:error, :auth_expired} = JotForm.sync(state, nil)
      end
    end

    test "an HTTP 200 whose responseCode is 5xx is :transient, and any other code is an error" do
      stub =
        ConnectorFixtureStub.install(:jot_form,
          status: 200,
          body: %{"responseCode" => 503, "content" => []}
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(@named)
      assert {:error, :transient} = JotForm.sync(state, nil)

      stub =
        ConnectorFixtureStub.install(:jot_form,
          status: 200,
          body: %{"responseCode" => 404, "content" => []}
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      assert {:error, {:http, 404}} = JotForm.sync(state, nil)
    end

    test "an unexpected 200 body is an error, not a crash" do
      stub = ConnectorFixtureStub.install(:jot_form, status: 200, body: %{"message" => "hello"})
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(@named)
      assert {:error, {:unexpected_response, 200}} = JotForm.sync(state, nil)
    end

    test "an unreachable endpoint is a transport error, not a crash" do
      stub = ConnectorFixtureStub.install(:jot_form, unreachable: true)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(@config)
      assert {:error, _reason} = JotForm.sync(state, nil)
    end
  end

  describe "transform/1" do
    setup do
      {:ok, state} = JotForm.init(@named)
      {:ok, %{signals: signals}} = JotForm.sync(state, nil)
      {:ok, signals: Map.new(signals, &{&1.path, &1})}
    end

    test "maps a submission: title, answers as Question: answer lines, genre, entities, path",
         %{signals: signals} do
      one = signals["optimal://connectors/jot_form/sub_0000001"]

      assert one.title == "Form form_0001 submission sub_0000001"
      assert one.genre == "form_submission"

      # A structured answer renders through its prettyFormat; the button and
      # the blank answers are left out.
      assert one.content ==
               "Full Name: Jane Example\nEmail: jane@example.com\nHow can we help?: Please send a quote for Example Co."

      assert one.entities == ["jane@example.com"]

      # The timestamp has no zone and is read as UTC. With no updated_at the
      # submission was last modified when it was created.
      assert DateTime.to_unix(one.created_at) == 1_793_005_200
      assert DateTime.to_unix(one.modified_at) == 1_793_005_200
    end

    test "orders answers by question order, joins list answers and strips HTML from labels",
         %{signals: signals} do
      two = signals["optimal://connectors/jot_form/sub_0000002"]

      assert two.content ==
               "Full Name: Sam Sample\nEmail: sam@example.com\nInterests: Pricing, Support\nReferral source: Newsletter"

      assert two.entities == ["sam@example.com"]

      # updated_at wins over created_at for modified_at.
      assert DateTime.to_unix(two.created_at) == 1_793_007_000
      assert DateTime.to_unix(two.modified_at) == 1_793_096_100
    end

    test "leaves a blank answer out of the content", %{signals: signals} do
      three = signals["optimal://connectors/jot_form/sub_0000003"]
      assert three.content == "Full Name: Alex Sample\nEmail: alex@example.com"
      assert three.entities == ["alex@example.com"]
    end

    test "takes the form id from the form being read when the submission omits it" do
      stub =
        ConnectorFixtureStub.install(:jot_form,
          status: 200,
          body: %{"responseCode" => 200, "content" => [%{"id" => "sub_9", "answers" => %{}}]}
        )

      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = JotForm.init(%{"form_ids" => ["form_0007"], "credentials" => @credentials})
      assert {:ok, %{signals: [signal]}} = JotForm.sync(state, nil)
      assert signal.title == "Form form_0007 submission sub_9"
    end

    test "renders numbers and nested answers, and only a value that is an email goes in entities" do
      raw = %{
        "id" => "sub_9",
        "form_id" => "form_9",
        "created_at" => "2026-10-26T09:00:00+01:00",
        "answers" => %{
          "1" => %{"name" => "guests", "text" => "Guests", "answer" => 3},
          "2" => %{
            "name" => "address",
            "text" => "Address",
            "answer" => %{"city" => "Exampleton", "state" => "EX"}
          },
          "3" => %{
            "name" => "note",
            "text" => "Note",
            "answer" => "Reply to ops@example.com please"
          },
          "4" => %{
            "name" => "contacts",
            "text" => "Contacts",
            "answer" => ["a@example.com", "b@example.com", "a@example.com"]
          },
          "5" => %{"name" => "cc", "answer" => "  cc@example.com  "}
        }
      }

      assert {:ok, %Signal{} = signal} = JotForm.transform(raw)

      assert signal.content ==
               "Guests: 3\nAddress: Exampleton, EX\nNote: Reply to ops@example.com please\n" <>
                 "Contacts: a@example.com, b@example.com, a@example.com\ncc: cc@example.com"

      assert signal.entities == ["a@example.com", "b@example.com", "cc@example.com"]

      # An explicit UTC offset is honoured.
      assert DateTime.to_unix(signal.created_at) == 1_793_001_600
    end

    test "returns a Signal for a minimal payload" do
      assert {:ok, %Signal{} = signal} = JotForm.transform(%{"id" => "sub_1"})
      assert signal.id =~ "jot_form:"
      assert signal.genre == "form_submission"
      assert signal.title == "Form submission sub_1"
      assert signal.content == ""
      assert signal.entities == []
    end
  end
end
