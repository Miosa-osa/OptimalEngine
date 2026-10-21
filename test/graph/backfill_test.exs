defmodule OptimalEngine.Graph.BackfillTest do
  @moduledoc """
  The graph backfill writes the edges of indexed contexts and claims in each
  row's own workspace, idempotently, a page at a time, and can resume.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Graph
  alias OptimalEngine.Graph.Backfill
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  setup do
    n = System.unique_integer([:positive])
    tenant = "graph-backfill-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Graph backfill tenant"})
    org = "#{tenant}:org"

    {:ok, _} =
      OptimalEngine.Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, ws} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "notes", name: "Notes"})

    {:ok, other} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "other", name: "Other"})

    alice = "alice-#{n}"
    bob = "bob-#{n}"
    carol = "carol-#{n}"

    first = context!(tenant, ws.id, "gbf-#{n}-1", "node-#{n}", [alice, bob])
    second = context!(tenant, ws.id, "gbf-#{n}-2", "node-#{n}", [bob])
    elsewhere = context!(tenant, other.id, "gbf-#{n}-3", "node-#{n}", [carol])

    %{
      n: n,
      tenant: tenant,
      ws: ws.id,
      other: other.id,
      first: first,
      second: second,
      elsewhere: elsewhere,
      alice: alice,
      bob: bob
    }
  end

  test "each context's edges are written in its own workspace, once", ctx do
    assert {:ok, %{contexts: 2, claims: 0, edges_before: 0, edges_after: added, next: nil}} =
             Backfill.run(workspace_id: ctx.ws)

    assert added > 0
    assert edge?(ctx.alice, ctx.first, "mentioned_in", ctx.ws)
    assert edge?(ctx.alice, ctx.bob, "co_occurs", ctx.ws)
    assert edge?(ctx.bob, ctx.alice, "co_occurs", ctx.ws)
    assert edge?(ctx.second, "node-#{ctx.n}", "lives_in", ctx.ws)
    assert edges_in(ctx.other) == 0

    assert {:ok, %{contexts: 2, edges_before: ^added, edges_after: ^added}} =
             Backfill.run(workspace_id: ctx.ws)
  end

  test "the counts can be left out, and a workspace's pages use its indexes", ctx do
    assert {:ok, %{contexts: 2, edges_before: nil, edges_after: nil}} =
             Backfill.run(workspace_id: ctx.ws, count: false)

    for {phase, sql, params} <- Backfill.page_statements(ctx.ws) do
      {:ok, plan} = Store.raw_query("EXPLAIN QUERY PLAN " <> sql, params)
      details = Enum.map_join(plan, "\n", &List.last/1)
      ref = if phase == :contexts, do: "c", else: "cl"
      table = if phase == :contexts, do: "contexts", else: "claims"
      assert details =~ ~r/SEARCH #{ref} USING (COVERING )?INDEX idx_#{table}_workspace_id/, details
    end
  end

  test "a tenant scope covers each of its workspaces", ctx do
    assert {:ok, %{contexts: 3, next: nil}} = Backfill.run(tenant_id: ctx.tenant)
    assert edges_in(ctx.ws) > 0
    assert edges_in(ctx.other) > 0
  end

  test "a limit stops the run and says where to resume", ctx do
    parent = self()
    on_page = fn progress -> send(parent, {:page, progress}) end

    assert {:ok, %{contexts: 1, next: {:contexts, first}}} =
             Backfill.run(workspace_id: ctx.ws, limit: 1, on_page: on_page)

    assert first == ctx.first
    assert_received {:page, {:contexts, 1}}

    assert {:ok, %{contexts: 1, next: nil}} =
             Backfill.run(workspace_id: ctx.ws, after: {:contexts, first}, page: 1)

    assert edge?(ctx.second, "node-#{ctx.n}", "lives_in", ctx.ws)
  end

  test "two workspaces that share an entity pair each get its edges", ctx do
    shared =
      context!(ctx.tenant, ctx.other, "gbf-#{ctx.n}-4", "node-#{ctx.n}", [ctx.alice, ctx.bob])

    assert {:ok, %{next: nil}} = Backfill.run(tenant_id: ctx.tenant)

    assert edge?(ctx.alice, ctx.bob, "co_occurs", ctx.ws)
    assert edge?(ctx.alice, ctx.bob, "co_occurs", ctx.other)
    assert edge?(ctx.alice, shared, "mentioned_in", ctx.other)
    assert edge?(shared, ctx.alice, "mentions", ctx.other)
  end

  test "only a whole run with its claims and no failed write is recorded", ctx do
    assert {:ok, %{next: {:contexts, _} = next, recorded: false}} =
             Backfill.run(workspace_id: ctx.ws, limit: 1)

    assert {:ok, %{next: nil, recorded: false}} = Backfill.run(workspace_id: ctx.ws, after: next)
    assert {:ok, %{recorded: false}} = Backfill.run(workspace_id: ctx.ws, claims: false)
    assert {:ok, %{next: nil, recorded: false}} = Backfill.run(tenant_id: ctx.tenant)
    assert recorded(ctx.ws) == 0

    assert {:ok, %{next: nil, failed_edges: 0, recorded: true}} =
             Backfill.run(workspace_id: ctx.ws, count: false)

    assert recorded(ctx.ws) == 1
  end

  test "claims get about edges to their source context's entities", ctx do
    claim = claim!(ctx.tenant, ctx.ws, "gbf-claim-#{ctx.n}", ctx.first)

    assert {:ok, %{contexts: 2, claims: 0}} = Backfill.run(workspace_id: ctx.ws, claims: false)
    refute edge?(claim, ctx.alice, "about", ctx.ws)

    assert {:ok, %{contexts: 0, claims: 1, next: nil}} =
             Backfill.run(workspace_id: ctx.ws, after: {:claims, ""})

    assert edge?(claim, ctx.alice, "about", ctx.ws)
    assert edge?(claim, ctx.bob, "about", ctx.ws)

    assert {:ok, %{contexts: 2, claims: 1}} = Backfill.status(workspace_id: ctx.ws)
  end

  defp edge?(source, target, relation, workspace) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT 1 FROM graph_edges WHERE source_id = ?1 AND target_id = ?2 AND relation = ?3 AND workspace_id = ?4",
        [source, target, relation, workspace]
      )

    rows != []
  end

  defp edges_in(workspace) do
    {:ok, count} = Graph.count(workspace_id: workspace)
    count
  end

  defp recorded(workspace) do
    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM graph_backfills WHERE workspace_id = ?1", [workspace])

    count
  end

  defp context!(tenant, workspace, id, node, entities) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, node, entities, created_at) VALUES (?1, ?2, ?3, 'signal', ?4, 'Body', ?5, ?6, datetime('now'))",
        [id, tenant, workspace, "Context #{id}", node, Jason.encode!(entities)]
      )

    id
  end

  defp claim!(tenant, workspace, id, signal_id) do
    package = "package-" <> id

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash) VALUES (?1, ?2, ?3, ?4)",
        [package, tenant, workspace, "hash-" <> id]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, ?5, 'A claim')",
        [id, tenant, workspace, package, signal_id]
      )

    id
  end
end
