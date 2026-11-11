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

  # Each captured line names the process that logged it (`said/3`).
  @own_log [format: "$metadata$message\n", metadata: [:pid]]

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    # The application's own renewer, if a test before left one running, reads
    # the same environment: it would renew against this test's stub and log
    # the same warnings. It goes first; restarted after with the environment
    # restored (which starts it as :ignore when OpenBao is not configured).
    OptimalEngine.Test.OpenBaoRenewer.stop_app_renewer()
    on_exit(&OptimalEngine.Test.OpenBaoRenewer.restart_app_renewer/0)
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

  # How many lines this renewer logged that contain `text`. Counted by the
  # logging process (the `pid` metadata), never the whole log: another
  # renewer (the application's own, started by an earlier test with OpenBao
  # configured) reads the same environment, reaches the same stub and may
  # log the same warning meanwhile.
  defp said(log, pid, text) do
    owner = "pid=" <> to_string(:erlang.pid_to_list(pid))

    log
    |> String.split("\n")
    |> Enum.count(&(String.contains?(&1, owner) and String.contains?(&1, text)))
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

    {pid, log} =
      with_log(@own_log, fn ->
        pid = start_supervised!({TokenRenewer, name: nil})
        Process.sleep(2_500)
        assert Process.alive?(pid)
        pid
      end)

    assert renewals(stub) <= 3
    assert said(log, pid, "stopped growing") == 1
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

    {pid, log} =
      with_log(@own_log, fn ->
        pid = start_supervised!({TokenRenewer, name: nil})
        TokenRenewer.check(pid)
        Process.sleep(1_200)
        pid
      end)

    assert renewals(stub) == 0
    assert said(log, pid, "too short to renew") == 1
    refute log =~ stub.token
  end

  test "a token that cannot be renewed is logged once, and never renewed" do
    stub = start(token_ttl: 3_600, renewable: false)

    {pid, log} =
      with_log(@own_log, fn ->
        pid = start_supervised!({TokenRenewer, name: nil})
        TokenRenewer.check(pid)
        TokenRenewer.check(pid)
        _ = TokenRenewer.status(pid)
        pid
      end)

    assert said(log, pid, "not renewable") == 1
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
