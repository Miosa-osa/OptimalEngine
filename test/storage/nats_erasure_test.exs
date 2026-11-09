defmodule OptimalEngine.Storage.NATSErasureTest do
  @moduledoc """
  What the Engine forgets leaves NATS too. The ledger stream keeps one subject
  per row (`<ns>.ledger.<tenant>.<workspace>.<table>.<row>`), so when the
  ledger carries a delete (an erasure, a retention delete, a derived-data
  removal) or a memory forget, the row's earlier messages are purged before the
  tombstone goes out, a republish never sends a row a later change forgot, and
  an archived or removed workspace has its whole subject tree purged, even when
  NATS was down when it happened. Every purge is an `events` row, and an
  erasure's report and audit event say what it removed from NATS.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Memory, Store, Sync, Workspace}
  alias OptimalEngine.Compliance.Erasure
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Storage.NATS.{Connection, LedgerPublisher, Protocol}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NATSStub

  setup do
    n = System.unique_integer([:positive])
    tenant = "natsera-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS erasure #{n}"})

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

    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)

    conn = :"nats_era_conn_#{n}"

    start_supervised!(
      {Connection, name: conn, url: "nats://127.0.0.1:#{stub.port}", backoff: {20, 100}},
      id: conn
    )

    assert wait_for(fn -> Connection.connected?(conn) end)

    pub = :"nats_era_pub_#{n}"

    start_supervised!(
      {LedgerPublisher,
       name: pub,
       connection: conn,
       namespace: "optimal",
       enabled: true,
       interval_ms: 0,
       workspaces: [ws.id]},
      id: pub
    )

    %{tenant: tenant, ws: ws.id, n: n, stub: stub, conn: conn, pub: pub}
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  defp insert_context(ctx, id, content, created_by \\ nil) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_by, created_at) VALUES (?1, ?2, ?3, 'T', ?4, ?5, '2026-10-14T10:00:00Z')",
        [id, ctx.tenant, ctx.ws, content, created_by]
      )
  end

  defp stream_text(stub),
    do: stub |> NATSStub.messages("OPTIMAL_LEDGER") |> Enum.map_join("\n", & &1.data)

  defp purge_events(ctx) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT target_uri, metadata FROM events WHERE tenant_id = ?1 AND kind = 'nats_purge' ORDER BY id",
        [ctx.tenant]
      )

    Enum.map(rows, fn [uri, meta] -> {uri, Jason.decode!(meta)} end)
  end

  # The ledger publisher reads SQLite's ledger and refuses another store
  # (`{:error, :unsupported_store}`), so this runs with the Engine on SQLite.
  @tag :sqlite_store
  test "each row has a subject of its own under its workspace", ctx do
    insert_context(ctx, "row-#{ctx.n}", "kept text")
    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)

    prefix = "optimal.ledger.#{Protocol.token(ctx.tenant)}.#{Protocol.token(ctx.ws)}."

    assert Enum.any?(
             NATSStub.messages(ctx.stub, "OPTIMAL_LEDGER"),
             &(&1.subject == prefix <> "contexts." <> Protocol.token("row-#{ctx.n}"))
           )

    assert Enum.all?(
             NATSStub.messages(ctx.stub, "OPTIMAL_LEDGER"),
             &String.starts_with?(&1.subject, prefix)
           )
  end

  # The ledger publisher reads SQLite's ledger and refuses another store
  # (`{:error, :unsupported_store}`), so this runs with the Engine on SQLite.
  @tag :sqlite_store
  test "a deleted row's earlier messages are purged and only its key's tombstone stays", ctx do
    insert_context(ctx, "gone-#{ctx.n}", "secret words #{ctx.n}")
    insert_context(ctx, "stays-#{ctx.n}", "public words #{ctx.n}")
    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)
    assert stream_text(ctx.stub) =~ "secret words #{ctx.n}"

    {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", ["gone-#{ctx.n}"])
    assert {:ok, %{purged: purged}} = LedgerPublisher.publish_now(ctx.pub)
    assert purged >= 1

    text = stream_text(ctx.stub)
    refute text =~ "secret words #{ctx.n}"
    assert text =~ "public words #{ctx.n}"

    tombstones =
      for m <- NATSStub.messages(ctx.stub, "OPTIMAL_LEDGER"),
          %{"operation" => "delete", "entity_id" => "gone-" <> _} = change <- [
            Jason.decode!(m.data)
          ],
          do: change

    assert [%{"payload" => %{"row" => row}}] = tombstones
    assert Map.keys(row) == ["id"]

    assert [{"workspace:" <> _, %{"messages_purged" => n, "rows_forgotten" => 1}}] =
             purge_events(ctx)

    assert n >= 1
  end

  # The ledger publisher reads SQLite's ledger and refuses another store
  # (`{:error, :unsupported_store}`), so this runs with the Engine on SQLite.
  @tag :sqlite_store
  test "a republish never sends a row a later change forgot", ctx do
    insert_context(ctx, "late-#{ctx.n}", "forgotten words #{ctx.n}")
    {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", ["late-#{ctx.n}"])

    # Never published before the delete: the create is withheld, the tombstone goes.
    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)
    refute stream_text(ctx.stub) =~ "forgotten words #{ctx.n}"
    assert stream_text(ctx.stub) =~ ~s("entity_id":"late-#{ctx.n}")
  end

  # Memory.forget soft-forgets the memory row. The source package and claim its
  # creation wrote keep their text in the Engine, and so on the stream: NATS
  # holds what the Engine holds, no more.
  # The ledger publisher reads SQLite's ledger and refuses another store
  # (`{:error, :unsupported_store}`), so this runs with the Engine on SQLite.
  @tag :sqlite_store
  test "a forgotten memory's messages are purged and its tombstone carries no text", ctx do
    {:ok, mem} =
      Memory.create(%{
        content: "remember the vault code #{ctx.n}",
        workspace_id: ctx.ws,
        tenant_id: ctx.tenant
      })

    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)

    subject =
      "optimal.ledger.#{Protocol.token(ctx.tenant)}.#{Protocol.token(ctx.ws)}.memories.#{Protocol.token(mem.id)}"

    on_row = fn ->
      Enum.filter(NATSStub.messages(ctx.stub, "OPTIMAL_LEDGER"), &(&1.subject == subject))
    end

    assert Enum.any?(on_row.(), &(&1.data =~ "vault code #{ctx.n}"))

    :ok = Memory.forget(mem.id, reason: "asked to forget #{ctx.n}")
    assert {:ok, %{purged: purged}} = LedgerPublisher.publish_now(ctx.pub)
    assert purged >= 1

    assert [tombstone] = on_row.()
    refute tombstone.data =~ "vault code #{ctx.n}"
    refute tombstone.data =~ "asked to forget #{ctx.n}"
    assert %{"payload" => %{"row" => %{"is_forgotten" => 1}}} = Jason.decode!(tombstone.data)
  end

  # The ledger publisher reads SQLite's ledger and refuses another store
  # (`{:error, :unsupported_store}`), so this runs with the Engine on SQLite.
  @tag :sqlite_store
  test "an erasure reaches NATS and its report and audit event say what went", ctx do
    principal = "user:natsera-#{ctx.n}@test"
    {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Erased #{ctx.n}"})
    insert_context(ctx, "erase-#{ctx.n}", "personal data #{ctx.n}", principal)
    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)
    assert stream_text(ctx.stub) =~ "personal data #{ctx.n}"

    previous = Application.get_env(:optimal_engine, :nats_ledger_publisher)
    Application.put_env(:optimal_engine, :nats_ledger_publisher, ctx.pub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_engine, :nats_ledger_publisher, previous),
        else: Application.delete_env(:optimal_engine, :nats_ledger_publisher)
    end)

    assert {:ok, report} = Erasure.erase(principal, tenant_id: ctx.tenant)
    assert %{state: "caught_up", messages_purged: purged} = report.nats_ledger
    assert purged >= 1
    refute stream_text(ctx.stub) =~ "personal data #{ctx.n}"

    {:ok, [[meta]]} =
      Store.raw_query(
        "SELECT metadata FROM events WHERE tenant_id = ?1 AND kind = 'erasure' AND target_uri = ?2",
        [ctx.tenant, "principal:#{principal}"]
      )

    assert %{"nats_ledger" => %{"messages_purged" => ^purged}} = Jason.decode!(meta)
  end

  # The ledger publisher reads SQLite's ledger and refuses another store
  # (`{:error, :unsupported_store}`), so this runs with the Engine on SQLite.
  @tag :sqlite_store
  test "an archived workspace has its whole subject tree purged, and the purge is recorded", ctx do
    insert_context(ctx, "arch-#{ctx.n}", "archived words #{ctx.n}")
    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)

    assert {:ok, %{messages_purged: n}} =
             LedgerPublisher.forget_workspace(ctx.pub, ctx.tenant, ctx.ws, "archived")

    assert n >= 1
    assert NATSStub.messages(ctx.stub, "OPTIMAL_LEDGER") == []

    assert Enum.any?(purge_events(ctx), fn {_uri, meta} ->
             meta["workspace_id"] == ctx.ws and meta["reason"] == "archived" and
               meta["messages_purged"] == n
           end)
  end

  # The ledger publisher reads SQLite's ledger and refuses another store
  # (`{:error, :unsupported_store}`), so this runs with the Engine on SQLite.
  @tag :sqlite_store
  test "a workspace forgotten while NATS is down is purged once NATS is back", ctx do
    insert_context(ctx, "down-#{ctx.n}", "words before the outage #{ctx.n}")
    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)

    # The server goes and comes back with its streams, as a restart does: drop
    # the connections, refuse new ones for a while.
    port = ctx.stub.port
    :gen_tcp.close(ctx.stub.listener)
    NATSStub.drop(ctx.stub)
    assert wait_for(fn -> not Connection.connected?(ctx.conn) end)

    {:ok, _} = Store.raw_query("UPDATE workspaces SET status = 'archived' WHERE id = ?1", [ctx.ws])

    assert {:ok, %{pending: true}} =
             LedgerPublisher.forget_workspace(ctx.pub, ctx.tenant, ctx.ws, "archived")

    {:ok, back} = NATSStub.restart(ctx.stub, port)
    on_exit(fn -> NATSStub.stop(back) end)
    assert wait_for(fn -> Connection.connected?(ctx.conn) end, 200)

    assert {:ok, _} = LedgerPublisher.publish_now(ctx.pub)
    refute stream_text(back) =~ "words before the outage #{ctx.n}"

    assert Enum.any?(purge_events(ctx), fn
             {"nats-purge-request:" <> _, meta} ->
               meta["workspace_id"] == ctx.ws

             _ ->
               false
           end)
  end

  test "Workspace.archive asks the Engine's publisher to forget the workspace" do
    # The Engine's own publisher is off in tests: archiving still works and
    # records nothing for NATS.
    n = System.unique_integer([:positive])
    {:ok, _} = Tenant.create(%{id: "natsarch-#{n}", name: "A #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "natsarch-#{n}:org",
        tenant_id: "natsarch-#{n}",
        slug: "org",
        name: "Org"
      })

    {:ok, ws} =
      Workspace.create(%{
        tenant_id: "natsarch-#{n}",
        organization_id: "natsarch-#{n}:org",
        slug: "a",
        name: "A"
      })

    assert :ok = Workspace.archive(ws.id)

    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM events WHERE tenant_id = ?1 AND kind LIKE 'nats_%'", [
        "natsarch-#{n}"
      ])

    assert count == 0
  end
end
