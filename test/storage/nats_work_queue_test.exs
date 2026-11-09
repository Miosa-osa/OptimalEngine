defmodule OptimalEngine.Storage.NATSWorkQueueTest do
  @moduledoc """
  Connector intake and background jobs through JetStream work queues.

  Intake: a connector's pulled Signals are queued on `<NS>_INTAKE`, each
  acknowledged by the stream before the pull's cursor moves, and ingested by
  the queue's durable consumer; with NATS down the pull ingests them in
  process as before. A Signal queued and not yet ingested survives a restart.

  Jobs: the `jobs` table stays the record (lease, attempts, dead letters);
  every queued job is announced on `<NS>_JOBS`, its message wakes the worker
  for its kind when the job is due, and is acknowledged only once the job is
  finished. A job enqueued while NATS is down is announced when it is back.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Jobs, Signal, Store, Workspace}
  alias OptimalEngine.Connectors.PullScheduler
  alias OptimalEngine.Storage.NATS.{Connection, IntakeQueue, JobQueue, WorkQueue}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NATSStub

  setup do
    n = System.unique_integer([:positive])
    tenant = "natswq-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS WQ #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "inbox",
        name: "Inbox"
      })

    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)

    conn = :"nats_wq_conn_#{n}"
    url = "nats://127.0.0.1:#{stub.port}"
    start_supervised!({Connection, name: conn, url: url, backoff: {20, 100}}, id: conn)
    assert wait_for(fn -> Connection.connected?(conn) end)

    %{tenant: tenant, ws: ws.id, n: n, stub: stub, conn: conn}
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  defp signal(ctx, i) do
    %Signal{
      id: "sig-#{ctx.n}-#{i}",
      title: "Pulled #{i}",
      content: "A pulled note #{i} for #{ctx.n}",
      genre: "note",
      mode: :linguistic,
      type: :inform,
      format: :markdown,
      created_at: ~U[2026-11-01 10:00:00Z],
      entities: []
    }
  end

  defp connector(ctx) do
    id = "nats-wq-#{ctx.n}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO connectors (id, tenant_id, workspace_id, kind, config, enabled) VALUES (?1, ?2, ?3, 'sources_folder', '{}', 1)",
        [id, ctx.tenant, ctx.ws]
      )

    %{
      workspace_id: ctx.ws,
      tenant_id: ctx.tenant,
      connector_id: id,
      kind: "sources_folder",
      config: %{}
    }
  end

  defp stored?(ctx, i) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2 AND title = ?3",
        [ctx.tenant, ctx.ws, "Pulled #{i}"]
      )

    rows == [[1]]
  end

  defp intake_queue(ctx) do
    name = :"nats_intake_#{System.unique_integer([:positive])}"

    start_supervised!(
      {IntakeQueue,
       name: name, connection: ctx.conn, namespace: "optimal", enabled: true, interval_ms: 0},
      id: name
    )

    name
  end

  describe "connector intake" do
    test "queued on the stream, not ingested in the pull, then ingested once by the consumer",
         ctx do
      scope = connector(ctx)
      queue = intake_queue(ctx)
      sink = PullScheduler.intake_sink(queue: queue)

      assert {:ok, 0} = sink.([signal(ctx, 1), signal(ctx, 2)], scope)
      refute stored?(ctx, 1)
      assert length(NATSStub.messages(ctx.stub, "OPTIMAL_INTAKE")) == 2

      # The same item pulled again (a pull whose cursor did not move) is queued once.
      assert {:ok, 0} = sink.([signal(ctx, 1)], scope)
      assert length(NATSStub.messages(ctx.stub, "OPTIMAL_INTAKE")) == 2

      assert {:ok, %{acked: 2}} = IntakeQueue.drain_now(queue)
      assert stored?(ctx, 1) and stored?(ctx, 2)
      # An ack is a publish the server takes in its own time.
      assert wait_for(fn -> NATSStub.messages(ctx.stub, "OPTIMAL_INTAKE") == [] end)
      assert %{state: "running", published: 2, acked: 2} = IntakeQueue.status(queue)
    end

    test "NATS down: the pull ingests in process, and nothing is lost", ctx do
      scope = connector(ctx)
      queue = intake_queue(ctx)
      NATSStub.stop(ctx.stub)
      assert wait_for(fn -> not Connection.connected?(ctx.conn) end)

      sink = PullScheduler.intake_sink(queue: queue)
      assert {:ok, 0} = sink.([signal(ctx, 1)], scope)
      assert stored?(ctx, 1)
      assert %{state: "buffering", fallback: 1} = IntakeQueue.status(queue)
    end

    test "a Signal that cannot be put on the wire is handed back, with the ones after it, in order",
         ctx do
      scope = connector(ctx)
      queue = intake_queue(ctx)
      bad = %{signal(ctx, 5) | content: "not utf-8 " <> <<0xFF, 0xFE>>}

      # The in-process path gets them, as it would without NATS.
      assert {[%{id: queued}], [%{id: first}, %{id: second}]} =
               IntakeQueue.offer(queue, [signal(ctx, 4), bad, signal(ctx, 6)], scope)

      assert {queued, first, second} == {"sig-#{ctx.n}-4", "sig-#{ctx.n}-5", "sig-#{ctx.n}-6"}
      assert length(NATSStub.messages(ctx.stub, "OPTIMAL_INTAKE")) == 1
      assert wait_for(fn -> IntakeQueue.status(queue).fallback == 2 end)
    end

    test "a Signal queued before a restart is ingested by the consumer that comes after", ctx do
      scope = connector(ctx)
      first = intake_queue(ctx)
      assert {:ok, 0} = PullScheduler.intake_sink(queue: first).([signal(ctx, 7)], scope)
      stop_supervised!(first)
      refute stored?(ctx, 7)

      second = intake_queue(ctx)
      assert {:ok, %{acked: 1}} = IntakeQueue.drain_now(second)
      assert stored?(ctx, 7)
    end

    test "a Signal for a connector that no longer exists is terminated, not retried", ctx do
      scope = connector(ctx)
      queue = intake_queue(ctx)
      assert {:ok, 0} = PullScheduler.intake_sink(queue: queue).([signal(ctx, 3)], scope)
      {:ok, _} = Store.raw_query("DELETE FROM connectors WHERE id = ?1", [scope.connector_id])

      assert {:ok, %{terminated: 1}} = IntakeQueue.drain_now(queue)
      refute stored?(ctx, 3)
      assert wait_for(fn -> NATSStub.messages(ctx.stub, "OPTIMAL_INTAKE") == [] end)
    end
  end

  describe "background jobs" do
    defp job_queue(ctx, wake) do
      name = :"nats_jobs_#{System.unique_integer([:positive])}"

      start_supervised!(
        {JobQueue,
         name: name,
         connection: ctx.conn,
         namespace: "optimal",
         enabled: true,
         interval_ms: 0,
         wake: wake,
         recheck_ms: 50},
        id: name
      )

      name
    end

    defp messages_for(ctx, job_id) do
      ctx.stub
      |> NATSStub.messages("OPTIMAL_JOBS")
      |> Enum.filter(&(&1.headers["Nats-Msg-Id"] == job_id))
    end

    test "a queued job is announced, wakes its worker when due, and leaves the queue once done",
         ctx do
      test = self()
      kind = "natstest.#{ctx.n}"

      wake = fn woken_kind ->
        send(test, {:woken, woken_kind})
        Jobs.run_next(fn _job -> :ok end, kinds: [woken_kind])
      end

      queue = job_queue(ctx, %{kind => wake})
      {:ok, job} = Jobs.enqueue(ctx.ws, kind, %{"n" => 1})
      assert :ok = JobQueue.announce(queue, job)
      assert wait_for(fn -> length(messages_for(ctx, job.id)) == 1 end)

      # The queue also holds every other queued job of the shared test
      # database (a new connection announces them all), so count this one.
      assert {:ok, %{retried: retried}} = JobQueue.drain_now(queue)
      assert retried >= 1
      assert_receive {:woken, ^kind}, 2_000
      assert wait_for(fn -> match?({:ok, %{status: "completed"}}, Jobs.fetch(job.id)) end)

      # Delivered again (the recheck delay), seen finished, acknowledged, gone.
      assert wait_for(fn ->
               JobQueue.drain_now(queue)
               messages_for(ctx, job.id) == []
             end)
    end

    test "a job that is not due yet is kept, not woken", ctx do
      test = self()
      kind = "natslater.#{ctx.n}"
      queue = job_queue(ctx, %{kind => fn k -> send(test, {:woken, k}) end})

      {:ok, job} = Jobs.enqueue(ctx.ws, kind, %{}, run_in: 3_600)
      :ok = JobQueue.announce(queue, job)
      assert wait_for(fn -> length(messages_for(ctx, job.id)) == 1 end)

      assert {:ok, %{retried: retried}} = JobQueue.drain_now(queue)
      assert retried >= 1
      refute_receive {:woken, _}, 200
      assert [_] = messages_for(ctx, job.id)
      assert {:ok, %{status: "available"}} = Jobs.fetch(job.id)
    end

    # The job is announced first when NATS is back, ahead of the reconnect
    # sweep, which goes through every unfinished job of the database oldest
    # first: in the full suite that took longer than the wait below, or never
    # reached the job at all past the sweep's limit. `older` stands for them.
    test "a job enqueued while NATS is down is announced first when it is back, and the enqueue never failed",
         ctx do
      kind = "natsdown.#{ctx.n}"
      queue = job_queue(ctx, %{})
      {:ok, older} = Jobs.enqueue(ctx.ws, kind <> ".older", %{}, run_in: 3_600)

      {:ok, _} =
        Store.raw_query("UPDATE jobs SET inserted_at = '2000-01-01 00:00:00' WHERE id = ?1", [
          older.id
        ])

      # Dated 2000, it would head every later sweep of the shared database.
      on_exit(fn -> Store.raw_query("DELETE FROM jobs WHERE id = ?1", [older.id]) end)

      port = ctx.stub.port
      NATSStub.stop(ctx.stub)
      assert wait_for(fn -> not Connection.connected?(ctx.conn) end)

      assert {:ok, job} = Jobs.enqueue(ctx.ws, kind, %{})
      assert :ok = JobQueue.announce(queue, job)
      assert wait_for(fn -> JobQueue.status(queue).state == "buffering" end)

      {:ok, back} = NATSStub.start(port: port)
      on_exit(fn -> NATSStub.stop(back) end)
      assert wait_for(fn -> Connection.connected?(ctx.conn) end, 200)

      assert {:ok, _} = JobQueue.drain_now(queue)

      assert wait_for(fn ->
               back
               |> NATSStub.messages("OPTIMAL_JOBS")
               |> Enum.any?(&(&1.headers["Nats-Msg-Id"] == job.id))
             end)

      assert [first | _] = NATSStub.messages(back, "OPTIMAL_JOBS")
      assert first.headers["Nats-Msg-Id"] == job.id
    end

    test "a message the server refuses for its size is dropped with a log line, not kept for the next connection",
         ctx do
      kind = "natsbig.#{ctx.n}"
      queue = job_queue(ctx, %{})
      assert {:ok, _} = JobQueue.drain_now(queue)

      # Past the stub's max_payload (1 MiB): the connection refuses it before
      # it reaches the server, which would close the connection over it.
      big = String.duplicate("x", 1_100_000)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = WorkQueue.publish_async(queue, kind, big, "big-#{ctx.n}")
          assert wait_for(fn -> JobQueue.status(queue).failed == 1 end)
        end)

      assert log =~ "big-#{ctx.n} dropped"
      assert Connection.connected?(ctx.conn)
      assert :sys.get_state(queue).unsent_count == 0
    end

    test "the background publishes kept while NATS is down are capped, oldest dropped first and counted" do
      state = %{
        callback: JobQueue,
        unsent: :queue.new(),
        unsent_count: 0,
        counts: %{unsent_dropped: 0}
      }

      {state, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Enum.reduce(1..10_005, state, fn i, state ->
            WorkQueue.keep_unsent(state, {"t", "p", "id-#{i}"})
          end)
        end)

      ids = state.unsent |> :queue.to_list() |> Enum.map(&elem(&1, 2))
      assert length(ids) == 10_000
      assert hd(ids) == "id-6"
      assert List.last(ids) == "id-10005"
      assert state.counts.unsent_dropped == 5

      # One line for the first drop, not one per drop.
      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "kept announcements are full"))
      assert length(lines) == 1
    end

    test "Jobs.enqueue announces to the Engine's queue, and an enqueue with the flow off still works",
         ctx do
      # The Engine's own queue is off in tests: the announce is a no-op and the
      # job is queued in SQLite as always.
      assert %{state: "off"} = JobQueue.status()
      assert {:ok, %{status: "available"}} = Jobs.enqueue(ctx.ws, "natsoff.#{ctx.n}", %{})
    end
  end
end
