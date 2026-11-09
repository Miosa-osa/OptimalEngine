defmodule OptimalEngine.AnalyticsDuckDBTest do
  @moduledoc """
  Analytics against a real `duckdb` executable: the export writes Parquet
  DuckDB reads back, each question aggregates what the store holds, and the
  lockdown keeps a statement inside the workspace's directory.

  Runs only with `OPTIMAL_TEST_DUCKDB` naming the executable (`test_helper.exs`).
  """

  use ExUnit.Case, async: false

  @moduletag :duckdb

  alias OptimalEngine.{Analytics, Store}
  alias OptimalEngine.Analytics.Export
  alias OptimalEngine.Storage.DuckDB
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "analytics-real-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Analytics #{n}"})
    workspace = "#{tenant}:ops"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'ops', 'ops', 'active', '{}')",
        [workspace, tenant]
      )

    # The real executable first on the PATH, as the guest image puts it.
    bin = Path.join(System.tmp_dir!(), "duckdb-real-#{n}")
    File.mkdir_p!(bin)
    File.ln_s!(Path.expand(System.fetch_env!("OPTIMAL_TEST_DUCKDB")), Path.join(bin, "duckdb"))
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)

    root = Path.join(System.tmp_dir!(), "optimal-analytics-real-#{n}")
    File.mkdir_p!(root)
    previous = System.get_env(DuckDB.env_name())
    System.put_env(DuckDB.env_name(), root)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(bin)
      File.rm_rf!(root)

      if previous,
        do: System.put_env(DuckDB.env_name(), previous),
        else: System.delete_env(DuckDB.env_name())
    end)

    for {value, at} <- [
          {2.0, "2026-11-01 10:00:00"},
          {4.0, "2026-11-01 11:30:00"},
          {9.0, "2026-11-02 09:00:00"}
        ] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO metric_samples (tenant_id, workspace_id, metric_name, metric_kind, value, labels, recorded_at) VALUES (?1, ?2, 'search.latency', 'gauge', ?3, '{}', ?4)",
          [tenant, workspace, value, at]
        )
    end

    for {status, pulled} <- [{"ok", 3}, {"error", 0}] do
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO sync_runs (tenant_id, workspace_id, peer_id, started_at, finished_at, status, pulled, pushed, conflicts, gated)
          VALUES (?1, ?2, 'peer-a', '2026-11-01T10:00:00Z', '2026-11-01T10:00:02Z', ?3, ?4, 1, 0, 0)
          """,
          [tenant, workspace, status, pulled]
        )
    end

    for i <- 1..3 do
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO sync_mutations (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload_hash, idempotency_key, occurred_at)
          VALUES (?1, ?2, ?3, 'device-x', 'contexts', ?4, 'update', 'h', ?1, '2026-11-01T10:0#{i}:00Z')
          """,
          ["mut-real-#{n}-#{i}", tenant, workspace, "e#{i}"]
        )
    end

    for latency <- [10, 30] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO events (tenant_id, workspace_id, ts, principal, kind, latency_ms, metadata) VALUES (?1, ?2, '2026-11-01 10:00:00', 'p', 'search', ?3, '{}')",
          [tenant, workspace, latency]
        )
    end

    %{tenant: tenant, workspace: workspace, root: root}
  end

  test "the export writes Parquet and every question aggregates it", ctx do
    assert {:ok, result} = Export.run(ctx.tenant, ctx.workspace)
    assert result.datasets["metrics"].rows == 3
    assert result.datasets["sync_runs"].rows == 2
    assert result.datasets["ledger"].rows == 1
    assert result.datasets["usage"].rows == 1

    dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
    assert File.read!(Path.join(dir, "metrics.parquet")) |> binary_part(0, 4) == "PAR1"

    assert {:ok, %{rows: metrics}} =
             Analytics.query(ctx.workspace, %{"dataset" => "metrics", "bucket" => "day"})

    assert [
             %{"bucket" => "2026-11-02T00:00:00Z", "samples" => 1, "max" => 9.0},
             %{"bucket" => "2026-11-01T00:00:00Z", "samples" => 2, "avg" => 3.0, "min" => 2.0}
           ] = metrics

    assert {:ok, %{rows: [%{"samples" => 1}]}} =
             Analytics.query(ctx.workspace, %{
               "dataset" => "metrics",
               "from" => "2026-11-02",
               "metric" => "search.latency"
             })

    assert {:ok, %{rows: [run]}} = Analytics.query(ctx.workspace, %{"dataset" => "sync_runs"})

    assert %{
             "peer_id" => "peer-a",
             "runs" => 2,
             "ok" => 1,
             "error" => 1,
             "pulled" => 3,
             "avg_duration_ms" => 2000
           } = run

    assert {:ok, %{rows: [%{"changes" => 3, "origin" => "peer", "entity_type" => "contexts"}]}} =
             Analytics.query(ctx.workspace, %{"dataset" => "ledger", "bucket" => "hour"})

    assert {:ok, %{rows: [%{"events" => 2, "avg_latency_ms" => 20.0, "max_latency_ms" => 30}]}} =
             Analytics.query(ctx.workspace, %{"dataset" => "usage", "kind" => "search"})
  end

  test "a statement run locked cannot read or write outside the workspace's directory", ctx do
    {:ok, _} = Export.run(ctx.tenant, ctx.workspace)
    {:ok, config} = DuckDB.config()
    dir = Analytics.workspace_dir(ctx.root, ctx.workspace)
    outside = Path.join(ctx.root, "outside.csv")
    File.write!(outside, "secret\n1\n")

    for sql <- [
          "SELECT * FROM read_csv(#{Analytics.literal(outside)})",
          "SELECT * FROM read_csv(#{Analytics.literal(dir <> "/../../outside.csv")})",
          "SELECT * FROM read_text('/etc/passwd')",
          "COPY (SELECT 1) TO #{Analytics.literal(Path.join(ctx.root, "written.csv"))}",
          "SET enable_external_access = true",
          "SET temp_directory = '/tmp'",
          "INSTALL httpfs",
          "LOAD httpfs",
          "SELECT * FROM read_csv('https://example.com/x.csv')"
        ] do
      assert {:error, {:exit, _, _}} = Analytics.run_locked(config, dir, sql), sql
    end

    refute File.exists?(Path.join(ctx.root, "written.csv"))

    # A spill goes to a directory inside the one the statement is locked to,
    # under the memory limit, and the directory goes with the statement.
    assert {:ok, [%{"temp" => temp, "memory" => memory}]} =
             Analytics.run_locked(
               config,
               dir,
               "SELECT current_setting('temp_directory') AS temp, current_setting('memory_limit') AS memory"
             )

    assert String.starts_with?(temp, dir <> "/~duckdb-tmp-")
    assert memory =~ ~r/^(488\.2 MiB|512\.0 MB|512MB)$/
    refute File.exists?(temp)

    # Inside it the workspace's own files are read.
    assert {:ok, [%{"n" => 3}]} =
             Analytics.run_locked(
               config,
               dir,
               "SELECT count(*) AS n FROM read_parquet(#{Analytics.literal(Path.join(dir, "metrics.parquet"))})"
             )
  end
end
