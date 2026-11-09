defmodule OptimalEngine.Sync.LedgerSequenceTest do
  @moduledoc """
  The ledger's identity sequence on PostgreSQL must hand out values in the
  order the ledger lock lets writers draw them. A sequence that caches values
  per session does not: each backend draws from a block of its own. Boot
  checks the cache (`Sync.Postgres.ensure_ledger_sequence/1`), sets it back to
  1 when it may, never fails the boot when it may not, and from then on every
  ledger writer discards what its session cached before it draws, so values
  cached before the change cannot come out of order.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres_store

  import ExUnit.CaptureLog

  alias OptimalEngine.{Health, Store, Workspace}
  alias OptimalEngine.Storage.PolicyStore
  alias OptimalEngine.Store.Postgres.Connection
  alias OptimalEngine.Sync.Postgres, as: PgCapture
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.LedgerHold

  setup do
    n = System.unique_integer([:positive])
    tenant = "ledseq-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Ledger sequence #{n}"})

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

    # Whatever a test does to the sequence, the next one starts from the
    # store's own state.
    on_exit(fn ->
      set_cache(1)
      capture_log(fn -> PgCapture.ensure_ledger_sequence() end)
    end)

    %{tenant: tenant, ws: ws.id, n: n}
  end

  defp set_cache(cache) do
    LedgerHold.with_conn(fn conn ->
      Postgrex.query!(
        conn,
        "ALTER TABLE sync_mutations ALTER COLUMN sequence SET CACHE #{cache}",
        []
      )
    end)
  end

  defp schema,
    do: Keyword.get(Application.get_env(:optimal_engine, :postgres_store, []), :schema, "public")

  defp append(ctx, i) do
    {:ok, entry} =
      PolicyStore.append_mutation(%{
        workspace_id: ctx.ws,
        device_id: "app-device",
        entity_type: "memory_object",
        entity_id: "seq-#{ctx.n}-#{i}",
        operation: :create,
        payload: %{"i" => i}
      })

    entry.sequence
  end

  defp last_value do
    {:ok, [[value]]} =
      Store.raw_query(
        "SELECT last_value FROM pg_sequences WHERE schemaname = current_schema() AND sequencename = 'sync_mutations_sequence_seq'",
        []
      )

    value
  end

  test "a larger cache is set back to 1 and said so in the log", _ctx do
    set_cache(20)
    assert {:ok, 20} = PgCapture.ledger_sequence_cache()

    log = capture_log(fn -> assert :ok = PgCapture.ensure_ledger_sequence() end)
    assert log =~ "set back to 1"
    assert {:ok, 1} = PgCapture.ledger_sequence_cache()
    assert Health.ready(skip: [:embedder]).checks.ledger == :ok
  end

  # A session of its own that draws once, and so holds a block of `cache`
  # values while the cache is larger than 1.
  defp draw(conn) do
    %{rows: [[value]]} =
      Postgrex.query!(
        conn,
        "SELECT nextval(pg_get_serial_sequence('sync_mutations', 'sequence'))",
        []
      )

    value
  end

  # What a ledger writer runs in its transaction before it draws.
  defp writer_draw(conn) do
    {:ok, value} =
      Postgrex.transaction(conn, fn conn ->
        Enum.each(PgCapture.ledger_lock_statements(), &Postgrex.query!(conn, &1, []))
        draw(conn)
      end)

    value
  end

  defp with_sessions(count, fun) do
    sessions = for _ <- 1..count, do: LedgerHold.open()

    try do
      fun.(sessions)
    after
      Enum.each(sessions, &GenServer.stop/1)
    end
  end

  test "a block a session cached before the check never comes out of order" do
    set_cache(20)

    with_sessions(4, fn sessions ->
      first = Enum.map(sessions, &draw/1)
      allocated = last_value()
      # Each session holds a block: the sequence went past every first draw.
      assert allocated >= Enum.max(first) + 19

      capture_log(fn -> assert :ok = PgCapture.ensure_ledger_sequence() end)
      assert PgCapture.discard_sequences?()

      drawn = Enum.map(sessions, &writer_draw/1)
      assert Enum.all?(drawn, &(&1 > allocated)), inspect({allocated, drawn})
      assert drawn == Enum.sort(drawn)
    end)
  end

  test "without the check, a session hands out the block it cached" do
    # The test above would catch a check that did not hold: here the cache
    # stays at 20 and the writers do not discard.
    set_cache(20)
    refute PgCapture.discard_sequences?()

    with_sessions(4, fn sessions ->
      Enum.each(sessions, &draw/1)
      allocated = last_value()

      drawn = Enum.map(sessions, &writer_draw/1)
      assert Enum.all?(drawn, &(&1 <= allocated)), inspect({allocated, drawn})
    end)
  end

  test "the ledger column is an identity; a serial one is set back through its sequence", ctx do
    {:ok, [[identity]]} =
      Store.raw_query(
        "SELECT attidentity::text FROM pg_attribute WHERE attrelid = 'sync_mutations'::regclass AND attname = 'sequence'",
        []
      )

    assert identity in ["a", "d"]

    other = "oe_serial_#{ctx.n}"

    LedgerHold.with_conn(fn conn ->
      Postgrex.query!(conn, ~s|CREATE SCHEMA "#{other}"|, [])
      Postgrex.query!(conn, ~s|CREATE TABLE "#{other}".sync_mutations (sequence BIGSERIAL)|, [])
      Postgrex.query!(conn, ~s|ALTER SEQUENCE "#{other}".sync_mutations_sequence_seq CACHE 20|, [])
    end)

    on_exit(fn ->
      LedgerHold.with_conn(fn conn ->
        Postgrex.query!(conn, ~s|DROP SCHEMA IF EXISTS "#{other}" CASCADE|, [])
      end)
    end)

    pool = schema_pool(other)
    assert {:ok, 20} = PgCapture.ledger_sequence_cache(pool: pool)

    log =
      capture_log(fn ->
        assert :ok = PgCapture.ensure_ledger_sequence(pool: pool, record: false)
      end)

    assert log =~ "set back to 1"
    assert {:ok, 1} = PgCapture.ledger_sequence_cache(pool: pool)
  end

  test "a check that could not run is tried again at the next install", ctx do
    checked = {PgCapture, :sequence_checked}
    :persistent_term.erase(checked)
    on_exit(fn -> :persistent_term.put(checked, true) end)

    # A schema with no ledger table: the check's query fails.
    pool = schema_pool("oe_missing_#{ctx.n}")

    capture_log(fn -> assert :ok = PgCapture.ensure(pool: pool) end)
    refute :persistent_term.get(checked, false)
    assert {:warn, {:ledger_sequence_unchecked, _}} = PgCapture.ledger_order()

    capture_log(fn -> assert :ok = PgCapture.ensure() end)
    assert :persistent_term.get(checked, false)
    assert PgCapture.ledger_order() == :ok
  end

  defp schema_pool(schema) do
    {:ok, config} = OptimalEngine.Storage.Postgres.config()

    url =
      "postgres://#{config.username}:#{config.password}@#{config.hostname}:#{config.port}/#{config.database}"

    {:ok, pool} = Connection.start_link(url: url, schema: schema, pool_size: 1)
    on_exit(fn -> if Process.alive?(pool), do: GenServer.stop(pool) end)
    pool
  end

  test "a role that does not own the table cannot set the cache back, and the boot goes on",
       ctx do
    role = "oe_nonowner_#{ctx.n}"

    LedgerHold.with_conn(fn conn ->
      Postgrex.query!(conn, "CREATE ROLE #{role} LOGIN PASSWORD 'nonowner'", [])
      Postgrex.query!(conn, ~s|GRANT USAGE ON SCHEMA "#{schema()}" TO #{role}|, [])
    end)

    on_exit(fn ->
      LedgerHold.with_conn(fn conn ->
        Postgrex.query!(conn, "DROP OWNED BY #{role}", [])
        Postgrex.query!(conn, "DROP ROLE IF EXISTS #{role}", [])
      end)
    end)

    {:ok, config} = OptimalEngine.Storage.Postgres.config()

    url =
      "postgres://#{role}:nonowner@#{config.hostname}:#{config.port}/#{config.database}"

    {:ok, pool} = Connection.start_link(url: url, schema: schema(), pool_size: 1)
    on_exit(fn -> if Process.alive?(pool), do: GenServer.stop(pool) end)

    set_cache(20)

    log =
      capture_log(fn ->
        assert {:degraded, {:sequence_cached, 20, _reason}} =
                 PgCapture.ensure_ledger_sequence(pool: pool)
      end)

    assert log =~ "ALTER SEQUENCE"
    assert log =~ "CACHE 1"
    assert {:ok, 20} = PgCapture.ledger_sequence_cache()
    assert {:warn, {:ledger_sequence_cached, 20}} = Health.ready(skip: [:embedder]).checks.ledger

    # The cache stays, and the ledger still draws in order: each writer
    # discards its session's block before it draws.
    first = append(ctx, 1)
    drawn = for i <- 2..10, do: append(ctx, i)
    assert drawn == Enum.sort(drawn)
    assert Enum.all?(drawn, &(&1 > first))

    # Its owner sets it back; the warning goes.
    capture_log(fn -> assert :ok = PgCapture.ensure_ledger_sequence() end)
    assert {:ok, 1} = PgCapture.ledger_sequence_cache()
    assert Health.ready(skip: [:embedder]).checks.ledger == :ok
  end

  test "a ledger column without a sequence is reported, not a crash", ctx do
    other = "oe_noseq_#{ctx.n}"

    LedgerHold.with_conn(fn conn ->
      Postgrex.query!(conn, ~s|CREATE SCHEMA "#{other}"|, [])
      Postgrex.query!(conn, ~s|CREATE TABLE "#{other}".sync_mutations (sequence BIGINT)|, [])
    end)

    on_exit(fn ->
      LedgerHold.with_conn(fn conn ->
        Postgrex.query!(conn, ~s|DROP SCHEMA IF EXISTS "#{other}" CASCADE|, [])
      end)
    end)

    pool = schema_pool(other)

    capture_log(fn ->
      assert {:degraded, :no_ledger_sequence} =
               PgCapture.ensure_ledger_sequence(pool: pool, record: false)
    end)
  end

  test "Capture.install checks the sequence once per boot, not on every install" do
    set_cache(20)
    # The boot's check ran already: an install does not run it again.
    assert {:ok, _} = OptimalEngine.Sync.Capture.install()
    assert {:ok, 20} = PgCapture.ledger_sequence_cache()
  end
end
