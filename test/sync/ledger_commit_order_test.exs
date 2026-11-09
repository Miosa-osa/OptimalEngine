defmodule OptimalEngine.Sync.LedgerCommitOrderTest do
  @moduledoc """
  On PostgreSQL a `sync_mutations` sequence is drawn when the row is inserted,
  before its writer commits. Readers follow the ledger by sequence (a peer
  pulling `Sync.changes/3`, the NATS ledger publisher), so a writer that drew a
  lower sequence and committed after one that drew a higher one would be
  skipped for good. Every ledger writer takes the ledger lock before it draws
  (`OptimalEngine.Sync.Postgres`, "Ledger sequences commit in order"); these
  tests hold one writer open with its sequence drawn, let another go, read, and
  then let the first commit.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres_store

  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Storage.NATS.{Connection, LedgerPublisher}
  alias OptimalEngine.Storage.PolicyStore
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Sync.Postgres, as: PgCapture
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.LedgerHold
  alias OptimalEngine.TestSupport.NATSStub

  setup do
    n = System.unique_integer([:positive])
    tenant = "ledord-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Ledger order #{n}"})

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

    LedgerHold.install()
    on_exit(&LedgerHold.uninstall/0)

    %{tenant: tenant, ws: ws.id, n: n}
  end

  defp peer_change(ctx, entity_id) do
    id = "mut_rep_order_#{ctx.n}_#{entity_id}"

    %{
      "id" => id,
      "device_id" => "rep_order_#{ctx.n}",
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

  # A storage mutation entry (`POST /api/storage/workspaces/:id/mutations`).
  defp entry_async(ctx, entity_id) do
    Task.async(fn ->
      PolicyStore.append_mutation(%{
        workspace_id: ctx.ws,
        device_id: "app-device",
        entity_type: "memory_object",
        entity_id: entity_id,
        operation: :create,
        payload: %{"text" => entity_id}
      })
    end)
  end

  # A local write, sealed into the ledger by this Engine.
  defp seal_async(ctx, id) do
    Task.async(fn ->
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, ?1, 'body', '2026-11-09T12:00:00Z')",
          [id, ctx.tenant, ctx.ws]
        )

      Capture.seal()
    end)
  end

  # A second Engine on the same database and schema sealing one of its own
  # changes: the seal's write, `Sync.Postgres.write_ledger/3`, run outside this
  # Engine's own seal lock (which is per Engine), as that Engine's seal runs.
  defp other_engine_seal_async(ctx, entity_id) do
    replica = "rep_other_#{ctx.n}"
    payload = Jason.encode!(%{"row" => %{"id" => entity_id, "title" => entity_id}, "blobs" => %{}})

    entry = [
      "mut_#{replica}_1",
      ctx.tenant,
      "#{ctx.tenant}:org",
      ctx.ws,
      replica,
      "contexts",
      entity_id,
      "create",
      payload,
      :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower),
      "#{replica}:1",
      "2026-11-09T12:00:00.000"
    ]

    Task.async(fn -> PgCapture.write_ledger([entry], 0) end)
  end

  # Writer A, a second Engine's seal, stops after drawing its sequence; writer
  # B, this Engine's seal of a local write, goes on. `read` runs once B had its
  # chance to commit (in a task of its own: with the ledger lock B waits for A,
  # and a read that seals first waits for B), and again after A is let go.
  #
  # One Engine alone cannot show this between a seal and an apply: its seals
  # take turns with each other (and a read seals first), and an apply's
  # SERIALIZABLE transaction that a later sequence overtook is aborted and run
  # again with a new sequence. A second Engine's seal, at READ COMMITTED, is
  # not; nor is a storage entry (`writer_b: :entry`).
  defp out_of_order(ctx, read, writer_b \\ :seal) do
    a = "hold-a-#{ctx.n}"
    b = "b-#{ctx.n}"
    hold = LedgerHold.hold(a)

    task_a = other_engine_seal_async(ctx, a)
    assert wait_for(fn -> LedgerHold.waiting?(hold, a) end), "writer A never drew its sequence"

    task_b = if writer_b == :entry, do: entry_async(ctx, b), else: seal_async(ctx, b)
    # Without the ledger lock B commits at once; with it B waits for A.
    b_early = Task.yield(task_b, 1_000)

    first_read = Task.async(fn -> read.(:first) end)
    read_early = Task.yield(first_read, 1_000)

    LedgerHold.release(hold)
    assert {:ok, 1} = Task.await(task_a, 30_000)
    assert {:ok, {:ok, _}} = b_early || {:ok, Task.await(task_b, 30_000)}
    {:ok, first} = read_early || {:ok, Task.await(first_read, 30_000)}

    {a, b, first, read.(:second)}
  end

  defp wait_for(fun, tries \\ 250) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  defp entity_ids(page), do: Enum.map(page["mutations"], & &1["entity_id"])

  test "a change that commits after a later sequence is still served to a pulling peer", ctx do
    {a, b, first, :read_after} =
      out_of_order(ctx, fn
        :first -> Sync.changes(ctx.tenant, ctx.ws, since: 0, requester: "rep_puller")
        :second -> :read_after
      end)

    # The peer goes on from the cursor the first page gave it.
    second = Sync.changes(ctx.tenant, ctx.ws, since: first["cursor"], requester: "rep_puller")

    served = entity_ids(first) ++ entity_ids(second)
    assert a in served, "A (#{inspect(a)}) was never served: #{inspect(served)}"
    assert b in served
    assert served |> Enum.frequencies() |> Map.values() |> Enum.all?(&(&1 == 1))
  end

  test "a change that commits after a later sequence is still read by the storage ledger reader",
       ctx do
    {a, b, first, :read_after} =
      out_of_order(
        ctx,
        fn
          :first -> PolicyStore.mutations_after(ctx.ws, 0)
          :second -> :read_after
        end,
        :entry
      )

    {:ok, first} = first
    cursor = if first == [], do: 0, else: first |> List.last() |> Map.fetch!(:sequence)
    {:ok, second} = PolicyStore.mutations_after(ctx.ws, cursor)

    read = Enum.map(first ++ second, & &1.entity_id)
    assert a in read, "A (#{inspect(a)}) was never read: #{inspect(read)}"
    assert b in read
  end

  test "a change that commits after a later sequence is still published to NATS", ctx do
    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)

    conn = :"ledord_conn_#{ctx.n}"

    start_supervised!(
      {Connection, name: conn, url: "nats://127.0.0.1:#{stub.port}", backoff: {20, 100}},
      id: conn
    )

    assert wait_for(fn -> Connection.connected?(conn) end)
    pub = :"ledord_pub_#{ctx.n}"

    start_supervised!(
      {LedgerPublisher,
       name: pub,
       connection: conn,
       namespace: "optimal",
       enabled: true,
       interval_ms: 0,
       workspaces: [ctx.ws]},
      id: pub
    )

    {a, b, _first, _second} =
      out_of_order(ctx, fn _pass -> LedgerPublisher.publish_now(pub) end)

    published =
      stub
      |> NATSStub.messages("OPTIMAL_LEDGER")
      |> Enum.map(&Jason.decode!(&1.data)["entity_id"])

    assert a in published, "A (#{inspect(a)}) was never published: #{inspect(published)}"
    assert b in published
  end

  test "a rolled-back sequence leaves a gap the readers go past", ctx do
    fail = "fail-#{ctx.n}"
    after_gap = "after-#{ctx.n}"
    before = ledger_top()

    assert_raise_or_error(fn ->
      Sync.apply_changes(ctx.tenant, ctx.ws, [peer_change(ctx, fail)])
    end)

    assert {:ok, %{applied: 1}} =
             Sync.apply_changes(ctx.tenant, ctx.ws, [peer_change(ctx, after_gap)])

    {:ok, [[after_seq]]} =
      Store.raw_query("SELECT sequence FROM sync_mutations WHERE entity_id = ?1", [after_gap])

    # The failed change drew a sequence and rolled back: it is not in the
    # ledger, and the change after it has a sequence past the gap.
    assert {:ok, []} =
             Store.raw_query("SELECT 1 FROM sync_mutations WHERE entity_id = ?1", [fail])

    assert after_seq > before + 1

    # A reader that had read up to the gap goes past it at once.
    page = Sync.changes(ctx.tenant, ctx.ws, since: before, requester: "rep_puller")
    assert after_gap in entity_ids(page)
    refute fail in entity_ids(page)
    assert page["cursor"] >= after_seq

    # A storage mutation entry after the gap commits and is read too: nothing
    # waits on the sequence that will never come.
    {:ok, entry} =
      PolicyStore.append_mutation(%{
        workspace_id: ctx.ws,
        device_id: "app-device",
        entity_type: "memory_object",
        entity_id: "obj-#{ctx.n}",
        operation: :create,
        payload: %{"text" => "after the gap"}
      })

    assert entry.sequence > after_seq
  end

  test "an apply takes the ledger lock only at its end, so a seal is not held up by it", ctx do
    slow = "slow-#{ctx.n}"
    hold = LedgerHold.hold(slow)

    # Two changes: the first applied and done, the second held part way, as
    # a long page would be.
    apply =
      Task.async(fn ->
        Sync.apply_changes(ctx.tenant, ctx.ws, [
          peer_change(ctx, "first-#{ctx.n}"),
          peer_change(ctx, slow)
        ])
      end)

    assert wait_for(fn -> LedgerHold.waiting?(hold, slow) end), "the apply never reached its row"

    seal = seal_async(ctx, "local-#{ctx.n}")
    assert {:ok, {:ok, sealed}} = Task.yield(seal, 5_000), "the seal waited on the apply"
    assert sealed >= 1

    LedgerHold.release(hold)
    assert {:ok, %{applied: 2}} = Task.await(apply, 30_000)

    # The apply's rows went in after the seal's, in the order applied.
    {:ok, rows} =
      Store.raw_query(
        "SELECT entity_id FROM sync_mutations WHERE workspace_id = ?1 AND entity_id IN (?2, ?3, ?4) ORDER BY sequence",
        [ctx.ws, "local-#{ctx.n}", "first-#{ctx.n}", slow]
      )

    assert List.flatten(rows) == ["local-#{ctx.n}", "first-#{ctx.n}", slow]
  end

  test "a seal that fails ends the publisher's pass, not the publisher", ctx do
    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)
    conn = :"ledord_conn_fail_#{ctx.n}"

    start_supervised!(
      {Connection, name: conn, url: "nats://127.0.0.1:#{stub.port}", backoff: {20, 100}},
      id: conn
    )

    assert wait_for(fn -> Connection.connected?(conn) end)
    pub = :"ledord_pub_fail_#{ctx.n}"

    start_supervised!(
      {LedgerPublisher,
       name: pub,
       connection: conn,
       namespace: "optimal",
       enabled: true,
       interval_ms: 0,
       workspaces: [ctx.ws]},
      id: pub
    )

    # A captured row whose ledger row the test trigger refuses: every seal fails
    # until it is gone.
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, ?1, 'body', '2026-11-09T12:00:00Z')",
        ["fail-seal-#{ctx.n}", ctx.tenant, ctx.ws]
      )

    on_exit(fn ->
      Store.raw_query("DELETE FROM sync_capture WHERE entity_key = ?1", ["fail-seal-#{ctx.n}"])
    end)

    pid = Process.whereis(pub)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _} = LedgerPublisher.publish_now(pub)
      assert %{state: "error"} = LedgerPublisher.status(pub)
    end)

    assert Process.whereis(pub) == pid

    {:ok, _} =
      Store.raw_query("DELETE FROM sync_capture WHERE entity_key = ?1", ["fail-seal-#{ctx.n}"])

    assert {:ok, _} = LedgerPublisher.publish_now(pub)
  end

  test "the ledger lock is taken even when no schema of the search path exists" do
    LedgerHold.with_conn(
      fn conn ->
        Postgrex.query!(conn, "BEGIN", [])
        %{rows: [[nil]]} = Postgrex.query!(conn, "SELECT current_schema()", [])
        Postgrex.query!(conn, PgCapture.lock_ledger_sql(), [])

        %{rows: [[n]]} =
          Postgrex.query!(
            conn,
            "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid()",
            []
          )

        Postgrex.query!(conn, "ROLLBACK", [])
        assert n == 1
      end,
      "oe_no_such_schema"
    )
  end

  test "the publisher's status answers while a seal waits on the ledger lock", ctx do
    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)
    conn = :"ledord_conn_status_#{ctx.n}"

    start_supervised!(
      {Connection, name: conn, url: "nats://127.0.0.1:#{stub.port}", backoff: {20, 100}},
      id: conn
    )

    assert wait_for(fn -> Connection.connected?(conn) end)
    pub = :"ledord_pub_status_#{ctx.n}"

    start_supervised!(
      {LedgerPublisher,
       name: pub,
       connection: conn,
       namespace: "optimal",
       enabled: true,
       interval_ms: 0,
       workspaces: [ctx.ws]},
      id: pub
    )

    # Another Engine's seal holds the ledger lock; a local write waits to be
    # sealed, and a seal now would wait for that lock.
    a = "hold-a-#{ctx.n}"
    hold = LedgerHold.hold(a)
    task_a = other_engine_seal_async(ctx, a)
    assert wait_for(fn -> LedgerHold.waiting?(hold, a) end)

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, ?1, 'body', '2026-11-09T12:00:00Z')",
        ["waiting-#{ctx.n}", ctx.tenant, ctx.ws]
      )

    {micros, status} = :timer.tc(fn -> LedgerPublisher.status(pub) end)

    LedgerHold.release(hold)
    assert {:ok, 1} = Task.await(task_a, 30_000)

    assert status.state != "down", "the status call timed out behind the seal"
    assert micros < 2_000_000
    # The captured write counts in the backlog before any seal.
    assert [%{backlog: backlog}] = status.workspaces
    assert backlog >= 1
  end

  test "the ledger's payload and the events' metadata come back as the JSON text written", ctx do
    payload = %{"text" => "ünïcode ✓ \"quoted\"", "nested" => %{"list" => [1, 2.5, nil, true]}}

    {:ok, entry} =
      PolicyStore.append_mutation(%{
        workspace_id: ctx.ws,
        device_id: "app-device",
        entity_type: "memory_object",
        entity_id: "json-#{ctx.n}",
        operation: :create,
        payload: payload
      })

    {:ok, [[stored]]} =
      Store.raw_query("SELECT payload FROM sync_mutations WHERE id = ?1", [entry.id])

    assert is_binary(stored)
    assert Jason.decode!(stored) == payload

    metadata = Jason.encode!(%{"messages_purged" => 3, "reason" => "ünïcode"})

    {:ok, [[id]]} =
      Store.raw_query(
        "INSERT INTO events (tenant_id, principal, kind, target_uri, metadata) VALUES (?1, 'system:test', 'test_json', 'x', ?2) RETURNING id",
        [ctx.tenant, metadata]
      )

    {:ok, [[read]]} = Store.raw_query("SELECT metadata FROM events WHERE id = ?1", [id])
    assert read == metadata
  end

  defp ledger_top do
    {:ok, [[top]]} = Store.raw_query("SELECT COALESCE(MAX(sequence), 0) FROM sync_mutations", [])
    top
  end

  test "storage mutation entries commit in sequence order as well", ctx do
    held = "hold-entry-#{ctx.n}"
    hold = LedgerHold.hold(held)

    append = fn entity_id ->
      Task.async(fn ->
        PolicyStore.append_mutation(%{
          workspace_id: ctx.ws,
          device_id: "app-device",
          entity_type: "memory_object",
          entity_id: entity_id,
          operation: :create,
          payload: %{"text" => entity_id}
        })
      end)
    end

    task_a = append.(held)
    assert wait_for(fn -> LedgerHold.waiting?(hold, held) end)
    task_b = append.("later-entry-#{ctx.n}")
    b_early = Task.yield(task_b, 1_000)

    # Whatever has committed now is a prefix of the ledger: no committed row
    # has a sequence above one still to commit.
    {:ok, rows} =
      Store.raw_query(
        "SELECT entity_id FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2",
        [ctx.tenant, ctx.ws]
      )

    refute ["later-entry-#{ctx.n}"] in rows,
           "a later entry committed while an earlier sequence was still open"

    LedgerHold.release(hold)
    assert {:ok, a} = Task.await(task_a, 30_000)
    assert {:ok, {:ok, b}} = b_early || {:ok, Task.await(task_b, 30_000)}
    assert a.sequence < b.sequence
  end

  defp assert_raise_or_error(fun) do
    result =
      try do
        fun.()
      rescue
        error -> {:raised, error}
      end

    refute match?({:ok, %{applied: 1}}, result),
           "the failing change was applied: #{inspect(result)}"
  end
end
