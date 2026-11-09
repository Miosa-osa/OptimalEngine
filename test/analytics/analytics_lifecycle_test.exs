defmodule OptimalEngine.AnalyticsLifecycleTest do
  @moduledoc """
  Analytics files follow their workspace out: archiving removed them since
  #224; a finished move, a discarded import's workspace record and any other
  way a workspace stops being active (the daily prune) remove them too.

  The Engine-wide metrics export (`Export.run_engine/0`) holds the Engine's
  own samples only (the `"engine"` scope, the Telemetry metric names, the
  `quantile` label), in a directory no workspace query can read, and its
  routes need `admin` on a key that is not restricted to named workspaces.

  These run against the fake executable (`OptimalEngine.TestSupport.DuckDBFake`).
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.{Analyses, Analytics, Store, Workspace}
  alias OptimalEngine.Analytics.Export
  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Storage.DuckDB
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.DuckDBFake

  setup do
    n = System.unique_integer([:positive])
    tenant = "analytics-life-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Analytics #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    previous = System.get_env(DuckDB.env_name())
    {_dir, restore} = DuckDBFake.install()
    root = Path.join(System.tmp_dir!(), "optimal-analytics-life-#{n}")
    File.mkdir_p!(root)
    log = Path.join(root, "fake.log")
    System.put_env(DuckDB.env_name(), root)
    System.put_env("DUCKDB_FAKE_LOG", log)

    on_exit(fn ->
      restore.()
      File.rm_rf!(root)
      System.delete_env("DUCKDB_FAKE_LOG")
      System.delete_env("DUCKDB_FAKE_ROWS")

      if previous,
        do: System.put_env(DuckDB.env_name(), previous),
        else: System.delete_env(DuckDB.env_name())
    end)

    %{tenant: tenant, root: root, log: log, n: n}
  end

  defp workspace(ctx, slug) do
    {:ok, workspace} =
      Workspace.create(%{
        tenant_id: ctx.tenant,
        organization_id: "#{ctx.tenant}:org",
        slug: slug,
        name: slug
      })

    workspace.id
  end

  defp sample(tenant, workspace, name, labels \\ "{}") do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO metric_samples (tenant_id, workspace_id, metric_name, metric_kind, value, labels, recorded_at) VALUES (?1, ?2, ?3, 'gauge', 4.5, ?4, '2026-11-01 10:00:00')",
        [tenant, workspace, name, labels]
      )
  end

  defp exported!(ctx, workspace) do
    sample(ctx.tenant, workspace, "x.latency")
    {:ok, _} = Export.run(ctx.tenant, workspace)
    dir = Analytics.workspace_dir(ctx.root, workspace)
    assert File.regular?(Path.join(dir, "metrics.parquet"))
    dir
  end

  describe "removing a workspace" do
    test "a finished move removes its analytics, and no other workspace's", ctx do
      moving = workspace(ctx, "moving")
      staying = workspace(ctx, "staying")
      dir = exported!(ctx, moving)
      other = exported!(ctx, staying)

      path = Path.join(System.tmp_dir!(), "analytics-move-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, moving, path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, moving, manifest["bundle_sha256"])

      assert {:ok, result} =
               WorkspaceBundle.finalize_move(ctx.tenant, moving, manifest["bundle_sha256"], %{
                 "target_url" => "https://target.example"
               })

      assert result.analytics_purged == :ok
      refute File.exists?(dir)
      assert File.regular?(Path.join(other, "metrics.parquet"))
    end

    test "discarding an import's workspace record removes its analytics", ctx do
      gone = workspace(ctx, "imported")
      dir = exported!(ctx, gone)
      {:ok, _} = Store.raw_query("DELETE FROM metric_samples WHERE workspace_id = ?1", [gone])

      log = Path.join(ctx.root, "no-such-written-log")
      assert :ok = WorkspaceBundle.discard_written(log, ctx.tenant, gone, record: true)

      assert {:ok, []} = Store.raw_query("SELECT 1 FROM workspaces WHERE id = ?1", [gone])
      refute File.exists?(dir)
    end

    test "the prune removes the analytics of every workspace that is not active", ctx do
      kept = workspace(ctx, "kept")
      archived = workspace(ctx, "archived")
      kept_dir = exported!(ctx, kept)
      archived_dir = exported!(ctx, archived)

      # A row removed by any path at all: deleted outright, or archived
      # without the purge (a store edited by hand, a purge that failed).
      {:ok, _} =
        Store.raw_query("UPDATE workspaces SET status = 'archived' WHERE id = ?1", [archived])

      deleted_dir = Analytics.workspace_dir(ctx.root, "#{ctx.tenant}:deleted")
      File.mkdir_p!(deleted_dir)
      File.write!(Path.join(deleted_dir, "metrics.parquet"), "x")

      assert {:ok, %{removed: removed}} = Analytics.prune_removed()
      assert removed >= 2

      assert File.regular?(Path.join(kept_dir, "metrics.parquet"))
      refute File.exists?(archived_dir)
      refute File.exists?(deleted_dir)
    end

    test "the prune never touches the Engine-wide directory", ctx do
      assert {:ok, _} = Export.run_engine()
      assert {:ok, _} = Analytics.prune_removed()
      assert File.regular?(Path.join(Analytics.engine_dir(ctx.root), "metrics.parquet"))
    end
  end

  describe "the Engine-wide metrics export" do
    test "holds the Engine's own samples only: no workspace's, no other name, no other label",
         ctx do
      ws = workspace(ctx, "private")
      sample(ctx.tenant, ws, "optimal_engine.search.query")
      sample("default", "engine", "optimal_engine.search.query")
      sample("default", "engine", "optimal_engine.search.latency_ms", ~s({"quantile":"0.95"}))

      sample(
        "default",
        "engine",
        "optimal_engine.uptime_ms",
        ~s({"workspace_id":"#{ws}","quantile":"0.5"})
      )

      sample("default", "engine", "leak.#{ctx.tenant}.private")

      assert {:ok, result} = Export.run_engine()
      # Other tests and the sampler may have written Engine samples of their own.
      assert result.datasets["metrics"].rows >= 3

      dir = Analytics.engine_dir(ctx.root)
      assert result.path == dir
      refute String.starts_with?(dir, Path.join(Path.expand(ctx.root), "workspaces"))

      exported = File.read!(Path.join(dir, "metrics.parquet"))
      assert exported =~ "optimal_engine.search.query"
      assert exported =~ "0.95"
      refute exported =~ ctx.tenant
      refute exported =~ "leak."
      refute exported =~ "workspace_id"
    end

    test "is queried locked to its own directory, and answers metrics only", ctx do
      assert {:ok, _} = Export.run_engine()
      File.write!(ctx.log, "")
      System.put_env("DUCKDB_FAKE_ROWS", ~s([{"bucket":"2026-11-01T00:00:00Z","samples":1}]))

      assert {:ok, answer} = Analytics.query_engine(%{"dataset" => "metrics", "bucket" => "day"})
      assert answer.rows == [%{"bucket" => "2026-11-01T00:00:00Z", "samples" => 1}]

      dir = Analytics.engine_dir(ctx.root)
      [sql] = File.read!(ctx.log) |> String.split("\n", trim: true)
      assert sql =~ "SET allowed_directories = ['#{dir}/']"
      assert sql =~ "read_parquet('#{dir}/metrics.parquet')"

      assert {:error, {:invalid_parameter, "dataset", _}} =
               Analytics.query_engine(%{"dataset" => "usage"})
    end

    test "a workspace called engine reads its own directory, never the Engine's", ctx do
      assert {:ok, _} = Export.run_engine()
      refute Analytics.workspace_dir(ctx.root, "engine") == Analytics.engine_dir(ctx.root)
      assert {:error, :not_exported} = Analytics.query("engine", %{"dataset" => "metrics"})
    end

    test "is scheduled once a day for the whole Engine, not once per tenant" do
      {:ok, before} = Store.raw_query("SELECT id FROM jobs", [])
      today = Date.utc_today()

      try do
        Analyses.schedule(today)
        Analyses.schedule(today)

        assert {:ok, [[1]]} =
                 Store.raw_query(
                   "SELECT COUNT(*) FROM jobs WHERE kind = ?1 AND idempotency_key = ?2",
                   [
                     "analysis.analytics_engine_export",
                     "analysis:analytics_engine_export:#{Date.to_iso8601(today)}"
                   ]
                 )
      after
        {:ok, now} = Store.raw_query("SELECT id FROM jobs", [])
        for [id] <- now -- before, do: Store.raw_execute("DELETE FROM jobs WHERE id = ?1", [id])
      end
    end

    test "running it as an analysis exports the Engine's metrics and prunes", ctx do
      gone = Analytics.workspace_dir(ctx.root, "#{ctx.tenant}:gone")
      File.mkdir_p!(gone)
      home = workspace(ctx, "home")

      assert {:ok, %{outcome: :completed}} =
               Analyses.run_now(ctx.tenant, home, "analytics_engine_export")

      assert File.regular?(Path.join(Analytics.engine_dir(ctx.root), "metrics.parquet"))
      refute File.exists?(gone)
    end
  end

  describe "the Engine-wide routes" do
    setup ctx do
      ws = workspace(ctx, "routes")
      {:ok, _} = Export.run_engine()

      mint = fn scopes, workspaces ->
        {:ok, %{key: key}} =
          ApiKey.mint(%{
            tenant_id: ctx.tenant,
            name: "k",
            scopes: scopes,
            workspace_scope: workspaces
          })

        key
      end

      %{
        reader: mint.(["read"], ["*"]),
        narrow_admin: mint.(["admin"], [ws]),
        admin: mint.(["admin"], ["*"])
      }
    end

    defp call(path, key) do
      conn = conn(:get, path)
      conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
      conn = Router.call(conn, Router.init([]))
      {conn.status, Jason.decode!(conn.resp_body)}
    end

    defp with_auth_required(fun) do
      original = Application.get_env(:optimal_engine, :auth, [])

      Application.put_env(
        :optimal_engine,
        :auth,
        Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
      )

      try do
        fun.()
      after
        Application.put_env(:optimal_engine, :auth, original)
      end
    end

    test "need admin on a key not restricted to named workspaces", ctx do
      System.put_env("DUCKDB_FAKE_ROWS", ~s([{"bucket":"2026-11-01T00:00:00Z","samples":1}]))

      with_auth_required(fn ->
        for path <- ["/api/analytics/engine", "/api/analytics/engine/query?dataset=metrics"] do
          assert {401, _} = call(path, nil)
          assert {403, _} = call(path, ctx.reader)
          assert {403, %{"error" => "workspace_scope_denied"}} = call(path, ctx.narrow_admin)
        end

        assert {200, %{"exported_at" => at, "datasets" => %{"metrics" => _}}} =
                 call("/api/analytics/engine", ctx.admin)

        assert is_binary(at)

        assert {200, %{"rows" => [%{"samples" => 1}], "scope" => "engine"}} =
                 call("/api/analytics/engine/query?dataset=metrics&bucket=hour", ctx.admin)

        assert {400, %{"error" => "invalid_parameter"}} =
                 call("/api/analytics/engine/query?dataset=usage", ctx.admin)
      end)
    end
  end
end
