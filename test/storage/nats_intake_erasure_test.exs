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

  describe "review 2: the write itself is fenced" do
    defp race_message(ctx, workspace, tag) do
      %{
        subject: "optimal.intake.#{ctx.tenant}.#{ctx.connectors[workspace]}",
        payload:
          Jason.encode!(%{
            "tenant_id" => ctx.tenant,
            "connector_id" => ctx.connectors[workspace],
            "workspace_id" => workspace,
            "signal" => IntakeQueue.encode_signal(long_signal(ctx, tag))
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

    defp long_signal(ctx, tag) do
      %{
        signal(ctx, tag, 1)
        | content:
            "zqintake#{tag}#{ctx.n}xv " <>
              String.duplicate("A meeting note about the quarterly plan and its owners. ", 6)
      }
    end

    defp written(workspace) do
      {:ok, [[contexts]]} =
        Store.raw_query("SELECT count(*) FROM contexts WHERE workspace_id = ?1", [workspace])

      {:ok, [[packages]]} =
        Store.raw_query("SELECT count(*) FROM source_packages WHERE workspace_id = ?1", [
          workspace
        ])

      contexts + packages
    end

    test "a queued Signal is ingested when nothing changed", ctx do
      assert :ack = IntakeQueue.handle_message(race_message(ctx, ctx.other, "fenced-ok"), %{})
      assert written(ctx.other) > 0
    end

    test "an archive that commits between the check and the write wins", ctx do
      archive_first = fn signal, scope ->
        :ok = Workspace.archive(ctx.ws)
        PullScheduler.ingest_signal(signal, scope)
      end

      assert :term =
               IntakeQueue.handle_message(race_message(ctx, ctx.ws, "fenced-archive"), %{
                 ingest: archive_first
               })

      assert written(ctx.ws) == 0
    end

    test "a connector delete that commits between the check and the write wins", ctx do
      delete_first = fn signal, scope ->
        {:ok, _} =
          Store.raw_query("DELETE FROM connectors WHERE id = ?1", [ctx.connectors[ctx.ws]])

        PullScheduler.ingest_signal(signal, scope)
      end

      assert :term =
               IntakeQueue.handle_message(race_message(ctx, ctx.ws, "fenced-delete"), %{
                 ingest: delete_first
               })

      assert written(ctx.ws) == 0
    end

    test "a connector row without a workspace ingests into the payload's, or the default one" do
      assert IntakeQueue.target_workspace(%{workspace_id: nil}, %{"workspace_id" => "t:ws"}) ==
               "t:ws"

      assert IntakeQueue.target_workspace(%{workspace_id: nil}, %{}) == Workspace.default_id()

      assert IntakeQueue.target_workspace(%{workspace_id: "t:own"}, %{"workspace_id" => "t:ws"}) ==
               "t:own"
    end

    test "an untenanted offer is published under the default tenant, where its removal looks",
         ctx do
      {:ok, default_ws} = Workspace.create(%{slug: "ie-offer-#{ctx.n}", name: "IE offer"})
      q = queue(ctx)
      IntakeQueue.drain_now(q)

      scope = %{
        workspace_id: default_ws.id,
        tenant_id: nil,
        connector_id: "untenanted-offer-#{ctx.n}"
      }

      assert {[_], []} = IntakeQueue.offer(q, [signal(ctx, "offered", 1)], scope)

      [message] =
        for m <- NATSStub.messages(ctx.stub, "OPTIMAL_INTAKE"),
            String.contains?(m.data, "zqintakeoffered#{ctx.n}xv"),
            do: m

      assert message.subject == "optimal.intake.default.untenanted-offer-#{ctx.n}"

      assert {:ok, %{queued_purged: 1}} =
               IntakeQueue.forget_workspace("default", default_ws.id, "archived",
                 connection: ctx.conn,
                 namespace: "optimal"
               )

      assert held(ctx, "offered") == []
    end

    test "requests of another namespace never crowd out this one's", ctx do
      fill(ctx)

      for i <- 1..501 do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO events (tenant_id, principal, kind, target_uri, metadata) VALUES (?1, 'system:nats', 'nats_intake_purge_requested', ?2, ?3)",
            [
              ctx.tenant,
              "other-ns-#{ctx.n}-#{i}",
              Jason.encode!(%{"namespace" => "elsewhere#{ctx.n}", "tenant_id" => ctx.tenant})
            ]
          )
      end

      down = :"nats_ie_down3_#{ctx.n}"
      start_supervised!({Connection, name: down, url: nil}, id: down)

      assert {:ok, %{pending: true}} =
               IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
                 connection: down,
                 namespace: "optimal"
               )

      assert {:ok, done} = IntakeQueue.process_requests(ctx.conn, "optimal")
      assert map_size(done) >= 1
      assert held(ctx, "gone") == []
    end
  end

  describe "review 2: the periodic run" do
    defmodule SlowPeriodic do
      @moduledoc false
      @behaviour OptimalEngine.Storage.NATS.WorkQueue
      def flow, do: "slowperiodic"
      def stream_suffix, do: "SLOWPERIODIC"
      def subject_root, do: "slowperiodic"
      def consumer, do: %{}
      def stream_options, do: %{}
      def handle_message(_message, _context), do: :ack
      def periodic_ms(_context), do: 10

      def periodic(_server, %{probe: probe}) do
        :ets.update_counter(probe, :running, 1)
        [{:running, now}] = :ets.lookup(probe, :running)
        :ets.update_counter(probe, :runs, 1)
        if now > :ets.lookup_element(probe, :max, 2), do: :ets.insert(probe, {:max, now})
        Process.sleep(80)
        :ets.update_counter(probe, :running, -1)
        if :ets.lookup_element(probe, :runs, 2) == 2, do: raise("periodic exploded")
        :ok
      end
    end

    test "never overlaps itself, and a run that crashes does not stop the next", ctx do
      probe = :ets.new(:periodic_probe, [:public, :set])
      :ets.insert(probe, [{:running, 0}, {:max, 0}, {:runs, 0}])
      name = :"nats_slow_periodic_#{ctx.n}"

      pid =
        start_supervised!(
          {OptimalEngine.Storage.NATS.WorkQueue,
           {SlowPeriodic,
            name: name,
            connection: ctx.conn,
            namespace: "optimal",
            enabled: true,
            interval_ms: 0,
            probe: probe}},
          id: name
        )

      Process.sleep(600)
      assert Process.alive?(pid)
      assert :ets.lookup_element(probe, :max, 2) == 1
      assert :ets.lookup_element(probe, :runs, 2) >= 3
    end
  end

  describe "review 3: what a fenced ingest leaves" do
    defp packages(workspace) do
      {:ok, rows} =
        Store.raw_query(
          "SELECT id, source_system FROM source_packages WHERE workspace_id = ?1",
          [workspace]
        )

      rows
    end

    defp package!(ctx, workspace, id, source_system) do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO source_packages (id, tenant_id, workspace_id, source_type, source_class, source_system, received_at, content_hash, raw_text, created_at, updated_at) VALUES (?1, ?2, ?3, 'manual', 'text', ?4, '2026-11-01', ?1, 'zqorphan', '2026-11-01', '2026-11-01')",
          [id, ctx.tenant, workspace, source_system]
        )
    end

    test "a queued Signal's package names its connector", ctx do
      assert :ack = IntakeQueue.handle_message(race_message(ctx, ctx.other, "named"), %{})
      connector = ctx.connectors[ctx.other]

      assert Enum.any?(packages(ctx.other), fn [_id, system] ->
               system == "connector:" <> connector
             end)
    end

    # The package commits, then the workspace is archived (here by a trigger on
    # the package insert itself), then the context's fence refuses: the
    # package this ingest wrote goes too.
    @tag :sqlite_store
    test "a context write fenced after the package committed takes the package with it", ctx do
      {:ok, _} =
        Store.raw_query(
          "CREATE TRIGGER fence_archive_after_package AFTER INSERT ON source_packages WHEN NEW.workspace_id = '#{ctx.ws}' BEGIN UPDATE workspaces SET status = 'archived' WHERE id = NEW.workspace_id; END",
          []
        )

      on_exit(fn -> Store.raw_query("DROP TRIGGER IF EXISTS fence_archive_after_package", []) end)

      assert :term = IntakeQueue.handle_message(race_message(ctx, ctx.ws, "orphan"), %{})
      assert written(ctx.ws) == 0
    end

    test "archive removes its connectors' packages no context holds, and nothing else", ctx do
      connector = ctx.connectors[ctx.ws]
      package!(ctx, ctx.ws, "sp-orphan-#{ctx.n}", "connector:" <> connector)
      package!(ctx, ctx.ws, "sp-manual-#{ctx.n}", "manual")
      package!(ctx, ctx.ws, "sp-held-#{ctx.n}", "connector:" <> connector)

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, metadata, created_at) VALUES (?1, ?2, ?3, 't', 'c', ?4, '2026-01-01')",
          [
            "ctx-held-#{ctx.n}",
            ctx.tenant,
            ctx.ws,
            Jason.encode!(%{"source_package_id" => "sp-held-#{ctx.n}"})
          ]
        )

      assert :ok = Workspace.archive(ctx.ws)

      ids = for [id, _] <- packages(ctx.ws), do: id
      refute "sp-orphan-#{ctx.n}" in ids
      assert "sp-manual-#{ctx.n}" in ids
      assert "sp-held-#{ctx.n}" in ids
    end

    test "deleting a connector again sweeps what the first delete left", ctx do
      connector = ctx.connectors[ctx.other]
      assert :ok = Rows.delete(ctx.tenant, connector)
      package!(ctx, ctx.other, "sp-late-#{ctx.n}", "connector:" <> connector)

      assert {:error, :not_found} = Rows.delete(ctx.tenant, connector)
      ids = for [id, _] <- packages(ctx.other), do: id
      refute "sp-late-#{ctx.n}" in ids
    end

    # The backstop (delete_unheld_connector_packages/1) finds a connector's
    # packages by `source_system` "connector:<id>", which Routing writes. Any
    # new code that builds the string is reviewed here: the store matches on
    # it, and the intake queue names its removal request's target with it.
    test "only Routing stamps a package with connector:<id>" do
      stamping =
        for path <- Path.wildcard("lib/**/*.ex"),
            File.read!(path) =~ ~r/"connector:"\s*<>/,
            do: path

      assert Enum.sort(stamping) == [
               "lib/optimal_engine/connectors/routing.ex",
               "lib/optimal_engine/memory_core/store.ex",
               "lib/optimal_engine/storage/nats/intake_queue.ex"
             ]
    end

    test "deleting a connector removes its packages no context holds", ctx do
      connector = ctx.connectors[ctx.other]
      package!(ctx, ctx.other, "sp-conn-orphan-#{ctx.n}", "connector:" <> connector)
      package!(ctx, ctx.other, "sp-conn-other-#{ctx.n}", "connector:someone-else")

      assert :ok = Rows.delete(ctx.tenant, connector)

      ids = for [id, _] <- packages(ctx.other), do: id
      refute "sp-conn-orphan-#{ctx.n}" in ids
      assert "sp-conn-other-#{ctx.n}" in ids
    end
  end

  describe "review 3: the removal requests" do
    defp request!(ctx, metadata) do
      {:ok, [[id]]} =
        Store.raw_query(
          "INSERT INTO events (tenant_id, principal, kind, target_uri, metadata) VALUES (?1, 'system:nats', 'nats_intake_purge_requested', ?2, ?3) RETURNING id",
          [ctx.tenant, "bad-#{ctx.n}-#{System.unique_integer([:positive])}", metadata]
        )

      id
    end

    defp done?(id) do
      {:ok, rows} =
        Store.raw_query("SELECT 1 FROM events WHERE kind = 'nats_purge' AND target_uri = ?1", [
          "nats-intake-purge-request:#{id}"
        ])

      rows != []
    end

    test "a malformed request is set aside with a warning, and the rest are done", ctx do
      fill(ctx)
      bad = request!(ctx, Jason.encode!(%{"namespace" => "optimal", "tenant_id" => 7}))
      junk = request!(ctx, ~s({"namespace": "optimal", "connector_ids": "x"}))

      down = :"nats_ie_down4_#{ctx.n}"
      start_supervised!({Connection, name: down, url: nil}, id: down)

      assert {:ok, %{pending: true}} =
               IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
                 connection: down,
                 namespace: "optimal"
               )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, done} = IntakeQueue.process_requests(ctx.conn, "optimal")
          assert map_size(done) >= 1
        end)

      assert log =~ "malformed"
      assert held(ctx, "gone") == []
      assert done?(bad) and done?(junk)
    end

    # Another Engine's namespace, down for 8 days: its request stays pending
    # for it, and is purged when it is back. Only a namespace recorded as
    # retired has its requests expired.
    test "a request of an Engine down for 8 days is still purged when it is back", ctx do
      fill(ctx)
      down = :"nats_ie_down5_#{ctx.n}"
      start_supervised!({Connection, name: down, url: nil}, id: down)

      assert {:ok, %{pending: true}} =
               IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
                 connection: down,
                 namespace: "optimal"
               )

      {:ok, [[id]]} =
        Store.raw_query(
          "SELECT max(id) FROM events WHERE kind = 'nats_intake_purge_requested' AND tenant_id = ?1",
          [ctx.tenant]
        )

      {:ok, _} =
        Store.raw_query("UPDATE events SET ts = datetime('now', '-8 days') WHERE id = ?1", [id])

      # Another Engine's pass meanwhile (its own namespace) leaves it alone.
      assert {:ok, _} = IntakeQueue.process_requests(ctx.conn, "elsewhere#{ctx.n}")
      refute done?(id)

      # It is reported as waiting.
      assert {:warn, {:nats_intake_removals_pending, waiting}} = IntakeQueue.pending_check()
      assert waiting >= 1

      # Back up: purged, not set aside.
      assert {:ok, done} = IntakeQueue.process_requests(ctx.conn, "optimal")
      assert Map.has_key?(done, id)
      assert held(ctx, "gone") == []
    end

    test "a request of a namespace recorded as retired expires with a warning", ctx do
      ns = "retired#{ctx.n}"
      old = request!(ctx, Jason.encode!(%{"namespace" => ns, "tenant_id" => ctx.tenant}))

      kept =
        request!(ctx, Jason.encode!(%{"namespace" => "paused#{ctx.n}", "tenant_id" => ctx.tenant}))

      for id <- [old, kept] do
        {:ok, _} =
          Store.raw_query("UPDATE events SET ts = datetime('now', '-30 days') WHERE id = ?1", [id])
      end

      assert :ok = IntakeQueue.retire_namespace(ns)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = IntakeQueue.process_requests(ctx.conn, "optimal")
        end)

      assert done?(old)
      refute done?(kept)
      assert log =~ "retired"
    end

    @tag :sqlite_store
    test "a removal whose request the store refuses to record is an error, not pending", ctx do
      {:ok, _} =
        Store.raw_query(
          "CREATE TRIGGER refuse_purge_request BEFORE INSERT ON events WHEN NEW.kind = 'nats_intake_purge_requested' BEGIN SELECT RAISE(ABORT, 'events refused'); END",
          []
        )

      on_exit(fn -> Store.raw_query("DROP TRIGGER IF EXISTS refuse_purge_request", []) end)

      assert {:error, {:request_not_recorded, _}} =
               IntakeQueue.forget_workspace(ctx.tenant, ctx.ws, "archived",
                 connection: ctx.conn,
                 namespace: "optimal"
               )
    end
  end

  describe "review 3: the fence's locks" do
    @tag :postgres_engine
    test "two ingests of one workspace hold the fence at once", ctx do
      fence = %{
        tenant_id: ctx.tenant,
        workspace_id: ctx.other,
        connector_id: ctx.connectors[ctx.other]
      }

      test = self()

      holder =
        Task.async(fn ->
          Store.transaction(fn txn ->
            :ok = OptimalEngine.Connectors.IngestFence.check_in(txn, fence)
            send(test, :held)
            Process.sleep(1_500)
            {:ok, :done}
          end)
        end)

      assert_receive :held, 5_000
      started = System.monotonic_time(:millisecond)

      assert {:ok, :second} =
               Store.transaction(fn txn ->
                 :ok = OptimalEngine.Connectors.IngestFence.check_in(txn, fence)
                 {:ok, :second}
               end)

      assert System.monotonic_time(:millisecond) - started < 1_000
      assert {:ok, :done} = Task.await(holder, 10_000)
    end
  end

  describe "review 3: the periodic run's fallback" do
    test "a run that ends normally is not logged as a failure", ctx do
      probe = :ets.new(:periodic_probe2, [:public, :set])
      :ets.insert(probe, [{:running, 0}, {:max, 0}, {:runs, 10}])
      name = :"nats_slow_periodic_fb_#{ctx.n}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!(
            {OptimalEngine.Storage.NATS.WorkQueue,
             {__MODULE__.SlowPeriodic,
              name: name,
              connection: ctx.conn,
              namespace: "optimal",
              enabled: true,
              interval_ms: 0,
              probe: probe,
              task_supervisor: :"no_such_supervisor_#{ctx.n}"}},
            id: name
          )

          Process.sleep(400)
          stop_supervised!(name)
        end)

      assert :ets.lookup_element(probe, :runs, 2) > 11
      refute log =~ "periodic run failed"
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
