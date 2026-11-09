defmodule OptimalEngine.Storage.NATSDeadLetterTest do
  @moduledoc """
  A queued item whose handling keeps failing is not retried forever: after
  its delivery cap it moves to the dead-letter stream (`<NS>_DEAD_LETTERS`,
  one subject per flow), where the inventory counts it and an operator lists
  and requeues it (`GET /api/maintenance/nats/dead-letters`,
  `POST .../:seq/requeue`, `mix optimal.nats`). A Signal intake refuses after
  it was queued, or one dead-lettered, is counted in the `connector_runs` row
  of the pull that queued it.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias OptimalEngine.{Signal, Store, Workspace}
  alias OptimalEngine.API.Router
  alias OptimalEngine.Connectors.PullScheduler
  alias OptimalEngine.Storage.NATS.{Connection, DeadLetters, IntakeQueue}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NATSStub

  setup do
    n = System.unique_integer([:positive])
    tenant = "natsdl-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS DL #{n}"})

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
    conn = :"nats_dl_conn_#{n}"

    start_supervised!(
      {Connection, name: conn, url: "nats://127.0.0.1:#{stub.port}", backoff: {20, 100}},
      id: conn
    )

    assert wait_for(fn -> Connection.connected?(conn) end)

    connector = "nats-dl-#{n}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO connectors (id, tenant_id, workspace_id, kind, config, enabled) VALUES (?1, ?2, ?3, 'sources_folder', '{}', 1)",
        [connector, tenant, ws.id]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO connector_runs (tenant_id, connector_id, workspace_id, status, signals_ingested, errors_encountered, completed_at) VALUES (?1, ?2, ?3, 'success', 2, 0, datetime('now'))",
        [tenant, connector, ws.id]
      )

    {:ok, [[run_id]]} =
      Store.raw_query("SELECT MAX(id) FROM connector_runs WHERE connector_id = ?1", [connector])

    scope = %{
      workspace_id: ws.id,
      tenant_id: tenant,
      connector_id: connector,
      kind: "sources_folder",
      config: %{},
      run_id: run_id
    }

    %{tenant: tenant, ws: ws.id, n: n, stub: stub, conn: conn, scope: scope, run_id: run_id}
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
      id: "dl-#{ctx.n}-#{i}",
      title: "DL #{i}",
      content: "dead letter body #{i} #{ctx.n}",
      genre: "note",
      mode: :linguistic,
      type: :inform,
      format: :markdown,
      created_at: ~U[2026-11-01 10:00:00Z],
      entities: []
    }
  end

  defp queue(ctx, extra) do
    name = :"nats_dl_q_#{System.unique_integer([:positive])}"

    opts =
      [name: name, connection: ctx.conn, namespace: "optimal", enabled: true, interval_ms: 0] ++
        extra

    start_supervised!({IntakeQueue, opts}, id: name)
    name
  end

  defp run_row(ctx) do
    {:ok, [[errors, detail]]} =
      Store.raw_query("SELECT errors_encountered, error_detail FROM connector_runs WHERE id = ?1", [
        ctx.run_id
      ])

    {errors, if(detail, do: Jason.decode!(detail), else: %{})}
  end

  # Drains until the predicate holds: each drain is one delivery, and a failed
  # one comes back after the stub's nak delay.
  defp drain_until(queue, fun, tries \\ 60) do
    IntakeQueue.drain_now(queue)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(30) && drain_until(queue, fun, tries - 1)
    end
  end

  test "an item that keeps failing is dead-lettered after its cap, counted, listed and requeued",
       ctx do
    test = self()

    failing = fn _signal, _scope ->
      send(test, :attempt)
      raise "intake exploded"
    end

    q = queue(ctx, ingest: failing, dead_letter_after: 3, retry_ms: 10)
    assert {:ok, 0} = PullScheduler.intake_sink(queue: q).([signal(ctx, 1)], ctx.scope)

    assert drain_until(q, fn -> IntakeQueue.status(q).dead_lettered == 1 end)
    for _ <- 1..3, do: assert_received(:attempt)
    refute_received :attempt

    # Gone from the work queue, held in the dead letters with why.
    assert wait_for(fn -> NATSStub.messages(ctx.stub, "OPTIMAL_INTAKE") == [] end)

    assert {:ok, [letter]} = DeadLetters.list(ctx.conn, "optimal", flow: "intake")
    assert letter.flow == "intake"
    assert letter.delivered == 3
    assert letter.error =~ "intake exploded"
    assert letter.subject =~ "optimal.intake."

    assert %{total: 1, flows: %{"intake" => 1}} = DeadLetters.summary(ctx.conn, "optimal")

    # The pull that queued it counts it.
    assert {1, %{"dead_lettered" => 1}} = run_row(ctx)

    # Requeued: back on the work queue, gone from the dead letters.
    assert {:ok, %{requeued: seq}} = DeadLetters.requeue(ctx.conn, "optimal", letter.seq)
    assert seq == letter.seq
    assert {:ok, []} = DeadLetters.list(ctx.conn, "optimal", flow: "intake")
    assert wait_for(fn -> length(NATSStub.messages(ctx.stub, "OPTIMAL_INTAKE")) == 1 end)
    assert {:error, :not_found} = DeadLetters.requeue(ctx.conn, "optimal", letter.seq)
  end

  test "an item delivered past its cap without an answer is dead-lettered without running again",
       ctx do
    test = self()

    q =
      queue(ctx,
        ingest: fn _s, _scope -> send(test, :ran) && :ok end,
        dead_letter_after: 2
      )

    assert {:ok, 0} = PullScheduler.intake_sink(queue: q).([signal(ctx, 2)], ctx.scope)

    # Two deliveries nobody answered (an Engine that died mid-way), forced by
    # naking them straight back.
    for _ <- 1..2 do
      {:ok, [m]} =
        OptimalEngine.Storage.NATS.JetStream.fetch(ctx.conn, "OPTIMAL_INTAKE", "engine",
          batch: 1,
          no_wait: true
        )

      :ok = OptimalEngine.Storage.NATS.JetStream.nak(ctx.conn, m)
    end

    Process.sleep(50)
    assert {:ok, %{dead_lettered: 1}} = IntakeQueue.drain_now(q)
    refute_received :ran
  end

  test "a refusal after the item was queued is counted in the pull's run row", ctx do
    q = queue(ctx, ingest: fn _s, _scope -> :refused end)

    assert {:ok, 0} =
             PullScheduler.intake_sink(queue: q).([signal(ctx, 3), signal(ctx, 4)], ctx.scope)

    assert {:ok, %{terminated: 2}} = IntakeQueue.drain_now(q)
    assert {2, %{"queue_refused" => 2}} = run_row(ctx)
  end

  test "a refusal while the pull is still running waits for its row, not lost", ctx do
    {:ok, _} =
      Store.raw_query("UPDATE connector_runs SET status = 'running' WHERE id = ?1", [ctx.run_id])

    q = queue(ctx, ingest: fn _s, _scope -> :refused end, retry_ms: 10)
    assert {:ok, 0} = PullScheduler.intake_sink(queue: q).([signal(ctx, 5)], ctx.scope)

    assert {:ok, %{retried: 1}} = IntakeQueue.drain_now(q)
    assert {0, %{}} = run_row(ctx)

    {:ok, _} =
      Store.raw_query("UPDATE connector_runs SET status = 'success' WHERE id = ?1", [ctx.run_id])

    assert drain_until(q, fn -> elem(run_row(ctx), 0) == 1 end)
  end

  describe "the operator API" do
    setup ctx do
      previous = Application.get_env(:optimal_engine, :nats_connection)
      Application.put_env(:optimal_engine, :nats_connection, ctx.conn)
      ns = System.get_env("OPTIMAL_NATS_NAMESPACE")
      System.delete_env("OPTIMAL_NATS_NAMESPACE")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:optimal_engine, :nats_connection, previous),
          else: Application.delete_env(:optimal_engine, :nats_connection)

        if ns, do: System.put_env("OPTIMAL_NATS_NAMESPACE", ns)
      end)

      q = queue(ctx, ingest: fn _s, _scope -> raise "boom" end, dead_letter_after: 1)
      assert {:ok, 0} = PullScheduler.intake_sink(queue: q).([signal(ctx, 6)], ctx.scope)
      assert {:ok, %{dead_lettered: 1}} = IntakeQueue.drain_now(q)
      :ok
    end

    test "lists the dead letters and requeues one, as the Engine operator" do
      conn = conn(:get, "/api/maintenance/nats/dead-letters?flow=intake") |> Router.call([])
      assert conn.status == 200

      assert %{"dead_letters" => [%{"seq" => seq, "flow" => "intake"}], "count" => 1} =
               Jason.decode!(conn.resp_body)

      conn = conn(:post, "/api/maintenance/nats/dead-letters/#{seq}/requeue") |> Router.call([])
      assert conn.status == 200
      assert %{"requeued" => ^seq} = Jason.decode!(conn.resp_body)

      conn = conn(:post, "/api/maintenance/nats/dead-letters/#{seq}/requeue") |> Router.call([])
      assert conn.status == 404
    end
  end
end
