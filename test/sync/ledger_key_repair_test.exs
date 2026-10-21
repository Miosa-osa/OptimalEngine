defmodule OptimalEngine.Sync.LedgerKeyRepairTest do
  @moduledoc """
  The one-time repair of ledger rows an earlier Engine stored for a peer's
  change under a key or id of this Engine's own capture space
  (`<replica>:<capture sequence>`, `mut_<replica>_<capture sequence>`). While
  such a row holds one, the local change sealed under it is dropped. And a
  peer's row whose id has a colon is reported, and never served or pushed.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.{Store, Sync, Workspace}
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

  test "the repair frees the keys and ids of this Engine's next changes that a peer's rows hold",
       ctx do
    next = next_capture_sequence()

    # What an earlier Engine stored for a peer's change: the sender's key, or
    # its id when it sent none.
    keyed =
      for seq <- next..(next + 3),
          do: plant(ctx, "mut_rep_remote_#{ctx.n}_#{seq}", "#{ctx.local}:#{seq}")

    owned =
      for seq <- (next + 4)..(next + 6),
          do: plant(ctx, "mut_#{ctx.local}_#{seq}", "mut_#{ctx.local}_#{seq}")

    coloned =
      for seq <- (next + 7)..(next + 9),
          do: plant(ctx, "#{ctx.local}:#{seq}", "#{ctx.local}:#{seq}")

    control = plant(ctx, "mut_rep_remote_#{ctx.n}_control", "rep_remote:#{ctx.n}")

    repair()
    before_second_run = rows(ctx)
    repair()
    assert rows(ctx) == before_second_run

    # The next local changes take the sequences the planted rows held, and every
    # one of them is sealed under its own id and key.
    for i <- 1..14, do: insert_context(ctx, "mine-#{ctx.n}-#{i}")
    {:ok, _} = Capture.seal()

    for i <- 1..14 do
      assert {:ok, [[device, id, key]]} =
               Store.raw_query(
                 "SELECT device_id, id, idempotency_key FROM sync_mutations WHERE entity_type = 'contexts' AND entity_id = ?1",
                 ["mine-#{ctx.n}-#{i}"]
               ),
             "the local change mine-#{ctx.n}-#{i} was not sealed"

      assert device == ctx.local
      assert String.starts_with?(id, "mut_#{ctx.local}_")
      assert String.starts_with?(key, ctx.local <> ":")
    end

    # A peer's key in this Engine's capture space is now the applied-change key.
    for id <- keyed, do: assert(key_of(id) == "peer:" <> id)

    # A peer's id in this Engine's own id space is moved out of it.
    for id <- owned do
      assert key_of(id) == nil
      assert key_of("peer_" <> id) == "peer:peer_" <> id
    end

    for id <- coloned, do: assert(key_of(id) == "peer:" <> id)
    assert key_of(control) == "rep_remote:#{ctx.n}"
  end

  test "a peer's row with a colon in its id is reported without its payload, and never served or pushed",
       ctx do
    colon = plant(ctx, "rep_other:#{ctx.n}", "rep_other:#{ctx.n}", "payload-marker-#{ctx.n}")
    plain = plant(ctx, "mut_rep_other_#{ctx.n}", "rep_other:#{ctx.n}x", "plain-marker-#{ctx.n}")

    log =
      capture_log(fn ->
        assert {:ok, reported} = Sync.report_colon_ids()
        assert reported >= 1
      end)

    assert log =~ colon
    refute log =~ "payload-marker-#{ctx.n}"

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
  defp repair do
    statements =
      case Enum.find(Migrations.all(), fn {_v, description, _s} ->
             description =~ "planted ledger"
           end) do
        {_version, _description, statements} -> statements
        nil -> []
      end

    for {label, sql} <- statements do
      assert {:ok, _} = Store.raw_query(sql, []), "#{label} failed"
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

  defp plant(ctx, id, key, marker \\ "planted") do
    payload = Jason.encode!(%{"row" => %{"id" => id, "title" => marker}, "blobs" => %{}})

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_mutations
          (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
           payload_hash, idempotency_key, occurred_at)
        VALUES (?1, ?2, ?3, 'rep_remote', 'contexts', ?1, 'create', ?4, 'h', ?5,
                '2026-10-14T12:00:00.000')
        """,
        [id, ctx.tenant, ctx.ws, payload, key]
      )

    id
  end

  defp key_of(id) do
    case Store.raw_query("SELECT idempotency_key FROM sync_mutations WHERE id = ?1", [id]) do
      {:ok, [[key]]} -> key
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

  defp insert_context(ctx, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, 'Mine', 'body', '2026-10-14T10:00:00Z')",
        [id, ctx.tenant, ctx.ws]
      )
  end
end
