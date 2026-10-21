defmodule OptimalEngine.Sync.LedgerKeyRepairTest do
  @moduledoc """
  The one-time repair of ledger rows an earlier Engine stored under an id or a
  key of this Engine's own changes (`mut_<replica>_<capture sequence>`,
  `<replica>:<capture sequence>`) or of a change it applies (`peer:<id>`):
  a peer's change stored under the key the sender sent, and a storage mutation
  entry under the key its caller chose. While such a row holds one, the change
  recorded under it is dropped. Each row that is no change of a row is re-id'd,
  re-keyed or, when it cannot move, deleted; every other row is left as it was.
  And a row whose id has a colon is reported, and never served.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Storage.PolicyStore
  alias OptimalEngine.Store.Migrations
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "repair-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Repair #{n}"})

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
    %{tenant: tenant, ws: ws.id, n: n, local: Sync.replica_id()}
  end

  test "a row that is no change with an id of this Engine's own changes is re-id'd", ctx do
    next = next_capture_sequence()

    # What an earlier Engine stored for a peer's change that took an id of this
    # Engine's own space, under the key the sender sent.
    owned =
      for seq <- next..(next + 2),
          do: plant(ctx, "mut_#{ctx.local}_#{seq}", "sent-#{ctx.n}-#{seq}")

    repair()

    for id <- owned do
      assert key_of("peer_" <> id) == "sent-#{ctx.n}-" <> seq(id)
      refute Sync.change_row?("peer_" <> id, "rep_remote", key_of("peer_" <> id))
    end

    assert_local_changes_seal(ctx, 4)

    for id <- owned do
      assert {:ok, [[device]]} =
               Store.raw_query("SELECT device_id FROM sync_mutations WHERE id = ?1", [id])

      assert device == ctx.local
    end
  end

  test "a row that is no change with a reserved key is re-keyed under moved:", ctx do
    next = next_capture_sequence()
    local = ctx.local

    # A peer's change under the key the sender sent, or its id when it sent none.
    keyed =
      for seq <- next..(next + 2),
          do: plant(ctx, "mut_rep_remote_#{ctx.n}_#{seq}", "#{local}:#{seq}")

    coloned =
      for seq <- (next + 3)..(next + 4), do: plant(ctx, "#{local}:#{seq}", "#{local}:#{seq}")

    # Storage entries under a caller's key, this Engine's device id included.
    stored =
      for seq <- (next + 5)..(next + 6),
          do: plant(ctx, "stored-#{ctx.n}-#{seq}", "#{local}:#{seq}", "stored", local)

    capture_id = plant(ctx, "stored-#{ctx.n}-id", "mut_#{local}_#{next}", "stored", local)

    # An entry that took the key a peer's next change is recorded under.
    peer = "rep_remote_#{ctx.n}"
    incoming = "mut_#{peer}_77"
    entry = plant(ctx, "entry-#{ctx.n}", "peer:" <> incoming, "entry", "app-device")

    repair()
    once = rows(ctx)
    repair()
    assert rows(ctx) == once

    for id <- keyed ++ coloned ++ stored,
        do: assert(key_of(id) == "moved:#{local}:" <> seq(id))

    assert key_of(capture_id) == "moved:mut_#{local}_#{next}"
    assert key_of(entry) == "moved:peer:" <> incoming

    served = Enum.map(Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)["mutations"], & &1["id"])
    assert Enum.filter(keyed ++ coloned ++ stored ++ [capture_id, entry], &(&1 in served)) == []

    assert_local_changes_seal(ctx, 9)

    assert {:ok, %{applied: 1}} =
             Sync.apply_changes(ctx.tenant, ctx.ws, [peer_change(ctx, incoming, peer)])

    assert key_of(incoming) == "peer:" <> incoming
  end

  test "a row that is no change and cannot move is deleted", ctx do
    next = next_capture_sequence()
    local = ctx.local

    # The key it would move to is held.
    blocked_key = plant(ctx, "blocked-#{ctx.n}", "#{local}:#{next}", "blocked", local)
    key_taker = plant(ctx, "taker-#{ctx.n}", "moved:#{local}:#{next}", "taker", local)

    # The id it would move to is held.
    blocked_id = plant(ctx, "mut_#{local}_#{next + 1}", "sent-#{ctx.n}")
    id_taker = plant(ctx, "peer_mut_#{local}_#{next + 1}", "taker-key-#{ctx.n}")

    repair()

    assert key_of(blocked_key) == nil
    assert key_of(key_taker) == "moved:#{local}:#{next}"
    assert key_of(id_taker) == "taker-key-#{ctx.n}"

    assert {:ok, []} =
             Store.raw_query("SELECT 1 FROM sync_mutations WHERE idempotency_key = ?1", [
               "sent-#{ctx.n}"
             ])

    assert_local_changes_seal(ctx, 3)

    assert {:ok, [[^local]]} =
             Store.raw_query("SELECT device_id FROM sync_mutations WHERE id = ?1", [blocked_id])
  end

  test "a storage entry keyed by its own id, and every change of a row, is left exactly as it was",
       ctx do
    {:ok, entry} =
      PolicyStore.append_mutation(%{
        workspace_id: ctx.ws,
        device_id: ctx.local,
        entity_type: "memory_object",
        entity_id: "obj-#{ctx.n}",
        operation: :create,
        payload: %{"text" => "App entry"}
      })

    assert entry.idempotency_key == entry.id

    insert_context(ctx, "mine-#{ctx.n}")
    {:ok, _} = Capture.seal()

    {:ok, [[own]]} =
      Store.raw_query(
        "SELECT id FROM sync_mutations WHERE entity_type = 'contexts' AND entity_id = ?1",
        ["mine-#{ctx.n}"]
      )

    peer = "rep_remote_#{ctx.n}"
    applied = "mut_#{peer}_1"

    assert {:ok, %{applied: 1}} =
             Sync.apply_changes(ctx.tenant, ctx.ws, [peer_change(ctx, applied, peer)])

    # A peer's change an earlier Engine stored under the key the sender sent.
    keyed_by_sender = plant(ctx, "mut_#{peer}_2", "#{peer}:2", "sent", peer)

    ids = [entry.id, own, applied, keyed_by_sender]
    before = Enum.map(ids, &row_of/1)
    assert Enum.all?(before, &(&1 != nil))

    repair()

    assert Enum.map(ids, &row_of/1) == before
  end

  test "the repair logs how many rows each action changed, and nothing of a row", ctx do
    # The repair runs as the upgrade runs it: on a copy of the store that has
    # not recorded it yet, with only the planted rows in the ledger.
    path = Path.join(System.tmp_dir!(), "ledger-repair-#{ctx.n}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)
    {:ok, _} = Store.raw_query("VACUUM INTO ?1", [path])
    {:ok, db} = Exqlite.Sqlite3.open(path)
    on_exit(fn -> Exqlite.Sqlite3.close(db) end)

    {_version, _description, _statements} = repair = repair_migration()
    execute!(db, "DELETE FROM sync_mutations", [])
    execute!(db, "DELETE FROM schema_migrations WHERE version = ?1", [elem(repair, 0)])

    local = ctx.local

    planted = [
      # re-id'd
      {"mut_#{local}_1", "sent-#{ctx.n}-1"},
      {"mut_#{local}_2", "sent-#{ctx.n}-2"},
      # re-keyed
      {"mut_rep_remote_#{ctx.n}_3", "#{local}:3"},
      {"stored-#{ctx.n}-4", "#{local}:4"},
      {"entry-#{ctx.n}-5", "peer:mut_rep_remote_#{ctx.n}_5"},
      # deleted: the key it would move to is held
      {"blocked-#{ctx.n}-6", "#{local}:6"},
      {"taker-#{ctx.n}-6", "moved:#{local}:6"}
    ]

    for {id, key} <- planted do
      execute!(
        db,
        """
        INSERT INTO sync_mutations
          (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
           payload_hash, idempotency_key, occurred_at)
        VALUES (?1, 'default', 'default', 'rep_remote', 'contexts', ?1, 'create',
                '{"row":{"title":"planted-marker"},"blobs":{}}', 'h', ?2, '2026-10-14T12:00:00.000')
        """,
        [id, key]
      )
    end

    log = capture_log(fn -> assert Migrations.run(db, [repair]) == :ok end)

    assert log =~ ~r/data: re-id [^\n]*, rows changed: 2(?!\d)/
    assert log =~ ~r/data: re-key [^\n]*, rows changed: 3(?!\d)/
    assert log =~ ~r/data: delete [^\n]*, rows changed: 1(?!\d)/
    refute log =~ "planted-marker"
    for {id, key} <- planted, do: refute(log =~ id or log =~ key)
  end

  describe "the rows the repair moved" do
    test "a row re-id'd into the shape of an applied change is re-id'd under moved:", ctx do
      next = next_capture_sequence()
      local = ctx.local

      # A peer's change an earlier Engine stored under an id of this Engine's own
      # space, keyed with the applied key of the id the repair renames it to.
      shaped = plant(ctx, "mut_#{local}_#{next}", "peer:peer_mut_#{local}_#{next}")
      plain = plant(ctx, "mut_#{local}_#{next + 1}", "sent-#{ctx.n}")

      repair()
      moved_ids()

      assert key_of("moved:" <> shaped) == "peer:peer_mut_#{local}_#{next}"
      assert key_of("moved:" <> plain) == "sent-#{ctx.n}"
      assert key_of("peer_" <> shaped) == nil
      assert key_of("peer_" <> plain) == nil

      for id <- ["moved:" <> shaped, "moved:" <> plain] do
        refute Sync.change_row?(id, "rep_remote", key_of(id))
        refute id in served(ctx)
      end

      assert_local_changes_seal(ctx, 3)
    end

    test "a row re-keyed into the shape of a capture is re-id'd under moved:", ctx do
      local = ctx.local

      # A device named `moved` makes `moved:<key>` the capture key of
      # `mut_moved_<key>`, the key the repair gives a row keyed `<key>`.
      shaped =
        plant(
          ctx,
          "mut_moved_mut_#{local}_#{ctx.n}",
          "mut_#{local}_#{ctx.n}",
          "planted",
          "moved"
        )

      repair()
      moved_ids()

      moved = "moved:" <> shaped
      assert key_of(shaped) == nil
      assert key_of(moved) == "moved:mut_#{local}_#{ctx.n}"
      refute Sync.change_row?(moved, "moved", key_of(moved))
      refute moved in served(ctx)
    end

    test "a storage entry keyed under moved: by its caller, and every change of a row, is left as it was",
         ctx do
      {:ok, entry} =
        PolicyStore.append_mutation(%{
          workspace_id: ctx.ws,
          device_id: "moved",
          entity_type: "memory_object",
          entity_id: "obj-#{ctx.n}",
          operation: :create,
          payload: %{"text" => "App entry"},
          idempotency_key: "moved:app-#{ctx.n}"
        })

      insert_context(ctx, "mine-#{ctx.n}")
      {:ok, _} = Capture.seal()

      {:ok, [[own]]} =
        Store.raw_query(
          "SELECT id FROM sync_mutations WHERE entity_type = 'contexts' AND entity_id = ?1",
          ["mine-#{ctx.n}"]
        )

      peer = "rep_remote_#{ctx.n}"
      applied = "mut_#{peer}_1"

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [peer_change(ctx, applied, peer)])

      ids = [entry.id, own, applied]
      before = Enum.map(ids, &row_of/1)

      repair()
      moved_ids()

      assert Enum.map(ids, &row_of/1) == before
    end
  end

  test "a peer's row with a colon in its id is reported without its payload, and never served",
       ctx do
    # Shaped as the other Engine's own change in every way but the colon.
    colon =
      plant(ctx, "mut_rep_other_1:#{ctx.n}", "rep_other:1:#{ctx.n}", "colon-marker", "rep_other")

    plain = plant(ctx, "mut_rep_other_#{ctx.n}", "rep_other:#{ctx.n}", "plain", "rep_other")

    log =
      capture_log(fn ->
        assert {:ok, reported} = Sync.report_colon_ids()
        assert reported >= 1
      end)

    assert log =~ colon
    refute log =~ "colon-marker"

    refute Sync.change_row?(colon, "rep_other", "rep_other:1:#{ctx.n}")
    page = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
    served = Enum.map(page["mutations"], & &1["id"])
    refute colon in served
    assert plain in served

    {:ok, [[sequence]]} =
      Store.raw_query("SELECT sequence FROM sync_mutations WHERE id = ?1", [colon])

    assert page["cursor"] >= sequence
  end

  # -- helpers ------------------------------------------------------------------

  # The repair is the migration that names it; an Engine without it has none.
  defp repair_migration do
    Enum.find(Migrations.all(), {0, "", []}, fn {_v, description, _s} ->
      description =~ "planted ledger"
    end)
  end

  # The migration after the repair that gives the rows it moved a colon in
  # their id; an Engine without it has none.
  defp moved_ids do
    {_version, _description, statements} =
      Enum.find(Migrations.all(), {0, "", []}, fn {_v, description, _s} ->
        description =~ "keep a colon"
      end)

    for {label, sql} <- statements do
      assert {:ok, _} = Store.raw_query(sql, []), "#{label} failed"
    end
  end

  defp served(ctx),
    do: Enum.map(Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)["mutations"], & &1["id"])

  defp repair do
    {_version, _description, statements} = repair_migration()

    for {label, sql} <- statements do
      assert {:ok, _} = Store.raw_query(sql, []), "#{label} failed"
    end
  end

  # `count` local changes, after the planted rows: each is sealed under its own
  # id and key, the ones the planted rows held included.
  defp assert_local_changes_seal(ctx, count) do
    for i <- 1..count, do: insert_context(ctx, "mine-#{ctx.n}-#{i}")
    {:ok, _} = Capture.seal()

    for i <- 1..count do
      assert {:ok, [[device, id, key]]} =
               Store.raw_query(
                 "SELECT device_id, id, idempotency_key FROM sync_mutations WHERE entity_type = 'contexts' AND entity_id = ?1",
                 ["mine-#{ctx.n}-#{i}"]
               ),
             "the local change mine-#{ctx.n}-#{i} was not sealed"

      assert device == ctx.local
      assert "mut_" <> String.replace(key, ":", "_") == id
    end
  end

  defp next_capture_sequence do
    {:ok, [[next]]} =
      Store.raw_query(
        "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'sync_capture'), 0) + 1",
        []
      )

    next
  end

  defp peer_change(ctx, id, peer) do
    %{
      "id" => id,
      "device_id" => peer,
      "entity_type" => "contexts",
      "entity_id" => "theirs-#{id}",
      "operation" => "create",
      "occurred_at" => "2026-10-14T12:00:00.000",
      "payload" => %{
        "row" => %{
          "id" => "theirs-#{id}",
          "title" => "Theirs",
          "content" => "remote body",
          "workspace_id" => ctx.ws,
          "tenant_id" => ctx.tenant
        },
        "blobs" => %{}
      }
    }
  end

  defp plant(ctx, id, key, marker \\ "planted", device \\ "rep_remote") do
    payload = Jason.encode!(%{"row" => %{"id" => id, "title" => marker}, "blobs" => %{}})

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_mutations
          (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
           payload_hash, idempotency_key, occurred_at)
        VALUES (?1, ?2, ?3, ?6, 'contexts', ?1, 'create', ?4, 'h', ?5,
                '2026-10-14T12:00:00.000')
        """,
        [id, ctx.tenant, ctx.ws, payload, key, device]
      )

    id
  end

  # The capture sequence at the end of a planted id.
  defp seq(id), do: id |> String.split(["_", ":", "-"]) |> List.last()

  defp key_of(id) do
    case Store.raw_query("SELECT idempotency_key FROM sync_mutations WHERE id = ?1", [id]) do
      {:ok, [[key]]} -> key
      {:ok, []} -> nil
    end
  end

  defp row_of(id) do
    case Store.raw_query("SELECT * FROM sync_mutations WHERE id = ?1", [id]) do
      {:ok, [row]} -> row
      {:ok, []} -> nil
    end
  end

  defp rows(ctx) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT sequence, id, idempotency_key FROM sync_mutations WHERE workspace_id = ?1 ORDER BY sequence",
        [ctx.ws]
      )

    rows
  end

  defp execute!(db, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      :done = Exqlite.Sqlite3.step(db, stmt)
    after
      Exqlite.Sqlite3.release(db, stmt)
    end
  end

  defp insert_context(ctx, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, 'Mine', 'body', '2026-10-14T10:00:00Z')",
        [id, ctx.tenant, ctx.ws]
      )
  end
end
