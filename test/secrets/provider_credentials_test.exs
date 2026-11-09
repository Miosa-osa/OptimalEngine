defmodule OptimalEngine.Secrets.ProviderCredentialsTest do
  @moduledoc """
  The credentials the Engine sends to Valkey, NATS and its sync and
  federation peers are read through `OptimalEngine.Secrets`, so each may be
  an `openbao:<path>#<field>` reference: what goes over the wire is the
  secret OpenBao holds, never the reference text, and a reference OpenBao
  cannot answer fails with a reason that says so instead of connecting
  without the credential.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.{Federation, Secrets, Sync, Workspace}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Storage.{NATS, Valkey}
  alias OptimalEngine.Storage.NATS.Connection
  alias OptimalEngine.TestSupport.{NATSStub, OpenBaoStub, ValkeyStub}

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_VALKEY_URL OPTIMAL_VALKEY_PASSWORD
          OPTIMAL_NATS_URL OPTIMAL_NATS_TOKEN OPTIMAL_NATS_PASSWORD CONNECTOR_KEY)

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
    System.put_env("OPTIMAL_OPENBAO_ADDR", bao.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bao.token)
    %{bao: bao}
  end

  test "every provider credential is an Engine secret a reference may name" do
    for name <- ~w(OPTIMAL_VALKEY_PASSWORD OPTIMAL_NATS_TOKEN OPTIMAL_NATS_PASSWORD) do
      assert name in Secrets.engine_secrets()
    end
  end

  describe "Valkey" do
    setup do
      {:ok, stub} = ValkeyStub.start(password: "valkey-pw-from-bao")
      on_exit(fn -> ValkeyStub.stop(stub) end)
      System.put_env("OPTIMAL_VALKEY_URL", "redis://127.0.0.1:#{stub.port}")
      %{stub: stub}
    end

    test "OPTIMAL_VALKEY_PASSWORD may be a reference, and AUTH sends the secret", %{
      bao: bao,
      stub: stub
    } do
      OpenBaoStub.put_secret(bao, "optimal/valkey", %{"password" => "valkey-pw-from-bao"})
      System.put_env("OPTIMAL_VALKEY_PASSWORD", "openbao:optimal/valkey#password")

      assert Valkey.health() == :healthy
      assert [["AUTH", "valkey-pw-from-bao"], ["PING"]] = ValkeyStub.commands(stub)
      assert "OPTIMAL_VALKEY_PASSWORD" in Secrets.references()
      refute inspect(Valkey.safe_config()) =~ "valkey-pw"
    end

    test "a plain OPTIMAL_VALKEY_PASSWORD is used as it is", %{stub: stub} do
      System.put_env("OPTIMAL_VALKEY_PASSWORD", "valkey-pw-from-bao")
      assert Valkey.health() == :healthy
      assert [["AUTH", "valkey-pw-from-bao"], ["PING"]] = ValkeyStub.commands(stub)
    end

    test "a reference OpenBao cannot answer is the reason, and nothing connects", %{
      bao: bao,
      stub: stub
    } do
      OpenBaoStub.seal(bao)
      System.put_env("OPTIMAL_VALKEY_PASSWORD", "openbao:optimal/valkey#password")

      assert {:error, {:password_unavailable, :openbao_sealed}} = Valkey.round_trip()
      assert {:ok, config} = Valkey.config()
      assert {:error, {:password_unavailable, :openbao_sealed}} = Valkey.open(config)
      assert ValkeyStub.commands(stub) == []
    end
  end

  describe "NATS" do
    test "OPTIMAL_NATS_TOKEN may be a reference, for the probe and the long-lived client", %{
      bao: bao
    } do
      {:ok, stub} = NATSStub.start(token: "nats-tok-from-bao")
      on_exit(fn -> NATSStub.stop(stub) end)
      OpenBaoStub.put_secret(bao, "optimal/nats", %{"token" => "nats-tok-from-bao"})
      System.put_env("OPTIMAL_NATS_URL", "nats://127.0.0.1:#{stub.port}")
      System.put_env("OPTIMAL_NATS_TOKEN", "openbao:optimal/nats#token")

      assert NATS.health() == :healthy

      name = :"nats_secret_client_#{System.unique_integer([:positive])}"
      start_supervised!({Connection, name: name, backoff: {20, 100}}, id: name)
      assert wait_for(fn -> Connection.status(name).state == "connected" end)
      refute inspect(Connection.status(name)) =~ "nats-tok"
    end

    test "OPTIMAL_NATS_PASSWORD goes with the URL's user" do
      config = %{
        hostname: "h",
        port: 4222,
        username: "engine",
        password: nil,
        token: nil,
        ssl: false
      }

      System.put_env("OPTIMAL_NATS_PASSWORD", "nats-pw")
      assert {:ok, %{username: "engine", password: "nats-pw"}} = NATS.credentials(config)
    end

    test "a reference OpenBao cannot answer is the reason", %{bao: bao} do
      {:ok, stub} = NATSStub.start(token: "nats-tok-from-bao")
      on_exit(fn -> NATSStub.stop(stub) end)
      OpenBaoStub.seal(bao)
      System.put_env("OPTIMAL_NATS_URL", "nats://127.0.0.1:#{stub.port}")
      System.put_env("OPTIMAL_NATS_TOKEN", "openbao:optimal/nats#token")

      assert {:error, {:token_unavailable, :openbao_sealed}} = NATS.round_trip()
      assert NATS.health() == :unreachable
    end
  end

  describe "sync peers" do
    setup do
      System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
      scheduler = Process.whereis(OptimalEngine.Sync.Scheduler)
      if scheduler, do: :sys.suspend(scheduler, 60_000)

      on_exit(fn ->
        if scheduler && Process.alive?(scheduler), do: :sys.resume(scheduler)
        Application.delete_env(:optimal_engine, :http_mock)
      end)

      n = System.unique_integer([:positive])
      tenant = "peer-secret-#{n}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Peer #{n}"})

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

    defp add_peer(ctx, key) do
      Sync.add_peer(
        ctx.tenant,
        %{
          "workspace_id" => ctx.ws,
          "url" => "https://peer.example",
          "api_key" => key,
          "policy" => "pull"
        },
        "u"
      )
    end

    defp run(ctx), do: Sync.run_all() |> Enum.find(&(&1.workspace_id == ctx.ws))

    # Every HTTP request goes through the mock once it is installed, OpenBao's
    # too, so the reference is read (and kept for a minute) before it is.
    test "a peer key given as a reference is sent as the secret OpenBao holds", %{bao: bao} = ctx do
      OpenBaoStub.put_secret(bao, "optimal/peer", %{"api_key" => "peer-key-from-bao"})
      assert {:ok, "peer-key-from-bao"} = Secrets.resolve_value("t", "openbao:optimal/peer#api_key")
      sent = :ets.new(:sent, [:public])

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        :ets.insert(sent, {List.keyfind(opts[:headers], "authorization", 0)})
        {:ok, {{~c"HTTP/1.1", 401, ~c"No"}, [], "{}"}}
      end)

      assert {:ok, _peer} = add_peer(ctx, "openbao:optimal/peer#api_key")
      _ = run(ctx)

      assert [{{"authorization", "Bearer peer-key-from-bao"}} | _] = :ets.tab2list(sent)
    end

    test "a peer key reference OpenBao cannot answer is the reason, and nothing is sent",
         %{bao: bao} = ctx do
      assert {:ok, _peer} = add_peer(ctx, "openbao:optimal/peer#api_key")

      Application.put_env(:optimal_engine, :http_mock, fn url, _opts ->
        if String.starts_with?(url, bao.endpoint),
          do: {:ok, {{~c"HTTP/1.1", 503, ~c"Sealed"}, [], ~s({"errors":["Vault is sealed"]})}},
          else: flunk("nothing is sent to the peer without the key")
      end)

      assert %{status: "error", reason: {:peer_key_unavailable, :openbao_sealed}} = run(ctx)
    end

    test "a federation peer key may be a reference too", %{bao: bao} = ctx do
      OpenBaoStub.put_secret(bao, "optimal/fed", %{"api_key" => "fed-key-from-bao"})
      assert {:ok, "fed-key-from-bao"} = Secrets.resolve_value("t", "openbao:optimal/fed#api_key")
      sent = :ets.new(:fed_sent, [:public])

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        :ets.insert(sent, {List.keyfind(opts[:headers], "authorization", 0)})
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"results": []})}}
      end)

      assert {:ok, _} =
               Federation.add_peer(
                 ctx.tenant,
                 %{
                   "workspace_id" => ctx.ws,
                   "url" => "https://fed.example",
                   "api_key" => "openbao:optimal/fed#api_key",
                   "share_up" => "read"
                 },
                 "u"
               )

      _ = Federation.search(ctx.tenant, "anything", allowed: [ctx.ws])
      assert [{{"authorization", "Bearer fed-key-from-bao"}} | _] = :ets.tab2list(sent)
    end
  end

  defp wait_for(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, attempts - 1)
    end
  end
end
