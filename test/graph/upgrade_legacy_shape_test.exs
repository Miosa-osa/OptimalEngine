defmodule OptimalEngine.Graph.UpgradeLegacyShapeTest do
  @moduledoc """
  What an Engine that wrote its graph the way 0.3.7 did shows after the graph
  edges migration, and what the upgrade guide tells its operator to look for.

  0.3.7 wrote edges to `edges` under UNIQUE(source_id, target_id, relation), so
  an entity pair a second workspace shares was dropped, and it labelled a
  context with the tenant of its workspace's row only: a context of an
  unregistered id read `default` whoever wrote it, while the source package kept
  the tenant of the writing key.

  After the migration:

    * `graph_edges` holds exactly the legacy rows, each with its workspace's
      tenant, and `GET /api/graph` answers what it answered before
    * the edges the old key dropped are missing until the graph backfill, and
      `GET /api/maintenance/graph` says so until one has run
    * a context of an unregistered id that names a tenant by prefix takes it
    * a context of a bare unregistered id is the default tenant's: the tenant
      whose key wrote it reads it as empty, cannot rewrite it, and the guide's
      pre-upgrade query finds it
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Context
  alias OptimalEngine.Graph
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  @guide Path.expand("../../docs/guides/versioning-and-releases.md", __DIR__)

  setup do
    n = System.unique_integer([:positive])
    tenant = "legacy-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Legacy tenant"})
    org = "#{tenant}:org"

    {:ok, _} =
      OptimalEngine.Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, own} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "own", name: "Own"})

    {:ok, first} = Workspace.create(%{slug: "first-#{n}", name: "First"})
    {:ok, second} = Workspace.create(%{slug: "second-#{n}", name: "Second"})

    # The migration keeps edge ids, so the legacy rows take ids no graph edge has.
    {:ok, [[base]]} =
      Store.raw_query(
        "SELECT MAX(COALESCE((SELECT MAX(id) FROM graph_edges), 0), COALESCE((SELECT MAX(id) FROM edges), 0)) + 1000",
        []
      )

    Process.put(:legacy_edge_id, base)

    %{
      n: n,
      tenant: tenant,
      own: own.id,
      first: first.id,
      second: second.id,
      loose: "#{tenant}:loose-#{n}",
      bare: "bare-#{n}",
      alice: "Alice#{n}",
      bob: "Bob#{n}"
    }
  end

  # Writes two contexts naming both entities the way 0.3.7 did: the context takes
  # the tenant of its workspace's row, else `default`; the source package takes
  # the tenant of the writing key; the edges go through the legacy table's own
  # key, so an edge another workspace wrote first is dropped.
  defp write_as_037!(ctx, workspace, writer) do
    label = registered_tenant(workspace)

    for i <- 1..2 do
      id = "ctx-#{workspace}-#{i}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, node, entities, created_at, modified_at) VALUES (?1, ?2, ?3, 'signal', ?4, 'Body', 'notes', ?5, '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')",
          [id, label, workspace, "Context #{id}", Jason.encode!([ctx.alice, ctx.bob])]
        )

      for name <- [ctx.alice, ctx.bob] do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO entities (context_id, name, type, tenant_id, workspace_id) VALUES (?1, ?2, 'person', ?3, ?4)",
            [id, name, label, workspace]
          )

        legacy_edge!(name, id, "mentioned_in", 1.0, workspace)
      end

      legacy_edge!(ctx.alice, ctx.bob, "co_occurs", 0.5, workspace)
      legacy_edge!(ctx.bob, ctx.alice, "co_occurs", 0.5, workspace)
      legacy_edge!(id, "notes", "lives_in", 1.0, workspace)

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash) VALUES (?1, ?2, ?3, ?4)",
          ["pkg-#{id}", writer, workspace, "hash-#{id}"]
        )
    end
  end

  # The statement 0.3.7 used, against the baseline table and its three-column key.
  defp legacy_edge!(source, target, relation, weight, workspace) do
    id = Process.get(:legacy_edge_id)
    Process.put(:legacy_edge_id, id + 1)

    {:ok, _} =
      Store.raw_query(
        "INSERT OR IGNORE INTO edges (id, source_id, target_id, relation, weight, valid_from, workspace_id) VALUES (?1, ?2, ?3, ?4, ?5, '2026-10-01T00:00:00Z', ?6)",
        [id, source, target, relation, weight, workspace]
      )
  end

  defp registered_tenant(workspace) do
    {:ok, [[tenant]]} =
      Store.raw_query(
        "SELECT COALESCE((SELECT w.tenant_id FROM workspaces w WHERE w.id = ?1), 'default')",
        [workspace]
      )

    tenant
  end

  defp migrate! do
    {_version, _description, statements} =
      Enum.find(OptimalEngine.Store.Migrations.all(), fn {_version, description, _statements} ->
        description == "graph edges keyed by tenant and workspace"
      end)

    for {_label, sql} <- statements, do: {:ok, _} = Store.raw_query(sql, [])
  end

  defp key(tenant) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "legacy", scopes: ["read"], workspace_scope: ["*"]})

    key
  end

  defp get(path, token) do
    response =
      conn(:get, path)
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    {response.status, Jason.decode!(response.resp_body)}
  end

  defp graph(workspace, tenant) do
    {200, %{"stats" => stats}} = get("/api/graph?workspace=#{workspace}", key(tenant))
    stats
  end

  defp graph_edge_count(workspace) do
    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM graph_edges WHERE workspace_id = ?1", [workspace])

    count
  end

  defp legacy_edge_count(workspace) do
    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM edges WHERE workspace_id = ?1", [workspace])

    count
  end

  defp graph_edge?(source, target, relation, workspace) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT 1 FROM graph_edges WHERE source_id = ?1 AND target_id = ?2 AND relation = ?3 AND workspace_id = ?4",
        [source, target, relation, workspace]
      )

    rows != []
  end

  # The first SQL block of the guide's "Graph edges upgrade" section: the query
  # an operator runs on the store before upgrading.
  defp guide_query do
    guide = File.read!(@guide)
    [_, section] = Regex.run(~r/### Graph edges upgrade\n(.*?)\n## /s, guide)
    [_, sql] = Regex.run(~r/```sql\n(.*?)```/s, section)
    sql
  end

  describe "an Engine upgraded from the 0.3.7 shape" do
    test "the migration copies every legacy edge with its workspace's tenant", ctx do
      write_as_037!(ctx, ctx.first, "default")
      write_as_037!(ctx, ctx.second, "default")
      write_as_037!(ctx, ctx.own, ctx.tenant)

      migrate!()

      for workspace <- [ctx.first, ctx.second, ctx.own] do
        assert graph_edge_count(workspace) == legacy_edge_count(workspace), workspace
      end

      {:ok, tenants} =
        Store.raw_query(
          "SELECT DISTINCT workspace_id, tenant_id FROM graph_edges WHERE workspace_id IN (?1, ?2, ?3) ORDER BY workspace_id",
          [ctx.first, ctx.second, ctx.own]
        )

      assert Enum.sort(tenants) ==
               Enum.sort([[ctx.first, "default"], [ctx.second, "default"], [ctx.own, ctx.tenant]])
    end

    test "the old key dropped the pair the second workspace shares, and the backfill writes it",
         ctx do
      write_as_037!(ctx, ctx.first, "default")
      write_as_037!(ctx, ctx.second, "default")
      migrate!()

      assert graph_edge?(ctx.alice, ctx.bob, "co_occurs", ctx.first)
      refute graph_edge?(ctx.alice, ctx.bob, "co_occurs", ctx.second)

      assert {:ok, %{backfill_needed: true, legacy_edges: legacy}} =
               Graph.backfill_status(ctx.second)

      assert legacy == legacy_edge_count(ctx.second)

      assert {:ok, %{failed_edges: 0, recorded: true}} =
               Graph.backfill(workspace_id: ctx.second)

      assert graph_edge?(ctx.alice, ctx.bob, "co_occurs", ctx.second)
      assert graph_edge?(ctx.bob, ctx.alice, "co_occurs", ctx.second)
      assert {:ok, %{backfill_needed: false}} = Graph.backfill_status(ctx.second)
    end

    test "GET /api/graph answers the same before and after the migration", ctx do
      write_as_037!(ctx, ctx.first, "default")
      write_as_037!(ctx, ctx.own, ctx.tenant)

      before_first = graph(ctx.first, "default")
      before_own = graph(ctx.own, ctx.tenant)
      migrate!()

      assert graph(ctx.first, "default") == before_first
      assert graph(ctx.own, ctx.tenant) == before_own

      # Two contexts naming the same two entities: each entity links them once.
      assert %{"context_count" => 2, "edge_count" => 1, "entity_count" => 2} = before_first
      assert %{"context_count" => 2, "edge_count" => 1, "entity_count" => 2} = before_own
    end

    test "an unregistered id that names a tenant takes it, and its owner reads it", ctx do
      write_as_037!(ctx, ctx.loose, ctx.tenant)

      assert registered_tenant(ctx.loose) == "default"
      assert %{"context_count" => 0} = graph(ctx.loose, ctx.tenant)

      migrate!()

      assert %{"context_count" => 2, "edge_count" => 1} = graph(ctx.loose, ctx.tenant)
      assert graph_edge?(ctx.alice, "ctx-#{ctx.loose}-1", "mentioned_in", ctx.loose)
    end

    test "a bare unregistered id stays the default tenant's, and the guide's query finds it",
         ctx do
      write_as_037!(ctx, ctx.bare, ctx.tenant)
      write_as_037!(ctx, ctx.own, ctx.tenant)
      migrate!()

      assert %{"context_count" => 0, "edge_count" => 0} = graph(ctx.bare, ctx.tenant)
      assert %{"context_count" => 2, "edge_count" => 1} = graph(ctx.bare, "default")

      assert {:ok, found} = Store.raw_query(guide_query(), [])

      assert [ctx.bare, ctx.tenant, 2] in found,
             "the guide's pre-upgrade query did not list #{ctx.bare}: #{inspect(found)}"

      refute Enum.any?(found, fn [workspace, _tenant, _n] -> workspace == ctx.own end)
    end

    test "the tenant that wrote a bare id's row cannot rewrite it, and the row stays default's",
         ctx do
      write_as_037!(ctx, ctx.bare, ctx.tenant)
      migrate!()
      id = "ctx-#{ctx.bare}-1"

      rewrite = %Context{
        id: id,
        uri: "optimal://#{ctx.bare}/#{id}",
        type: :signal,
        title: "Rewritten #{id}",
        content: "Rewritten.",
        node: "notes",
        entities: [ctx.alice, ctx.bob],
        workspace_id: ctx.bare,
        tenant_id: ctx.tenant
      }

      assert {:error, {:context_id_in_use, ^id}} = Store.insert_context(rewrite)

      assert {:ok, [["default", "Body"]]} =
               Store.raw_query("SELECT tenant_id, content FROM contexts WHERE id = ?1", [id])

      # A new document under the same bare id is the writer's own.
      fresh = %Context{rewrite | id: "fresh-#{ctx.bare}", uri: "optimal://#{ctx.bare}/fresh"}
      assert :ok = Store.insert_context(fresh)

      assert {:ok, [[tenant]]} =
               Store.raw_query("SELECT tenant_id FROM contexts WHERE id = ?1", [fresh.id])

      assert tenant == ctx.tenant
    end
  end
end
