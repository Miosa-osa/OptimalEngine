defmodule OptimalEngine.Storage.NATSWorkQueueIntegrationTest do
  @moduledoc """
  Connector intake and job dispatch through real JetStream work queues
  (`OPTIMAL_TEST_NATS_URL`, `nats -js`). Skipped without a server. The
  namespace, and so every stream, is the test's own and is deleted after.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Jobs, Signal, Store, Workspace}
  alias OptimalEngine.Connectors.PullScheduler
  alias OptimalEngine.Storage.NATS.{Connection, IntakeQueue, JetStream, JobQueue}
  alias OptimalEngine.Tenancy.Tenant

  @url System.get_env("OPTIMAL_TEST_NATS_URL")

  if is_nil(@url) or @url == "" do
    @moduletag skip: "set OPTIMAL_TEST_NATS_URL to a JetStream server (nats -js) to run"
  end

  @moduletag :nats_integration

  setup do
    n = System.unique_integer([:positive])
    tenant = "natswqit-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS WQ IT #{n}"})

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

    conn = :"nats_wq_it_#{n}"
    start_supervised!({Connection, name: conn, url: @url, backoff: {50, 500}}, id: conn)
    assert wait_for(fn -> Connection.connected?(conn) end)

    namespace = "wq" <> String.downcase(Base.encode16(:crypto.strong_rand_bytes(4)))

    on_exit(fn ->
      name = :"nats_wq_it_cleanup_#{System.unique_integer([:positive])}"
      {:ok, pid} = Connection.start_link(name: name, url: @url)
      wait_for(fn -> Connection.connected?(name) end)

      for suffix <- ~w(INTAKE JOBS),
          do: JetStream.api(name, "STREAM.DELETE.#{String.upcase(namespace)}_#{suffix}")

      GenServer.stop(pid)
    end)

    %{tenant: tenant, ws: ws.id, n: n, conn: conn, namespace: namespace}
  end

  defp wait_for(fun, tries \\ 150) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  defp queue(module, ctx, extra \\ []) do
    name = :"nats_wq_it_q_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      connection: ctx.conn,
      namespace: ctx.namespace,
      enabled: true,
      interval_ms: 0
    ]

    start_supervised!({module, opts ++ extra}, id: name)
    name
  end

  test "a pulled Signal is queued, survives the consumer's restart, and is ingested once", ctx do
    id = "nats-wq-it-#{ctx.n}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO connectors (id, tenant_id, workspace_id, kind, config, enabled) VALUES (?1, ?2, ?3, 'sources_folder', '{}', 1)",
        [id, ctx.tenant, ctx.ws]
      )

    scope = %{
      workspace_id: ctx.ws,
      tenant_id: ctx.tenant,
      connector_id: id,
      kind: "sources_folder",
      config: %{}
    }

    signal = %Signal{
      id: "it-sig-#{ctx.n}",
      title: "Queued #{ctx.n}",
      content: "A queued note #{ctx.n}",
      genre: "note",
      mode: :linguistic,
      type: :inform,
      format: :markdown,
      created_at: ~U[2026-11-01 10:00:00Z],
      entities: []
    }

    first = queue(IntakeQueue, ctx)
    sink = PullScheduler.intake_sink(queue: first)
    assert {:ok, 0} = sink.([signal], scope)
    assert {:ok, 0} = sink.([signal], scope)
    stop_supervised!(first)

    second = queue(IntakeQueue, ctx)
    assert {:ok, %{acked: 1}} = IntakeQueue.drain_now(second)

    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1 AND title = ?2", [
        ctx.tenant,
        "Queued #{ctx.n}"
      ])

    assert count == 1
    assert {:ok, %{acked: 0}} = IntakeQueue.drain_now(second)
  end

  test "a queued job wakes its worker and its message leaves the queue once it is done", ctx do
    test = self()
    kind = "natsit.#{ctx.n}"

    wake = fn k ->
      send(test, {:woken, k})
      Jobs.run_next(fn _job -> :ok end, kinds: [k])
    end

    q = queue(JobQueue, ctx, wake: %{kind => wake}, recheck_ms: 100)
    {:ok, job} = Jobs.enqueue(ctx.ws, kind, %{})
    :ok = JobQueue.announce(q, job)

    assert wait_for(fn ->
             JobQueue.drain_now(q)
             match?({:ok, %{status: "completed"}}, Jobs.fetch(job.id))
           end)

    assert_received {:woken, ^kind}

    stream = String.upcase(ctx.namespace) <> "_JOBS"

    assert wait_for(fn ->
             JobQueue.drain_now(q)

             {:ok, info} =
               JetStream.api(ctx.conn, "STREAM.INFO." <> stream, %{"subjects_filter" => ">"})

             not Map.has_key?(
               info["state"]["subjects"] || %{},
               "#{ctx.namespace}.jobs.natsit%2E#{ctx.n}"
             )
           end)
  end
end
