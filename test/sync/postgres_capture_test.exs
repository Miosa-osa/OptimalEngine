defmodule OptimalEngine.Sync.PostgresCaptureTest do
  @moduledoc """
  Change capture on a PostgreSQL store records what SQLite's capture triggers
  record: the same writes, made on the embedded SQLite store and on a
  PostgreSQL store, leave the same `sync_capture` rows (table, operation,
  workspace, entity key, row and blobs, decoded), in the same order. Neither
  captures while changes are applied, or for a workspace that does not sync.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Postgres, as: PgStore
  alias OptimalEngine.Sync
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Sync.Postgres, as: PgCapture
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres
  # Starts its own PostgreSQL store beside the embedded one, which a
  # PostgreSQL build already runs as OptimalEngine.Store.
  @moduletag :sqlite_store

  @tables ~w(contexts vectors memories memory_embeddings memory_relations)

  # A key part with the characters a JSON key array escapes or keeps as they are.
  @model "stub/ü \"q\" \\ \t end"

  setup_all do
    schema = PostgresStore.unique_schema()

    start_supervised!(
      {PgStore, PostgresStore.options(schema, pool_size: 4, full_text_interval_ms: 0)}
    )

    on_exit(fn -> PostgresStore.drop_schema(schema) end)

    :ok = PgCapture.ensure()
    for table <- @tables, do: :ok = Capture.install_postgres(table, PgCapture.columns(table))
    :ok
  end

  setup do
    n = System.unique_integer([:positive])
    tenant = "pgcap-#{n}"
    ws = "#{tenant}:notes"

    for store <- [Store, PgStore] do
      :ok =
        store.raw_execute("INSERT OR IGNORE INTO tenants (id, name) VALUES (?1, ?1)", [tenant])

      :ok =
        store.raw_execute(
          "INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name) VALUES (?1, ?2, 'notes', 'Notes')",
          [ws, tenant]
        )
    end

    {:ok, _} = Sync.enable(tenant, ws, "user:owner")

    :ok =
      PgStore.raw_execute(
        "INSERT INTO sync_workspaces (tenant_id, workspace_id, enabled_by) VALUES (?1, ?2, 'user:owner')",
        [tenant, ws]
      )

    %{tenant: tenant, ws: ws}
  end

  # The same statements on both stores.
  defp both(statements) do
    for {sql, params} <- statements, store <- [Store, PgStore] do
      assert :ok == store.raw_execute(sql, params), "#{inspect(store)}: #{sql}"
    end
  end

  defp captured(store, ws) do
    {:ok, rows} =
      store.raw_query(
        "SELECT table_name, operation, workspace_id, entity_key, row_data, blob_data FROM sync_capture WHERE workspace_id = ?1 ORDER BY seq",
        [ws]
      )

    Enum.map(rows, fn [table, op, workspace, key, row, blobs] ->
      blobs =
        (blobs && Jason.decode!(blobs)) |> Kernel.||(%{}) |> Enum.reject(&is_nil(elem(&1, 1)))

      %{
        table: table,
        op: op,
        workspace: workspace,
        key: key,
        row: Jason.decode!(row),
        blobs: Map.new(blobs)
      }
    end)
  end

  defp writes(tenant, ws) do
    [
      {"INSERT INTO contexts (id, tenant_id, workspace_id, title, content, sn_ratio, valid_from, created_at) VALUES (?1, ?2, ?3, 'Café ✓', 'body \"quoted\" \\\\ line\nnext', 1.0, NULL, '2026-10-14T10:00:00Z')",
       ["c1-#{ws}", tenant, ws]},
      {"INSERT INTO contexts (id, tenant_id, workspace_id, title, sn_ratio, created_at) VALUES (?1, ?2, ?3, 'second', 0.1, '2026-10-14T10:00:00Z')",
       ["c2-#{ws}", tenant, ws]},
      {"UPDATE contexts SET title = 'renamed', sn_ratio = 0.75 WHERE id = ?1", ["c1-#{ws}"]},
      {"INSERT INTO vectors (context_id, embedding, dimensions, tenant_id, workspace_id) VALUES (?1, ?2, 4, ?3, ?4)",
       ["c1-#{ws}", {:blob, <<0, 1, 2, 255>>}, tenant, ws]},
      {"INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES (?1, ?2, ?3, 'm one')",
       ["m1-#{ws}", tenant, ws]},
      {"INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES (?1, ?2, ?3, 'm two')",
       ["m2-#{ws}", tenant, ws]},
      {"INSERT INTO memory_embeddings (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash) VALUES (?1, ?2, ?3, ?5, 2, ?4, 'h')",
       ["m1-#{ws}", tenant, ws, {:blob, <<10, 11>>}, @model]},
      {"UPDATE memory_embeddings SET content_hash = 'h2' WHERE memory_id = ?1", ["m1-#{ws}"]},
      {"INSERT INTO memory_relations (tenant_id, workspace_id, source_memory_id, target_memory_id, relation, created_at) VALUES (?1, ?2, ?3, ?4, 'related', '2026-10-14T10:00:00Z')",
       [tenant, ws, "m1-#{ws}", "m2-#{ws}"]},
      {"DELETE FROM memory_embeddings WHERE memory_id = ?1", ["m1-#{ws}"]},
      {"DELETE FROM vectors WHERE context_id = ?1", ["c1-#{ws}"]},
      {"DELETE FROM contexts WHERE id = ?1", ["c2-#{ws}"]}
    ]
  end

  # Columns whose values the two stores fill in themselves (time defaults and
  # generated ids) are left out of the comparison of a row.
  @generated ~w(created_at modified_at updated_at indexed_at id)

  defp comparable(entries) do
    Enum.map(entries, fn entry ->
      row =
        if entry.op == "delete",
          do: entry.row,
          else:
            Map.drop(
              entry.row,
              if(entry.table == "memory_relations", do: @generated, else: @generated -- ["id"])
            )

      %{entry | row: row}
    end)
  end

  test "the same writes are captured the same on both stores", %{tenant: tenant, ws: ws} do
    both(writes(tenant, ws))

    sqlite = captured(Store, ws)
    postgres = captured(PgStore, ws)

    assert length(sqlite) == length(writes(tenant, ws))

    assert Enum.map(postgres, &{&1.table, &1.op, &1.key}) ==
             Enum.map(sqlite, &{&1.table, &1.op, &1.key})

    # Row by row: the decoded row (numbers compare by value: 1 equals 1.0) and
    # the blobs as upper-case hex.
    for {pg, lite} <- Enum.zip(comparable(postgres), comparable(sqlite)) do
      assert Map.keys(pg.row) |> Enum.sort() == Map.keys(lite.row) |> Enum.sort(), inspect(lite)

      for {column, value} <- lite.row do
        assert pg.row[column] == value,
               "#{lite.table}.#{column}: #{inspect(pg.row[column])} vs #{inspect(value)}"
      end

      assert pg.blobs == lite.blobs
      assert pg.workspace == lite.workspace
    end

    # An append-only table's rows carry no key, and their deletes are not captured.
    assert Enum.any?(sqlite, &(&1.table == "memory_relations" and is_nil(&1.key)))
    # A composite key is a compact JSON array on both.
    assert Enum.any?(postgres, &(&1.key == Jason.encode!(["m1-#{ws}", @model])))

    # The key of every captured row is the key `Sync` computes from its values.
    for %{op: op, table: table, key: key, row: row} <- postgres, key != nil, op != "delete" do
      keys = Capture.key_columns(PgCapture.columns(table))
      assert Sync.entity_key(keys, row) == key, "#{table}: #{key}"
    end

    assert %{"embedding" => "000102FF"} = Enum.find(postgres, &(&1.table == "vectors")).blobs
  end

  test "nothing is captured while changes are applied", %{tenant: tenant, ws: ws} do
    for store <- [Store, PgStore] do
      :ok = store.raw_execute("UPDATE sync_identity SET applying = 1 WHERE id = 1", [])
    end

    try do
      both([
        {"INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES (?1, ?2, ?3, 'applied')",
         ["ma-#{ws}", tenant, ws]}
      ])
    after
      for store <- [Store, PgStore] do
        :ok = store.raw_execute("UPDATE sync_identity SET applying = 0 WHERE id = 1", [])
      end
    end

    assert captured(Store, ws) == []
    assert captured(PgStore, ws) == []
  end

  test "a workspace that does not sync is not captured", %{tenant: tenant} do
    other = "#{tenant}:other"

    for store <- [Store, PgStore] do
      :ok =
        store.raw_execute(
          "INSERT INTO workspaces (id, tenant_id, slug, name) VALUES (?1, ?2, 'other', 'Other')",
          [other, tenant]
        )

      :ok =
        store.raw_execute(
          "INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES (?1, ?2, ?3, 'quiet')",
          ["mq-#{other}", tenant, other]
        )
    end

    assert captured(Store, other) == []
    assert captured(PgStore, other) == []
  end

  test "installing again changes no trigger, and a trigger left on a local table is dropped" do
    oid = fn name ->
      {:ok, [[oid]]} =
        PgStore.raw_query(
          "SELECT CAST(g.oid AS INTEGER) FROM pg_trigger g JOIN pg_class c ON c.oid = g.tgrelid " <>
            "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
            "WHERE g.tgname = ?1 AND n.nspname = current_schema()",
          [name]
        )

      oid
    end

    before = oid.("sync_capture_ai_contexts")
    assert :ok = Capture.install_postgres("contexts", PgCapture.columns("contexts"))
    assert oid.("sync_capture_ai_contexts") == before

    # jobs stays on its Engine: a capture trigger found there is removed.
    :ok =
      PgCapture.ensure_triggers(
        "jobs",
        "sync_capture_",
        "optimal_sync_capture",
        PgCapture.capture_triggers("jobs", ["id"], [], false)
      )

    assert "jobs" in PgCapture.triggered_tables("sync_capture_")
    :ok = PgCapture.drop_triggers("sync_capture_", :all, &(&1 in Capture.replicated_tables()))
    refute "jobs" in PgCapture.triggered_tables("sync_capture_")
    assert "contexts" in PgCapture.triggered_tables("sync_capture_")
  end

  test "the stamp moves with every committed write it watches", %{tenant: tenant, ws: ws} do
    stamp = fn -> Map.new(PgCapture.stamp(), &List.to_tuple/1) end
    before = stamp.()

    :ok =
      PgStore.raw_execute(
        "INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES (?1, ?2, ?3, 's')",
        ["ms-#{ws}", tenant, ws]
      )

    assert stamp.()["sync_capture"] > Map.get(before, "sync_capture", 0)
  end
end
