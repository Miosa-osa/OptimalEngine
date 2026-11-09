defmodule OptimalEngine.Connectors.CredentialVaultTest do
  @moduledoc """
  With OpenBao configured and `OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao`,
  connector credentials are written to OpenBao and the connector row holds
  only a marker: nothing in the Engine database can
  open them. A sync reads them for its own cycle; OpenBao sealed or refusing
  fails the sync or the write with that reason; deleting the connector deletes
  the secret.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.{CredentialVault, Rows, Runner}
  alias OptimalEngine.{Secrets, Store}
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_KV_MOUNT
          OPTIMAL_CONNECTOR_CREDENTIAL_STORE CONNECTOR_KEY)

  defmodule CaptureAdapter do
    @moduledoc false
    @behaviour OptimalEngine.Connectors.Behaviour

    @impl true
    def kind, do: :slack
    @impl true
    def display_name, do: "Vault capture"
    @impl true
    def auth_scheme, do: :token
    @impl true
    def required_config_keys, do: []

    @impl true
    def init(config) do
      send(:persistent_term.get({__MODULE__, :test}), {:init, config})
      {:ok, config}
    end

    @impl true
    def sync(_state, _cursor), do: {:ok, [], "done"}
    @impl true
    def transform(_payload), do: {:error, :not_used}
  end

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    {:ok, stub} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", stub.token)
    System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", "openbao")
    :persistent_term.put({CaptureAdapter, :test}, self())

    %{stub: stub, id: "vault-slack-#{System.unique_integer([:positive])}"}
  end

  defp register(id, credentials \\ %{"bot_token" => "xoxb-vaulted"}) do
    Connectors.register(%{
      id: id,
      kind: :slack,
      config: %{"workspace_id" => "T01", "channels" => ["C01"], "credentials" => credentials}
    })
  end

  defp row_config(id) do
    {:ok, [[json]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
    json
  end

  test "OpenBao configured is not an opt-in: without the store set, credentials stay in the Engine",
       %{stub: stub, id: id} do
    System.delete_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))

    for unset_or_unknown <- [nil, "", "auto", "bao"] do
      if unset_or_unknown,
        do: System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", unset_or_unknown),
        else: System.delete_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE")

      assert CredentialVault.mode() == :engine
    end

    {:ok, ^id} = register(id)
    assert Map.has_key?(Jason.decode!(row_config(id)), "credentials_ciphertext")
    assert OpenBaoStub.secrets(stub) == %{}
  end

  test "credentials go to OpenBao without CONNECTOR_KEY, and the row holds only the marker", %{
    stub: stub,
    id: id
  } do
    assert CredentialVault.mode() == :openbao

    nested = %{"bot_token" => "xoxb-vaulted", "oauth" => %{"refresh_token" => "r-1"}}
    assert {:ok, ^id} = register(id, nested)

    json = row_config(id)
    refute json =~ "xoxb-vaulted"
    refute json =~ "r-1"
    config = Jason.decode!(json)
    assert config["credentials_store"] == "openbao"
    refute Map.has_key?(config, "credentials_ciphertext")
    refute Map.has_key?(config, "credentials")

    assert OpenBaoStub.secrets(stub)["optimal/connectors/default/#{id}"] == nested

    # The view says credentials are stored and shows none of them.
    {:ok, view} = Rows.get("default", id)
    refute inspect(view) =~ "xoxb-vaulted"
    refute Map.has_key?(view.config, "credentials_store")
  end

  test "a sync hands the adapter the credentials from OpenBao for that cycle", %{id: id} do
    {:ok, ^id} = register(id)

    assert {:ok, result} = Runner.run(id, adapter: CaptureAdapter, governed: false)
    assert result.status == :success
    assert_received {:init, config}
    assert config["bot_token"] == "xoxb-vaulted"
    refute Map.has_key?(config, "credentials_store")
  end

  test "a sealed OpenBao fails the sync with that reason before the adapter starts", %{
    stub: stub,
    id: id
  } do
    {:ok, ^id} = register(id)
    OpenBaoStub.seal(stub)

    assert {:ok, result} = Runner.run(id, adapter: CaptureAdapter, governed: false)
    assert result.status == :error
    assert result.reason == {:credentials_unavailable, :openbao_sealed}
    refute_received {:init, _config}

    {:ok, [[error]]} =
      Store.raw_query(
        "SELECT error_detail FROM connector_runs WHERE connector_id = ?1 ORDER BY id DESC LIMIT 1",
        [id]
      )

    assert error =~ "openbao_sealed"
  end

  test "a write OpenBao refuses is refused, and no row is left claiming credentials", %{
    stub: stub,
    id: id
  } do
    OpenBaoStub.seal(stub)

    capture_log(fn -> assert register(id) == {:error, :openbao_sealed} end)
    assert {:ok, []} = Store.raw_query("SELECT 1 FROM connectors WHERE id = ?1", [id])
  end

  test "deleting the connector deletes its secret; removing the credentials does too", %{
    stub: stub,
    id: id
  } do
    {:ok, ^id} = register(id)
    path = "optimal/connectors/default/#{id}"
    assert Map.has_key?(OpenBaoStub.secrets(stub), path)

    # Replacing them writes a new version over the same secret and keeps it.
    {:ok, _view} = Rows.update("default", id, %{"credentials" => %{"bot_token" => "xoxb-1"}})
    assert OpenBaoStub.secrets(stub)[path] == %{"bot_token" => "xoxb-1"}
    refute row_config(id) =~ "xoxb-1"

    assert {:ok, _view} = Rows.update("default", id, %{"credentials" => nil})
    refute Map.has_key?(OpenBaoStub.secrets(stub), path)

    {:ok, _view} = Rows.update("default", id, %{"credentials" => %{"bot_token" => "xoxb-2"}})
    assert OpenBaoStub.secrets(stub)[path] == %{"bot_token" => "xoxb-2"}

    assert :ok = Rows.delete("default", id)
    refute Map.has_key?(OpenBaoStub.secrets(stub), path)
  end

  test "a row that cannot be written leaves no new secret behind in OpenBao", %{
    stub: stub,
    id: id
  } do
    path = "optimal/connectors/default/#{id}"
    # A value the row cannot be encoded with fails the write after the
    # credentials were vaulted.
    unwritable = %{
      "workspace_id" => "T01",
      "channels" => ["C01"],
      "credentials" => %{"bot_token" => "xoxb-orphan"},
      "unencodable" => {:not, :json}
    }

    assert catch_error(Runner.upsert_row(%{id: id, kind: :slack, config: unwritable}))
    assert {:ok, []} = Store.raw_query("SELECT 1 FROM connectors WHERE id = ?1", [id])
    refute Map.has_key?(OpenBaoStub.secrets(stub), path)

    # A connector that already has a secret keeps the one its row still names.
    {:ok, ^id} = register(id)
    assert OpenBaoStub.secrets(stub)[path] == %{"bot_token" => "xoxb-vaulted"}

    changed = put_in(unwritable, ["credentials"], %{"bot_token" => "xoxb-new"})
    assert catch_error(Runner.upsert_row(%{id: id, kind: :slack, config: changed}))
    assert OpenBaoStub.secrets(stub)[path] == %{"bot_token" => "xoxb-vaulted"}
    assert {:ok, %{status: :success}} = Runner.run(id, adapter: CaptureAdapter, governed: false)
    assert_received {:init, %{"bot_token" => "xoxb-vaulted"}}
  end

  test "a delete OpenBao refuses keeps the connector, so its secret is never orphaned", %{
    stub: stub,
    id: id
  } do
    {:ok, ^id} = register(id)
    OpenBaoStub.seal(stub)

    assert Rows.delete("default", id) == {:error, :openbao_sealed}
    assert {:ok, [[1]]} = Store.raw_query("SELECT 1 FROM connectors WHERE id = ?1", [id])
  end

  test "a freshly initialised server gets its KV mount enabled on the first write", %{id: id} do
    {:ok, bare} = OpenBaoStub.start(mount: nil)
    on_exit(fn -> OpenBaoStub.stop(bare) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", bare.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bare.token)

    capture_log(fn -> assert {:ok, ^id} = register(id) end)
    assert {"POST", "/v1/sys/mounts/secret"} in OpenBaoStub.requests(bare)
    assert Map.has_key?(OpenBaoStub.secrets(bare), "optimal/connectors/default/#{id}")

    {:ok, refused} = OpenBaoStub.start(mount: nil, mount_enable: :forbidden)
    on_exit(fn -> OpenBaoStub.stop(refused) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", refused.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", refused.token)

    capture_log(fn -> assert register(id <> "-b") == {:error, :openbao_mount_missing} end)
  end

  test "OPTIMAL_CONNECTOR_CREDENTIAL_STORE=engine keeps the database envelope, and both kinds keep working",
       %{stub: stub, id: id} do
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
    System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", "engine")
    assert CredentialVault.mode() == :engine

    {:ok, ^id} = register(id)
    assert Map.has_key?(Jason.decode!(row_config(id)), "credentials_ciphertext")
    assert OpenBaoStub.secrets(stub) == %{}

    # Back to OpenBao: the envelope row still syncs with its own credentials.
    System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", "openbao")
    assert {:ok, %{status: :success}} = Runner.run(id, adapter: CaptureAdapter, governed: false)
    assert_received {:init, %{"bot_token" => "xoxb-vaulted"}}

    # OpenBao named explicitly but not configured refuses the write.
    System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", "openbao")
    System.delete_env("OPTIMAL_OPENBAO_TOKEN")
    capture_log(fn -> assert register(id <> "-c") == {:error, :openbao_not_configured} end)
  end
end
