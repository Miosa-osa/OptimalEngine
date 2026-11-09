defmodule OptimalEngine.Storage.OpenBaoInventoryTest do
  @moduledoc """
  The provider inventory reports OpenBao as it reports every provider since
  #222 (`serves`, `data_path`), plus what only OpenBao has: whether it is
  reachable, initialized and sealed. A probed inventory asks OpenBao; an
  unprobed one reports what the last data-path call found, and never asks.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.Providers
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_BACKUP_KEY
          OPTIMAL_CONNECTOR_CREDENTIAL_STORE OPTIMAL_OPENBAO_TRANSIT_KEY)

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
    %{bao: bao}
  end

  defp point_at(bao) do
    System.put_env("OPTIMAL_OPENBAO_ADDR", bao.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bao.token)
  end

  defp openbao(opts \\ []) do
    {:ok, provider} = Providers.get("openbao", opts)
    provider
  end

  test "unconfigured: probe_only, and nothing is known about the server" do
    provider = openbao(probe: true)
    assert provider.lifecycle_state == "not_configured"
    assert provider.serves == []
    assert provider.data_path == "probe_only"

    assert provider.runtime == %{
             reachable: nil,
             initialized: nil,
             sealed: nil,
             checked: "not_configured"
           }
  end

  test "probed and unsealed: reachable, unsealed, and serving the references it holds", %{
    bao: bao
  } do
    point_at(bao)
    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")

    provider = openbao(probe: true)
    assert provider.lifecycle_state == "available"
    assert provider.serves == ["secret_references"]
    assert provider.data_path == "serving"
    assert provider.runtime == %{reachable: true, initialized: true, sealed: false, checked: "live"}
  end

  test "probed and sealed: reachable, sealed, standby", %{bao: bao} do
    point_at(bao)
    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    OpenBaoStub.seal(bao)

    provider = openbao(probe: true)
    assert provider.lifecycle_state == "unavailable"
    assert provider.data_path == "standby"
    assert %{reachable: true, sealed: true, checked: "live"} = provider.runtime
  end

  test "probed and not answering: unreachable, seal unknown", %{bao: bao} do
    point_at(bao)
    OpenBaoStub.stop(bao)

    provider = openbao(probe: true)
    assert provider.lifecycle_state == "unavailable"
    assert provider.runtime == %{reachable: false, initialized: nil, sealed: nil, checked: "live"}
  end

  test "unprobed: what the last data-path call found, without asking OpenBao", %{bao: bao} do
    point_at(bao)
    assert %{reachable: nil, sealed: nil, checked: "not_checked"} = openbao().runtime

    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    OpenBaoStub.seal(bao)
    assert {:error, _} = Secrets.fetch("OPTIMAL_BACKUP_KEY")

    requests = length(OpenBaoStub.requests(bao))
    assert %{reachable: true, sealed: true, checked: "last_call"} = openbao().runtime
    assert length(OpenBaoStub.requests(bao)) == requests
  end

  test "the runtime never carries the token or the address", %{bao: bao} do
    point_at(bao)
    provider = openbao(probe: true)
    refute inspect(provider.runtime) =~ bao.token
    refute inspect(provider.runtime) =~ "127.0.0.1"
  end
end
