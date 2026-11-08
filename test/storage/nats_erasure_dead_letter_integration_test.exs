defmodule OptimalEngine.Storage.NATSErasureDeadLetterIntegrationTest do
  @moduledoc """
  Against a real JetStream server (`OPTIMAL_TEST_NATS_URL`, `nats -js`): a
  deleted row's messages purged by its subject, a workspace's subject tree
  purged, and an intake item dead-lettered at its cap, listed, requeued and
  removed. Skipped without a server; every stream is the test's own namespace
  and is deleted afterwards.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Signal, Store, Sync, Workspace}
  alias OptimalEngine.Connectors.PullScheduler

  alias OptimalEngine.Storage.NATS.{
    Connection,
    DeadLetters,
    IntakeQueue,
    JetStream,
    LedgerPublisher
  }

  alias OptimalEngine.Tenancy.Tenant

  @url System.get_env("OPTIMAL_TEST_NATS_URL")

  if is_nil(@url) or @url == "" do
    @moduletag skip: "set OPTIMAL_TEST_NATS_URL to a JetStream server (nats -js) to run"
  end

  @moduletag :nats_integration

  setup do
    n = System.unique_integer([:positive])
    tenant = "natsedit-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS ED IT #{n}"})

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

    conn = :"nats_edit_#{n}"
    start_supervised!({Connection, name: conn, url: @url, backoff: {50, 500}}, id: conn)
    assert wait_for(fn -> Connection.connected?(conn) end)

    namespace = "ed" <> String.downcase(Base.encode16(:crypto.strong_rand_bytes(4)))

    on_exit(fn ->
      name = :"nats_edit_cleanup_#{System.unique_integer([:positive])}"
      {:ok, pid} = Connection.start_link(name: name, url: @url)
      wait_for(fn -> Connection.connected?(name) end)

      for suffix <- ~w(LEDGER INTAKE DEAD_LETTERS),
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

  defp ledger_subjects(ctx) do
    stream = String.upcase(ctx.namespace) <> "_LEDGER"

    {:ok, %{"state" => state}} =
      JetStream.api(ctx.conn, "STREAM.INFO." <> stream, %{
        "subjects_filter" => "#{ctx.namespace}.ledger.>"
      })

    state["subjects"] || %{}
  end

  test "a deleted row's messages and then a whole workspace leave the real stream", ctx do
    {:ok, _} = Sync.enable(ctx.tenant, ctx.ws, "user:owner")
    pub = :"nats_edit_pub_#{ctx.n}"

    start_supervised!(
      {LedgerPublisher,
       name: pub,
       connection: ctx.conn,
       namespace: ctx.namespace,
       enabled: true,
       interval_ms: 0,
       workspaces: [ctx.ws]},
      id: pub
    )

    for id <- ["a-#{ctx.n}", "b-#{ctx.n}"] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, 'T', 'secret', '2026-10-14T10:00:00Z')",
          [id, ctx.tenant, ctx.ws]
        )
    end

    assert {:ok, _} = LedgerPublisher.publish_now(pub)

    a_subject =
      Enum.find(Map.keys(ledger_subjects(ctx)), &String.ends_with?(&1, ".contexts.a-#{ctx.n}"))

    assert ledger_subjects(ctx)[a_subject] == 1

    {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", ["a-#{ctx.n}"])
    assert {:ok, %{purged: purged, forgotten: 1}} = LedgerPublisher.publish_now(pub)
    assert purged >= 1

    # Only the tombstone is left on the row's subject.
    assert ledger_subjects(ctx)[a_subject] == 1

    {:ok, [m]} =
      JetStream.api(ctx.conn, "STREAM.MSG.GET.#{String.upcase(ctx.namespace)}_LEDGER", %{
        "last_by_subj" => a_subject
      })
      |> then(fn {:ok, %{"message" => msg}} -> {:ok, [msg]} end)

    assert %{"operation" => "delete"} = m["data"] |> Base.decode64!() |> Jason.decode!()

    assert {:ok, %{messages_purged: n}} =
             LedgerPublisher.forget_workspace(pub, ctx.tenant, ctx.ws, "archived")

    assert n >= 2
    assert ledger_subjects(ctx) == %{}
  end

  test "an intake item is dead-lettered at its cap, listed, requeued and removed", ctx do
    id = "nats-edit-#{ctx.n}"

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

    q = :"nats_edit_q_#{ctx.n}"

    start_supervised!(
      {IntakeQueue,
       name: q,
       connection: ctx.conn,
       namespace: ctx.namespace,
       enabled: true,
       interval_ms: 0,
       dead_letter_after: 2,
       retry_ms: 10,
       ingest: fn _signal, _scope -> raise "always fails" end},
      id: q
    )

    signal = %Signal{id: "edit-#{ctx.n}", title: "x", content: "x", genre: "note", entities: []}
    assert {:ok, 0} = PullScheduler.intake_sink(queue: q).([signal], scope)

    assert wait_for(fn ->
             IntakeQueue.drain_now(q)
             IntakeQueue.status(q).dead_lettered == 1
           end)

    assert {:ok, [letter]} = DeadLetters.list(ctx.conn, ctx.namespace)
    assert %{flow: "intake", delivered: 2} = letter
    assert letter.error =~ "always fails"
    assert %{total: 1, flows: %{"intake" => 1}} = DeadLetters.summary(ctx.conn, ctx.namespace)

    assert {:ok, %{requeued: _}} = DeadLetters.requeue(ctx.conn, ctx.namespace, letter.seq)
    assert {:ok, []} = DeadLetters.list(ctx.conn, ctx.namespace)
    assert {:error, :not_found} = DeadLetters.requeue(ctx.conn, ctx.namespace, letter.seq)

    {:ok, %{"state" => %{"messages" => 1}}} =
      JetStream.api(ctx.conn, "STREAM.INFO.#{String.upcase(ctx.namespace)}_INTAKE")
  end
end
