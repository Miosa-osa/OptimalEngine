defmodule OptimalEngine.AnalyticsTest do
  @moduledoc """
  Analytics on DuckDB and Parquet: the export rebuilds one workspace's
  metrics, sync runs, ledger and usage as Parquet files under
  `OPTIMAL_ANALYTICS_PATH`, and the query route answers fixed, parameterized
  questions over them with DuckDB locked to that workspace's directory.

  These run against the fake executable (`OptimalEngine.TestSupport.DuckDBFake`),
  which records every statement; `analytics_duckdb_test.exs` runs the same
  paths against a real `duckdb`.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.{Analyses, Analytics, Jobs, Store, Workspace}
  alias OptimalEngine.Analytics.{Export, Slots}
  alias OptimalEngine.API.{AnalyticsAPI, Router}
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Storage.DuckDB
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.DuckDBFake

  setup do
    n = System.unique_integer([:positive])
    tenant = "analytics-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Analytics #{n}"})
    workspace = "#{tenant}:ops"
    other = "#{tenant}:other"

    for {id, slug} <- [{workspace, "ops"}, {other, "other"}] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?3, 'active', '{}')",
          [id, tenant, slug]
        )
    end

    previous = System.get_env(DuckDB.env_name())
    {_dir, restore} = DuckDBFake.install()
    root = Path.join(System.tmp_dir!(), "optimal-analytics-test-#{n}")
    File.mkdir_p!(root)
    log = Path.join(root, "fake.log")
    System.put_env(DuckDB.env_name(), root)
    System.put_env("DUCKDB_FAKE_LOG", log)

    on_exit(fn ->
      restore.()
      File.rm_rf!(root)
      System.delete_env("DUCKDB_FAKE_LOG")
      System.delete_env("DUCKDB_FAKE_ROWS")
      System.delete_env("DUCKDB_FAKE_FAIL")

      if previous,
        do: System.put_env(DuckDB.env_name(), previous),
        else: System.delete_env(DuckDB.env_name())
    end)

    %{tenant: tenant, workspace: workspace, other: other, root: root, log: log, n: n}
  end

  defp seed(ctx, workspace, tag) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO metric_samples (tenant_id, workspace_id, metric_name, metric_kind, value, labels, recorded_at) VALUES (?1, ?2, ?3, 'gauge', 4.5, '{}', '2026-11-01 10:00:00')",
        [ctx.tenant, workspace, "#{tag}.latency"]
      )

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_runs (tenant_id, workspace_id, peer_id, started_at, finished_at, status, pulled, pushed, conflicts, gated, message)
        VALUES (?1, ?2, ?3, '2026-11-01T10:00:00Z', '2026-11-01T10:00:02Z', 'ok', 3, 1, 0, 0, 'secret peer message')
        """,
        [ctx.tenant, workspace, "peer-#{tag}"]
      )

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_mutations (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload, payload_hash, idempotency_key, occurred_at)
        VALUES (?1, ?2, ?3, 'device-x', 'contexts', ?4, 'update', '{"title":"private"}', 'h', ?1, '2026-11-01T10:05:00Z')
        """,
        ["mut-#{tag}-#{ctx.n}", ctx.tenant, workspace, "entity-#{tag}-secret"]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO events (tenant_id, workspace_id, ts, principal, kind, target_uri, latency_ms, metadata) VALUES (?1, ?2, '2026-11-01 10:00:00', 'person@example.com', ?3, 'optimal://private', 12, '{}')",
        [ctx.tenant, workspace, "#{tag}.search"]
      )
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)

  describe "the export" do
    test "rebuilds the workspace's datasets as Parquet files, and nothing of another workspace",
         ctx do
      seed(ctx, ctx.workspace, "mine")
      seed(ctx, ctx.other, "theirs")

      assert {:ok, result} = Export.run(ctx.tenant, ctx.workspace)
      dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
      assert result.path == dir

      for dataset <- Analytics.datasets() do
        assert File.exists?(Path.join(dir, dataset <> ".parquet")), dataset
        assert result.datasets[dataset].rows == 1, dataset
      end

      # The fake copies the NDJSON the Engine wrote, so the files show what was exported.
      all = Enum.map_join(Analytics.datasets(), "\n", &File.read!(Path.join(dir, &1 <> ".parquet")))
      assert all =~ "mine.latency"
      assert all =~ "peer-mine"
      assert all =~ "mine.search"
      refute all =~ "theirs"

      # Payloads, entity ids, messages, principals and targets never leave the store.
      for secret <- ["private", "entity-mine-secret", "secret peer message", "person@example.com"] do
        refute all =~ secret, secret
      end

      [ledger] = lines(Path.join(dir, "ledger.parquet"))

      assert Jason.decode!(ledger) == %{
               "occurred_at" => "2026-11-01 10:05:00",
               "entity_type" => "contexts",
               "operation" => "update",
               "origin" => "peer"
             }

      manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["workspace_id"] == ctx.workspace
      assert manifest["datasets"]["metrics"]["rows"] == 1
      assert is_binary(manifest["exported_at"])

      # Staging is gone, and every statement ran locked to the staging directory.
      assert dir |> File.ls!() |> Enum.sort() ==
               Enum.sort(["manifest.json" | Enum.map(Analytics.datasets(), &(&1 <> ".parquet"))])

      for sql <- lines(ctx.log) do
        assert sql =~ "SET enable_external_access = false"
        assert sql =~ "SET lock_configuration = true"
        assert sql =~ "SET allowed_directories = ['#{dir}/.staging-"
      end
    end

    test "a second export replaces the files with what the store holds now", ctx do
      seed(ctx, ctx.workspace, "mine")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)

      {:ok, _} =
        Store.raw_query("DELETE FROM metric_samples WHERE workspace_id = ?1", [ctx.workspace])

      assert {:ok, result} = Export.run(ctx.tenant, ctx.workspace)
      assert result.datasets["metrics"].rows == 0
      dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
      assert File.read!(Path.join(dir, "metrics.parquet")) == ""
    end

    test "a failing duckdb fails the export clearly and keeps the previous files", ctx do
      seed(ctx, ctx.workspace, "mine")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
      dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
      before = File.read!(Path.join(dir, "metrics.parquet"))

      System.put_env("DUCKDB_FAKE_FAIL", "1")
      assert {:error, {:export_failed, failed}} = Export.run(ctx.tenant, ctx.workspace)
      assert Enum.sort(Map.keys(failed)) == Enum.sort(Analytics.datasets())
      assert File.read!(Path.join(dir, "metrics.parquet")) == before
      refute dir |> File.ls!() |> Enum.any?(&String.starts_with?(&1, ".staging-"))
    end

    test "without OPTIMAL_ANALYTICS_PATH there is nothing to export", ctx do
      System.delete_env(DuckDB.env_name())
      assert {:error, :not_configured} = Export.run(ctx.tenant, ctx.workspace)
    end

    test "a workspace of another tenant is not exported", ctx do
      assert {:error, :workspace_not_found} = Export.run("someone-else", ctx.workspace)
    end
  end

  describe "the workspace directory" do
    test "is one directory per workspace under the analytics path, never a path from the id" do
      assert Analytics.workspace_dir("/data/analytics", "acme:sales") ==
               "/data/analytics/workspaces/acme~sales"

      assert Analytics.workspace_dir("/data/analytics", "default") ==
               "/data/analytics/workspaces/default"

      for bad <- ["../etc", "a/b", "a:b:c", "", ".hidden", "a..b"] do
        assert_raise ArgumentError, fn -> Analytics.workspace_dir("/data/analytics", bad) end
      end
    end
  end

  describe "the query" do
    setup ctx do
      seed(ctx, ctx.workspace, "mine")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
      File.write!(ctx.log, "")
      :ok
    end

    test "answers a named question over the workspace's own file, locked to its directory", ctx do
      System.put_env("DUCKDB_FAKE_ROWS", ~s([{"bucket":"2026-11-01T00:00:00Z","samples":1}]))

      assert {:ok, answer} =
               Analytics.query(ctx.workspace, %{
                 "dataset" => "metrics",
                 "bucket" => "day",
                 "metric" => "mine.latency",
                 "from" => "2026-10-01",
                 "to" => "2026-11-30T00:00:00Z",
                 "limit" => "10"
               })

      assert answer.rows == [%{"bucket" => "2026-11-01T00:00:00Z", "samples" => 1}]
      assert answer.dataset == "metrics"
      assert answer.bucket == "day"
      assert is_binary(answer.exported_at)

      dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
      [sql] = lines(ctx.log)
      assert sql =~ "SET allowed_directories = ['#{dir}/']"
      assert sql =~ "SET enable_external_access = false"
      assert sql =~ "SET lock_configuration = true"
      assert sql =~ "read_parquet('#{dir}/metrics.parquet')"
      assert sql =~ "metric_name = 'mine.latency'"
      assert sql =~ "recorded_at >= TIMESTAMP '2026-10-01 00:00:00'"
      assert sql =~ "recorded_at < TIMESTAMP '2026-11-30 00:00:00'"
      assert sql =~ "date_trunc('day', recorded_at)"
      assert sql =~ "LIMIT 10"
    end

    test "every statement spills to a temp directory inside the directory it is locked to",
         ctx do
      {:ok, _} = Analytics.query(ctx.workspace, %{"dataset" => "usage"})
      dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
      [sql] = lines(ctx.log)

      assert [_, temp] = Regex.run(~r/SET temp_directory = '([^']+)'/, sql)
      assert String.starts_with?(temp, dir <> "/~duckdb-tmp-")

      # Set while external access is still on, so DuckDB takes it, and locked with the rest.
      [before_lock, _] = String.split(sql, "SET enable_external_access = false", parts: 2)
      assert before_lock =~ "SET temp_directory"

      # The spill directory goes with the statement.
      refute dir |> File.ls!() |> Enum.any?(&String.starts_with?(&1, "~duckdb-tmp-"))

      # An export spills inside its staging directory, which it removes.
      File.write!(ctx.log, "")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)

      for sql <- lines(ctx.log) do
        assert [_, temp] = Regex.run(~r/SET temp_directory = '([^']+)'/, sql)
        assert temp =~ ~r{^#{Regex.escape(dir)}/\.staging-[0-9a-f]+/~duckdb-tmp-}
      end
    end

    test "every dataset has its question", ctx do
      for dataset <- Analytics.datasets() do
        assert {:ok, %{rows: []}} = Analytics.query(ctx.workspace, %{"dataset" => dataset}),
               dataset
      end
    end

    test "parameters are validated, never spliced", ctx do
      bad = [
        %{"dataset" => "contexts"},
        %{"dataset" => "../../etc/passwd"},
        %{"dataset" => "metrics", "bucket" => "second"},
        %{"dataset" => "metrics", "bucket" => "day'); COPY"},
        %{"dataset" => "metrics", "metric" => "x' OR '1'='1"},
        %{"dataset" => "metrics", "from" => "yesterday"},
        %{"dataset" => "metrics", "to" => "2026-13-45"},
        %{"dataset" => "sync_runs", "peer" => "p'; DROP"},
        %{"dataset" => "ledger", "origin" => "anywhere"},
        %{"dataset" => "ledger", "table" => "Contexts; --"},
        %{"dataset" => "usage", "kind" => "a b"},
        %{"dataset" => "metrics", "limit" => "0"},
        %{"dataset" => "metrics", "limit" => "ten"},
        %{"dataset" => "usage", "metric" => "x"}
      ]

      for params <- bad do
        assert {:error, {:invalid_parameter, _name, _why}} = Analytics.query(ctx.workspace, params),
               inspect(params)
      end

      assert lines(ctx.log) == []
    end

    test "a limit past the cap is capped", ctx do
      {:ok, _} = Analytics.query(ctx.workspace, %{"dataset" => "usage", "limit" => "999999"})
      [sql] = lines(ctx.log)
      assert sql =~ "LIMIT #{Analytics.max_limit()}"
    end

    test "a workspace never exported says so", ctx do
      assert {:error, :not_exported} = Analytics.query(ctx.other, %{"dataset" => "metrics"})
    end

    test "without the analytics path the query is not configured", ctx do
      System.delete_env(DuckDB.env_name())
      assert {:error, :not_configured} = Analytics.query(ctx.workspace, %{"dataset" => "metrics"})
    end
  end

  describe "routes" do
    setup ctx do
      seed(ctx, ctx.workspace, "mine")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)

      {:ok, %{key: reader}} =
        ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "reader",
          scopes: ["read"],
          workspace_scope: [ctx.workspace]
        })

      {:ok, %{key: admin}} =
        ApiKey.mint(%{tenant_id: ctx.tenant, name: "admin", scopes: ["*"], workspace_scope: ["*"]})

      %{reader: reader, admin: admin}
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

    defp call(method, path, key, body \\ nil) do
      conn =
        if body,
          do:
            conn(method, path, Jason.encode!(body))
            |> put_req_header("content-type", "application/json"),
          else: conn(method, path)

      conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
      conn = Router.call(conn, Router.init([]))
      {conn.status, Jason.decode!(conn.resp_body)}
    end

    test "GET /api/analytics/query answers a reader of the workspace", ctx do
      System.put_env("DUCKDB_FAKE_ROWS", ~s([{"bucket":"2026-11-01T00:00:00Z","events":1}]))

      with_auth_required(fn ->
        assert {200, body} =
                 call(
                   :get,
                   "/api/analytics/query?workspace=#{ctx.workspace}&dataset=usage&bucket=hour",
                   ctx.reader
                 )

        assert body["rows"] == [%{"bucket" => "2026-11-01T00:00:00Z", "events" => 1}]
        assert body["dataset"] == "usage"
        assert body["workspace"] == ctx.workspace
      end)
    end

    test "the query is authenticated and workspace scoped", ctx do
      with_auth_required(fn ->
        assert {401, _} =
                 call(:get, "/api/analytics/query?workspace=#{ctx.workspace}&dataset=usage", nil)

        assert {403, %{"error" => "workspace_scope_denied"}} =
                 call(:get, "/api/analytics/query?workspace=#{ctx.other}&dataset=usage", ctx.reader)

        {:ok, %{key: stranger}} =
          ApiKey.mint(%{tenant_id: "default", name: "s", scopes: ["*"], workspace_scope: ["*"]})

        assert {404, _} =
                 call(
                   :get,
                   "/api/analytics/query?workspace=#{ctx.workspace}&dataset=usage",
                   stranger
                 )
      end)
    end

    test "bad parameters are 400, an unexported workspace 404, no analytics path 503", ctx do
      with_auth_required(fn ->
        assert {400, %{"error" => "invalid_parameter", "parameter" => "dataset"}} =
                 call(:get, "/api/analytics/query?workspace=#{ctx.workspace}&dataset=x", ctx.admin)

        assert {404, %{"error" => "not_exported"}} =
                 call(:get, "/api/analytics/query?workspace=#{ctx.other}&dataset=usage", ctx.admin)

        System.delete_env(DuckDB.env_name())

        assert {503, %{"error" => "analytics_not_configured"}} =
                 call(
                   :get,
                   "/api/analytics/query?workspace=#{ctx.workspace}&dataset=usage",
                   ctx.admin
                 )
      end)
    end

    test "a workspace given as a list or a map is a 400, not a crash", ctx do
      paths = [
        "/api/analytics/query?workspace[]=#{ctx.workspace}&dataset=usage",
        "/api/analytics/query?workspace[]=#{ctx.workspace}&workspace[]=#{ctx.other}&dataset=usage",
        "/api/analytics?workspace[]=#{ctx.workspace}",
        "/api/analytics/query?workspace[a]=#{ctx.workspace}&dataset=usage"
      ]

      for path <- paths, key <- [nil, ctx.admin] do
        assert {400, body} = call(:get, path, key), path
        assert body["error"] in ["invalid workspace", "invalid_parameter"], path
      end

      with_auth_required(fn ->
        for path <- paths, key <- [ctx.reader, ctx.admin] do
          assert {status, _} = call(:get, path, key), path
          assert status in [400, 403], path
        end
      end)

      # The handler refuses one too, whatever runs before it.
      for {route, params} <- [
            {&AnalyticsAPI.query/1, %{"workspace" => [ctx.workspace], "dataset" => "usage"}},
            {&AnalyticsAPI.status/1, %{"workspace" => %{"a" => ctx.workspace}}}
          ] do
        conn = %{conn(:get, "/api/analytics") | query_params: params} |> route.()

        assert {400, %{"error" => "invalid_parameter", "parameter" => "workspace"}} =
                 {conn.status, Jason.decode!(conn.resp_body)}
      end

      assert {400, %{"error" => "invalid_parameter", "parameter" => "limit"}} =
               call(
                 :get,
                 "/api/analytics/query?workspace=#{ctx.workspace}&dataset=usage&limit[]=5",
                 ctx.admin
               )
    end

    test "a query past the cap on DuckDB processes is a 503 with Retry-After", ctx do
      System.put_env("OPTIMAL_ANALYTICS_MAX_PROCESSES", "1")
      holder = hold_slot()

      try do
        conn =
          conn(:get, "/api/analytics/query?workspace=#{ctx.workspace}&dataset=usage")
          |> put_req_header("authorization", "Bearer " <> ctx.admin)
          |> Router.call(Router.init([]))

        assert conn.status == 503
        assert %{"error" => "analytics_busy"} = Jason.decode!(conn.resp_body)
        assert [retry] = get_resp_header(conn, "retry-after")
        assert String.to_integer(retry) > 0
      after
        release_slot(holder)
        System.delete_env("OPTIMAL_ANALYTICS_MAX_PROCESSES")
      end

      assert {200, _} =
               call(
                 :get,
                 "/api/analytics/query?workspace=#{ctx.workspace}&dataset=usage",
                 ctx.admin
               )
    end

    test "GET /api/analytics reports the datasets and when they were exported", ctx do
      with_auth_required(fn ->
        assert {200, body} = call(:get, "/api/analytics?workspace=#{ctx.workspace}", ctx.reader)
        assert body["configured"] == true
        assert body["exported_at"]
        assert body["datasets"]["metrics"]["rows"] == 1
        assert Enum.sort(body["questions"] |> Map.keys()) == Enum.sort(Analytics.datasets())
        refute Jason.encode!(body) =~ ctx.root

        assert {200, %{"exported_at" => nil, "datasets" => %{}}} =
                 call(:get, "/api/analytics?workspace=#{ctx.other}", ctx.admin)
      end)
    end

    test "the export runs as an analysis, and running one needs admin", ctx do
      with_auth_required(fn ->
        assert {403, _} =
                 call(:post, "/api/analyses/run", ctx.reader, %{
                   "workspace" => ctx.workspace,
                   "kind" => "analytics_export"
                 })

        assert {200, %{"outcome" => "completed", "report" => report}} =
                 call(:post, "/api/analyses/run", ctx.admin, %{
                   "workspace" => ctx.workspace,
                   "kind" => "analytics_export"
                 })

        assert report["status"] == "ok"
        assert report["report"]["datasets"]["metrics"]["rows"] == 1
      end)
    end
  end

  describe "the provider inventory" do
    test "says DuckDB serves the workspace analytics while the path is set", _ctx do
      assert {:ok, duckdb} = OptimalEngine.Storage.Providers.get("duckdb")
      assert duckdb.serves == ["workspace_analytics"]
      assert duckdb.data_path == "serving"

      System.delete_env(DuckDB.env_name())
      assert {:ok, %{data_path: "standby"}} = OptimalEngine.Storage.Providers.get("duckdb")
    end
  end

  describe "the cap on DuckDB processes" do
    setup do
      on_exit(fn -> System.delete_env("OPTIMAL_ANALYTICS_MAX_PROCESSES") end)
      :ok
    end

    test "defaults to one process, for a 1 GiB guest, and reads OPTIMAL_ANALYTICS_MAX_PROCESSES" do
      System.delete_env("OPTIMAL_ANALYTICS_MAX_PROCESSES")
      assert Slots.limit() == 1
      System.put_env("OPTIMAL_ANALYTICS_MAX_PROCESSES", "3")
      assert Slots.limit() == 3

      for bad <- ["0", "-1", "many", ""] do
        System.put_env("OPTIMAL_ANALYTICS_MAX_PROCESSES", bad)
        assert Slots.limit() == 1, bad
      end
    end

    test "a query beyond the cap is refused at once, and never starts duckdb", ctx do
      seed(ctx, ctx.workspace, "mine")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
      File.write!(ctx.log, "")
      System.put_env("OPTIMAL_ANALYTICS_MAX_PROCESSES", "1")
      holder = hold_slot()

      assert {:error, :busy} = Analytics.query(ctx.workspace, %{"dataset" => "usage"})
      assert lines(ctx.log) == []

      release_slot(holder)
      assert {:ok, _} = Analytics.query(ctx.workspace, %{"dataset" => "usage"})
    end

    test "a slot whose holder died is free again", ctx do
      seed(ctx, ctx.workspace, "mine")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
      System.put_env("OPTIMAL_ANALYTICS_MAX_PROCESSES", "1")
      holder = hold_slot()
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert eventually(fn ->
               match?({:ok, _}, Analytics.query(ctx.workspace, %{"dataset" => "usage"}))
             end)
    end

    test "a query is answered while an export holds its own slot", ctx do
      seed(ctx, ctx.workspace, "mine")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
      System.put_env("OPTIMAL_ANALYTICS_MAX_PROCESSES", "1")
      exporting = hold_slot(:export)

      assert {:ok, _} = Analytics.query(ctx.workspace, %{"dataset" => "usage"})
      release_slot(exporting)
    end

    test "an export runs with a lower memory limit, spilling the rest to disk", ctx do
      seed(ctx, ctx.workspace, "mine")
      File.write!(ctx.log, "")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
      exports = lines(ctx.log)
      assert exports != []
      assert Enum.all?(exports, &(&1 =~ "SET memory_limit = '256MB'"))

      File.write!(ctx.log, "")
      {:ok, _} = Analytics.query(ctx.workspace, %{"dataset" => "usage"})
      assert Enum.all?(lines(ctx.log), &(&1 =~ "SET memory_limit = '512MB'"))
    end

    test "a boot removes the spill and staging directories a crash left behind", ctx do
      seed(ctx, ctx.workspace, "mine")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
      dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
      leftovers = for name <- ["~duckdb-tmp-0a1b2c", ".staging-3d4e5f"], do: Path.join(dir, name)
      Enum.each(leftovers, &File.mkdir_p!(Path.join(&1, "inside")))

      # As at boot: the slots server starts again and sweeps before any statement runs.
      :ok = Supervisor.terminate_child(OptimalEngine.Supervisor, Slots)
      {:ok, _} = Supervisor.restart_child(OptimalEngine.Supervisor, Slots)
      _ = Slots.limit()
      assert eventually(fn -> Enum.all?(leftovers, &(not File.exists?(&1))) end)
      assert File.exists?(Path.join(dir, "metrics.parquet"))
    end

    test "an export waits behind another export instead of failing", ctx do
      seed(ctx, ctx.workspace, "mine")
      holder = hold_slot(:export)
      export = Task.async(fn -> Export.run(ctx.tenant, ctx.workspace) end)
      refute Task.yield(export, 300)
      release_slot(holder)
      assert {:ok, %{datasets: %{"metrics" => %{rows: 1}}}} = Task.await(export, 10_000)
    end
  end

  describe "archiving a workspace" do
    test "removes its analytics directory, and no other workspace's", ctx do
      seed(ctx, ctx.workspace, "mine")
      seed(ctx, ctx.other, "theirs")
      {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
      {:ok, _} = Export.run(ctx.tenant, ctx.other)
      dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
      other_dir = Analytics.workspace_dir(ctx.root, ctx.other)
      assert File.dir?(dir)

      assert :ok = Workspace.archive(ctx.workspace)

      refute File.exists?(dir)
      assert File.exists?(Path.join(other_dir, "metrics.parquet"))
    end

    test "is not held up by analytics that are not configured", ctx do
      System.delete_env(DuckDB.env_name())
      assert :ok = Workspace.archive(ctx.workspace)
    end
  end

  # A process that holds one DuckDB slot until told to let it go.
  defp hold_slot(class \\ :query) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Slots.acquire(class, 0)
        send(test, {:holding, self()})

        receive do
          :release -> Slots.release()
        end

        send(test, {:released, self()})
      end)

    assert_receive {:holding, ^pid}, 1_000
    pid
  end

  defp release_slot(pid) do
    send(pid, :release)
    assert_receive {:released, ^pid}, 1_000
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  describe "scheduling" do
    test "the daily analyses export every active workspace while analytics is configured", ctx do
      try do
        Analyses.schedule(Date.utc_today(), tenant_id: ctx.tenant)
        {:ok, jobs} = Jobs.list(ctx.workspace)
        assert "analysis.analytics_export" in Enum.map(jobs, & &1.kind)

        System.delete_env(DuckDB.env_name())
        Analyses.schedule(Date.add(Date.utc_today(), 1), tenant_id: ctx.tenant)
        {:ok, jobs} = Jobs.list(ctx.workspace)
        assert Enum.count(jobs, &(&1.kind == "analysis.analytics_export")) == 1
      after
        # Scheduling is scoped to this test's tenant; the jobs it queued go.
        :ok = Store.raw_execute("DELETE FROM jobs WHERE tenant_id = ?1", [ctx.tenant])
      end
    end
  end
end
