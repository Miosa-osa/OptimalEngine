defmodule OptimalEngine.Connectors.CredentialSourceTest do
  @moduledoc """
  Where a connector's credentials come from: the Engine's own encrypted store by
  default, or an outside broker at sync time.

  The broker is answered by a recorded fixture through the HTTP mock seam, so
  no real broker is called.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.{AccessToken, CredentialSource, Registry, Runner}
  alias OptimalEngine.Store
  alias OptimalEngine.Test.{BrokerStub, ConnectorFixtureStub}

  @stored_config %{
    "user_email" => "jane@example.com",
    "credentials" => %{"api_key" => "stored-example-key"}
  }

  @broker_config %{
    "user_email" => "jane@example.com",
    "credential_source" => "broker",
    "broker_url" => "https://connect.example.com/api/credentials",
    "broker_reference" => "conn_0000000000",
    "broker_scopes" => ["mail.read"]
  }

  # What a stored connector's config holds: the reference sealed for its id.
  @scope %{id: "c-1", kind: "gmail", tenant_id: "default", workspace_id: "hq"}

  defp sealed(config \\ @broker_config, id \\ "c-1") do
    {:ok, sealed} = CredentialSource.seal_reference(config, %{id: id})
    sealed
  end

  defmodule RecordingAdapter do
    @moduledoc "Records the config it was initialised with, so a test can see the credentials."

    @behaviour OptimalEngine.Connectors.Behaviour

    @impl true
    def kind, do: :recording

    @impl true
    def display_name, do: "Recording"

    @impl true
    def auth_scheme, do: :token

    @impl true
    def required_config_keys, do: []

    @impl true
    def init(config) do
      send(self(), {:initialised_with, config})
      {:ok, config}
    end

    @impl true
    def sync(_state, _cursor) do
      {:ok,
       [
         %OptimalEngine.Signal{id: "recording-1", title: "Recording", content: "A recorded Signal."}
       ], "cursor-1"}
    end
  end

  setup do
    key = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    original = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", key)

    on_exit(fn ->
      if original,
        do: System.put_env("CONNECTOR_KEY", original),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    {:ok, id: "cred-source-#{System.unique_integer([:positive])}"}
  end

  describe "source/1" do
    test "an absent or empty source means the Engine's own store" do
      assert {:ok, :stored} = CredentialSource.source(%{})
      assert {:ok, :stored} = CredentialSource.source(%{"credential_source" => ""})
      assert {:ok, :stored} = CredentialSource.source(%{"credential_source" => "stored"})
    end

    test "the broker source is recognised under either key shape" do
      assert {:ok, :broker} = CredentialSource.source(%{"credential_source" => "broker"})
      assert {:ok, :broker} = CredentialSource.source(%{credential_source: "broker"})
    end

    test "an unknown source is refused" do
      assert {:error, :invalid_credential_source} =
               CredentialSource.source(%{"credential_source" => "carrier_pigeon"})
    end
  end

  describe "hydrate/2" do
    test "the stored source returns the config untouched" do
      assert {:ok, config} = CredentialSource.hydrate(@stored_config)
      assert config == @stored_config
    end

    test "the broker source merges what the broker issued" do
      stub = ConnectorFixtureStub.install(:credential_broker)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      scope = %{id: "c-1", kind: "gmail", tenant_id: "default", workspace_id: "hq"}
      assert {:ok, config} = CredentialSource.hydrate(sealed(), scope)

      assert AccessToken.reveal(config["credentials"]["api_key"]) == "example-broker-issued-key"

      # The request named the reference, the connector and the scopes, and sent
      # no secret of the Engine's own.
      assert [call] = ConnectorFixtureStub.calls(stub)
      assert call.body["reference"] == "conn_0000000000"
      assert call.body["connector"] == %{"id" => "c-1", "kind" => "gmail"}
      assert call.body["tenant_id"] == "default"
      assert call.body["workspace_id"] == "hq"
      assert call.body["scopes"] == ["mail.read"]
    end

    test "a broker that refuses is named as refusing" do
      for status <- [403, 404] do
        stub = ConnectorFixtureStub.install(:credential_broker, status: status)
        assert {:error, :broker_refused} = CredentialSource.hydrate(sealed(), @scope)
        ConnectorFixtureStub.uninstall(stub)
      end
    end

    test "a broker that does not accept the reference is named as unauthorized" do
      stub = ConnectorFixtureStub.install(:credential_broker, status: 401)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      assert {:error, :broker_unauthorized} = CredentialSource.hydrate(sealed(), @scope)
    end

    test "a broker with no credentials in the answer is a refusal, not an empty login" do
      stub = ConnectorFixtureStub.install(:credential_broker, body: %{"credentials" => %{}})

      assert {:error, :broker_refused} = CredentialSource.hydrate(sealed(), @scope)
      ConnectorFixtureStub.uninstall(stub)
    end

    test "an unreachable broker is named as unreachable" do
      stub = ConnectorFixtureStub.install(:credential_broker, unreachable: true)

      assert {:error, :broker_unreachable} = CredentialSource.hydrate(sealed(), @scope)
      ConnectorFixtureStub.uninstall(stub)

      stub = ConnectorFixtureStub.install(:credential_broker, status: 503)
      assert {:error, :broker_unreachable} = CredentialSource.hydrate(sealed(), @scope)
      ConnectorFixtureStub.uninstall(stub)
    end

    test "a broker source with no endpoint or reference is not configured" do
      assert {:error, :broker_not_configured} =
               CredentialSource.hydrate(%{"credential_source" => "broker"}, %{})

      assert {:error, :broker_not_configured} =
               CredentialSource.hydrate(
                 %{
                   "credential_source" => "broker",
                   "broker_url" => "https://connect.example.com/x"
                 },
                 %{}
               )

      assert {:error, :broker_not_configured} =
               CredentialSource.hydrate(
                 sealed(%{"credential_source" => "broker", "broker_reference" => "conn_0000000000"}),
                 @scope
               )
    end
  end

  describe "an OAuth connection" do
    test "is answered under credentials with an issued access token and its expiry" do
      stub = BrokerStub.install(nil, issue: [{"example-issued-token", 300}])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      assert {:ok, config} = CredentialSource.hydrate(sealed(), @scope)

      assert %AccessToken{source: :broker, expires_at: %DateTime{} = at} =
               config["credentials"]["access_token"]

      assert DateTime.diff(at, DateTime.utc_now()) in 290..300
      refute inspect(config) =~ "example-issued-token"
    end

    test "accepts the token at the top level, and expires_in when there is no expires_at" do
      body = %{"access_token" => "example-issued-token", "expires_in" => 120}
      stub = ConnectorFixtureStub.install(:credential_broker, body: body)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      assert {:ok, config} = CredentialSource.hydrate(sealed(), @scope)
      assert %AccessToken{expires_at: at} = config["credentials"]["access_token"]
      assert DateTime.diff(at, DateTime.utc_now()) in 110..120
      assert Map.keys(config["credentials"]) == ["access_token"]
    end

    test "the broker settings and the reference are not handed to the adapter" do
      stub = BrokerStub.install(nil, issue: [{"example-issued-token", 300}])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      assert {:ok, config} = CredentialSource.hydrate(sealed(), @scope)
      refute Map.has_key?(config, "broker_reference")
      refute Map.has_key?(config, "broker_reference_ciphertext")
    end

    test "the request carries no header of the Engine's own, a bounded timeout and no redirect" do
      stub = BrokerStub.install(nil, issue: [{"example-issued-token", 300}])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      config = sealed(Map.put(@broker_config, "broker_timeout_ms", 600_000))
      assert {:ok, _config} = CredentialSource.hydrate(config, @scope)

      assert [call] = BrokerStub.broker_calls(stub)
      assert call.headers == []
      assert call.timeout == 30_000
      assert call.follow_redirects == false
    end
  end

  describe "where the broker's secret lands" do
    alias OptimalEngine.Connectors.Adapters.{
      Beehiiv,
      Confluence,
      Fathom,
      GitHub,
      GoHighLevel,
      Gmail,
      Jira,
      JotForm,
      Linear,
      Notion,
      Slack,
      Stripe
    }

    # The secrets a broker issues are held opaque; this is what they stand for.
    defp revealed(credentials),
      do: Map.new(credentials, fn {key, value} -> {key, AccessToken.reveal(value)} end)

    defp hydrate_for(adapter, body) do
      stub = BrokerStub.install(nil, issue: [{:body, body}])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      scope = %{id: "c-1", kind: "x", tenant_id: "default", workspace_id: "hq", adapter: adapter}
      CredentialSource.hydrate(sealed(), scope)
    end

    @access_token %{
      "credentials" => %{"access_token" => "example-secret", "expires_at" => "2999-01-01T00:00:00Z"}
    }
    @api_key %{
      "credentials" => %{"api_key" => "example-secret", "expires_at" => "2999-01-01T00:00:00Z"}
    }

    test "an access token stays renewable under access_token for an adapter that calls through AccessToken" do
      for adapter <- [Gmail, Notion, Slack] do
        assert {:ok, config} = hydrate_for(adapter, @access_token)
        assert %AccessToken{source: :broker} = config["credentials"]["access_token"]
        assert Map.keys(config["credentials"]) == ["access_token"]
      end
    end

    test "an access token becomes the key of an adapter that does not call through AccessToken" do
      for {adapter, key} <- [
            {Stripe, "api_key"},
            {Fathom, "api_key"},
            {Linear, "api_key"},
            {JotForm, "api_key"},
            {Beehiiv, "api_key"},
            {GitHub, "pat"},
            {GoHighLevel, "api_token"},
            {Jira, "api_token"},
            {Confluence, "api_token"}
          ] do
        assert {:ok, config} = hydrate_for(adapter, @access_token)
        assert revealed(config["credentials"]) == %{key => "example-secret"}
      end
    end

    test "an API key becomes the key of an adapter whose own is not api_key" do
      for {adapter, key} <- [
            {Notion, "integration_token"},
            {Slack, "bot_token"},
            {GitHub, "pat"},
            {GoHighLevel, "api_token"},
            {Jira, "api_token"}
          ] do
        assert {:ok, config} = hydrate_for(adapter, @api_key)
        assert revealed(config["credentials"]) == %{key => "example-secret"}
      end
    end

    test "an API key stays api_key for an adapter that reads api_key" do
      for adapter <- [Stripe, Fathom, Linear, JotForm, Beehiiv, nil] do
        assert {:ok, config} = hydrate_for(adapter, @api_key)
        assert revealed(config["credentials"]) == %{"api_key" => "example-secret"}
      end
    end

    test "a key the broker names itself is passed on and wins" do
      body = %{"credentials" => %{"bot_token" => "example-own", "api_key" => "example-secret"}}

      assert {:ok, config} = hydrate_for(Slack, body)
      assert revealed(config["credentials"]) == %{"bot_token" => "example-own"}
    end

    test "expires_at beside credentials is read, and is not handed to the adapter" do
      body = %{
        "credentials" => %{"access_token" => "example-secret"},
        "expires_at" => "2999-01-01T00:00:00Z"
      }

      assert {:ok, config} = hydrate_for(Gmail, body)

      assert %AccessToken{expires_at: ~U[2999-01-01 00:00:00Z]} =
               config["credentials"]["access_token"]

      assert Map.keys(config["credentials"]) == ["access_token"]

      assert {:ok, config} =
               hydrate_for(Stripe, %{
                 "credentials" => %{"api_key" => "k"},
                 "expires_at" => "2999-01-01T00:00:00Z"
               })

      assert revealed(config["credentials"]) == %{"api_key" => "k"}
    end

    test "every adapter says where its secret lives" do
      oauth = ~w(drive dropbox gmail hubspot notion onedrive salesforce slack teams zoom)a

      for mod <- Registry.all() do
        kind = mod.kind()

        assert mod.broker_access_token?() == kind in oauth,
               "#{kind}: calls through AccessToken exactly when it is one of #{inspect(oauth)}"

        assert mod.broker_access_token?() or mod.broker_token_key() != nil or
                 kind == :sources_folder,
               "#{kind} names neither an access token nor a key for the broker's secret"
      end
    end

    test "each adapter initialises on what it is given" do
      for {adapter, config} <- [
            {Stripe, %{"resources" => ["charges"]}},
            {GitHub, %{"org_or_user" => "example", "repos" => ["one"]}},
            {Notion, %{"workspace_name" => "Example", "database_ids" => []}},
            {Slack, %{"workspace_id" => "T0EXAMPLE1", "channels" => []}}
          ] do
        {:ok, hydrated} = hydrate_for(adapter, @api_key)
        assert {:ok, _state} = adapter.init(Map.merge(hydrated, config))
      end

      {:ok, hydrated} = hydrate_for(GitHub, @access_token)

      assert {:ok, _state} =
               GitHub.init(Map.merge(hydrated, %{"org_or_user" => "example", "repos" => ["one"]}))
    end
  end

  describe "the broker URL" do
    test "must be https on an allowed host, or no call is made" do
      stub = BrokerStub.install(nil, issue: [{"example-issued-token", 300}])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      for url <- [
            "http://connect.example.com/api/credentials",
            "https://elsewhere.example.com/api/credentials",
            "https://user:pass@connect.example.com/api/credentials",
            "https://169.254.169.254/latest/meta-data",
            "connect.example.com/api/credentials",
            "file:///etc/passwd"
          ] do
        assert {:error, :broker_url_not_allowed} =
                 CredentialSource.hydrate(
                   sealed(Map.put(@broker_config, "broker_url", url)),
                   @scope
                 ),
               url
      end

      assert BrokerStub.broker_calls(stub) == []
    end

    test "is checked against the configured hosts without regard to case" do
      assert :ok = CredentialSource.check_url("https://CONNECT.example.com/api/credentials")
    end

    test "with no hosts configured, no broker is called" do
      original = Application.get_env(:optimal_engine, :credential_broker_hosts)
      Application.delete_env(:optimal_engine, :credential_broker_hosts)
      on_exit(fn -> Application.put_env(:optimal_engine, :credential_broker_hosts, original) end)

      assert {:error, :broker_url_not_allowed} = CredentialSource.hydrate(sealed(), @scope)
    end

    test "a disallowed URL is refused when the connector is written", %{id: id} do
      config = Map.put(@broker_config, "broker_url", "https://elsewhere.example.com/x")

      assert {:error, :broker_url_not_allowed} = CredentialSource.check_persistable(config)

      assert {:error, :broker_url_not_allowed} =
               Connectors.register(%{id: id, kind: :recording, config: config})
    end
  end

  describe "the broker reference" do
    test "is sealed with CONNECTOR_KEY, and opened only for the broker call" do
      assert {:ok, sealed} = CredentialSource.seal_reference(@broker_config, %{id: "c-1"})
      refute Map.has_key?(sealed, "broker_reference")
      assert is_binary(sealed["broker_reference_ciphertext"])
      refute sealed["broker_reference_ciphertext"] =~ "conn_0000000000"

      stub = BrokerStub.install(nil, issue: [{"example-issued-token", 300}])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      assert {:ok, _config} = CredentialSource.hydrate(sealed, @scope)
      assert [call] = BrokerStub.broker_calls(stub)
      assert call.body["reference"] == "conn_0000000000"
    end

    test "a seal this key cannot open is named, not sent" do
      sealed = sealed()
      System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

      assert {:error, :broker_reference_unreadable} = CredentialSource.hydrate(sealed, @scope)
    end

    test "without CONNECTOR_KEY the write is refused" do
      System.delete_env("CONNECTOR_KEY")

      assert {:error, :connector_key_missing} =
               CredentialSource.seal_reference(@broker_config, %{id: "c-1"})
    end

    test "a config without a reference is unchanged" do
      assert {:ok, @stored_config} = CredentialSource.seal_reference(@stored_config, %{id: "c-1"})
    end

    test "is read from the seal alone: a plaintext reference in the config is not read" do
      stub = BrokerStub.install(nil, issue: [{"example-issued-token", 300}])
      on_exit(fn -> BrokerStub.uninstall(stub) end)

      assert {:error, :broker_not_configured} = CredentialSource.hydrate(@broker_config, @scope)
      assert BrokerStub.broker_calls(stub) == []
    end

    test "is stored sealed when the connector is registered", %{id: id} do
      {:ok, ^id} = Connectors.register(%{id: id, kind: :recording, config: @broker_config})

      {:ok, [[stored]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
      refute stored =~ "conn_0000000000"
      assert stored =~ "broker_reference_ciphertext"
    end
  end

  describe "check_persistable/1" do
    test "a broker connector may not also carry credentials" do
      assert {:error, :broker_credentials_must_not_be_stored} =
               CredentialSource.check_persistable(
                 Map.put(@broker_config, "credentials", %{"api_key" => "x"})
               )

      assert {:error, :broker_credentials_must_not_be_stored} =
               CredentialSource.check_persistable(
                 Map.put(@broker_config, :credentials, %{"api_key" => "x"})
               )

      assert :ok = CredentialSource.check_persistable(@broker_config)
    end

    test "a stored connector is unaffected" do
      assert :ok = CredentialSource.check_persistable(@stored_config)
      assert :ok = CredentialSource.check_persistable(%{})
    end
  end

  # The run rows for a connector, as `{status, error_detail}`.
  defp run_rows(connector_id) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT status, error_detail FROM connector_runs WHERE connector_id = ?1 ORDER BY id",
        [connector_id]
      )

    Enum.map(rows, fn [status, detail] -> {status, detail} end)
  end

  describe "through the Runner" do
    test "registration refuses to store credentials alongside a broker source", %{id: id} do
      assert {:error, :broker_credentials_must_not_be_stored} =
               Connectors.register(%{
                 id: id,
                 kind: :recording,
                 config: Map.put(@broker_config, "credentials", %{"api_key" => "x"})
               })

      assert {:ok, []} = Store.raw_query("SELECT id FROM connectors WHERE id = ?1", [id])
    end

    test "a sync on the broker source initialises the adapter with the broker's credential", %{
      id: id
    } do
      stub = ConnectorFixtureStub.install(:credential_broker)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, ^id} =
        Connectors.register(%{id: id, kind: :recording, config: @broker_config})

      {:ok, result} = Runner.run(id, adapter: RecordingAdapter, governed: false)
      assert result.status == :success

      assert_received {:initialised_with, config}
      assert AccessToken.reveal(config["credentials"]["api_key"]) == "example-broker-issued-key"

      # The credential the broker issued never reaches the database.
      {:ok, [[stored]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
      refute stored =~ "example-broker-issued-key"
    end

    test "a refused broker fails the sync before the adapter is initialised", %{id: id} do
      stub = ConnectorFixtureStub.install(:credential_broker, status: 403)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, ^id} = Connectors.register(%{id: id, kind: :recording, config: @broker_config})

      assert {:ok, result} = Runner.run(id, adapter: RecordingAdapter, governed: false)
      assert result.status == :error
      assert result.reason == :broker_refused
      refute_received {:initialised_with, _config}

      # The refusal is on the record, even though no adapter ever ran.
      assert [{"error", detail}] = run_rows(id)
      assert detail =~ "broker_refused"
    end

    test "an unreachable broker does not disable the connector", %{id: id} do
      stub = ConnectorFixtureStub.install(:credential_broker, unreachable: true)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      {:ok, ^id} = Connectors.register(%{id: id, kind: :recording, config: @broker_config})

      assert {:ok, result} = Runner.run(id, adapter: RecordingAdapter, governed: false)
      assert result.status == :error
      assert result.reason == :broker_unreachable

      {:ok, [[enabled]]} = Store.raw_query("SELECT enabled FROM connectors WHERE id = ?1", [id])
      assert enabled == 1
      assert [{"error", detail}] = run_rows(id)
      assert detail =~ "broker_unreachable"
    end

    test "the stored path still works when the broker is not in play", %{id: id} do
      {:ok, ^id} =
        Connectors.register(%{id: id, kind: :recording, config: @stored_config})

      {:ok, result} = Runner.run(id, adapter: RecordingAdapter, governed: false)
      assert result.status == :success

      assert_received {:initialised_with, config}
      assert config["api_key"] == "stored-example-key"
    end
  end
end
