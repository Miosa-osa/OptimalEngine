defmodule OptimalEngine.Secrets.OpenBaoBreakerTest do
  @moduledoc """
  While OpenBao is down (sealed, unreachable, not answering), the Engine asks
  it again only after a short window (`OPTIMAL_OPENBAO_RETRY_AFTER_MS`, five
  seconds): every call inside the window fails at once with the same reason,
  instead of each one waiting out the HTTP timeout.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.Connectors.CredentialVault
  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.OpenBao
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_BACKUP_KEY
          OPTIMAL_OPENBAO_RETRY_AFTER_MS)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Secrets.flush_cache()
    end)

    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    :ok
  end

  defp point_at(endpoint, token) do
    System.put_env("OPTIMAL_OPENBAO_ADDR", endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", token)
  end

  defp timed(fun) do
    {micros, result} = :timer.tc(fun)
    {div(micros, 1000), result}
  end

  test "a sealed OpenBao is asked once per window, and answers again after it" do
    {:ok, stub} = OpenBaoStub.start(sealed: true)
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    point_at(stub.endpoint, stub.token)
    OpenBaoStub.put_secret(stub, "optimal/engine", %{"backup_key" => "k"})
    System.put_env("OPTIMAL_OPENBAO_RETRY_AFTER_MS", "300")

    assert {:error, {:secret_unavailable, _, :openbao_sealed}} =
             Secrets.fetch("OPTIMAL_BACKUP_KEY")

    asked = length(OpenBaoStub.requests(stub))
    assert asked == 1

    # Inside the window: the same reason, and OpenBao is not asked.
    assert {:error, {:secret_unavailable, _, :openbao_sealed}} =
             Secrets.fetch("OPTIMAL_BACKUP_KEY")

    assert CredentialVault.get(%{}, "default", "c1") == {:error, :openbao_sealed}
    assert OpenBao.kv_write("optimal/x", %{"a" => "b"}) == {:error, :openbao_sealed}
    assert OpenBao.availability() == {:error, :openbao_sealed}
    assert length(OpenBaoStub.requests(stub)) == asked

    # Unsealed, it is asked again once the window has passed.
    OpenBaoStub.unseal(stub)
    Process.sleep(350)
    assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "k"}
    assert OpenBao.availability() == :ok
  end

  test "an OpenBao that never answers costs one timeout per window, not one per call" do
    # Accepts the connection (the kernel backlog does) and never answers.
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, backlog: 16])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    point_at("http://127.0.0.1:#{port}", "t")

    {first_ms, first} = timed(fn -> Secrets.fetch("OPTIMAL_BACKUP_KEY") end)
    assert {:error, {:secret_unavailable, _, :openbao_unreachable}} = first
    assert first_ms >= 1_000

    for _call <- 1..5 do
      {ms, result} = timed(fn -> Secrets.fetch("OPTIMAL_BACKUP_KEY") end)
      assert {:error, {:secret_unavailable, _, :openbao_unreachable}} = result
      assert ms < 200
    end
  end

  test "a definite answer is not an outage: a refused token is asked again every time" do
    {:ok, stub} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    point_at(stub.endpoint, "wrong-token")

    for _call <- 1..3 do
      assert {:error, {:secret_unavailable, _, :openbao_forbidden}} =
               Secrets.fetch("OPTIMAL_BACKUP_KEY")
    end

    assert length(OpenBaoStub.requests(stub)) == 3
  end

  test "the window is per OpenBao address, and 0 turns it off" do
    {:ok, sealed} = OpenBaoStub.start(sealed: true)
    {:ok, open} = OpenBaoStub.start()
    on_exit(fn -> Enum.each([sealed, open], &OpenBaoStub.stop/1) end)
    OpenBaoStub.put_secret(open, "optimal/engine", %{"backup_key" => "k2"})

    point_at(sealed.endpoint, sealed.token)
    assert {:error, _} = Secrets.fetch("OPTIMAL_BACKUP_KEY")

    point_at(open.endpoint, open.token)
    assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "k2"}

    System.put_env("OPTIMAL_OPENBAO_RETRY_AFTER_MS", "0")
    point_at(sealed.endpoint, sealed.token)
    Secrets.flush_cache()
    before = length(OpenBaoStub.requests(sealed))
    assert {:error, _} = Secrets.fetch("OPTIMAL_BACKUP_KEY")
    assert {:error, _} = Secrets.fetch("OPTIMAL_BACKUP_KEY")
    assert length(OpenBaoStub.requests(sealed)) == before + 2
  end
end
