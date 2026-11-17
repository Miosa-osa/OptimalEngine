defmodule OptimalEngine.Storage.NATSLedgerRedactionIntegrationTest do
  @moduledoc """
  What an erasure takes out of the ledger leaves a real JetStream stream
  (`OPTIMAL_TEST_NATS_URL`, `nats -js`) too: a forgotten memory, a deleted
  memory and a context redacted in place by retention are published first,
  then erased, and no message under the workspace's subjects holds their text
  afterwards. Skipped without a server. The namespace, and so the stream, is
  the test's own and is deleted afterwards.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.Retention
  alias OptimalEngine.{Memory, Store, Sync, Workspace}
  alias OptimalEngine.Storage.NATS.{Connection, JetStream, LedgerPublisher, Protocol}
  alias OptimalEngine.Tenancy.Tenant

  @url System.get_env("OPTIMAL_TEST_NATS_URL")

  if is_nil(@url) or @url == "" do
    @moduletag skip: "set OPTIMAL_TEST_NATS_URL to a JetStream server (nats -js) to run"
  end

  @moduletag :nats_integration

  setup do
    n = System.unique_integer([:positive])
    tenant = "natsredact-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS redact #{n}"})

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

    conn = :"nats_redact_it_#{n}"
    start_supervised!({Connection, name: conn, url: @url, backoff: {50, 500}}, id: conn)
    assert wait_for(fn -> Connection.connected?(conn) end)

    namespace = "rd" <> String.downcase(Base.encode16(:crypto.strong_rand_bytes(4)))
    stream = String.upcase(namespace) <> "_LEDGER"
    on_exit(fn -> delete_stream(stream) end)

    pub = :"nats_redact_it_pub_#{n}"

    start_supervised!(
      {LedgerPublisher,
       name: pub,
       connection: conn,
       namespace: namespace,
       enabled: true,
       interval_ms: 0,
       workspaces: [ws.id]},
      id: pub
    )

    # The erasure paths flush the publisher the Engine is configured with.
    previous = Application.get_env(:optimal_engine, :nats_ledger_publisher)
    Application.put_env(:optimal_engine, :nats_ledger_publisher, pub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_engine, :nats_ledger_publisher, previous),
        else: Application.delete_env(:optimal_engine, :nats_ledger_publisher)
    end)

    %{tenant: tenant, ws: ws.id, n: n, conn: conn, namespace: namespace, stream: stream, pub: pub}
  end

  test "a forgotten memory, a deleted memory and a redacted context leave the stream", ctx do
    forgotten = "forgotten-#{ctx.n}-#{System.unique_integer([:positive])}"
    deleted = "deleted-#{ctx.n}-#{System.unique_integer([:positive])}"
    email = "jane.#{ctx.n}@example.com"

    {:ok, kept} = Memory.create(%{content: "forget me #{forgotten}", workspace_id: ctx.ws})
    {:ok, gone} = Memory.create(%{content: "delete me #{deleted}", workspace_id: ctx.ws})
    context_id = "ctx-nats-#{ctx.n}"

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, l0_abstract, l1_overview, genre, node, created_at)
        VALUES (?1, ?2, ?3, ?4, 't', ?5, ?5, ?5, 'note', 'person-operator', '2020-01-01T00:00:00Z')
        """,
        [context_id, ctx.tenant, ctx.ws, "optimal://nats/#{context_id}", "write to #{email}"]
      )

    assert {:ok, %{published: published}} = LedgerPublisher.publish_now(ctx.pub)
    assert published >= 3

    on_stream = messages(ctx, "before")
    assert Enum.any?(on_stream, &(&1 =~ forgotten))
    assert Enum.any?(on_stream, &(&1 =~ deleted))
    assert Enum.any?(on_stream, &(&1 =~ email))

    # Each erasure flushes the publisher itself.
    assert :ok = Memory.forget(kept.id)
    assert :ok = Memory.delete(gone.id)

    {:ok, _} =
      Retention.add_policy(
        tenant_id: ctx.tenant,
        scope_type: "tenant",
        ttl_days: 1,
        action: "redact"
      )

    assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)

    # Nothing left for a later pass to purge.
    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)

    after_erasure = memory_and_context_messages(ctx, "after", [kept.id, gone.id, context_id])
    assert after_erasure != []

    for {subject, body} <- after_erasure do
      refute body =~ forgotten, "#{subject} still holds the forgotten memory's text"
      refute body =~ deleted, "#{subject} still holds the deleted memory's text"
      refute body =~ email, "#{subject} still holds the redacted context's text"
    end

    # The context's subject holds what stands now: the redacted text.
    assert Enum.any?(after_erasure, fn {_subject, body} -> body =~ "<REDACTED:email>" end)
  end

  defp messages(ctx, durable) do
    for {_subject, body} <- fetch_all(ctx, durable), do: body
  end

  # The messages on the subjects of the memories' and the context's rows.
  defp memory_and_context_messages(ctx, durable, ids) do
    tokens = Enum.map(ids, &Protocol.token/1)

    for {subject, body} <- fetch_all(ctx, durable),
        Enum.any?(tokens, &String.ends_with?(subject, "." <> &1)) or body =~ "ledger_redactions",
        do: {subject, body}
  end

  defp fetch_all(ctx, durable) do
    subject = "#{ctx.namespace}.ledger.#{Protocol.token(ctx.tenant)}.#{Protocol.token(ctx.ws)}.>"

    {:ok, _} =
      JetStream.ensure_consumer(ctx.conn, ctx.stream, %{
        durable_name: durable,
        filter_subject: subject
      })

    {:ok, messages} = JetStream.fetch(ctx.conn, ctx.stream, durable, batch: 500, no_wait: true)
    Enum.each(messages, &JetStream.ack(ctx.conn, &1))
    Enum.map(messages, &{&1.subject, &1.payload})
  end

  defp delete_stream(stream) do
    name = :"nats_redact_it_cleanup_#{System.unique_integer([:positive])}"
    {:ok, pid} = Connection.start_link(name: name, url: @url)
    wait_for(fn -> Connection.connected?(name) end)
    JetStream.api(name, "STREAM.DELETE." <> stream)
    GenServer.stop(pid)
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end
end
