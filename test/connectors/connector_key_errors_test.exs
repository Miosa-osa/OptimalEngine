defmodule OptimalEngine.Connectors.ConnectorKeyErrorsTest do
  @moduledoc """
  When `CONNECTOR_KEY` cannot be used, the reason says which way: not set
  (`connector_key_missing`), not 64 hex characters (`connector_key_invalid`),
  or an OpenBao reference that could not be read (`connector_key_unavailable`,
  with OpenBao's reason in the log). A reference to a sealed OpenBao used to
  be reported as "CONNECTOR_KEY is not configured".
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias OptimalEngine.{Health, Secrets, Sync, Workspace}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Connectors.{Credential, CredentialSource, Runner}
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN CONNECTOR_KEY)
  @broker_config %{
    "credential_source" => "broker",
    "broker_url" => "https://connect.example.com/api/credentials",
    "broker_reference" => "conn_0000000000"
  }

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    on_exit(fn ->
      Secrets.flush_cache()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    {:ok, bao} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(bao) end)
    %{bao: bao, hex: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)}
  end

  defp sealed_reference(bao) do
    System.put_env("OPTIMAL_OPENBAO_ADDR", bao.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bao.token)
    OpenBaoStub.seal(bao)
    System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")
  end

  describe "Credential" do
    test "names each way the key is unusable" do
      assert Credential.encrypt(%{"a" => "b"}) == {:error, :key_missing}
      assert Credential.key_status() == {:error, :connector_key_missing}

      System.put_env("CONNECTOR_KEY", "not-hex")
      assert Credential.encrypt(%{"a" => "b"}) == {:error, :key_invalid}
      assert Credential.decrypt("x") == {:error, :key_invalid}
      assert Credential.key_status() == {:error, :connector_key_invalid}
    end

    test "a reference OpenBao cannot answer is unavailable, not missing", %{bao: bao} do
      sealed_reference(bao)
      assert Credential.encrypt(%{"a" => "b"}) == {:error, :key_unavailable}
      assert Credential.key_status() == {:error, :connector_key_unavailable}
    end
  end

  describe "the call sites" do
    test "storing connector credentials says the reference could not be read", %{bao: bao} do
      sealed_reference(bao)

      log =
        capture_log(fn ->
          assert {:error, :connector_key_unavailable} =
                   Runner.upsert_row(%{
                     id: "key-err-#{System.unique_integer([:positive])}",
                     kind: :slack,
                     config: %{"credentials" => %{"bot_token" => "xoxb-example"}}
                   })
        end)

      assert log =~ "CONNECTOR_KEY"
      assert log =~ "sealed"
      refute log =~ "not configured"
    end

    test "an invalid key is named invalid when credentials are stored" do
      System.put_env("CONNECTOR_KEY", "abc")

      log =
        capture_log(fn ->
          assert {:error, :connector_key_invalid} =
                   Runner.upsert_row(%{
                     id: "key-err-#{System.unique_integer([:positive])}",
                     kind: :slack,
                     config: %{"credentials" => %{"bot_token" => "xoxb-example"}}
                   })
        end)

      assert log =~ "64 hex"
      refute log =~ "not configured"
    end

    test "sealing a broker reference says the reference could not be read", %{bao: bao} do
      sealed_reference(bao)

      assert {:error, :connector_key_unavailable} =
               CredentialSource.seal_reference(@broker_config, %{id: "c-1"})
    end

    test "opening a broker reference while the key is unavailable says so", %{bao: bao, hex: hex} do
      System.put_env("CONNECTOR_KEY", hex)
      {:ok, sealed} = CredentialSource.seal_reference(@broker_config, %{id: "c-1"})

      sealed_reference(bao)

      assert {:error, :connector_key_unavailable} =
               CredentialSource.hydrate(sealed, %{id: "c-1", kind: "gmail"})
    end

    test "a sync peer is refused with the key's own reason", %{bao: bao} do
      ctx = workspace()
      sealed_reference(bao)

      assert {:error, :connector_key_unavailable} =
               Sync.add_peer(
                 ctx.tenant,
                 %{"workspace_id" => ctx.ws, "url" => "https://p.example", "api_key" => "k"},
                 "u"
               )

      assert {:error, :connector_key_unavailable} =
               OptimalEngine.Federation.add_peer(
                 ctx.tenant,
                 %{"workspace_id" => ctx.ws, "url" => "https://p.example", "api_key" => "k"},
                 "u"
               )
    end

    test "a sync peer whose envelope cannot be opened names the key, not the credential",
         %{bao: bao, hex: hex} do
      ctx = workspace()
      System.put_env("CONNECTOR_KEY", hex)
      scheduler = Process.whereis(OptimalEngine.Sync.Scheduler)
      if scheduler, do: :sys.suspend(scheduler, 60_000)

      on_exit(fn ->
        if scheduler && Process.alive?(scheduler), do: :sys.resume(scheduler)
        Application.delete_env(:optimal_engine, :http_mock)
      end)

      Application.put_env(:optimal_engine, :http_mock, fn url, _opts ->
        if String.starts_with?(url, bao.endpoint),
          do: {:ok, {{~c"HTTP/1.1", 503, ~c"Sealed"}, [], ~s({"errors":["Vault is sealed"]})}},
          else: flunk("nothing is sent to the peer without the key")
      end)

      assert {:ok, _} =
               Sync.add_peer(
                 ctx.tenant,
                 %{
                   "workspace_id" => ctx.ws,
                   "url" => "https://p.example",
                   "api_key" => "k",
                   "policy" => "pull"
                 },
                 "u"
               )

      sealed_reference(bao)

      assert %{status: "error", reason: :connector_key_unavailable} =
               Sync.run_all() |> Enum.find(&(&1.workspace_id == ctx.ws))
    end

    test "a connector run whose credentials cannot be opened names the key", %{bao: bao, hex: hex} do
      System.put_env("CONNECTOR_KEY", hex)
      id = "key-run-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Runner.upsert_row(%{
                 id: id,
                 kind: :slack,
                 config: %{"credentials" => %{"bot_token" => "xoxb-example"}}
               })

      sealed_reference(bao)

      assert {:ok,
              %{status: :error, reason: {:credentials_unavailable, :connector_key_unavailable}}} =
               Runner.run(id)
    end

    test "readiness names an invalid key invalid when connectors are configured" do
      System.put_env("CONNECTOR_KEY", "abc")
      report = Health.ready(skip: [:embedder])

      if report.checks.credential_key != :ok,
        do: assert(report.checks.credential_key == {:error, :connector_key_invalid})
    end
  end

  defp workspace do
    n = System.unique_integer([:positive])
    tenant = "key-err-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Key #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "notes",
        name: "Notes"
      })

    %{tenant: tenant, ws: ws.id}
  end
end
