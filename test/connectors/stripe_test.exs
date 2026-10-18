defmodule OptimalEngine.Connectors.StripeTest do
  @moduledoc """
  Stripe adapter end to end against a recorded Stripe list API recording
  (`test/fixtures/connectors/stripe/routes.json`): a two-page customer list paged
  with `starting_after`, a one-page invoice list (one outstanding, one paid), a
  one-page charge list, and a resume id Stripe no longer knows.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Adapters.Stripe
  alias OptimalEngine.Operating.Loops
  alias OptimalEngine.Signal
  alias OptimalEngine.Test.ConnectorFixtureStub

  @api_key "rk_example_restricted_key"

  @config %{
    "resources" => ["customers", "invoices", "charges"],
    "credentials" => %{"api_key" => @api_key}
  }

  setup do
    stub = ConnectorFixtureStub.install(:stripe)
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)
    {:ok, stub: stub}
  end

  describe "init/1" do
    test "describes itself" do
      assert Stripe.kind() == :stripe
      assert Stripe.display_name() == "Stripe"
      assert Stripe.auth_scheme() == :token
      assert Stripe.required_config_keys() == [:resources]
    end

    test "rejects a missing api key" do
      assert {:error, {:missing_credentials, [:api_key]}} = Stripe.init(%{"resources" => []})
    end

    test "rejects a missing resources key" do
      config = %{"credentials" => %{"api_key" => @api_key}}
      assert {:error, {:missing_config, [:resources]}} = Stripe.init(config)
    end

    test "rejects a resource the connector does not pull" do
      config = Map.put(@config, "resources", ["customers", "payouts"])

      assert {:error, {:invalid_config, {:unknown_resources, ["payouts"]}}} = Stripe.init(config)

      assert {:error, {:invalid_config, :resources}} =
               Stripe.init(Map.put(@config, "resources", "x"))
    end

    test "an empty resource list pulls all three", %{stub: stub} do
      {:ok, state} = Stripe.init(Map.put(@config, "resources", []))
      assert {:ok, %{signals: signals}} = Stripe.sync(state, nil)

      assert length(signals) == 7
      assert length(ConnectorFixtureStub.calls_matching(stub, "/v1/invoices")) == 1
      assert length(ConnectorFixtureStub.calls_matching(stub, "/v1/charges")) == 1
    end
  end

  describe "full sync" do
    test "walks every page of a family and finishes with no cursor", %{stub: stub} do
      {:ok, state} = Stripe.init(@config)
      assert {:ok, %{signals: signals, cursor: nil}} = Stripe.sync(state, nil)

      genres = signals |> Enum.map(& &1.genre) |> Enum.frequencies()
      assert genres == %{"customer" => 3, "invoice" => 2, "payment" => 2}

      # The second customer page was fetched, after the last id of the first.
      [first_page, second_page] = ConnectorFixtureStub.calls_matching(stub, "/v1/customers")
      assert String.ends_with?(first_page.url, "/v1/customers?limit=100")
      assert String.ends_with?(second_page.url, "/v1/customers?limit=100&starting_after=cus_0002")
    end

    test "pulls customers, then invoices, then charges, with the key as a bearer token", %{
      stub: stub
    } do
      {:ok, state} = Stripe.init(@config)
      {:ok, _result} = Stripe.sync(state, nil)

      calls = ConnectorFixtureStub.calls(stub)

      assert Enum.map(calls, & &1.method) |> Enum.uniq() == ["GET"]
      assert Enum.all?(calls, &String.starts_with?(&1.url, "https://api.stripe.com/v1/"))

      families =
        calls
        |> Enum.map(fn call ->
          call.url |> String.split("/") |> Enum.at(4) |> String.split("?") |> hd()
        end)
        |> Enum.dedup()

      assert families == ["customers", "invoices", "charges"]

      assert Enum.all?(calls, fn call ->
               {"authorization", "Bearer " <> @api_key} in call.headers
             end)
    end

    test "pulls only the configured resources", %{stub: stub} do
      {:ok, state} = Stripe.init(Map.put(@config, "resources", ["charges", "invoices"]))
      assert {:ok, %{signals: signals}} = Stripe.sync(state, nil)

      assert length(signals) == 4
      assert ConnectorFixtureStub.calls_matching(stub, "/v1/customers") == []
    end
  end

  describe "cursor" do
    test "resumes the named family after the named id and starts the later ones fresh", %{
      stub: stub
    } do
      {:ok, state} = Stripe.init(@config)

      assert {:ok, %{signals: signals, cursor: nil}} = Stripe.sync(state, "customers:cus_0002")

      # Page 1 of customers is not read again; page 2 and the later families are.
      assert [call] = ConnectorFixtureStub.calls_matching(stub, "/v1/customers")
      assert String.ends_with?(call.url, "starting_after=cus_0002")
      assert length(signals) == 5
    end

    test "an empty id starts that family from the top and skips the ones before it", %{
      stub: stub
    } do
      {:ok, state} = Stripe.init(@config)

      assert {:ok, %{signals: signals}} = Stripe.sync(state, "charges:")

      assert Enum.map(signals, & &1.genre) == ["payment", "payment"]
      assert ConnectorFixtureStub.calls_matching(stub, "/v1/customers") == []
      assert ConnectorFixtureStub.calls_matching(stub, "/v1/invoices") == []
    end

    test "a cursor for a family that is not pulled, or that does not parse, starts over" do
      {:ok, state} = Stripe.init(Map.put(@config, "resources", ["customers"]))

      for cursor <- ["invoices:in_0001", "payouts:po_1", "nonsense", ""] do
        # Each page of the recording answers once per install, so reinstall per pass.
        stub = ConnectorFixtureStub.install(:stripe)
        on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

        assert {:ok, %{signals: signals, cursor: nil}} = Stripe.sync(state, cursor)
        assert length(signals) == 3
      end
    end

    test "a resume id Stripe no longer knows restarts that family instead of failing" do
      {:ok, state} = Stripe.init(Map.put(@config, "resources", ["customers"]))

      assert {:ok, %{signals: signals, cursor: nil}} = Stripe.sync(state, "customers:cus_gone")
      assert length(signals) == 3
    end

    test "parks the cursor on the last id read when the request budget runs out" do
      requests = install_pages(fn _resource, _page -> true end)

      {:ok, state} = Stripe.init(Map.put(@config, "resources", ["customers", "invoices"]))
      assert {:ok, %{signals: signals, cursor: cursor}} = Stripe.sync(state, nil)

      assert length(signals) == 20
      assert cursor == "customers:cus_0020"

      urls = urls(requests)
      assert length(urls) == 20
      assert String.ends_with?(hd(urls), "/v1/customers?limit=100")
      assert String.ends_with?(List.last(urls), "/v1/customers?limit=100&starting_after=cus_0019")

      # The next run asks for the page after that id, not for the top of the list.
      assert {:ok, %{cursor: "customers:cus_0040"}} = Stripe.sync(state, cursor)
      assert String.ends_with?(urls(requests) |> Enum.at(20), "starting_after=cus_0020")
    end

    test "parks the cursor on the next family when the budget ends at a family boundary" do
      install_pages(fn resource, page -> resource == "customers" and page < 20 end)

      {:ok, state} = Stripe.init(Map.put(@config, "resources", ["customers", "invoices"]))
      assert {:ok, %{signals: signals, cursor: "invoices:"}} = Stripe.sync(state, nil)

      assert length(signals) == 20
      assert Enum.all?(signals, &(&1.genre == "customer"))
    end

    test "stops walking a family on an empty page even if Stripe says there is more" do
      mock = fn _url, _opts ->
        body = %{"object" => "list", "has_more" => true, "data" => []}

        {:ok,
         {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
          Jason.encode!(body)}}
      end

      Application.put_env(:optimal_engine, :http_mock, mock)
      on_exit(fn -> Application.delete_env(:optimal_engine, :http_mock) end)

      {:ok, state} = Stripe.init(@config)
      assert {:ok, %{signals: [], cursor: nil}} = Stripe.sync(state, nil)
    end
  end

  describe "transform/1" do
    setup do
      {:ok, state} = Stripe.init(@config)
      {:ok, %{signals: signals}} = Stripe.sync(state, nil)
      {:ok, signals: signals}
    end

    test "maps a customer", %{signals: signals} do
      [customer] = Enum.filter(signals, &(&1.title == "Customer Jane Example"))

      assert %Signal{genre: "customer", mode: :linguistic} = customer
      assert customer.entities == ["jane@example.com"]
      assert customer.path == "optimal://connectors/stripe/cus_0001"
      assert customer.id =~ "stripe:"
      assert DateTime.to_unix(customer.modified_at) == 1_793_016_000
      assert customer.created_at == customer.modified_at

      assert customer.content ==
               "Customer Jane Example (jane@example.com), created 2026-10-26.\n" <>
                 "Description: Example Co primary contact"
    end

    test "a customer without a name is titled by its email", %{signals: signals} do
      [customer] = Enum.filter(signals, &(&1.path =~ "cus_0003"))

      assert customer.title == "Customer accounts@example.com"
      assert customer.entities == ["accounts@example.com"]
      assert customer.content == "Customer accounts@example.com, created 2026-10-26."
    end

    test "maps an outstanding invoice", %{signals: signals} do
      invoice = by_path(signals, "in_0001")

      assert invoice.genre == "invoice"
      assert invoice.title == "Invoice INV-0007"
      assert invoice.entities == ["jane@example.com"]
      assert invoice.path == "optimal://connectors/stripe/in_0001"
      assert DateTime.to_unix(invoice.modified_at) == 1_793_016_000

      [amounts, blank | sentences] = String.split(invoice.content, "\n")
      assert blank == ""

      assert sentences == [
               "Invoice INV-0007 is outstanding, 1200.00 USD due 2026-11-01.",
               "Billed to Jane Example (jane@example.com).",
               "Hosted invoice: https://invoice.example.com/i/in_0001"
             ]

      assert parse_amounts(amounts) == %{
               "amount_minor" => "120000",
               "amount_paid_minor" => "0",
               "currency" => "usd",
               "status" => "open"
             }
    end

    test "maps a paid invoice without any due wording", %{signals: signals} do
      invoice = by_path(signals, "in_0002")

      assert invoice.entities == ["sam@example.com"]

      assert parse_amounts(invoice.content) == %{
               "amount_minor" => "50000",
               "amount_paid_minor" => "50000",
               "currency" => "usd",
               "status" => "paid"
             }

      assert invoice.content =~ "Invoice INV-0006 was paid, 500.00 USD."
      refute invoice.content =~ ~r/due|outstanding|overdue|unpaid|owed/i
    end

    test "maps charges, and the receipt email is the entity", %{signals: signals} do
      paid = by_path(signals, "ch_0001")
      failed = by_path(signals, "ch_0002")

      assert paid.genre == "payment"
      assert paid.title == "Payment ch_0001"
      assert paid.entities == ["sam@example.com"]
      assert DateTime.to_unix(paid.modified_at) == 1_793_019_600

      assert paid.content ==
               "amount_minor=50000 amount_paid_minor=50000 currency=usd status=succeeded\n\n" <>
                 "Payment ch_0001 of 500.00 USD succeeded.\n" <>
                 "Receipt email: sam@example.com\n" <>
                 "Description: Example Co subscription"

      assert parse_amounts(failed.content) == %{
               "amount_minor" => "2500",
               "amount_paid_minor" => "0",
               "currency" => "usd",
               "status" => "failed"
             }

      assert failed.content =~ "Payment ch_0002 of 25.00 USD failed."
    end

    test "money Signals carry a parseable amount line, then a blank line, then prose", %{
      signals: signals
    } do
      for signal <- Enum.filter(signals, &(&1.genre in ["invoice", "payment"])) do
        assert [amounts, "", sentence | _rest] = String.split(signal.content, "\n")

        assert %{"amount_minor" => _, "amount_paid_minor" => _, "currency" => _} =
                 parse_amounts(amounts)

        assert sentence =~ ~r/^(Invoice|Payment) /
      end
    end

    test "formats zero-decimal and three-decimal currencies by their own exponent" do
      yen = %{
        "id" => "ch_yen",
        "object" => "charge",
        "amount" => 5000,
        "currency" => "JPY",
        "status" => "succeeded"
      }

      dinar = %{
        "id" => "ch_bhd",
        "object" => "charge",
        "amount" => 12_340,
        "currency" => "bhd",
        "status" => "pending"
      }

      {:ok, yen_signal} = Stripe.transform(yen)
      {:ok, dinar_signal} = Stripe.transform(dinar)

      assert yen_signal.content =~ "Payment ch_yen of 5000 JPY succeeded."
      assert parse_amounts(yen_signal.content)["currency"] == "jpy"
      assert dinar_signal.content =~ "Payment ch_bhd of 12.340 BHD is pending."
    end

    test "tells the object kind from the id when the payload omits it" do
      assert {:ok, %Signal{genre: "customer"}} = Stripe.transform(%{"id" => "cus_9"})
      assert {:ok, %Signal{genre: "invoice"}} = Stripe.transform(%{"id" => "in_9"})
      assert {:ok, %Signal{genre: "payment"}} = Stripe.transform(%{"id" => "ch_9"})
    end

    test "refuses what it cannot map instead of raising" do
      assert {:error, {:unsupported_object, "pi_9"}} = Stripe.transform(%{"id" => "pi_9"})
      assert {:error, :invalid_payload} = Stripe.transform(%{"object" => "customer"})
      assert {:error, :invalid_payload} = Stripe.transform(%{"id" => ""})
    end
  end

  describe "open loops" do
    test "an outstanding invoice reads as money owed, with its due date resolved" do
      invoice = %{
        "id" => "in_9",
        "object" => "invoice",
        "number" => "INV-0007",
        "amount_due" => 120_000,
        "amount_paid" => 0,
        "currency" => "usd",
        "status" => "open",
        "created" => 1_793_016_000,
        "due_date" => 1_793_491_200
      }

      {:ok, signal} = Stripe.transform(invoice)

      # The same text the loop extractor reads: title, then content.
      assert [loop] = Loops.detect("#{signal.title}\n#{signal.content}", ~D[2026-10-26])

      assert loop["kind"] in ["payment_owed", "payment_due"]
      assert loop["due_at"] == "2026-11-01"
      assert loop["title"] == "Invoice INV-0007 is outstanding, 1200.00 USD due 2026-11-01."
    end

    test "a part-paid invoice is owed the remainder; one with no due date has no due_at" do
      part_paid = %{
        "id" => "in_8",
        "object" => "invoice",
        "number" => "INV-0008",
        "amount_due" => 120_000,
        "amount_paid" => 20_000,
        "currency" => "usd",
        "status" => "open"
      }

      {:ok, signal} = Stripe.transform(part_paid)
      assert [loop] = Loops.detect(signal.content, ~D[2026-10-26])

      assert loop["kind"] == "payment_owed"
      assert loop["due_at"] == nil
      assert loop["title"] == "Invoice INV-0008 is outstanding, 1000.00 USD."
      assert parse_amounts(signal.content)["amount_paid_minor"] == "20000"
    end

    test "invoices that owe nothing, and charges, open no money loop" do
      {:ok, state} = Stripe.init(@config)
      {:ok, %{signals: signals}} = Stripe.sync(state, nil)

      quiet = Enum.reject(signals, &(&1.path =~ "in_0001"))
      assert length(quiet) == 6

      for signal <- quiet do
        assert Loops.detect("#{signal.title}\n#{signal.content}", ~D[2026-10-26]) == []
      end

      for status <- ["paid", "draft", "void"] do
        {:ok, signal} =
          Stripe.transform(%{
            "id" => "in_#{status}",
            "number" => "INV-1",
            "amount_due" => 100,
            "amount_paid" => 0,
            "currency" => "usd",
            "status" => status,
            "due_date" => 1_793_491_200
          })

        assert Loops.detect(signal.content, ~D[2026-10-26]) == []
      end
    end

    test "an uncollectible invoice still reads as money owed" do
      {:ok, signal} =
        Stripe.transform(%{
          "id" => "in_7",
          "number" => "INV-0009",
          "amount_due" => 4_000,
          "amount_paid" => 0,
          "currency" => "usd",
          "status" => "uncollectible"
        })

      assert [%{"kind" => "payment_owed"}] = Loops.detect(signal.content, ~D[2026-10-26])
    end
  end

  describe "errors" do
    test "a rejected key is :auth_expired, for both 401 and 403" do
      for status <- [401, 403] do
        stub = ConnectorFixtureStub.install(:stripe, status: status)
        on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

        {:ok, state} = Stripe.init(@config)
        assert {:error, :auth_expired} = Stripe.sync(state, nil)
      end
    end

    test "a rate-limited list is :rate_limited" do
      stub = ConnectorFixtureStub.install(:stripe, status: 429)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Stripe.init(@config)
      assert {:error, :rate_limited} = Stripe.sync(state, nil)
    end

    test "a server error is :transient" do
      stub = ConnectorFixtureStub.install(:stripe, status: 503)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Stripe.init(@config)
      assert {:error, :transient} = Stripe.sync(state, nil)
    end

    test "an unreachable endpoint is a transport error, not a crash" do
      stub = ConnectorFixtureStub.install(:stripe, unreachable: true)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Stripe.init(@config)
      assert {:error, _reason} = Stripe.sync(state, nil)
    end

    test "an answer that is not a list is an error, not a crash" do
      stub = ConnectorFixtureStub.install(:stripe, status: 200, body: %{"unexpected" => true})
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Stripe.init(@config)
      assert {:error, {:unexpected_body, "customers"}} = Stripe.sync(state, nil)
    end

    test "any other status is reported with its code" do
      stub = ConnectorFixtureStub.install(:stripe, status: 404)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, state} = Stripe.init(@config)
      assert {:error, {:http, 404}} = Stripe.sync(state, nil)
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp by_path(signals, id), do: Enum.find(signals, &String.ends_with?(&1.path, "/" <> id))

  # The labelled first line of a money Signal as a map of strings.
  defp parse_amounts(content) do
    [line | _rest] = String.split(content, "\n")

    ~r/(\w+)=(\S+)/
    |> Regex.scan(line)
    |> Map.new(fn [_whole, key, value] -> {key, value} end)
  end

  # Replaces the recording with a synthetic listing: every request answers one
  # record, and `more?.(resource, page)` says whether Stripe reports `has_more`
  # after that page (pages count per resource, from 1, across the test). Returns
  # an Agent holding the requested URLs, newest first; read it with `urls/1`.
  defp install_pages(more?) do
    {:ok, requests} = Agent.start_link(fn -> [] end)

    prefixes = %{"customers" => "cus_", "invoices" => "in_", "charges" => "ch_"}

    mock = fn url, _opts ->
      resource = url |> String.split("/v1/") |> List.last() |> String.split("?") |> hd()

      page =
        Agent.get_and_update(
          requests,
          &{Enum.count(&1, fn u -> u =~ "/v1/#{resource}?" end) + 1, [url | &1]}
        )

      id = prefixes[resource] <> String.pad_leading(Integer.to_string(page), 4, "0")

      body = %{"object" => "list", "has_more" => more?.(resource, page), "data" => [%{"id" => id}]}

      {:ok,
       {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
        Jason.encode!(body)}}
    end

    Application.put_env(:optimal_engine, :http_mock, mock)
    on_exit(fn -> Application.delete_env(:optimal_engine, :http_mock) end)
    requests
  end

  defp urls(requests), do: requests |> Agent.get(& &1) |> Enum.reverse()
end
