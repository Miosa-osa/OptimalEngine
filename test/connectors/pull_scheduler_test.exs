defmodule OptimalEngine.Connectors.PullSchedulerTest do
  @moduledoc """
  The pull loop runs the connectors table, not the config list.

  Covers what runs (every enabled row of the tenant, config specs only
  provision), when it runs (per-connector cadence), that a run never overlaps
  itself, that a slow connector does not hold up the others, and that a
  failed pull is reported with its reason.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Connectors.{PullScheduler, Rows, Runner}
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.ScheduledStubAdapter, as: Stub

  setup do
    original_key = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))
    original_intake = Application.get_env(:optimal_engine, :corpus_source_workspace)

    on_exit(fn ->
      if original_key,
        do: System.put_env("CONNECTOR_KEY", original_key),
        else: System.delete_env("CONNECTOR_KEY")

      if original_intake,
        do: Application.put_env(:optimal_engine, :corpus_source_workspace, original_intake),
        else: Application.delete_env(:optimal_engine, :corpus_source_workspace)

      Stub.stop_listening()
    end)

    Stub.listen(self())

    tenant = "sched-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Scheduler #{tenant}"})

    {:ok,
     tenant: tenant,
     inbox: insert_workspace("#{tenant}:inbox", tenant, "active"),
     clients: insert_workspace("#{tenant}:clients", tenant, "active"),
     intake: insert_workspace("#{tenant}:intake", tenant, "active"),
     old: insert_workspace("#{tenant}:old", tenant, "archived")}
  end

  describe "what a tick runs" do
    test "every enabled connector row of the tenant, not only the configured specs", ctx do
      a = register(ctx, "a", ctx.inbox, %{"marker" => "a"})
      b = register(ctx, "b", ctx.clients, %{"marker" => "b"})
      c = register(ctx, "c", ctx.inbox, %{"marker" => "c"}, false)

      {:ok, summary} = run_once(ctx)

      assert summary.connector_results |> Enum.map(& &1.connector_id) |> Enum.sort() ==
               Enum.sort([a, b])

      assert summary.ingested_count == 2
      assert summary.error_count == 0
      assert_received {:pulled, ^a, workspace_a, 1}
      assert workspace_a == ctx.inbox
      assert_received {:pulled, ^b, workspace_b, 1}
      assert workspace_b == ctx.clients
      refute_received {:pulled, ^c, _, _}
    end

    test "a configured spec only provisions: the operator's workspace, config and enabled state survive",
         ctx do
      id = "pull:#{ctx.tenant}:sources_folder"
      register_id(ctx, id, ctx.clients, %{"marker" => "operator"})
      spec = %{kind: :sources_folder, workspace_id: ctx.inbox, config: %{"marker" => "spec"}}

      {:ok, summary} = run_once(ctx, defaults: [spec])

      assert [%{connector_id: ^id, status: :ok, kind: :sources_folder}] =
               summary.connector_results

      assert_received {:pulled, ^id, workspace, 1}
      assert workspace == ctx.clients
      assert row(id) == {ctx.clients, %{"marker" => "operator"}, 1}

      # The operator disables it: the next tick neither runs nor re-enables it.
      {:ok, _} = Store.raw_query("UPDATE connectors SET enabled = 0 WHERE id = ?1", [id])
      {:ok, summary} = run_once(ctx, defaults: [spec])

      assert summary.connector_results == []
      assert row(id) == {ctx.clients, %{"marker" => "operator"}, 0}
    end

    test "a spec without a workspace provisions into the tenant's intake workspace", ctx do
      Application.put_env(:optimal_engine, :corpus_source_workspace, ctx.intake)
      id = "pull:#{ctx.tenant}:sources_folder"

      {:ok, summary} =
        run_once(ctx, defaults: [%{kind: :sources_folder, config: %{"marker" => "intake"}}])

      assert [%{connector_id: ^id, status: :ok}] = summary.connector_results
      assert {workspace, _config, 1} = row(id)
      assert workspace == ctx.intake
    end

    test "a spec is never provisioned into an archived workspace", ctx do
      # The tenant's intake workspace is archived and it owns no other
      # candidate, so the spec is reported rather than parked somewhere dead.
      Application.put_env(:optimal_engine, :corpus_source_workspace, ctx.old)
      id = "pull:#{ctx.tenant}:sources_folder"

      {:ok, summary} =
        capture_and_run(fn ->
          run_once(ctx, defaults: [%{kind: :sources_folder, config: %{"marker" => "nowhere"}}])
        end)

      assert summary.error_count == 1

      assert [%{connector_id: ^id, status: :error, reason: :no_intake_workspace}] =
               summary.connector_results

      assert {:ok, []} = Store.raw_query("SELECT id FROM connectors WHERE id = ?1", [id])
    end

    test "the intake workspace is the first active candidate the tenant owns", ctx do
      assert {:ok, workspace} = Rows.default_workspace(ctx.tenant, [ctx.old, ctx.inbox])
      assert workspace == ctx.inbox

      # "default" belongs to the default tenant, so it is never this tenant's fallback.
      assert {:error, :no_intake_workspace} =
               Rows.default_workspace(ctx.tenant, [ctx.old, "default"])
    end
  end

  describe "cadence" do
    test "a scheduled tick runs only the connectors whose cadence has passed", ctx do
      fresh = register(ctx, "fresh", ctx.inbox, %{"marker" => "fresh"})
      recent = register(ctx, "recent", ctx.inbox, %{"marker" => "recent", "cadence" => "hourly"})
      stale = register(ctx, "stale", ctx.inbox, %{"marker" => "stale", "interval_ms" => 3_600_000})
      daily = register(ctx, "daily", ctx.inbox, %{"marker" => "daily", "cadence" => "daily"})

      past_run(ctx, recent, "-10 minutes")
      past_run(ctx, stale, "-2 hours")
      past_run(ctx, daily, "-2 hours")

      {:ok, summary} = run_once(ctx, due_only: true)

      assert summary.connector_results |> Enum.map(& &1.connector_id) |> Enum.sort() ==
               Enum.sort([fresh, stale])

      # A manual pull (mix optimal.pull) still runs every enabled connector.
      {:ok, summary} = run_once(ctx)
      assert length(summary.connector_results) == 4
    end
  end

  describe "overlap" do
    test "a connector never runs twice at once, whoever asks", ctx do
      blocker = register(ctx, "blocker", ctx.inbox, %{"marker" => "blocker", "block" => true})
      task = Task.async(fn -> Runner.run(blocker, adapter: Stub) end)
      assert_receive {:stub_sync, "blocker", pid}, 5_000

      assert Runner.running?(blocker)
      assert {:error, :already_running} = Runner.run(blocker, adapter: Stub)

      {:ok, summary} = run_once(ctx)

      assert [%{connector_id: ^blocker, status: :skipped, reason: :already_running}] =
               summary.connector_results

      assert summary.error_count == 0

      send(pid, :release)
      assert {:ok, %{status: :success}} = Task.await(task, 10_000)
      refute Runner.running?(blocker)
    end
  end

  describe "the scheduler process" do
    test "pulls registered connectors on its own, and a slow one does not hold up the others",
         ctx do
      slow = register(ctx, "slow", ctx.inbox, %{"marker" => "slow", "block" => true})
      quick = register(ctx, "quick", ctx.clients, %{"marker" => "quick"})
      name = :"pull_scheduler_#{ctx.tenant}"
      test_pid = self()

      start_supervised!({
        PullScheduler,
        # config/test.exs turns the live loop off; this test starts its own.
        name: name,
        tenant_id: ctx.tenant,
        enabled: true,
        boot_delay_ms: 10,
        tick_ms: 50,
        max_concurrency: 2,
        defaults: [],
        run_opts: [adapter: Stub, signal_sink: sink(test_pid)]
      })

      assert_receive {:stub_sync, "slow", slow_pid}, 5_000
      assert_receive {:stub_sync, "quick", _quick_pid}, 5_000
      assert_receive {:pulled, ^quick, _workspace, 1}, 5_000

      status = PullScheduler.status(name)
      assert Enum.any?(status.running, &(&1.connector_id == slow))

      # Quick ran inside its cadence and slow is still running: neither is
      # dispatched again on the next ticks.
      refute_receive {:stub_sync, _marker, _pid}, 400

      send(slow_pid, :release)
      assert_receive {:pulled, ^slow, _workspace, 1}, 5_000

      assert eventually(fn ->
               status = PullScheduler.status(name)
               status.running == [] and Map.has_key?(status.connectors, slow)
             end)

      assert %{status: :ok, signals: 1} = PullScheduler.status(name).connectors[quick]
    end

    test "start_run/2 runs one connector now through the scheduler and refuses a second", ctx do
      blocker = register(ctx, "now", ctx.inbox, %{"marker" => "now", "block" => true})
      name = :"pull_scheduler_now_#{ctx.tenant}"

      start_supervised!(
        {PullScheduler,
         name: name,
         tenant_id: ctx.tenant,
         enabled: false,
         defaults: [],
         run_opts: [adapter: Stub, signal_sink: sink(self())]}
      )

      assert {:ok, :started} = PullScheduler.start_run(blocker, server: name)
      assert_receive {:stub_sync, "now", pid}, 5_000
      assert {:error, :already_running} = PullScheduler.start_run(blocker, server: name)

      send(pid, :release)
      assert_receive {:pulled, ^blocker, _workspace, 1}, 5_000
    end
  end

  describe "failures" do
    test "a failed pull is logged as a warning with its reason and kept as the last error", ctx do
      failing = register(ctx, "failing", ctx.inbox, %{"marker" => "failing", "fail" => true})

      log =
        capture_log(fn ->
          {:ok, summary} = run_once(ctx)
          assert summary.error_count == 1

          assert [%{connector_id: ^failing, status: :error, reason: :boom}] =
                   summary.connector_results
        end)

      assert log =~ failing
      assert log =~ "boom"

      assert {:ok, view} = Rows.get(ctx.tenant, failing)
      assert view.last_run.status == "error"
      assert view.last_error.error =~ "boom"
    end

    test "a connector whose workspace was archived fails its run with the reason", ctx do
      parked = register(ctx, "parked", ctx.old, %{"marker" => "parked"})

      {:ok, summary} = capture_and_run(fn -> run_once(ctx) end)

      assert [%{connector_id: ^parked, status: :error, reason: :workspace_archived}] =
               summary.connector_results

      refute_received {:stub_sync, "parked", _}
      assert {:ok, view} = Rows.get(ctx.tenant, parked)
      assert view.last_error.error =~ "workspace_archived"
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp run_once(ctx, opts \\ []) do
    PullScheduler.run_once(
      Keyword.merge(
        [tenant_id: ctx.tenant, defaults: [], adapter: Stub, signal_sink: sink(self())],
        opts
      )
    )
  end

  defp capture_and_run(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, result} -> result
    end
  end

  defp sink(pid) do
    fn signals, scope ->
      send(pid, {:pulled, scope.connector_id, scope.workspace_id, length(signals)})
      :ok
    end
  end

  defp register(ctx, name, workspace, config, enabled \\ true) do
    register_id(ctx, "#{ctx.tenant}-#{name}", workspace, config, enabled)
  end

  defp register_id(ctx, id, workspace, config, enabled \\ true) do
    {:ok, ^id} =
      Runner.upsert_row(%{
        id: id,
        kind: :sources_folder,
        tenant_id: ctx.tenant,
        workspace_id: workspace,
        config: config,
        enabled: enabled
      })

    id
  end

  defp past_run(ctx, id, offset) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO connector_runs
          (tenant_id, workspace_id, connector_id, started_at, completed_at, status)
        VALUES (?1, ?2, ?3, datetime('now', ?4), datetime('now', ?4), 'success')
        """,
        [ctx.tenant, ctx.inbox, id, offset]
      )
  end

  defp row(id) do
    {:ok, [[workspace, config, enabled]]} =
      Store.raw_query("SELECT workspace_id, config, enabled FROM connectors WHERE id = ?1", [id])

    {workspace, Jason.decode!(config), enabled}
  end

  defp insert_workspace(id, tenant, status) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, ?2, ?3, ?4, ?5, '{}')
        """,
        [id, tenant, id |> String.split(":") |> List.last(), "WS #{id}", status]
      )

    id
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end
end
