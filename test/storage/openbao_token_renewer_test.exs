defmodule OptimalEngine.Storage.OpenBaoTokenRenewerTest do
  @moduledoc """
  A renewable `OPTIMAL_OPENBAO_TOKEN` is renewed (`auth/token/renew-self`)
  before it expires, at half its remaining time. A token that expires and
  cannot be renewed is logged once, naming when it runs out, never the token.
  A token with no expiry (a root token) needs nothing.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Storage.OpenBao.TokenRenewer
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    # Tokens here live seconds, not hours: renew as often as they need.
    Application.put_env(:optimal_engine, :openbao_renew_floor_ms, 100)
    on_exit(fn -> Application.delete_env(:optimal_engine, :openbao_renew_floor_ms) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp start(stub_opts) do
    {:ok, stub} = OpenBaoStub.start(stub_opts)
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", stub.token)
    stub
  end

  defp renewals(stub),
    do: Enum.count(OpenBaoStub.requests(stub), &(&1 == {"POST", "/v1/auth/token/renew-self"}))

  test "a renewable token is renewed at half its remaining time, again and again" do
    stub = start(token_ttl: 2, renewable: true)
    pid = start_supervised!({TokenRenewer, name: nil})

    Process.sleep(2_300)
    assert renewals(stub) >= 2
    assert Process.alive?(pid)
    assert TokenRenewer.status(pid).renewable
  end

  test "a lease that stops growing is renewed no more, and that is said once" do
    # Near its maximum TTL each renewal answers less than the last.
    stub =
      start(token_ttl: 2, renewable: true, renew_ttls: [2, 1, 1, 1], explicit_max_ttl: 4)

    log =
      capture_log(fn ->
        pid = start_supervised!({TokenRenewer, name: nil})
        Process.sleep(2_500)
        assert Process.alive?(pid)
      end)

    assert renewals(stub) <= 3
    assert length(String.split(log, "stopped growing")) == 2
    refute log =~ stub.token
  end

  test "a shrinking lease with no cap of its own is renewed on, never given up" do
    # A lease cut by the mount's or the server's maximum, not the token's own.
    stub = start(token_ttl: 2, renewable: true, renew_ttls: [2, 1, 1, 1])

    pid = start_supervised!({TokenRenewer, name: nil})
    Process.sleep(3_300)

    # Still renewing: the next renewal is scheduled. (Judged on this renewer's
    # own state, not the log, which any other process may write to.)
    assert renewals(stub) >= 4
    assert is_reference(:sys.get_state(pid).timer)
  end

  test "a renewable lease shorter than twice the floor is renewed at the floor" do
    Application.put_env(:optimal_engine, :openbao_renew_floor_ms, 1_500)
    stub = start(token_ttl: 2, renewable: true)
    _pid = start_supervised!({TokenRenewer, name: nil})
    Process.sleep(1_900)
    assert renewals(stub) >= 1
  end

  test "a lease shorter than the floor is never renewed in a loop, and that is said once" do
    Application.put_env(:optimal_engine, :openbao_renew_floor_ms, 30_000)
    stub = start(token_ttl: 1, renewable: true)

    log =
      capture_log(fn ->
        pid = start_supervised!({TokenRenewer, name: nil})
        TokenRenewer.check(pid)
        Process.sleep(1_200)
      end)

    assert renewals(stub) == 0
    assert length(String.split(log, "too short to renew")) == 2
    refute log =~ stub.token
  end

  test "a token that cannot be renewed is logged once, and never renewed" do
    stub = start(token_ttl: 3_600, renewable: false)

    log =
      capture_log(fn ->
        pid = start_supervised!({TokenRenewer, name: nil})
        TokenRenewer.check(pid)
        TokenRenewer.check(pid)
        _ = TokenRenewer.status(pid)
      end)

    assert length(String.split(log, "not renewable")) == 2
    assert log =~ "OPTIMAL_OPENBAO_TOKEN"
    refute log =~ stub.token
    assert renewals(stub) == 0
  end

  test "a token with no expiry needs nothing, and no OpenBao means no renewer" do
    stub = start(token_ttl: 0, renewable: false)

    log =
      capture_log(fn ->
        pid = start_supervised!({TokenRenewer, name: nil})
        TokenRenewer.check(pid)
        assert TokenRenewer.status(pid).ttl == 0
      end)

    refute log =~ "not renewable"
    assert renewals(stub) == 0

    Enum.each(@env, &System.delete_env/1)
    assert TokenRenewer.start_link(name: nil) == :ignore
  end
end
