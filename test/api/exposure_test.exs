defmodule OptimalEngine.API.ExposureTest do
  @moduledoc """
  An API with authentication off on a network interface is reported: an error
  log line at boot and every 10 minutes, and the `auth_open_on_network` warning
  in /api/health. With the refusal on (OPTIMAL_REFUSE_OPEN_NETWORK) it does not
  start. Loopback with authentication off is the trusted local mode and stays
  quiet.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias OptimalEngine.API.{Endpoint, Exposure, ExposureMonitor, Router}
  alias OptimalEngine.Health

  setup do
    api = Application.get_env(:optimal_engine, :api, [])
    auth = Application.get_env(:optimal_engine, :auth, [])
    refuse = Application.fetch_env(:optimal_engine, :refuse_open_network)

    on_exit(fn ->
      Application.put_env(:optimal_engine, :api, api)
      Application.put_env(:optimal_engine, :auth, auth)

      case refuse do
        {:ok, value} -> Application.put_env(:optimal_engine, :refuse_open_network, value)
        :error -> Application.delete_env(:optimal_engine, :refuse_open_network)
      end
    end)

    %{auth: auth}
  end

  # The API configured on `interface` with authentication off. Endpoint.children/0
  # only returns child specs, so nothing listens.
  defp listen(ctx, interface) do
    Application.put_env(:optimal_engine, :api, enabled: true, port: 4999, interface: interface)
    Application.put_env(:optimal_engine, :auth, Keyword.put(ctx.auth, :auth_required, false))
  end

  defp health do
    conn(:get, "/api/health")
    |> Router.call(Router.init([]))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  test "only an enabled API beyond loopback with authentication off is open" do
    for interface <- ["127.0.0.1", "127.0.0.2", "::1", "localhost"] do
      assert Exposure.open_interface([enabled: true, interface: interface], auth_required: false) ==
               nil
    end

    assert Exposure.open_interface([enabled: true, interface: "0.0.0.0"], auth_required: true) ==
             nil

    assert Exposure.open_interface([enabled: false, interface: "0.0.0.0"], auth_required: false) ==
             nil

    assert Exposure.open_interface([enabled: true, interface: "0.0.0.0"], auth_required: false) ==
             "0.0.0.0"

    assert Exposure.open_interface([enabled: true, interface: "10.1.2.3"], []) == "10.1.2.3"
  end

  test "an open API logs the error at boot and is watched", ctx do
    listen(ctx, "0.0.0.0")

    log =
      capture_log(fn ->
        assert {ExposureMonitor, interface: "0.0.0.0"} in Endpoint.children()
      end)

    assert log =~ "API is open: auth is off on 0.0.0.0; set OPTIMAL_AUTH_REQUIRED=true"
  end

  test "the error repeats on the watcher's interval" do
    log =
      capture_log(fn ->
        {:ok, pid} = ExposureMonitor.start_link(interface: "0.0.0.0", interval_ms: 20, name: nil)
        Process.sleep(110)
        GenServer.stop(pid)
      end)

    repeats = length(String.split(log, "API is open: auth is off on 0.0.0.0")) - 1
    assert repeats >= 3
  end

  test "/api/health warns auth_open_on_network while the API is open", ctx do
    listen(ctx, "0.0.0.0")

    # The credential check depends on the connectors other tests register, so
    # it is skipped here: with everything else healthy, the open API alone
    # degrades the Engine.
    report = Health.ready(skip: [:embedder, :credential_key])
    assert :network_auth in report.degraded
    assert Health.warnings(report) == ["auth_open_on_network"]
    assert Health.status_of(report) == :degraded

    body = health()
    assert "auth_open_on_network" in body["warnings"]
    assert "network_auth" in body["degraded"]
    refute body["status"] == "up"
  end

  test "a loopback Engine with authentication off is neither warned nor watched", ctx do
    listen(ctx, "127.0.0.1")

    log =
      capture_log(fn ->
        refute Enum.any?(Endpoint.children(), &match?({ExposureMonitor, _}, &1))
      end)

    refute log =~ "API is open"
    refute "auth_open_on_network" in health()["warnings"]
  end

  test "with the refusal on, an open API does not start; a loopback one does", ctx do
    Application.put_env(:optimal_engine, :refuse_open_network, true)
    listen(ctx, "0.0.0.0")

    error = assert_raise ArgumentError, fn -> Endpoint.children() end
    assert error.message =~ "API is open: auth is off on 0.0.0.0; set OPTIMAL_AUTH_REQUIRED=true"
    assert error.message =~ "OPTIMAL_REFUSE_OPEN_NETWORK"

    listen(ctx, "127.0.0.1")
    assert [_cowboy] = Endpoint.children()
  end
end
