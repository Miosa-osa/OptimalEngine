defmodule OptimalEngine.Secrets.CacheOwnerTest do
  @moduledoc """
  The fields read from OpenBao are kept in a `:protected` ETS table owned by a
  supervised process (`OptimalEngine.Secrets.Cache`): any process may read a
  kept field, only the owner writes one, so no other process in the VM can
  plant a value a later fetch would serve. The owner restarting starts an
  empty table, and a fetch meanwhile reads OpenBao.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.Secrets
  alias OptimalEngine.TestSupport.OpenBaoStub

  @table :optimal_engine_secrets_cache
  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_KV_MOUNT OPTIMAL_BACKUP_KEY)

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

    {:ok, stub} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", stub.token)
    %{stub: stub}
  end

  defp kv_reads(stub, path) do
    Enum.count(OpenBaoStub.requests(stub), &(&1 == {"GET", "/v1/secret/data/" <> path}))
  end

  test "the table is protected and owned by the supervised cache process" do
    owner = Process.whereis(OptimalEngine.Secrets.Cache)
    assert is_pid(owner)
    assert :ets.info(@table, :protection) == :protected
    assert :ets.info(@table, :owner) == owner
  end

  test "another process cannot plant a value, and a fetch never serves one", %{stub: stub} do
    OpenBaoStub.put_secret(stub, "optimal/engine", %{"backup_key" => "the-real-value"})
    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")

    assert_raise ArgumentError, fn ->
      :ets.insert(@table, {:planted, System.monotonic_time(:millisecond) + 60_000, "planted"})
    end

    assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "the-real-value"}

    # Every kept entry was written by the owner: overwriting one is refused.
    [{key, _expires, _value}] = Secrets.cache_entries()

    assert_raise ArgumentError, fn ->
      :ets.insert(@table, {key, System.monotonic_time(:millisecond) + 60_000, "poisoned"})
    end

    assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "the-real-value"}
    assert kv_reads(stub, "optimal/engine") == 1
  end

  test "an owner that restarts starts empty, and fetches keep working", %{stub: stub} do
    OpenBaoStub.put_secret(stub, "optimal/engine", %{"backup_key" => "kept"})
    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "kept"}

    owner = Process.whereis(OptimalEngine.Secrets.Cache)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "kept"}

    restarted =
      Enum.find_value(1..100, fn _ ->
        pid = Process.whereis(OptimalEngine.Secrets.Cache)
        if is_pid(pid) and pid != owner, do: pid, else: Process.sleep(10) && nil
      end)

    assert is_pid(restarted)
    assert :ets.info(@table, :owner) == restarted
    assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "kept"}
    assert length(Secrets.cache_entries()) == 1
  end
end
