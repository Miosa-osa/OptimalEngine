defmodule OptimalEngine.Connectors.CredentialSourceTest do
  @moduledoc """
  Where a connector's credentials come from: the Engine's own encrypted store by
  default, or an outside broker at sync time.

  The broker is answered by a recorded fixture through the HTTP mock seam, so
  no real broker is called.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.{CredentialSource, Runner}
  alias OptimalEngine.Store
  alias OptimalEngine.Test.ConnectorFixtureStub

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
      assert {:ok, config} = CredentialSource.hydrate(@broker_config, scope)

      assert config["credentials"]["api_key"] == "example-broker-issued-key"

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
      for status <- [401, 403, 404] do
        stub = ConnectorFixtureStub.install(:credential_broker, status: status)
        assert {:error, :broker_refused} = CredentialSource.hydrate(@broker_config, %{})
        ConnectorFixtureStub.uninstall(stub)
      end
    end

    test "a broker with no credentials in the answer is a refusal, not an empty login" do
      stub = ConnectorFixtureStub.install(:credential_broker, body: %{"credentials" => %{}})

      assert {:error, :broker_refused} = CredentialSource.hydrate(@broker_config, %{})
      ConnectorFixtureStub.uninstall(stub)
    end

    test "an unreachable broker is named as unreachable" do
      stub = ConnectorFixtureStub.install(:credential_broker, unreachable: true)

      assert {:error, :broker_unreachable} = CredentialSource.hydrate(@broker_config, %{})
      ConnectorFixtureStub.uninstall(stub)

      stub = ConnectorFixtureStub.install(:credential_broker, status: 503)
      assert {:error, :broker_unreachable} = CredentialSource.hydrate(@broker_config, %{})
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
                 %{"credential_source" => "broker", "broker_reference" => "conn_0000000000"},
                 %{}
               )
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
      assert config["credentials"]["api_key"] == "example-broker-issued-key"

      # The credential the broker issued never reaches the database.
      {:ok, [[stored]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
      refute stored =~ "example-broker-issued-key"
    end

    test "a refused broker fails the sync before the adapter is initialised", %{id: id} do
      stub = ConnectorFixtureStub.install(:credential_broker, status: 401)
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
