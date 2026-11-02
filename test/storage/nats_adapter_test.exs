defmodule OptimalEngine.Storage.NATSAdapterTest do
  @moduledoc """
  The NATS JetStream provider must report itself honestly: implemented,
  configured and healthy only when the server answered PING and JetStream
  answered an account request, and proved only by a message stored in a stream
  and read back by sequence.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.{NATS, Providers}
  alias OptimalEngine.Storage.NATS.Adapter
  alias OptimalEngine.TestSupport.NATSStub

  setup do
    previous = System.get_env(NATS.env_name())
    System.delete_env(NATS.env_name())

    on_exit(fn ->
      if previous,
        do: System.put_env(NATS.env_name(), previous),
        else: System.delete_env(NATS.env_name())
    end)

    :ok
  end

  defp point_at(stub, extra \\ ""),
    do: System.put_env(NATS.env_name(), "nats://#{extra}127.0.0.1:#{stub.port}")

  test "nats_jetstream is an implemented provider, not adapter_missing" do
    assert {:ok, provider} = Providers.get("nats_jetstream")
    assert provider.adapter_implemented
    assert provider.adapter_module == "OptimalEngine.Storage.NATS.Adapter"
    assert provider.lifecycle_state == "not_configured"
    assert Enum.sort(provider.capabilities) == ~w(coordination event_stream jobs replication)a
  end

  test "unconfigured is not_configured, a bad URL invalid, and the credential never shown" do
    assert NATS.health() == :not_configured
    assert {:error, :not_configured} = Adapter.probe()

    System.put_env(NATS.env_name(), "redis://127.0.0.1:1")
    assert NATS.health() == :invalid_config

    System.put_env(NATS.env_name(), "tls://engine:p%40ss@bus.example.com:4443")
    assert {:ok, %{username: "engine", password: "p@ss", port: 4443, ssl: true}} = NATS.config()
    assert {:ok, safe} = NATS.safe_config()
    refute Map.has_key?(safe, :password)

    assert %{tls: true, configured: true, lifecycle_state: "configured_unverified"} =
             Adapter.status()

    System.put_env(NATS.env_name(), "nats://s3cret-token@bus.example.com")
    assert {:ok, %{token: "s3cret-token", username: nil}} = NATS.config()
  end

  test "a JetStream server is healthy and available; a core server without JetStream is not" do
    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)
    point_at(stub)

    assert NATS.health() == :healthy
    assert {:ok, provider} = Providers.get("nats_jetstream", probe: true)
    assert provider.lifecycle_state == "available"
    assert Enum.any?(NATSStub.commands(stub), &String.starts_with?(&1, "CONNECT "))
    assert "PING" in NATSStub.commands(stub)

    {:ok, core} = NATSStub.start(jetstream: false)
    on_exit(fn -> NATSStub.stop(core) end)
    point_at(core)
    assert NATS.health() == :unreachable
    assert {:ok, down} = Providers.get("nats_jetstream", probe: true)
    assert down.lifecycle_state == "unavailable"
  end

  test "the proof creates a stream, publishes, reads the message back by sequence and deletes the stream" do
    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)
    point_at(stub)

    assert {:ok, evidence} = Adapter.probe()

    assert %{
             provider: "nats_jetstream",
             stream_created: true,
             published: 1,
             sequence: 1,
             read_back: true
           } = evidence

    assert NATSStub.streams(stub) == %{}

    apis = NATSStub.commands(stub) |> Enum.filter(&String.starts_with?(&1, "PUB $JS.API."))

    assert Enum.map(
             apis,
             &(&1 |> String.split(" ") |> Enum.at(1) |> String.replace(~r/_[0-9A-F]+$/, ""))
           ) ==
             ~w($JS.API.STREAM.CREATE.OPTIMAL_PROOF $JS.API.STREAM.MSG.GET.OPTIMAL_PROOF $JS.API.STREAM.DELETE.OPTIMAL_PROOF)

    assert [%{provider: "nats_jetstream", status: "pass"}] =
             Providers.proofs() |> Enum.filter(&(&1.provider == "nats_jetstream"))
  end

  test "a token is sent in CONNECT and a wrong one is unreachable, not healthy" do
    {:ok, stub} = NATSStub.start(token: "right")
    on_exit(fn -> NATSStub.stop(stub) end)

    point_at(stub, "right@")
    assert NATS.health() == :healthy

    point_at(stub, "wrong@")
    assert NATS.health() == :unreachable
    assert {:error, _} = NATS.round_trip()
  end

  test "a closed port is unreachable" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)
    System.put_env(NATS.env_name(), "nats://127.0.0.1:#{port}")
    assert NATS.health(timeout: 500) == :unreachable
  end
end
