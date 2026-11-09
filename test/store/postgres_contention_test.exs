defmodule OptimalEngine.Store.PostgresContentionTest do
  @moduledoc """
  The PostgreSQL store under contention: many writers at once, as a busy
  Engine has (API traffic, connectors and background jobs side by side).

  Every Store transaction on PostgreSQL runs at SERIALIZABLE, and a transaction
  PostgreSQL aborts to keep it so is rolled back and run again. A transaction
  that conflicts with every concurrent writer by design (every claimer reads the
  same due jobs and leases one of them; a rename reads and rewrites a workspace
  in every table) is aborted again and again under load, and gives up. These
  tests count the retries of the operations under test, in their own processes
  only, so the counts do not depend on what else the suite runs.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres_store
  @moduletag timeout: 300_000

  alias OptimalEngine.{DataSteward, Jobs, Store, Workspace}
  alias OptimalEngine.Storage.PolicyStore
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.LedgerHold

  @claimers 24
  @jobs 240
  @writers 8

  setup do
    n = "#{System.unique_integer([:positive])}x#{:rand.uniform(999_999)}"
    tenant = "contend-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Contention #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    retries = :ets.new(:contention_retries, [:public, :bag])
    handler = "contention-#{n}"

    :telemetry.attach(
      handler,
      [:optimal_engine, :store, :retry],
      fn _event, measurements, metadata, table ->
        :ets.insert(table, {self(), metadata.scope, metadata.reason, measurements.attempt})
      end,
      retries
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{tenant: tenant, n: n, retries: retries}
  end

  # The retries emitted by `pids`.
  defp retries_of(ctx, pids) do
    pids = MapSet.new(pids)
    ctx.retries |> :ets.tab2list() |> Enum.filter(fn {pid, _, _, _} -> pid in pids end)
  end

  defp workspace(ctx, slug) do
    {:ok, ws} =
      Workspace.create(%{
        tenant_id: ctx.tenant,
        organization_id: "#{ctx.tenant}:org",
        slug: slug,
        name: slug
      })

    ws.id
  end

  defp insert_context(workspace_id, tenant, id) do
    Store.raw_query(
      "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, ?2, ?3, 'signal', ?1, 'body', '2026-11-09T12:00:00Z')",
      [id, tenant, workspace_id]
    )
  end

  # Writers that read their workspace and add a context to it, in one
  # transaction, until told to stop; each in a workspace of its own.
  defp start_writers(ctx, count) do
    parent = self()

    for i <- 1..count do
      ws = workspace(ctx, "load-#{i}")

      spawn_link(fn ->
        writer_loop(ctx, ws, i, 0)
        send(parent, {:writer_done, self()})
      end)
    end
  end

  defp writer_loop(ctx, ws, i, k) do
    receive do
      :stop -> :ok
    after
      0 ->
        _ =
          Store.transaction(fn txn ->
            {:ok, _} =
              Store.txn_query(txn, "SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [ws])

            {:ok, _} =
              Store.txn_execute(
                txn,
                "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, ?2, ?3, 'signal', ?1, 'body', '2026-11-09T12:00:00Z')",
                ["load-#{ctx.n}-#{i}-#{k}", ctx.tenant, ws]
              )

            {:ok, :written}
          end)

        writer_loop(ctx, ws, i, k + 1)
    end
  end

  defp stop_writers(writers) do
    Enum.each(writers, &send(&1, :stop))
    for pid <- writers, do: assert_receive({:writer_done, ^pid}, 60_000)
  end

  defp report(label, fields) do
    IO.puts(
      "\n[contention] #{label}: " <> Enum.map_join(fields, ", ", fn {k, v} -> "#{k}=#{v}" end)
    )
  end

  test "claimers drain a shared queue without serialization retries", ctx do
    ws = workspace(ctx, "queue")

    ids =
      for i <- 1..@jobs do
        {:ok, job} = Jobs.enqueue(ws, "contention.test", %{"i" => i})
        job.id
      end

    started = System.monotonic_time(:millisecond)

    tasks =
      for c <- 1..@claimers do
        Task.async(fn -> claim_loop(ws, "claimer-#{c}", []) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 240_000))
    elapsed = System.monotonic_time(:millisecond) - started

    done = results |> Enum.flat_map(&elem(&1, 0))
    errors = results |> Enum.flat_map(&elem(&1, 1))
    retries = retries_of(ctx, Enum.map(tasks, & &1.pid))

    report("jobs claim/complete",
      claimers: @claimers,
      jobs: @jobs,
      completed: length(done),
      errors: length(errors),
      retries: length(retries),
      ms: elapsed
    )

    assert errors == [], "claimers failed: #{inspect(Enum.take(errors, 3))}"
    assert Enum.sort(done) == Enum.sort(ids), "a job was lost or run twice"
    assert retries == [], "#{length(retries)} retries, e.g. #{inspect(Enum.take(retries, 3))}"
  end

  # Claims and completes jobs until none is due; returns the completed ids and
  # the errors met.
  defp claim_loop(ws, owner, done, errors \\ []) do
    case Jobs.claim(workspace_id: ws, lease_owner: owner, kinds: ["contention.test"]) do
      {:ok, nil} ->
        {done, errors}

      {:ok, job} ->
        case Jobs.complete(job.id, owner) do
          {:ok, _} -> claim_loop(ws, owner, [job.id | done], errors)
          {:error, reason} -> claim_loop(ws, owner, done, [{:complete, reason} | errors])
        end

      {:error, reason} ->
        if length(errors) > 50,
          do: {done, [{:claim, reason} | errors]},
          else: claim_loop(ws, owner, done, [{:claim, reason} | errors])
    end
  end

  test "renames and merges finish beside concurrent writers without serialization retries",
       ctx do
    steward = [tenant_id: ctx.tenant, actor_id: "user:steward"]

    # Each round renames a workspace whose slug changed (its id follows), then
    # merges rows left under an id with no workspace into it.
    olds =
      for r <- 1..4 do
        old = workspace(ctx, "old-#{r}")
        for k <- 1..5, do: {:ok, _} = insert_context(old, ctx.tenant, "ren-#{ctx.n}-#{r}-#{k}")
        {:ok, _} = Workspace.update(old, %{slug: "new-#{r}"})
        orphan = "#{ctx.tenant}:orphan-#{r}"
        for k <- 1..5, do: {:ok, _} = insert_context(orphan, ctx.tenant, "orph-#{ctx.n}-#{r}-#{k}")
        old
      end

    writers = start_writers(ctx, @writers)
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        for {old, r} <- Enum.with_index(olds, 1) do
          renamed = DataSteward.rename_workspace(old, "#{ctx.tenant}:new-#{r}", steward)

          merged =
            DataSteward.repair_orphan_scope(
              "#{ctx.tenant}:orphan-#{r}",
              "#{ctx.tenant}:new-#{r}",
              steward
            )

          {renamed, merged}
        end
      end)

    outcomes = Task.await(task, 240_000)
    elapsed = System.monotonic_time(:millisecond) - started
    stop_writers(writers)
    retries = retries_of(ctx, [task.pid])

    failed = for {r, m} <- outcomes, o <- [r, m], not match?({:ok, _}, o), do: o

    report("rename+merge beside #{@writers} writers",
      operations: 2 * length(outcomes),
      failed: length(failed),
      retries: length(retries),
      ms: elapsed
    )

    assert failed == [], "#{inspect(Enum.take(failed, 2))}"

    for {old, r} <- Enum.with_index(olds, 1) do
      {:ok, [[left]]} =
        Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id IN (?1, ?2)", [
          old,
          "#{ctx.tenant}:orphan-#{r}"
        ])

      assert left == 0
    end

    assert retries == [], "#{length(retries)} retries, e.g. #{inspect(Enum.take(retries, 3))}"
  end

  test "a writer of the workspace being renamed leaves no row under the old id", ctx do
    old = workspace(ctx, "moving")
    {:ok, _} = Workspace.update(old, %{slug: "moved"})
    target = "#{ctx.tenant}:moved"
    parent = self()

    # Each write checks that the workspace is still active and adds a context
    # to it, in one transaction, as an Engine write into a workspace does.
    writer =
      spawn_link(fn ->
        count = source_writer_loop(ctx, old, 0)
        send(parent, {:source_writer_done, count})
      end)

    Process.sleep(200)

    assert {:ok, _} =
             DataSteward.rename_workspace(old, target,
               tenant_id: ctx.tenant,
               actor_id: "user:steward"
             )

    send(writer, :stop)
    assert_receive {:source_writer_done, written}, 60_000
    assert written > 0

    {:ok, [[stranded]]} =
      Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [old])

    assert stranded == 0, "#{stranded} contexts were written under the old id after the rename"
  end

  defp source_writer_loop(ctx, ws, k) do
    receive do
      :stop -> k
    after
      0 ->
        result =
          Store.transaction(fn txn ->
            case Store.txn_query(
                   txn,
                   "SELECT 1 FROM workspaces WHERE id = ?1 AND status = 'active'",
                   [ws]
                 ) do
              {:ok, [[1]]} ->
                Store.txn_execute(
                  txn,
                  "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, ?2, ?3, 'signal', ?1, 'body', '2026-11-09T12:00:00Z')",
                  ["src-#{ctx.n}-#{k}", ctx.tenant, ws]
                )

              {:ok, []} ->
                {:ok, 0}
            end
          end)

        case result do
          {:ok, 1} -> source_writer_loop(ctx, ws, k + 1)
          _ -> source_writer_loop(ctx, ws, k)
        end
    end
  end

  describe "the ledger lock" do
    setup ctx do
      {:ok, ws} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "ledger",
          name: "Ledger"
        })

      {:ok, _} = OptimalEngine.Sync.enable(ctx.tenant, ws.id, "user:owner")
      LedgerHold.install()
      on_exit(&LedgerHold.uninstall/0)
      %{ws: ws.id}
    end

    # A storage entry waits for the ledger lock. Its snapshot must not be taken
    # before that wait: a replay of the same key that commits meanwhile would be
    # a serialization failure for INSERT OR IGNORE, and the retry would draw
    # another sequence.
    test "a replay that commits while an entry waits for the lock is answered without a retry",
         ctx do
      held = "hold-replay-#{ctx.n}"
      hold = LedgerHold.hold(held)

      entry = %{
        workspace_id: ctx.ws,
        device_id: "app-device",
        entity_type: "memory_object",
        entity_id: held,
        operation: :create,
        payload: %{"text" => held},
        idempotency_key: "replay-#{ctx.n}"
      }

      first = Task.async(fn -> PolicyStore.append_mutation(entry) end)
      assert wait_for(fn -> LedgerHold.waiting?(hold, held) end), "the first entry never drew"

      replay = Task.async(fn -> PolicyStore.append_mutation(entry) end)
      assert wait_for(fn -> ledger_waiters() > 0 end), "the replay never waited for the lock"

      LedgerHold.release(hold)
      assert {:ok, a} = Task.await(first, 30_000)
      assert {:ok, b} = Task.await(replay, 30_000)
      assert a.sequence == b.sequence

      assert retries_of(ctx, [replay.pid]) == []
    end
  end

  describe "applying a peer's changes beside local seals" do
    setup ctx do
      {:ok, ws} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "applied",
          name: "Applied"
        })

      {:ok, _} = OptimalEngine.Sync.enable(ctx.tenant, ws.id, "user:owner")
      %{ws: ws.id}
    end

    # An apply takes the ledger lock after it has read, and waits there behind
    # the seals of local writes. The seals run at READ COMMITTED, so what they
    # commit meanwhile is no serialization conflict for the apply.
    test "applies do not retry behind the seals of local writes", ctx do
      parent = self()

      sealers =
        for i <- 1..4 do
          spawn_link(fn ->
            seal_loop(ctx, i, 0)
            send(parent, {:writer_done, self()})
          end)
        end

      task =
        Task.async(fn ->
          for b <- 1..10 do
            mutations = for k <- 1..5, do: peer_change(ctx, "peer-#{ctx.n}-#{b}-#{k}")
            OptimalEngine.Sync.apply_changes(ctx.tenant, ctx.ws, mutations)
          end
        end)

      results = Task.await(task, 120_000)
      stop_writers(sealers)
      retries = retries_of(ctx, [task.pid])

      report("apply beside 4 sealers", batches: length(results), retries: length(retries))

      assert Enum.all?(results, &match?({:ok, %{applied: 5}}, &1)), inspect(Enum.take(results, 2))
      assert retries == [], "#{length(retries)} retries, e.g. #{inspect(Enum.take(retries, 3))}"
    end
  end

  defp seal_loop(ctx, i, k) do
    receive do
      :stop -> :ok
    after
      0 ->
        {:ok, _} = insert_context(ctx.ws, ctx.tenant, "local-#{ctx.n}-#{i}-#{k}")
        OptimalEngine.Sync.Capture.seal()
        seal_loop(ctx, i, k + 1)
    end
  end

  defp peer_change(ctx, entity_id) do
    %{
      "id" => "mut_contend_#{ctx.n}_#{entity_id}",
      "device_id" => "contend_peer_#{ctx.n}",
      "entity_type" => "contexts",
      "entity_id" => entity_id,
      "operation" => "create",
      "occurred_at" => "2026-11-09T12:00:00.000",
      "payload" => %{
        "row" => %{
          "id" => entity_id,
          "title" => entity_id,
          "content" => "body",
          "workspace_id" => ctx.ws,
          "tenant_id" => ctx.tenant
        },
        "blobs" => %{}
      }
    }
  end

  defp ledger_waiters do
    {:ok, [[n]]} =
      Store.transaction(fn txn ->
        OptimalEngine.Store.Postgres.txn_query_native(
          txn,
          "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND classid = hashtext('optimal_engine.sync.ledger')::oid",
          []
        )
      end)

    n
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && wait_for(fun, tries - 1)
    end
  end
end
