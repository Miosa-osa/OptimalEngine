defmodule OptimalEngine.Storage.NATSLedgerIntegrationTest do
  @moduledoc """
  The change ledger published to a real JetStream server
  (`OPTIMAL_TEST_NATS_URL`, `nats -js`): in order, once, and resumed from
  what the stream holds after a restart. Skipped without a server. The
  namespace, and so the stream, is the test's own and is deleted afterwards.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Storage.NATS.{Connection, JetStream, LedgerPublisher, Protocol}
  alias OptimalEngine.Tenancy.Tenant

  @url System.get_env("OPTIMAL_TEST_NATS_URL")

  if is_nil(@url) or @url == "" do
    @moduletag skip: "set OPTIMAL_TEST_NATS_URL to a JetStream server (nats -js) to run"
  end

  @moduletag :nats_integration

  setup do
    n = System.unique_integer([:positive])
    tenant = "natsit-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS IT #{n}"})

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
        slug: "notes",
        name: "Notes"
      })

    {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")

    conn = :"nats_ledger_it_#{n}"
    start_supervised!({Connection, name: conn, url: @url, backoff: {50, 500}}, id: conn)
    assert wait_for(fn -> Connection.connected?(conn) end)

    namespace = "it" <> String.downcase(Base.encode16(:crypto.strong_rand_bytes(4)))
    stream = String.upcase(namespace) <> "_LEDGER"
    on_exit(fn -> delete_stream(stream) end)

    %{tenant: tenant, ws: ws.id, n: n, conn: conn, namespace: namespace, stream: stream}
  end

  defp delete_stream(stream) do
    name = :"nats_ledger_it_cleanup_#{System.unique_integer([:positive])}"
    {:ok, pid} = Connection.start_link(name: name, url: @url)
    wait_for(fn -> Connection.connected?(name) end)
    JetStream.api(name, "STREAM.DELETE." <> stream)
    GenServer.stop(pid)
  end

  defp publisher(ctx) do
    name = :"nats_ledger_it_pub_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LedgerPublisher,
       name: name,
       connection: ctx.conn,
       namespace: ctx.namespace,
       enabled: true,
       interval_ms: 0,
       workspaces: [ctx.ws]},
      id: name
    )

    name
  end

  defp insert_context(ctx, id, title) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, ?4, 'body', '2026-10-14T10:00:00Z')",
        [id, ctx.tenant, ctx.ws, title]
      )
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  test "the ledger goes out in order, once, and a restart resumes from the stream", ctx do
    for i <- 1..3, do: insert_context(ctx, "it#{i}-#{ctx.n}", "I#{i}")

    first = publisher(ctx)
    assert {:ok, %{published: published}} = LedgerPublisher.publish_now(first)
    assert published >= 3
    stop_supervised!(first)

    insert_context(ctx, "it4-#{ctx.n}", "I4")
    second = publisher(ctx)
    assert {:ok, %{published: 1}} = LedgerPublisher.publish_now(second)
    assert %{state: "caught_up", workspaces: [%{backlog: 0}]} = LedgerPublisher.status(second)

    # Read the stream back through a durable consumer, as a subscriber would.
    subject = "#{ctx.namespace}.ledger.#{Protocol.token(ctx.tenant)}.#{Protocol.token(ctx.ws)}.>"

    {:ok, _} =
      JetStream.ensure_consumer(ctx.conn, ctx.stream, %{
        durable_name: "reader",
        filter_subject: subject
      })

    {:ok, messages} = JetStream.fetch(ctx.conn, ctx.stream, "reader", batch: 50, no_wait: true)
    Enum.each(messages, &JetStream.ack(ctx.conn, &1))

    sequences = Enum.map(messages, &String.to_integer(&1.headers["Optimal-Ledger-Seq"]))
    assert sequences == Enum.sort(sequences)
    assert length(sequences) == length(Enum.uniq(sequences))

    titles =
      for m <- messages,
          %{"entity_type" => "contexts", "payload" => %{"row" => %{"title" => t}}} <- [
            Jason.decode!(m.payload)
          ],
          do: t

    assert titles == ~w(I1 I2 I3 I4)
  end
end
