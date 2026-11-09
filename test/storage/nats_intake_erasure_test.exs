defmodule OptimalEngine.Storage.NATSIntakeErasureTest do
  @moduledoc """
  What was taken in but not yet ingested goes when its workspace or its
  connector does. A Signal queued on `<NS>_INTAKE` holds connector content
  until it is consumed, and a dead letter holds it until it is requeued or
  expires; archiving the workspace (or renaming it away, or finishing its
  move) and deleting the connector remove both, so nothing erased comes back
  through intake. A removal asked for while NATS is down is recorded and
  done once the intake queue is provisioned again.

  The dead letters expire too: `OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS`
  (default 720, `0` keeps them) is the dead-letter stream's `max_age`, so
  JetStream purges a letter older than that.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Signal, Store, Workspace}
  alias OptimalEngine.Connectors.{PullScheduler, Rows}
  alias OptimalEngine.Storage.NATS.{Connection, DeadLetters, IntakeQueue}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NATSStub

  @env ~w(OPTIMAL_NATS_URL OPTIMAL_NATS_FLOWS OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    previous_conn = Application.get_env(:optimal_engine, :nats_connection)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if previous_conn,
        do: Application.put_env(:optimal_engine, :nats_connection, previous_conn),
        else: Application.delete_env(:optimal_engine, :nats_connection)
    end)

    n = System.unique_integer([:positive])
    tenant = "natsie-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS IE #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    [ws, other] =
      for slug <- ~w(gone kept) do
        {:ok, ws} =
          Workspace.create(%{
            tenant_id: tenant,
            organization_id: "#{tenant}:org",
            slug: slug,
            name: slug
          })

        ws.id
      end

    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)
    conn = :"nats_ie_conn_#{n}"

    start_supervised!(
      {Connection, name: conn, url: "nats://127.0.0.1:#{stub.port}", backoff: {20, 100}},
      id: conn
    )

    assert wait_for(fn -> Connection.connected?(conn) end)

    connectors =
      for {id, workspace} <- [{"ie-gone-#{n}", ws}, {"ie-kept-#{n}", other}], into: %{} do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO connectors (id, tenant_id, workspace_id, kind, config, enabled) VALUES (?1, ?2, ?3, 'sources_folder', '{}', 1)",
            [id, tenant, workspace]
          )

        {workspace, id}
      end

    %{tenant: tenant, ws: ws, other: other, n: n, stub: stub, conn: conn, connectors: connectors}
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  defp signal(ctx, tag, i) do
    %Signal{
      id: "ie-#{tag}-#{ctx.n}-#{i}",
      title: "IE #{i}",
      content: "zqintake#{tag}#{ctx.n}xv queued body #{i}",
      genre: "note",
      mode: :linguistic,
      type: :inform,
      format: :markdown,
      created_at: ~U[2026-11-01 10:00:00Z],
      entities: []
    }
  end

  defp scope(ctx, workspace) do
    %{
      workspace_id: workspace,
      tenant_id: ctx.tenant,
      connector_id: ctx.connectors[workspace],
      kind: "sources_folder",
      config: %{}
    }
  end

  # A queue that never consumes on its own (interval 0), so what is queued stays.
  defp queue(ctx, extra \\ []) do
    name = :"nats_ie_q_#{System.unique_integer([:positive])}"

    opts =
      [name: name, connection: ctx.conn, namespace: "optimal", enabled: true, interval_ms: 0] ++
        extra

    start_supervised!({IntakeQueue, opts}, id: name)
    name
  end

  defp held(ctx, tag) do
    token = "zqintake#{tag}#{ctx.n}xv"

    for stream <- ~w(OPTIMAL_INTAKE OPTIMAL_DEAD_LETTERS),
        message <- NATSStub.messages(ctx.stub, stream),
        String.contains?(message.data, token),
        do: stream
  end

  # Two queued for the doomed workspace's connector and one dead-lettered,
  # one queued for the other workspace's.
  defp fill(ctx) do
    failing = fn _signal, _scope -> raise "intake exploded" end
    dead = queue(ctx, ingest: failing, dead_letter_after: 1, retry_ms: 10)

    assert {:ok, 0} =
             PullScheduler.intake_sink(queue: dead).([signal(ctx, "gone", 0)], scope(ctx, ctx.ws))

    assert wait_for(fn ->
             IntakeQueue.drain_now(dead)
             IntakeQueue.status(dead).dead_lettered == 1
           end)

    q = queue(ctx)
    gone = for i <- 1..2, do: signal(ctx, "gone", i)
    assert {:ok, 0} = PullScheduler.intake_sink(queue: q).(gone, scope(ctx, ctx.ws))

    assert {:ok, 0} =
             PullScheduler.intake_sink(queue: q).([signal(ctx, "kept", 1)], scope(ctx, ctx.other))

    assert Enum.sort(held(ctx, "gone")) ==
             ~w(OPTIMAL_DEAD_LETTERS OPTIMAL_INTAKE OPTIMAL_INTAKE)

    q
  end

  test "removing a workspace's intake takes its queued Signals and dead letters, nobody else's",
       ctx do
    fill(ctx)

    assert {:ok, %{queued_purged: 2, dead_letters_removed: 1}} =
             IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
               connection: ctx.conn,
               namespace: "optimal"
             )

    assert held(ctx, "gone") == []
    assert held(ctx, "kept") == ["OPTIMAL_INTAKE"]
  end

  test "Workspace.archive removes what its connectors queued", ctx do
    fill(ctx)
    System.put_env("OPTIMAL_NATS_URL", "nats://127.0.0.1:#{ctx.stub.port}")
    System.put_env("OPTIMAL_NATS_FLOWS", "intake")
    Application.put_env(:optimal_engine, :nats_connection, ctx.conn)

    assert :ok = Workspace.archive(ctx.ws)

    assert wait_for(fn -> held(ctx, "gone") == [] end)
    assert held(ctx, "kept") == ["OPTIMAL_INTAKE"]
  end

  test "deleting a connector removes what it queued", ctx do
    fill(ctx)
    System.put_env("OPTIMAL_NATS_URL", "nats://127.0.0.1:#{ctx.stub.port}")
    System.put_env("OPTIMAL_NATS_FLOWS", "intake")
    Application.put_env(:optimal_engine, :nats_connection, ctx.conn)

    assert :ok = Rows.delete(ctx.tenant, ctx.connectors[ctx.ws])

    assert wait_for(fn -> held(ctx, "gone") == [] end)
    assert held(ctx, "kept") == ["OPTIMAL_INTAKE"]
  end

  test "a removal asked for while NATS is down is done once the queue is provisioned", ctx do
    fill(ctx)
    down = :"nats_ie_down_#{ctx.n}"
    start_supervised!({Connection, name: down, url: nil}, id: down)

    assert {:ok, %{pending: true}} =
             IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
               connection: down,
               namespace: "optimal"
             )

    refute held(ctx, "gone") == []

    assert {:ok, done} = IntakeQueue.process_requests(ctx.conn, "optimal")
    assert map_size(done) >= 1
    assert held(ctx, "gone") == []
    assert {:ok, %{}} = IntakeQueue.process_requests(ctx.conn, "optimal")
  end

  describe "review: nothing erased is ingested afterwards" do
    defp in_flight(ctx, workspace, tag) do
      %{
        subject: "optimal.intake.#{ctx.tenant}.#{ctx.connectors[workspace]}",
        payload:
          Jason.encode!(%{
            "tenant_id" => ctx.tenant,
            "connector_id" => ctx.connectors[workspace],
            "workspace_id" => workspace,
            "signal" => IntakeQueue.encode_signal(signal(ctx, tag, 1))
          }),
        headers: %{},
        reply: nil,
        stream: "OPTIMAL_INTAKE",
        consumer: nil,
        delivered: 1,
        stream_seq: 1,
        consumer_seq: 1,
        pending: 0
      }
    end

    test "a Signal a consumer already holds when its workspace is archived is dropped", ctx do
      test = self()
      ingest = fn _signal, _scope -> send(test, :ingested) && :ok end
      message = in_flight(ctx, ctx.ws, "held")

      assert :ok = Workspace.archive(ctx.ws)

      assert :term = IntakeQueue.handle_message(message, %{ingest: ingest})
      refute_received :ingested

      # The other workspace's still goes in.
      assert :ack = IntakeQueue.handle_message(in_flight(ctx, ctx.other, "live"), %{ingest: ingest})
      assert_received :ingested
    end

    test "a removal whose request cannot be recorded is an error, not pending", ctx do
      Application.put_env(:optimal_engine, :intake_purge_record, fn _ns, _req, _target ->
        raise "events table unavailable"
      end)

      on_exit(fn -> Application.delete_env(:optimal_engine, :intake_purge_record) end)

      assert {:error, {:request_not_recorded, _}} =
               IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
                 connection: ctx.conn,
                 namespace: "optimal"
               )
    end

    test "a recorded removal is retried on a timer, not only on reprovision", ctx do
      fill(ctx)
      down = :"nats_ie_down2_#{ctx.n}"
      start_supervised!({Connection, name: down, url: nil}, id: down)

      assert {:ok, %{pending: true}} =
               IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
                 connection: down,
                 namespace: "optimal"
               )

      # A queue already provisioned: only its timer can pick the request up.
      _q = queue(ctx, purge_retry_ms: 50)
      assert wait_for(fn -> held(ctx, "gone") == [] end)
      assert held(ctx, "kept") == ["OPTIMAL_INTAKE"]
    end

    test "an untenanted payload is the default tenant's, and no other tenant's", ctx do
      {:ok, default_ws} = Workspace.create(%{slug: "ie-default-#{ctx.n}", name: "IE default"})
      q = queue(ctx)
      IntakeQueue.drain_now(q)

      payload = fn ws ->
        Jason.encode!(%{
          "connector_id" => "untenanted-#{ctx.n}",
          "workspace_id" => ws,
          "signal" => %{"content" => "zqintakeuntenanted#{ctx.n}xv"}
        })
      end

      for {ws, i} <- [{default_ws.id, 1}, {ctx.ws, 2}] do
        {:ok, _} =
          OptimalEngine.Storage.NATS.JetStream.publish(
            ctx.conn,
            "optimal.intake.default.untenanted-#{ctx.n}",
            payload.(ws),
            msg_id: "untenanted-#{ctx.n}-#{i}"
          )
      end

      # Another tenant's erasure of a workspace id never touches them.
      assert {:ok, %{queued_purged: 0}} =
               IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
                 connection: ctx.conn,
                 namespace: "optimal"
               )

      assert length(held(ctx, "untenanted")) == 2

      assert {:ok, %{queued_purged: 1}} =
               IntakeQueue.forget_workspace("default", default_ws.id, "archived",
                 connection: ctx.conn,
                 namespace: "optimal"
               )

      assert length(held(ctx, "untenanted")) == 1
    end
  end

  describe "the dead-letter age limit" do
    defp dead_letter_config(ctx),
      do: NATSStub.streams(ctx.stub)["OPTIMAL_DEAD_LETTERS"].config

    test "is 30 days by default, set in hours, and 0 keeps letters forever", ctx do
      assert :ok = DeadLetters.ensure(ctx.conn, "optimal")
      assert dead_letter_config(ctx)["max_age"] == 720 * 3_600 * 1_000_000_000
      assert DeadLetters.max_age_ms() == 720 * 3_600_000

      # An existing stream takes the new limit.
      System.put_env("OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS", "2")
      assert :ok = DeadLetters.ensure(ctx.conn, "optimal")
      assert dead_letter_config(ctx)["max_age"] == 2 * 3_600 * 1_000_000_000

      System.put_env("OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS", "0")
      assert :ok = DeadLetters.ensure(ctx.conn, "optimal")
      assert dead_letter_config(ctx)["max_age"] == 0

      # Not a whole number of hours: the default, never a crash, and said so.
      System.put_env("OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS", "soon")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert DeadLetters.max_age_ms() == 720 * 3_600_000
        end)

      assert log =~ "OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS"
    end

    test "is the limit the work queue provisions the dead letters with", ctx do
      System.put_env("OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS", "5")
      q = queue(ctx, dead_letter_after: 1)
      IntakeQueue.drain_now(q)

      assert wait_for(fn ->
               match?(
                 %{config: %{"max_age" => _}},
                 NATSStub.streams(ctx.stub)["OPTIMAL_DEAD_LETTERS"]
               )
             end)

      assert dead_letter_config(ctx)["max_age"] == 5 * 3_600 * 1_000_000_000
    end
  end
end
