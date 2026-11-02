defmodule OptimalEngine.Storage.OpenBaoAdapterTest do
  @moduledoc """
  The OpenBao provider must report itself honestly: implemented, configured and
  healthy only when an unsealed server accepted the token, and proved only by a
  secret written, read back and deleted.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.{OpenBao, Providers}
  alias OptimalEngine.Storage.OpenBao.Adapter
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_KV_MOUNT)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp point_at(stub, token \\ nil) do
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", token || stub.token)
  end

  test "openbao is an implemented provider, not adapter_missing" do
    assert {:ok, provider} = Providers.get("openbao")
    assert provider.adapter_implemented
    assert provider.adapter_module == "OptimalEngine.Storage.OpenBao.Adapter"
    assert provider.lifecycle_state == "not_configured"
    assert "OPTIMAL_OPENBAO_TOKEN" in provider.missing_environment
  end

  test "an address without a token is not configured, a non-http address invalid, the token never shown" do
    System.put_env("OPTIMAL_OPENBAO_ADDR", "https://bao.example.com:8200")
    assert OpenBao.health() == :not_configured
    refute OpenBao.configured?()

    System.put_env("OPTIMAL_OPENBAO_TOKEN", "hvs.verysecret")

    assert {:ok,
            %{base_url: "https://bao.example.com:8200", tls: true, mount: "secret", token: true}} =
             OpenBao.config()

    refute inspect(Adapter.status()) =~ "verysecret"
    refute inspect(Adapter.describe()) =~ "verysecret"

    System.put_env("OPTIMAL_OPENBAO_ADDR", "bao.example.com:8200")
    assert OpenBao.health() == :invalid_config
  end

  test "an unsealed server that accepts the token is available; a sealed one or a bad token is not" do
    {:ok, stub} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    point_at(stub)

    assert OpenBao.health() == :healthy
    assert {:ok, provider} = Providers.get("openbao", probe: true)
    assert provider.lifecycle_state == "available"

    assert [{"GET", "/v1/sys/health"}, {"GET", "/v1/auth/token/lookup-self"} | _] =
             OpenBaoStub.requests(stub)

    point_at(stub, "wrong")
    assert OpenBao.health() == :unreachable

    {:ok, sealed} = OpenBaoStub.start(sealed: true)
    on_exit(fn -> OpenBaoStub.stop(sealed) end)
    point_at(sealed)
    assert OpenBao.health() == :unreachable
    assert {:ok, down} = Providers.get("openbao", probe: true)
    assert down.lifecycle_state == "unavailable"
  end

  test "the proof writes a secret under the mount, reads the same value back and deletes it" do
    {:ok, stub} = OpenBaoStub.start(mount: "kv")
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    point_at(stub)
    System.put_env("OPTIMAL_OPENBAO_KV_MOUNT", "kv")

    assert {:ok, %{provider: "openbao", wrote: 1, read_back: true, mount: "kv"}} = Adapter.probe()
    assert OpenBaoStub.secrets(stub) == %{}

    assert [
             {"POST", "/v1/kv/data/optimal/proof/" <> name},
             {"GET", _},
             {"DELETE", "/v1/kv/metadata/optimal/proof/" <> name}
           ] =
             OpenBaoStub.requests(stub)

    assert [%{provider: "openbao", status: "pass"}] =
             Providers.proofs() |> Enum.filter(&(&1.provider == "openbao"))
  end

  test "a closed port is unreachable" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)
    System.put_env("OPTIMAL_OPENBAO_ADDR", "http://127.0.0.1:#{port}")
    System.put_env("OPTIMAL_OPENBAO_TOKEN", "t")
    assert OpenBao.health(timeout: 500) == :unreachable
  end
end
