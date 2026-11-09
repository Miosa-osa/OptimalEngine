defmodule OptimalEngine.API.PrometheusAccessTest do
  @moduledoc """
  `GET /api/metrics/prometheus` exposes counters for the whole Engine, across
  every tenant. It is for the Engine operator (an admin key of the default
  tenant whose workspace scope is `*`) or a scraper that holds the metrics
  token `OPTIMAL_METRICS_TOKEN`, which is resolved through `OptimalEngine.Secrets`
  and so may be an OpenBao reference. On an Engine that requires no key, a
  request without one (an in-guest local scrape) still gets the counters.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Secrets
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.OpenBaoStub

  @path "/api/metrics/prometheus"
  @env ~w(OPTIMAL_METRICS_TOKEN OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_KV_MOUNT)

  setup do
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    previous_auth = Application.get_env(:optimal_engine, :auth, [])
    Application.put_env(:optimal_engine, :auth, Keyword.put(previous_auth, :auth_required, true))

    on_exit(fn ->
      Application.put_env(:optimal_engine, :auth, previous_auth)
      Secrets.flush_cache()

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    n = System.unique_integer([:positive])
    tenant = "prom-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Prometheus #{n}"})

    mint = fn tenant_id, scopes, workspaces ->
      {:ok, %{key: key}} =
        ApiKey.mint(%{
          tenant_id: tenant_id,
          name: "prom #{n}",
          scopes: scopes,
          workspace_scope: workspaces
        })

      key
    end

    default = Tenant.default_id()

    %{
      n: n,
      foreign_reader: mint.(tenant, ["read"], ["*"]),
      foreign_admin: mint.(tenant, ["*"], ["*"]),
      default_reader: mint.(default, ["read"], ["*"]),
      scoped_admin: mint.(default, ["*"], ["default:prom-#{n}"]),
      operator: mint.(default, ["*"], ["*"])
    }
  end

  defp scrape(token, path \\ @path) do
    conn = conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, Router.init([]))
  end

  defp error(resp), do: Jason.decode!(resp.resp_body)["error"]

  describe "API keys" do
    test "another tenant's read key is refused", ctx do
      resp = scrape(ctx.foreign_reader)
      assert resp.status == 403
      refute resp.resp_body =~ "optimal_engine_uptime_seconds"
    end

    test "another tenant's admin key is refused as not the Engine operator", ctx do
      resp = scrape(ctx.foreign_admin)
      assert resp.status == 403
      assert error(resp) == "operator_only"
    end

    test "a read key of the default tenant is refused", ctx do
      resp = scrape(ctx.default_reader)
      assert resp.status == 403
      assert error(resp) == "permission_scope_denied"
    end

    test "a default-tenant admin key limited to some workspaces is refused", ctx do
      resp = scrape(ctx.scoped_admin)
      assert resp.status == 403
      assert error(resp) == "operator_only"
    end

    test "the Engine operator gets the counters", ctx do
      resp = scrape(ctx.operator)
      assert resp.status == 200
      assert resp.resp_body =~ "optimal_engine_uptime_seconds"
    end

    test "a request without a key is refused when the Engine requires one" do
      assert scrape(nil).status == 401
    end
  end

  describe "the metrics token" do
    test "OPTIMAL_METRICS_TOKEN gets the counters, and a different token does not" do
      token = "metrics-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      System.put_env("OPTIMAL_METRICS_TOKEN", token)

      resp = scrape(token)
      assert resp.status == 200
      assert resp.resp_body =~ "optimal_engine_uptime_seconds"

      assert scrape(token <> "x").status == 401
      assert scrape("metrics-wrong").status == 401
    end

    test "the token opens no other route" do
      token = "metrics-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      System.put_env("OPTIMAL_METRICS_TOKEN", token)

      for path <- ["/api/metrics", "/api/status", "/api/maintenance/log"] do
        assert scrape(token, path).status == 401, path
      end
    end

    test "an unset or blank token admits nobody" do
      System.put_env("OPTIMAL_METRICS_TOKEN", "   ")
      assert scrape("").status == 401
      assert scrape("   ").status == 401
    end

    test "the token may be an OpenBao reference, read through Secrets" do
      {:ok, stub} = OpenBaoStub.start()
      on_exit(fn -> OpenBaoStub.stop(stub) end)

      token = "metrics-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      OpenBaoStub.put_secret(stub, "optimal/metrics", %{"token" => token})
      System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
      System.put_env("OPTIMAL_OPENBAO_TOKEN", stub.token)
      System.put_env("OPTIMAL_METRICS_TOKEN", "openbao:optimal/metrics#token")

      assert scrape(token).status == 200
      # The reference itself is not the token.
      assert scrape("openbao:optimal/metrics#token").status == 401
    end

    test "an operator key still works while the token is set", ctx do
      System.put_env("OPTIMAL_METRICS_TOKEN", "metrics-" <> Integer.to_string(ctx.n))
      assert scrape(ctx.operator).status == 200
    end
  end

  describe "GET /api/metrics" do
    @engine_wide ~w(counters histograms uptime_ms sizing gauges)

    # A failing connector of the default tenant: its id, kind and error text.
    defp failing_connector!(ctx) do
      id = "prom-failing-#{ctx.n}"
      error = "zqsecretfailure#{ctx.n}xv"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO connectors (id, tenant_id, workspace_id, kind, config, enabled) VALUES (?1, 'default', 'default', 'sources_folder', '{}', 1)",
          [id]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO connector_runs (tenant_id, workspace_id, connector_id, started_at, completed_at, status, error_detail) VALUES ('default', 'default', ?1, datetime('now'), datetime('now'), 'error', ?2)",
          [id, error]
        )

      on_exit(fn ->
        Store.raw_query("DELETE FROM connector_runs WHERE connector_id = ?1", [id])
        Store.raw_query("DELETE FROM connectors WHERE id = ?1", [id])
      end)

      {id, error}
    end

    test "another tenant's key sees none of this tenant's connectors", ctx do
      {id, error} = failing_connector!(ctx)

      # The operator (default tenant) sees it, so the row is one the summary reads.
      operator = scrape(ctx.operator, "/api/metrics").resp_body
      assert operator =~ id

      for key <- [ctx.foreign_reader, ctx.foreign_admin] do
        resp = scrape(key, "/api/metrics")
        body = Jason.decode!(resp.resp_body)
        assert body["connectors"]["total"] == 0
        assert body["connectors"]["failing_connectors"] == []
        refute resp.resp_body =~ id
        refute resp.resp_body =~ error
      end
    end

    test "another tenant's key gets its connectors and no Engine-wide field", ctx do
      for key <- [ctx.foreign_reader, ctx.foreign_admin, ctx.default_reader, ctx.scoped_admin] do
        resp = scrape(key, "/api/metrics")
        assert resp.status == 200
        body = Jason.decode!(resp.resp_body)
        assert Map.has_key?(body, "connectors")
        for field <- @engine_wide, do: refute(Map.has_key?(body, field), field)
      end
    end

    test "the Engine operator gets the Engine-wide fields", ctx do
      body = Jason.decode!(scrape(ctx.operator, "/api/metrics").resp_body)
      for field <- ["connectors" | @engine_wide], do: assert(Map.has_key?(body, field), field)
    end
  end

  describe "GET /api/health and /api/status" do
    test "another tenant's key gets the status and fixed codes, not the checks", ctx do
      for path <- ["/api/health", "/api/status"], key <- [ctx.foreign_reader, ctx.default_reader] do
        resp = scrape(key, path)
        assert resp.status == 200
        body = Jason.decode!(resp.resp_body)
        assert body["status"] in ["up", "degraded", "down"]
        assert is_boolean(body["ok?"])
        assert is_list(body["warnings"])
        refute Map.has_key?(body, "checks"), path
      end
    end

    test "the Engine operator gets the checks", ctx do
      for path <- ["/api/health", "/api/status"] do
        body = Jason.decode!(scrape(ctx.operator, path).resp_body)
        assert is_map(body["checks"]), path
      end
    end
  end

  test "an Engine that requires no key serves a request without one (in-guest scrape)" do
    auth = Application.get_env(:optimal_engine, :auth, [])
    Application.put_env(:optimal_engine, :auth, Keyword.put(auth, :auth_required, false))

    resp = scrape(nil)
    assert resp.status == 200
    assert resp.resp_body =~ "optimal_engine_uptime_seconds"
  end
end
