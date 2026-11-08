defmodule OptimalEngine.Test.SyncPageFixture do
  @moduledoc false
  # A page of changes as an Engine on one store serves it, for the test that
  # applies it on the other store (test/sync/cross_store_apply_test.exs).
  # `record/1` writes one; the files under test/fixtures/sync were recorded on
  # a SQLite build and on a PostgreSQL build:
  #
  #     mix run --no-start -e 'Application.ensure_all_started(:optimal_engine); \
  #       OptimalEngine.Test.SyncPageFixture.record("test/fixtures/sync/<store>_page.json")'
  #
  # (run with MIX_ENV=test so test/support is compiled). Ids carry fxtoken,
  # which the test replaces, and the serving replica is renamed to
  # rep_fixture_<store>, so the page is a peer's on any Engine.

  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @token "fxtoken"

  def token, do: @token

  # The rows the page leaves in the applying workspace, read back by the test.
  def queries do
    hex = fn column ->
      if Store.selected?(OptimalEngine.Store.Postgres),
        do: "upper(encode(#{column}, 'hex'))",
        else: "hex(#{column})"
    end

    [
      {"contexts",
       "SELECT id, title, content, sn_ratio, valid_from FROM contexts WHERE workspace_id = ?1 ORDER BY id"},
      {"vectors",
       "SELECT context_id, #{hex.("embedding")}, dimensions FROM vectors WHERE workspace_id = ?1 ORDER BY context_id"},
      {"memories", "SELECT id, content FROM memories WHERE workspace_id = ?1 ORDER BY id"},
      {"memory_embeddings",
       "SELECT memory_id, model, content_hash, #{hex.("embedding")} FROM memory_embeddings WHERE workspace_id = ?1 ORDER BY memory_id, model"},
      {"memory_relations",
       "SELECT source_memory_id, target_memory_id, relation FROM memory_relations WHERE workspace_id = ?1 ORDER BY source_memory_id"}
    ]
  end

  def record(path) do
    tenant = "fx-#{@token}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Fixture"})

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

    ws = ws.id
    {:ok, _} = Sync.enable(tenant, ws, "user:owner")
    id = fn name -> "#{name}-#{@token}" end

    for {sql, params} <- [
          {"INSERT INTO contexts (id, tenant_id, workspace_id, title, content, sn_ratio, created_at) VALUES (?1, ?2, ?3, 'Café ✓', 'body \"q\" \\\\ line\nnext', 1.0, '2026-10-14T10:00:00Z')",
           [id.("c1"), tenant, ws]},
          {"INSERT INTO contexts (id, tenant_id, workspace_id, title, sn_ratio, created_at) VALUES (?1, ?2, ?3, 'second', 0.1, '2026-10-14T10:00:00Z')",
           [id.("c2"), tenant, ws]},
          {"UPDATE contexts SET title = 'renamed', sn_ratio = 0.75 WHERE id = ?1", [id.("c1")]},
          {"INSERT INTO vectors (context_id, embedding, dimensions, tenant_id, workspace_id) VALUES (?1, ?2, 4, ?3, ?4)",
           [id.("c1"), {:blob, <<0, 1, 2, 255>>}, tenant, ws]},
          {"INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES (?1, ?2, ?3, 'm one')",
           [id.("m1"), tenant, ws]},
          {"INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES (?1, ?2, ?3, 'm two')",
           [id.("m2"), tenant, ws]},
          {"INSERT INTO memory_embeddings (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash) VALUES (?1, ?2, ?3, 'stub', 2, ?4, 'h')",
           [id.("m1"), tenant, ws, {:blob, <<10, 11>>}]},
          {"INSERT INTO memory_embeddings (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash) VALUES (?1, ?2, ?3, 'other', 2, ?4, 'h')",
           [id.("m2"), tenant, ws, {:blob, <<12, 13>>}]},
          {"UPDATE memory_embeddings SET content_hash = 'h2' WHERE memory_id = ?1", [id.("m1")]},
          {"INSERT INTO memory_relations (tenant_id, workspace_id, source_memory_id, target_memory_id, relation, created_at) VALUES (?1, ?2, ?3, ?4, 'related', '2026-10-14T10:00:00Z')",
           [tenant, ws, id.("m1"), id.("m2")]},
          {"DELETE FROM memory_embeddings WHERE memory_id = ?1", [id.("m2")]},
          {"DELETE FROM contexts WHERE id = ?1", [id.("c2")]}
        ] do
      :ok = Store.raw_execute(sql, params)
    end

    page = Sync.changes(tenant, ws, limit: 100)

    expected =
      Map.new(queries(), fn {table, sql} ->
        {:ok, rows} = Store.raw_query(sql, [ws])
        {table, rows}
      end)

    store = if Store.selected?(OptimalEngine.Store.Postgres), do: "postgres", else: "sqlite"

    json =
      %{"store" => store, "mutations" => page["mutations"], "expected" => expected}
      |> Jason.encode!(pretty: true)
      |> String.replace(Sync.replica_id(), "rep_fixture_#{store}")
      |> String.replace(ws, "fx-#{@token}:ws")

    File.write!(path, json)
  end
end
