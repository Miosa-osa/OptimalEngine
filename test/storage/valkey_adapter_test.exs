defmodule OptimalEngine.Storage.ValkeyAdapterTest do
  @moduledoc """
  The Valkey provider must report itself honestly: implemented, configured and
  healthy only when a server answered a PING, and proved only by a key written,
  read back and deleted.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.{Providers, Valkey}
  alias OptimalEngine.Storage.Valkey.Adapter
  alias OptimalEngine.TestSupport.ValkeyStub

  setup do
    previous = System.get_env(Valkey.env_name())
    System.delete_env(Valkey.env_name())

    on_exit(fn ->
      if previous,
        do: System.put_env(Valkey.env_name(), previous),
        else: System.delete_env(Valkey.env_name())
    end)

    :ok
  end

  defp point_at(stub, extra \\ "") do
    System.put_env(Valkey.env_name(), "redis://#{extra}127.0.0.1:#{stub.port}")
  end

  test "valkey is an implemented provider, not adapter_missing" do
    assert {:ok, provider} = Providers.get("valkey")
    assert provider.adapter_implemented
    assert provider.adapter_module == "OptimalEngine.Storage.Valkey.Adapter"
    assert provider.lifecycle_state == "not_configured"
    assert Enum.sort(provider.capabilities) == ~w(cache coordination rate_limits)a
  end

  test "unconfigured valkey is not_configured, and a bad URL is invalid, never healthy" do
    assert Valkey.health() == :not_configured
    assert {:error, :not_configured} = Adapter.probe()
    assert %{configured: false, lifecycle_state: "not_configured"} = Adapter.status(probe: true)

    System.put_env(Valkey.env_name(), "http://127.0.0.1:1")
    assert Valkey.health() == :invalid_config
    refute Valkey.configured?()
  end

  test "the URL's credential is parsed for the connection and never shown" do
    System.put_env(Valkey.env_name(), "rediss://app:s3cr%40t@cache.example.com:6380/2")
    assert {:ok, config} = Valkey.config()
    assert config.password == "s3cr@t"
    assert config.username == "app"
    assert config.port == 6380
    assert config.database == 2
    assert config.ssl

    assert {:ok, safe} = Valkey.safe_config()
    refute Map.has_key?(safe, :password)
    refute Adapter.describe() |> inspect() =~ "s3cr"
    assert %{tls: true} = Adapter.status()
  end

  test "a server that answers PING is healthy and available; a closed port is unreachable" do
    {:ok, stub} = ValkeyStub.start()
    on_exit(fn -> ValkeyStub.stop(stub) end)
    point_at(stub)

    assert Valkey.health() == :healthy
    assert {:ok, provider} = Providers.get("valkey", probe: true)
    assert provider.health == "healthy"
    assert provider.lifecycle_state == "available"
    assert [["PING"] | _] = ValkeyStub.commands(stub)

    ValkeyStub.stop(stub)
    assert Valkey.health(timeout: 500) == :unreachable
    assert {:ok, down} = Providers.get("valkey", probe: true)
    assert down.lifecycle_state == "unavailable"
  end

  test "the proof writes a key, reads the same value back and deletes it" do
    {:ok, stub} = ValkeyStub.start()
    on_exit(fn -> ValkeyStub.stop(stub) end)
    point_at(stub)

    assert {:ok, evidence} = Adapter.probe()
    assert %{provider: "valkey", wrote: 1, read_back: true, deleted: true} = evidence
    assert ValkeyStub.keys(stub) == %{}

    assert [["SET", key, _value, "PX", "60000"], ["GET", key], ["DEL", key]] =
             ValkeyStub.commands(stub)

    assert String.starts_with?(key, "optimal:proof:")

    assert [%{provider: "valkey", status: "pass"}] =
             Providers.proofs() |> Enum.filter(&(&1.provider == "valkey"))
  end

  test "a password is sent with AUTH first and a wrong one is unreachable, not healthy" do
    {:ok, stub} = ValkeyStub.start(password: "right")
    on_exit(fn -> ValkeyStub.stop(stub) end)

    point_at(stub, ":right@")
    assert Valkey.health() == :healthy
    assert [["AUTH", "right"], ["PING"]] = ValkeyStub.commands(stub)

    point_at(stub, ":wrong@")
    assert Valkey.health() == :unreachable
    assert {:error, {:auth_failed, _}} = Valkey.round_trip()
  end

  test "RESP replies of every kind decode" do
    assert {:ok, "PONG", ""} = Valkey.decode("+PONG\r\n")
    assert {:ok, {:error, "ERR x"}, ""} = Valkey.decode("-ERR x\r\n")
    assert {:ok, 7, ""} = Valkey.decode(":7\r\n")
    assert {:ok, nil, ""} = Valkey.decode("$-1\r\n")
    assert {:ok, "ab", "rest"} = Valkey.decode("$2\r\nab\r\nrest")
    assert {:ok, ["a", 1], ""} = Valkey.decode("*2\r\n$1\r\na\r\n:1\r\n")
    assert :incomplete = Valkey.decode("$5\r\nab")
    assert Valkey.encode(["GET", "k"]) == "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n"
  end
end
