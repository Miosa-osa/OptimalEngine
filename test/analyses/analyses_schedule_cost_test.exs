defmodule OptimalEngine.Analyses.ScheduleCostTest do
  @moduledoc """
  `Analyses.schedule/2` enqueues the day's analyses of every active workspace.
  It used to make a few store calls per workspace (the workspace's tenant, the
  insert, the read back, its meeting connectors), so on an Engine with many
  workspaces the daily schedule ran for minutes. It now makes a bounded number
  per tenant: the workspaces, the tenant's meeting connectors, and the jobs
  inserted in batches. Counted in store calls, not in time.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Analyses, Store}
  alias OptimalEngine.Tenancy.Tenant

  @workspaces 300

  setup do
    n = System.unique_integer([:positive])
    tenant = tenant!("sched-cost-#{n}", @workspaces)
    other = tenant!("sched-cost-b-#{n}", 20)
    %{tenant: tenant, other: other, n: n}
  end

  defp tenant!(tenant, workspaces) do
    {:ok, _} = Tenant.create(%{id: tenant, name: "Schedule cost #{tenant}"})

    for chunk <- Enum.chunk_every(1..workspaces, 100) do
      values =
        Enum.map_join(chunk, ", ", fn i -> "('#{tenant}:w#{i}', '#{tenant}', 'w#{i}', 'W #{i}')" end)

      {:ok, _} =
        Store.raw_query("INSERT INTO workspaces (id, tenant_id, slug, name) VALUES #{values}", [])
    end

    tenant
  end

  defp jobs_of(tenant) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT tenant_id, workspace_id FROM jobs WHERE tenant_id = ?1 OR workspace_id LIKE ?2",
        [tenant, tenant <> ":%"]
      )

    rows
  end

  @counted [
    {Store, :raw_query, 2},
    {Store, :raw_execute, 2},
    {Store, :transaction, 1},
    {Store, :transaction, 2}
  ]

  # The store calls the calling process makes while `fun` runs (meta call
  # tracing, which names the caller: the jobs other processes run meanwhile
  # are not counted).
  defp store_calls(fun) do
    me = self()
    counter = spawn(fn -> count_calls(me, 0) end)
    for mfa <- @counted, do: :erlang.trace_pattern(mfa, true, [{:meta, counter}])

    try do
      result = fun.()
      for mfa <- @counted, do: :erlang.trace_pattern(mfa, false, [:meta])
      send(counter, {:total, me})

      receive do
        {:calls, calls} -> {result, calls}
      after
        5_000 -> flunk("the call counter did not answer")
      end
    after
      for mfa <- @counted, do: :erlang.trace_pattern(mfa, false, [:meta])
    end
  end

  defp count_calls(pid, n) do
    receive do
      {:trace_ts, ^pid, :call, _mfa, _ts} -> count_calls(pid, n + 1)
      {:trace, ^pid, :call, _mfa} -> count_calls(pid, n + 1)
      {:total, reply} -> send(reply, {:calls, n})
      _other -> count_calls(pid, n)
    end
  end

  test "the store calls of a tenant's schedule do not grow with its workspaces", ctx do
    today = Date.utc_today()
    {scheduled, calls} = store_calls(fn -> Analyses.schedule(today, tenant_id: ctx.tenant) end)

    assert scheduled >= @workspaces

    {:ok, [[jobs]]} =
      Store.raw_query("SELECT count(*) FROM jobs WHERE tenant_id = ?1", [ctx.tenant])

    assert jobs == scheduled
    # The workspaces, the meeting connectors, the corpus source and the inserts
    # (in batches): far fewer than one call per workspace.
    assert calls < 40, "#{calls} store calls for #{@workspaces} workspaces"

    # Again on the same day: the same jobs, nothing new.
    assert Analyses.schedule(today, tenant_id: ctx.tenant) == scheduled

    {:ok, [[again]]} =
      Store.raw_query("SELECT count(*) FROM jobs WHERE tenant_id = ?1", [ctx.tenant])

    assert again == jobs
  end

  test "two tenants scheduled in one pass each get their own workspaces' jobs", ctx do
    today = Date.utc_today()

    {scheduled, calls} =
      store_calls(fn -> Analyses.schedule(today, tenant_ids: [ctx.tenant, ctx.other]) end)

    mine = jobs_of(ctx.tenant)
    theirs = jobs_of(ctx.other)
    assert scheduled == length(mine) + length(theirs)

    assert Enum.all?(mine, fn [t, w] ->
             t == ctx.tenant and String.starts_with?(w, ctx.tenant <> ":")
           end)

    assert Enum.all?(theirs, fn [t, w] ->
             t == ctx.other and String.starts_with?(w, ctx.other <> ":")
           end)

    assert length(theirs) > 0
    assert calls < 40, "#{calls} store calls"
  end

  test "a workspace archived after it was listed gets no job, and the rest do", ctx do
    {:ok, _} =
      Store.raw_query("UPDATE workspaces SET status = 'archived' WHERE id = ?1", ["#{ctx.other}:w3"])

    Analyses.schedule(Date.utc_today(), tenant_ids: [ctx.other])
    workspaces = for [_t, w] <- jobs_of(ctx.other), do: w
    refute "#{ctx.other}:w3" in workspaces
    assert "#{ctx.other}:w4" in workspaces
  end

  # The statements the calling process sends while `fun` runs.
  defp store_statements(fun) do
    me = self()
    collector = spawn(fn -> collect_statements(me, []) end)
    mfa = {Store, :raw_query, 2}
    :erlang.trace_pattern(mfa, true, [{:meta, collector}])

    try do
      fun.()
      :erlang.trace_pattern(mfa, false, [:meta])
      send(collector, {:total, me})

      receive do
        {:statements, statements} -> statements
      after
        5_000 -> flunk("the statement collector did not answer")
      end
    after
      :erlang.trace_pattern(mfa, false, [:meta])
    end
  end

  defp collect_statements(pid, acc) do
    receive do
      {:trace_ts, ^pid, :call, {_m, _f, [sql, params]}, _ts} ->
        collect_statements(pid, [{sql, params} | acc])

      {:trace, ^pid, :call, {_m, _f, [sql, params]}} ->
        collect_statements(pid, [{sql, params} | acc])

      {:total, reply} ->
        send(reply, {:statements, Enum.reverse(acc)})

      _other ->
        collect_statements(pid, acc)
    end
  end

  # Every job the Engine ever queued stays in `jobs` until it is pruned, so a
  # statement that reads the whole table per batch makes the daily schedule
  # quadratic: on a full test database it ran past a minute (#259, test-current).
  # SQLite's plan names a full read of a table, or of all of an index, `SCAN`;
  # a lookup is a `SEARCH`.
  @tag :sqlite_store
  test "no statement of the schedule reads the whole jobs table", ctx do
    statements =
      store_statements(fn -> Analyses.schedule(Date.utc_today(), tenant_id: ctx.other) end)

    assert statements != []

    scans =
      for {sql, params} <- statements,
          sql =~ ~r/\bjobs\b/i,
          {:ok, plan} = Store.raw_query("EXPLAIN QUERY PLAN " <> sql, params),
          detail = Enum.map_join(plan, "\n", &List.last/1),
          detail =~ ~r/\bSCAN (jobs|j)\b/,
          do: {sql, detail}

    assert scans == [],
           "statements that read the whole jobs table:\n#{inspect(scans, pretty: true)}"
  end

  describe "the Engine-wide export" do
    setup do
      env = OptimalEngine.Storage.DuckDB.env_name()
      previous = System.get_env(env)
      root = Path.join(System.tmp_dir!(), "sched-engine-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      System.put_env(env, root)

      on_exit(fn ->
        if previous, do: System.put_env(env, previous), else: System.delete_env(env)
        Store.raw_query("UPDATE workspaces SET status = 'active' WHERE id = 'default'", [])
      end)
    end

    defp engine_jobs(today) do
      {:ok, [[count]]} =
        Store.raw_query("SELECT count(*) FROM jobs WHERE kind = ?1 AND idempotency_key = ?2", [
          "analysis.analytics_engine_export",
          "analysis:analytics_engine_export:#{Date.to_iso8601(today)}"
        ])

      count
    end

    test "is not scheduled while the default workspace is archived, and is once it is back", ctx do
      # A day no other test schedules.
      today = Date.add(Date.utc_today(), 400 + rem(ctx.n, 1000))

      {:ok, _} =
        Store.raw_query("UPDATE workspaces SET status = 'archived' WHERE id = 'default'", [])

      Analyses.schedule(today, tenant_ids: [ctx.other, "default"])
      assert engine_jobs(today) == 0
      assert length(jobs_of(ctx.other)) > 0

      {:ok, _} = Store.raw_query("UPDATE workspaces SET status = 'active' WHERE id = 'default'", [])
      Analyses.schedule(today, tenant_ids: [ctx.other, "default"])
      assert engine_jobs(today) == 1
    end
  end

  describe "Jobs.enqueue_many/2" do
    test "refuses options it would ignore" do
      for opt <- [priority: 5, run_in: 60, run_at: DateTime.utc_now()] do
        assert {:error, {:unsupported_options, [_]}} = OptimalEngine.Jobs.enqueue_many([], [opt])
      end
    end

    # The store refuses one row, and so the whole batch: the others go in one
    # at a time.
    @tag :sqlite_store
    test "a batch the store refuses falls back to one job at a time", ctx do
      {:ok, _} =
        Store.raw_query(
          "CREATE TRIGGER poison_job BEFORE INSERT ON jobs WHEN NEW.idempotency_key = 'poison-#{ctx.n}' BEGIN SELECT RAISE(ABORT, 'poisoned'); END",
          []
        )

      on_exit(fn -> Store.raw_query("DROP TRIGGER IF EXISTS poison_job", []) end)

      entries =
        for i <- 1..5 do
          key = if i == 3, do: "poison-#{ctx.n}", else: "ok-#{ctx.n}-#{i}"
          {ctx.other, "#{ctx.other}:w#{i}", "analysis.promises", %{}, key}
        end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{inserted: 4, scheduled: 4}} = OptimalEngine.Jobs.enqueue_many(entries)
        end)

      assert log =~ "[error]"
      assert log =~ "one at a time"
    end
  end
end
