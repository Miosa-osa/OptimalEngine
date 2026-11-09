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

  test "values a session cached before the cache was set back never come out of order", ctx do
    set_cache(20)

    # Every pooled session draws once, and so holds a block of 20 values.
    1..20
    |> Enum.map(fn i -> Task.async(fn -> append(ctx, i) end) end)
    |> Task.await_many(30_000)

    allocated = last_value()
    capture_log(fn -> assert :ok = PgCapture.ensure_ledger_sequence() end)

    # Whichever session draws next, it does not hand out a value from a block
    # it cached before: every new value is past all that was allocated.
    drawn = for i <- 21..60, do: append(ctx, i)
    assert Enum.all?(drawn, &(&1 > allocated)), inspect({allocated, drawn})
    assert drawn == Enum.sort(drawn)
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

    {:ok, config} = OptimalEngine.Storage.Postgres.config()

    url =
      "postgres://#{config.username}:#{config.password}@#{config.hostname}:#{config.port}/#{config.database}"

    {:ok, pool} = Connection.start_link(url: url, schema: other, pool_size: 1)
    on_exit(fn -> if Process.alive?(pool), do: GenServer.stop(pool) end)

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
