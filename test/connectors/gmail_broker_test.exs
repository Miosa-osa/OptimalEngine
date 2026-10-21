defmodule OptimalEngine.Connectors.GmailBrokerTest do
  @moduledoc """
  Gmail on a brokered token, end to end through the Runner: the broker issues a
  short-lived access token, the adapter pulls the recorded mailbox with it, an
  expiry mid-sync costs one re-fetch, a second refusal fails the run clearly,
  and neither the token nor the broker reference is written anywhere.

  The broker and the Gmail API are stubs (`OptimalEngine.Test.BrokerStub` over
  the recorded `gmail` fixture); no real Google endpoint is called.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.Connectors.{CredentialSource, Rows, Runner}
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.{BrokerStub, ConnectorFixtureStub}

  @reference "conn_example.signed-reference-0001"

  defmodule LeakyKey do
    @moduledoc "An adapter that reads an API key and crashes with its state as the argument."

    use OptimalEngine.Connectors.Adapters.Base,
      kind: :leaky_key,
      display_name: "Leaky",
      auth_scheme: :token,
      required_keys: [],
      credential_keys: [:api_key],
      token_key: :api_key

    @impl true
    def sync(state, _cursor), do: String.upcase(state)
  end

  defmodule LeakyOAuth do
    @moduledoc "An adapter that calls through AccessToken and crashes with its state as the argument."

    use OptimalEngine.Connectors.Adapters.Base,
      kind: :leaky_oauth,
      display_name: "Leaky OAuth",
      auth_scheme: :oauth2,
      required_keys: [],
      credential_keys: [:client_id],
      access_token: true

    @impl true
    def sync(state, _cursor), do: String.upcase(state)
  end

  setup do
    original_key = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    on_exit(fn ->
      if original_key,
        do: System.put_env("CONNECTOR_KEY", original_key),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    suffix = System.unique_integer([:positive])
    tenant = "gmail-broker-#{suffix}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Gmail broker #{suffix}"})
    workspace = insert_workspace("#{tenant}:mail", tenant)

    {:ok, tenant: tenant, workspace: workspace, id: "gmail-broker-#{suffix}"}
  end

  defp register(ctx, config \\ %{}) do
    config =
      Map.merge(
        %{
          "user_email" => "jane@example.com",
          "labels" => ["INBOX"],
          "credential_source" => "broker",
          "broker_url" => BrokerStub.broker_url(),
          "broker_reference" => @reference,
          "broker_scopes" => ["gmail.readonly"]
        },
        config
      )

    {:ok, view} =
      Rows.register(
        %{
          id: ctx.id,
          kind: "gmail",
          tenant_id: ctx.tenant,
          workspace_id: ctx.workspace,
          config: config
        },
        actor: "operator:test"
      )

    view
  end

  defp run(ctx), do: Runner.run(ctx.id, governed: false)

  defp install(opts) do
    stub = BrokerStub.install(:gmail, opts)
    on_exit(fn -> BrokerStub.uninstall(stub) end)
    stub
  end

  defp token_endpoint_calls(stub),
    do:
      stub
      |> BrokerStub.api_calls()
      |> Enum.filter(&String.contains?(&1.url, "oauth2.googleapis.com"))

  describe "a brokered token" do
    test "is fetched once and carried by every Gmail call", ctx do
      register(ctx)
      stub = install(issue: [{"example-broker-token-1", 3_600}])

      assert {:ok, result} = run(ctx)
      assert result.status == :success
      assert result.signals == 3
      assert result.cursor_after == "900001"

      # One broker call, naming the decrypted reference and this connector, with
      # no header of the Engine's own.
      assert [call] = BrokerStub.broker_calls(stub)
      assert call.body["reference"] == @reference
      assert call.body["connector"] == %{"id" => ctx.id, "kind" => "gmail"}
      assert call.body["tenant_id"] == ctx.tenant
      assert call.body["workspace_id"] == ctx.workspace
      assert call.body["scopes"] == ["gmail.readonly"]
      assert call.headers == []
      assert call.timeout == 5_000

      # Every Gmail call carried the brokered token, and Google's token endpoint
      # was never asked: the Engine holds no client secret or refresh token.
      assert [_ | _] = BrokerStub.api_calls(stub)
      assert Enum.uniq(BrokerStub.bearers(stub)) == ["example-broker-token-1"]
      assert token_endpoint_calls(stub) == []
    end

    test "a connector as the MIOSA platform registers it asks the broker with its own workspace",
         ctx do
      miosa_url = "https://api.miosa.ai/api/v1/connect/broker/credentials"
      reference = "conn_0001.c2lnbmVkLXJlZmVyZW5jZQ"
      own_workspace = insert_workspace("#{ctx.tenant}:team", ctx.tenant)
      id = "miosa:conn_#{ctx.id}:gmail"

      {:ok, view} =
        Rows.register(
          %{
            id: id,
            kind: "gmail",
            tenant_id: ctx.tenant,
            workspace_id: own_workspace,
            config: %{
              "user_email" => "jane@example.com",
              "labels" => ["INBOX"],
              "credential_source" => "broker",
              "broker_url" => miosa_url,
              "broker_reference" => reference,
              "broker_scopes" => ["gmail.readonly"],
              "interval_ms" => 900_000
            }
          },
          actor: "operator:test"
        )

      assert view.config["broker_reference"] == "[redacted]"

      stub = install(broker_url: miosa_url, issue: [{"example-broker-token-1", 3_600}])

      assert {:ok, %{status: :success, signals: 3}} = Runner.run(id, governed: false)

      # The workspace is the connector's own: the broker signs it into the
      # reference, and answers any other with a 401.
      assert [call] = BrokerStub.broker_calls(stub)
      assert call.url == miosa_url
      assert call.headers == []

      assert call.body == %{
               "reference" => reference,
               "workspace_id" => own_workspace,
               "tenant_id" => ctx.tenant,
               "connector" => %{"id" => id, "kind" => "gmail"},
               "scopes" => ["gmail.readonly"]
             }

      assert call.body["workspace_id"] == view.workspace_id
    end

    test "an expiry mid-sync costs one re-fetch, then the sync succeeds", ctx do
      register(ctx)

      # The first token serves two calls, then Gmail answers it with a 401.
      stub =
        install(
          issue: [{"example-broker-token-1", 3_600}, {"example-broker-token-2", 3_600}],
          expire: %{"example-broker-token-1" => 2}
        )

      assert {:ok, result} = run(ctx)
      assert result.status == :success
      assert result.signals == 3

      assert length(BrokerStub.broker_calls(stub)) == 2

      assert [
               {"example-broker-token-1", 200},
               {"example-broker-token-1", 200},
               {"example-broker-token-1", 401},
               {"example-broker-token-2", 200} | rest
             ] = Enum.map(BrokerStub.api_calls(stub), &{&1.bearer, &1.status})

      assert Enum.all?(rest, &(&1 == {"example-broker-token-2", 200}))
    end

    test "a token that expires within 60 seconds is replaced before it is used", ctx do
      register(ctx)

      stub =
        install(issue: [{"example-broker-token-short", 20}, {"example-broker-token-long", 3_600}])

      assert {:ok, %{status: :success, signals: 3}} = run(ctx)
      assert length(BrokerStub.broker_calls(stub)) == 2
      assert Enum.uniq(BrokerStub.bearers(stub)) == ["example-broker-token-long"]
    end

    test "a second refusal fails the run with :broker_token_rejected, and never loops", ctx do
      register(ctx)

      stub =
        install(
          issue: [{"example-broker-token-1", 3_600}, {"example-broker-token-2", 3_600}],
          reject: ["example-broker-token-1", "example-broker-token-2"]
        )

      assert {:ok, result} = run(ctx)
      assert result.status == :error
      assert result.reason == :broker_token_rejected
      assert result.cursor_after == nil

      # One fetch, one re-fetch, two refused calls, and nothing after.
      assert length(BrokerStub.broker_calls(stub)) == 2
      assert BrokerStub.bearers(stub) == ["example-broker-token-1", "example-broker-token-2"]

      assert [{"error", ":broker_token_rejected"}] = run_rows(ctx.id)
      assert {:ok, %{enabled: true}} = Rows.get(ctx.tenant, ctx.id)
    end
  end

  describe "a broker that is down" do
    test "fails the run before Gmail is called", ctx do
      register(ctx)
      stub = install(issue: [:unreachable])

      assert {:ok, %{status: :error, reason: :broker_unreachable}} = run(ctx)
      assert BrokerStub.api_calls(stub) == []
      assert [{"error", ":broker_unreachable"}] = run_rows(ctx.id)
    end

    test "a broker that does not accept the reference fails the run as unauthorized", ctx do
      register(ctx)
      stub = install(issue: [{:status, 401}])

      assert {:ok, %{status: :error, reason: :broker_unauthorized}} = run(ctx)
      assert BrokerStub.api_calls(stub) == []
      assert {:ok, %{enabled: true}} = Rows.get(ctx.tenant, ctx.id)
    end

    test "fails the run when the re-fetch cannot be answered", ctx do
      register(ctx)

      stub =
        install(
          issue: [{"example-broker-token-1", 3_600}, {:status, 503}],
          expire: %{"example-broker-token-1" => 1}
        )

      assert {:ok, %{status: :error, reason: :broker_unreachable}} = run(ctx)
      assert length(BrokerStub.broker_calls(stub)) == 2
      assert length(BrokerStub.api_calls(stub)) == 2
    end
  end

  describe "secrecy" do
    test "neither the token nor the reference reaches a stored row, a view or a log", ctx do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :debug], fn ->
          register(ctx)

          renewed =
            install(
              issue: [{"example-broker-token-1", 3_600}, {"example-broker-token-2", 3_600}],
              expire: %{"example-broker-token-1" => 2}
            )

          {:ok, %{status: :success}} = run(ctx)
          BrokerStub.uninstall(renewed)

          # A failing run leaves its own records too.
          install(
            issue: [{"example-broker-token-3", 3_600}, {"example-broker-token-4", 3_600}],
            reject: ["example-broker-token-3", "example-broker-token-4"]
          )

          Store.raw_query("UPDATE connectors SET cursor = NULL WHERE id = ?1", [ctx.id])
          {:ok, %{status: :error, reason: :broker_token_rejected}} = run(ctx)
        end)

      secrets = [
        @reference,
        "example-broker-token-1",
        "example-broker-token-2",
        "example-broker-token-3",
        "example-broker-token-4"
      ]

      stored = every_stored_row()
      {:ok, view} = Rows.get(ctx.tenant, ctx.id)
      evidence = ctx.tenant |> Evidence.list() |> Jason.encode!()

      for secret <- secrets do
        refute stored =~ secret, "#{secret} is in a stored row"
        refute log =~ secret, "#{secret} is in the log"
        refute Jason.encode!(view) =~ secret, "#{secret} is in the connector view"
        refute evidence =~ secret, "#{secret} is in the evidence chain"
      end

      # The reference is stored sealed and shown only as redacted.
      {:ok, [[config]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [ctx.id])
      assert Jason.decode!(config)["broker_reference_ciphertext"]
      assert view.config["broker_reference"] == "[redacted]"
      refute Map.has_key?(view.config, "broker_reference_ciphertext")
    end
  end

  describe "the retry budget belongs to the run" do
    # The first token is refused at once, so the sync spends its one re-fetch on
    # the second token; the second token is throttled once, which the Runner
    # answers by running the sync again.
    defp throttle_first_call_of_token_2 do
      fn
        %{bearer: "example-broker-token-2", nth: 1} -> {429, %{}}
        _call -> nil
      end
    end

    test "a retry after a 429 keeps the renewed token and asks the broker for nothing", ctx do
      register(ctx)

      stub =
        install(
          issue: [{"example-broker-token-1", 3_600}, {"example-broker-token-2", 3_600}],
          reject: ["example-broker-token-1"],
          override: throttle_first_call_of_token_2()
        )

      assert {:ok, %{status: :success, signals: 3}} = run(ctx)

      assert length(BrokerStub.broker_calls(stub)) == 2
      bearers = BrokerStub.bearers(stub)
      assert hd(bearers) == "example-broker-token-1"
      assert Enum.all?(tl(bearers), &(&1 == "example-broker-token-2"))
      assert Enum.count(bearers, &(&1 == "example-broker-token-1")) == 1
    end

    test "a refusal after a retry fails the run, and the broker is not asked a third time", ctx do
      register(ctx)

      stub =
        install(
          issue: [{"example-broker-token-1", 3_600}, {"example-broker-token-2", 3_600}],
          reject: ["example-broker-token-1"],
          expire: %{"example-broker-token-2" => 1},
          override: throttle_first_call_of_token_2()
        )

      assert {:ok, %{status: :error, reason: :broker_token_rejected}} = run(ctx)
      assert length(BrokerStub.broker_calls(stub)) == 2
    end
  end

  describe "a connector's own workspace" do
    test "a move re-seals the reference, and the next run asks with the new workspace", ctx do
      register(ctx)
      before = sealed_reference(ctx.id)
      moved = insert_workspace("#{ctx.tenant}:moved", ctx.tenant)

      assert {:ok, %{workspace_id: ^moved} = view} =
               Rows.update(ctx.tenant, ctx.id, %{"workspace" => moved})

      assert view.config["broker_reference"] == "[redacted]"
      refute sealed_reference(ctx.id) == before

      stub = install(issue: [{"example-broker-token-1", 3_600}])
      assert {:ok, %{status: :success}} = run(ctx)

      assert [call] = BrokerStub.broker_calls(stub)
      assert call.body["workspace_id"] == moved
      assert call.body["reference"] == @reference
    end

    test "a move there and back leaves the reference readable", ctx do
      register(ctx)
      moved = insert_workspace("#{ctx.tenant}:moved-twice", ctx.tenant)
      {:ok, _view} = Rows.update(ctx.tenant, ctx.id, %{"workspace" => moved})
      {:ok, _view} = Rows.update(ctx.tenant, ctx.id, %{"workspace" => ctx.workspace})

      stub = install(issue: [{"example-broker-token-1", 3_600}])
      assert {:ok, %{status: :success}} = run(ctx)
      assert [%{body: %{"workspace_id" => workspace}}] = BrokerStub.broker_calls(stub)
      assert workspace == ctx.workspace
    end

    test "routing its signals elsewhere does not change the workspace the broker is asked with",
         ctx do
      review = insert_workspace("#{ctx.tenant}:review", ctx.tenant)

      register(ctx, %{"review_workspace_id" => review, "routing_channel" => "#clients"})
      stub = install(issue: [{"example-broker-token-1", 3_600}])

      assert {:ok, %{status: :success}} = run(ctx)

      assert [call] = BrokerStub.broker_calls(stub)
      assert call.body["workspace_id"] == ctx.workspace
      refute call.body["workspace_id"] == review
    end

    test "a sealed reference copied to another connector is not read", ctx do
      register(ctx)
      other_id = "#{ctx.id}-copy"
      sealed = sealed_reference(ctx.id)

      {:ok, ^other_id} =
        Runner.upsert_row(%{
          id: other_id,
          kind: :gmail,
          tenant_id: ctx.tenant,
          workspace_id: ctx.workspace,
          config: %{
            "user_email" => "jane@example.com",
            "credential_source" => "broker",
            "broker_url" => BrokerStub.broker_url(),
            "broker_reference_ciphertext" => sealed
          }
        })

      stub = install(issue: [{"example-broker-token-1", 3_600}])

      assert {:ok, %{status: :error, reason: :broker_reference_unreadable}} =
               Runner.run(other_id, governed: false)

      assert BrokerStub.broker_calls(stub) == []
    end
  end

  describe "secrecy when an adapter crashes" do
    @api_key "example-secret-api-key"
    @access_token "example-secret-access-token"

    defp crash_text(adapter, config) do
      scope = %{id: "c-1", kind: "x", tenant_id: "default", workspace_id: "default", adapter: adapter}

      with {:ok, hydrated} <- CredentialSource.hydrate(config, scope),
           {:ok, state} <- adapter.init(hydrated) do
        result =
          try do
            {:returned, adapter.sync(state, nil)}
          rescue
            error -> {:crashed, Exception.format(:error, error, __STACKTRACE__)}
          end

        case result do
          {:crashed, text} -> text
          {:returned, other} -> flunk("the adapter was meant to crash, it returned #{inspect(other)}")
        end
      end
    end

    defp broker_config do
      %{
        "credential_source" => "broker",
        "broker_url" => BrokerStub.broker_url(),
        "broker_reference" => @reference
      }
    end

    test "a broker's API key and access token are not in the failure that shows the adapter's state" do
      for {adapter, body} <- [
            {LeakyKey, %{"credentials" => %{"api_key" => @api_key}}},
            {LeakyKey, %{"credentials" => %{"access_token" => @access_token}}},
            {LeakyOAuth, %{"credentials" => %{"access_token" => @access_token}}}
          ] do
        stub = BrokerStub.install(nil, issue: [{:body, body}])
        text = crash_text(adapter, broker_config())
        BrokerStub.uninstall(stub)

        assert text =~ "no function clause matching", "the crash did not show the state"
        refute text =~ @api_key
        refute text =~ @access_token
        refute text =~ @reference
      end
    end

    test "a token given directly is not in it either" do
      assert {:ok, state} =
               LeakyOAuth.init(%{"credentials" => %{"access_token" => "example-direct-secret"}})

      text =
        try do
          LeakyOAuth.sync(state, nil)
        rescue
          error -> Exception.format(:error, error, __STACKTRACE__)
        end

      assert text =~ "no function clause matching"
      refute text =~ "example-direct-secret"
    end

    test "nothing of it reaches the log of a run that crashes", ctx do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      id = "#{ctx.id}-leaky"

      {:ok, ^id} =
        Runner.upsert_row(%{
          id: id,
          kind: :leaky_key,
          tenant_id: ctx.tenant,
          workspace_id: ctx.workspace,
          config: broker_config()
        })

      stub = BrokerStub.install(nil, issue: [{:body, %{"credentials" => %{"api_key" => @api_key}}}])

      log =
        capture_log([level: :debug], fn ->
          try do
            Runner.run(id, governed: false, adapter: LeakyKey)
          rescue
            error -> send(self(), {:raised, Exception.format(:error, error, __STACKTRACE__)})
          catch
            kind, reason -> send(self(), {:raised, Exception.format(kind, reason, __STACKTRACE__)})
          end
        end)

      BrokerStub.uninstall(stub)

      raised =
        receive do
          {:raised, text} -> text
        after
          0 -> ""
        end

      refute log <> raised =~ @api_key
      refute log <> raised =~ @reference
    end
  end

  describe "the refresh-token flow" do
    test "is unchanged: one token refresh, no broker, the refreshed token on every call", ctx do
      {:ok, _view} =
        Rows.register(%{
          id: ctx.id,
          kind: "gmail",
          tenant_id: ctx.tenant,
          workspace_id: ctx.workspace,
          config: %{"user_email" => "jane@example.com", "labels" => ["INBOX"]},
          credentials: %{
            "oauth_refresh_token" => "1//example-refresh-token",
            "client_id" => "example-client-id.apps.googleusercontent.com",
            "client_secret" => "example-client-secret"
          }
        })

      stub = install([])

      assert {:ok, %{status: :success, signals: 3}} = run(ctx)
      assert BrokerStub.broker_calls(stub) == []

      assert [refresh | calls] = BrokerStub.api_calls(stub)
      assert refresh.url =~ "oauth2.googleapis.com/token"
      assert refresh.bearer == nil
      assert Enum.uniq(Enum.map(calls, & &1.bearer)) == ["example-gmail-access-token"]

      [token_call] =
        ConnectorFixtureStub.calls_matching(stub.fixture, "oauth2.googleapis.com/token")

      assert token_call.body["grant_type"] == "refresh_token"
      assert token_call.body["refresh_token"] == "1//example-refresh-token"
      assert token_call.body["client_secret"] == "example-client-secret"
    end

    test "a refused refreshed token is :auth_expired, with no second refresh", ctx do
      {:ok, _view} =
        Rows.register(%{
          id: ctx.id,
          kind: "gmail",
          tenant_id: ctx.tenant,
          workspace_id: ctx.workspace,
          config: %{"user_email" => "jane@example.com"},
          credentials: %{
            "oauth_refresh_token" => "1//example-refresh-token",
            "client_id" => "example-client-id.apps.googleusercontent.com",
            "client_secret" => "example-client-secret"
          }
        })

      stub = install(reject: ["example-gmail-access-token"])

      assert {:ok, %{status: :error, reason: :auth_expired}} = run(ctx)
      assert length(token_endpoint_calls(stub)) == 1
      assert length(BrokerStub.api_calls(stub)) == 2
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp sealed_reference(connector_id) do
    {:ok, [[config]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [connector_id])
    Jason.decode!(config)["broker_reference_ciphertext"]
  end

  defp run_rows(connector_id) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT status, error_detail FROM connector_runs WHERE connector_id = ?1 ORDER BY id",
        [connector_id]
      )

    Enum.map(rows, fn [status, detail] -> {status, detail} end)
  end

  # Every row of every table in the store, as text.
  defp every_stored_row do
    {:ok, tables} =
      Store.raw_query("SELECT name FROM sqlite_master WHERE type = 'table'", [])

    tables
    |> Enum.map(fn [table] ->
      case Store.raw_query(~s(SELECT * FROM "#{table}"), []) do
        {:ok, rows} -> inspect(rows, limit: :infinity, printable_limit: :infinity)
        _unreadable -> ""
      end
    end)
    |> Enum.join("\n")
  end

  defp insert_workspace(id, tenant) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, ?2, ?3, ?4, 'active', '{}')
        """,
        [id, tenant, id |> String.split(":") |> List.last(), "WS #{id}"]
      )

    id
  end
end
