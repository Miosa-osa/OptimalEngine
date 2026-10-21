defmodule OptimalEngine.DataStewardRelabelBareScopeTest do
  @moduledoc """
  Before 0.3.8 a context was filed under the tenant of its workspace row, so
  what a tenant's key wrote under a bare, unregistered workspace id was labelled
  `default` and is invisible to that tenant now. `relabel_bare_scope/2` gives a
  tenant the `default` rows under such an id that its own source packages
  vouch for, in one transaction, and leaves every other row where it is.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.DataSteward
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "relabel-t-#{n}"
    other = "relabel-u-#{n}"
    for id <- [tenant, other], do: {:ok, _} = Tenant.create(%{id: id, name: id})

    %{n: n, tenant: tenant, other: other, ws: "relabel-bare-#{n}"}
  end

  defp sql!(sql, params) do
    {:ok, _} = Store.raw_query(sql, params)
    :ok
  end

  defp package!(id, tenant, ws) do
    sql!(
      "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash) VALUES (?1, ?2, ?3, ?4)",
      [id, tenant, ws, "hash-" <> id]
    )
  end

  defp context!(id, tenant, ws) do
    sql!(
      "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, node, created_at) VALUES (?1, ?2, ?3, 'signal', 'Title', 'Body', 'team', datetime('now'))",
      [id, tenant, ws]
    )
  end

  # What intake records when it turns a source package into a signal and a context.
  defp ledger!(id, tenant, ws, package, context) do
    sql!(
      """
      INSERT INTO derivation_ledger
        (id, tenant_id, workspace_id, activity_type, derivation_stage, output_object_links, source_package_links)
      VALUES (?1, ?2, ?3, 'intake.process', 'source_to_signal_context', ?4, ?5)
      """,
      [
        id,
        tenant,
        ws,
        Jason.encode!([%{type: "signal", id: context}, %{type: "context", id: context}]),
        Jason.encode!([%{type: "source_package", id: package}])
      ]
    )
  end

  defp claim!(id, tenant, ws, package, signal) do
    sql!(
      "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, ?5, 'A claim')",
      [id, tenant, ws, package, signal]
    )
  end

  defp chunk!(id, tenant, ws, context) do
    sql!(
      "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, workspace_id) VALUES (?1, ?2, ?3, 'document', 'Body', ?4)",
      [id, tenant, context, ws]
    )
  end

  defp entity!(context, tenant, ws) do
    sql!(
      "INSERT INTO entities (context_id, name, type, workspace_id, tenant_id) VALUES (?1, 'Acme Corp', 'person', ?2, ?3)",
      [context, ws, tenant]
    )
  end

  defp chunk_embedding!(chunk, tenant, ws) do
    sql!(
      "INSERT INTO chunk_embeddings (chunk_id, tenant_id, model, modality, dim, vector, workspace_id) VALUES (?1, ?2, 'm', 'text', 2, ?3, ?4)",
      [chunk, tenant, {:blob, <<0, 0>>}, ws]
    )
  end

  defp decision!(context, tenant, ws) do
    sql!(
      "INSERT INTO decisions (context_id, title, decision, tenant_id, workspace_id) VALUES (?1, 'Title', 'Decision', ?2, ?3)",
      [context, tenant, ws]
    )
  end

  defp edge!(tenant, ws, source, target) do
    sql!(
      "INSERT INTO graph_edges (tenant_id, workspace_id, source_id, target_id, relation) VALUES (?1, ?2, ?3, ?4, 'mentions')",
      [tenant, ws, source, target]
    )
  end

  defp tenants(sql, params) do
    {:ok, rows} = Store.raw_query(sql, params)
    rows |> List.flatten() |> Enum.sort()
  end

  defp tenant_of(table, column, id),
    do: tenants("SELECT tenant_id FROM #{table} WHERE #{column} = ?1", [id])

  # A workspace as 0.3.7 left it: the tenant's package and contexts, a context
  # the tenant's package does not name, another tenant's package and context,
  # a context nobody vouches for, and one that both tenants' intake derived (the
  # same connector item on a shared id: the first writer kept the row).
  defp legacy!(ctx) do
    %{n: n, tenant: t, other: u, ws: ws} = ctx

    ids = %{
      mine: "mine-#{n}",
      mine2: "mine2-#{n}",
      unvouched: "unvouched-#{n}",
      theirs: "theirs-#{n}",
      shared: "shared-#{n}",
      done: "done-#{n}"
    }

    package!("pkg-t-#{n}", t, ws)
    package!("pkg-u-#{n}", u, ws)

    for id <- [ids.mine, ids.mine2, ids.unvouched, ids.theirs, ids.shared],
        do: context!(id, "default", ws)

    context!(ids.done, t, ws)

    ledger!("led-t-#{n}", t, ws, "pkg-t-#{n}", ids.mine)
    ledger!("led-t2-#{n}", t, ws, "pkg-t-#{n}", ids.mine2)
    ledger!("led-u-#{n}", u, ws, "pkg-u-#{n}", ids.theirs)
    ledger!("led-ts-#{n}", t, ws, "pkg-t-#{n}", ids.shared)
    ledger!("led-us-#{n}", u, ws, "pkg-u-#{n}", ids.shared)

    claim!("claim-mine-#{n}", "default", ws, "pkg-t-#{n}", ids.mine)
    claim!("claim-theirs-#{n}", "default", ws, "pkg-u-#{n}", ids.theirs)

    for id <- [ids.mine, ids.unvouched, ids.theirs, ids.shared] do
      chunk!("chunk-#{id}", "default", ws, id)
      chunk_embedding!("chunk-#{id}", "default", ws)
      decision!(id, "default", ws)
      entity!(id, "default", ws)
      assert :ok = Vectors.store(id, [0.1, 0.2], workspace_id: ws)
    end

    edge!("default", ws, ids.mine, "Acme Corp")
    edge!("default", ws, "Acme Corp", ids.theirs)
    # The same edge, already the tenant's: the default copy is the duplicate.
    edge!("default", ws, "claim-mine-#{n}", ids.mine)
    edge!(t, ws, "claim-mine-#{n}", ids.mine)
    # Between two entities: no context to attribute it to.
    edge!("default", ws, "Acme Corp", "Bolt Inc")
    # Between two of the tenant's contexts: the tenant's.
    edge!("default", ws, ids.mine, ids.mine2)
    # Between the tenant's and a context or a claim that stays: it stays with them.
    edge!("default", ws, ids.mine, ids.unvouched)
    edge!("default", ws, ids.mine, "claim-theirs-#{n}")
    ids
  end

  test "gives the tenant the rows its source packages vouch for", ctx do
    ids = legacy!(ctx)
    %{ws: ws, tenant: t, n: n} = ctx

    assert {:ok, result} = DataSteward.relabel_bare_scope(ws, tenant_id: t, actor_id: "user:test")

    assert %{workspace_id: ^ws, tenant_id: ^t, contexts: 2, claims: 1} = result
    assert %{chunks: 1, vectors: 1, entities: 1, chunk_embeddings: 1, decisions: 1} = result
    assert %{graph_edges: 2, duplicate_edges: 1} = result

    assert tenant_of("contexts", "id", ids.mine) == [t]
    assert tenant_of("claims", "id", "claim-mine-#{n}") == [t]
    assert tenant_of("chunks", "signal_id", ids.mine) == [t]
    assert tenant_of("vectors", "context_id", ids.mine) == [t]
    assert tenant_of("entities", "context_id", ids.mine) == [t]
    assert tenant_of("chunk_embeddings", "chunk_id", "chunk-#{ids.mine}") == [t]
    assert tenant_of("decisions", "context_id", ids.mine) == [t]
    assert tenant_of("contexts", "id", ids.mine2) == [t]

    # The edge of the context is the tenant's, once: the default duplicate of the one
    # it already had is gone, the other moved.
    assert tenants(
             "SELECT tenant_id FROM graph_edges WHERE workspace_id = ?1 AND source_id = ?2 AND target_id = ?3",
             [ws, "claim-mine-#{n}", ids.mine]
           ) == [t]

    # Of the edges that start at the context, the ones to an entity and to the
    # tenant's other context moved; the ones to a context and a claim that stay did not.
    assert tenants(
             "SELECT tenant_id FROM graph_edges WHERE workspace_id = ?1 AND source_id = ?2 AND target_id IN ('Acme Corp', ?3)",
             [ws, ids.mine, ids.mine2]
           ) == [t]

    assert tenants(
             "SELECT tenant_id FROM graph_edges WHERE workspace_id = ?1 AND source_id = ?2 AND target_id IN (?3, ?4)",
             [ws, ids.mine, ids.unvouched, "claim-theirs-#{n}"]
           ) == ["default"]
  end

  test "records the relabel in the tenant's evidence chain", ctx do
    legacy!(ctx)
    %{ws: ws, tenant: t} = ctx

    assert {:ok, _} = DataSteward.relabel_bare_scope(ws, tenant_id: t, actor_id: "user:test")

    assert [entry] = Evidence.list(t, kind: "workspace.relabeled")
    assert entry["workspace_id"] == ws
    assert entry["subject"] == "user:test"
    assert %{"tenant" => ^t, "contexts" => 2, "claims" => 1} = entry["detail"]
    assert Evidence.verify(t) |> elem(0) == :ok
  end

  test "leaves every other row where it is", ctx do
    ids = legacy!(ctx)
    %{ws: ws, tenant: t, n: n} = ctx

    assert {:ok, _} = DataSteward.relabel_bare_scope(ws, tenant_id: t, actor_id: "user:test")

    # Two tenants' intake derived the shared one: whose it is, nobody can say.
    for id <- [ids.unvouched, ids.theirs, ids.shared] do
      assert tenant_of("contexts", "id", id) == ["default"]
      assert tenant_of("chunks", "signal_id", id) == ["default"]
      assert tenant_of("vectors", "context_id", id) == ["default"]
      assert tenant_of("entities", "context_id", id) == ["default"]
      assert tenant_of("chunk_embeddings", "chunk_id", "chunk-#{id}") == ["default"]
      assert tenant_of("decisions", "context_id", id) == ["default"]
    end

    assert tenant_of("contexts", "id", ids.done) == [t]
    assert tenant_of("claims", "id", "claim-theirs-#{n}") == ["default"]

    assert tenants(
             "SELECT tenant_id FROM graph_edges WHERE workspace_id = ?1 AND source_id = 'Acme Corp' AND target_id = 'Bolt Inc'",
             [ws]
           ) == ["default"]

    assert tenants(
             "SELECT tenant_id FROM graph_edges WHERE workspace_id = ?1 AND target_id = ?2",
             [ws, ids.theirs]
           ) == ["default"]

    # The packages and the ledger are evidence, not rows to relabel.
    assert tenant_of("source_packages", "id", "pkg-u-#{n}") == [ctx.other]
    assert tenant_of("source_packages", "id", "pkg-t-#{n}") == [t]
  end

  test "is done once: a second run has nothing to relabel", ctx do
    legacy!(ctx)

    assert {:ok, _} =
             DataSteward.relabel_bare_scope(ctx.ws, tenant_id: ctx.tenant, actor_id: "user:test")

    assert {:error, :nothing_to_relabel} =
             DataSteward.relabel_bare_scope(ctx.ws, tenant_id: ctx.tenant, actor_id: "user:test")
  end

  describe "what is refused" do
    test "an id with no evidence of the tenant's, and says nothing of what others hold", ctx do
      %{ws: ws, other: u, tenant: t, n: n} = ctx
      package!("pkg-u-#{n}", u, ws)
      context!("only-theirs-#{n}", "default", ws)
      ledger!("led-u-#{n}", u, ws, "pkg-u-#{n}", "only-theirs-#{n}")

      assert {:error, :nothing_to_relabel} =
               DataSteward.relabel_bare_scope(ws, tenant_id: t, actor_id: "user:test")

      assert tenant_of("contexts", "id", "only-theirs-#{n}") == ["default"]
    end

    test "a registered workspace id: its owner decides", ctx do
      %{ws: ws, tenant: t, n: n} = ctx
      legacy!(ctx)

      sql!(
        "INSERT INTO workspaces (id, tenant_id, organization_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?4, 'Legacy', 'active', '{}')",
        [ws, ctx.other, OptimalEngine.Organization.default_for(ctx.other), "legacy-#{n}"]
      )

      assert {:error, :workspace_is_registered} =
               DataSteward.relabel_bare_scope(ws, tenant_id: t, actor_id: "user:test")

      assert tenant_of("contexts", "id", "mine-#{n}") == ["default"]
    end

    test "an id a tenant's prefix names", ctx do
      assert {:error, :not_a_bare_workspace_id} =
               DataSteward.relabel_bare_scope("#{ctx.other}:ops",
                 tenant_id: ctx.tenant,
                 actor_id: "user:test"
               )

      assert {:error, :not_a_bare_workspace_id} =
               DataSteward.relabel_bare_scope("default:ops",
                 tenant_id: ctx.tenant,
                 actor_id: "user:test"
               )
    end

    test "the default tenant and a tenant that is not there", ctx do
      assert {:error, :tenant_is_default} =
               DataSteward.relabel_bare_scope(ctx.ws, tenant_id: "default", actor_id: "user:test")

      assert {:error, :unknown_tenant} =
               DataSteward.relabel_bare_scope(ctx.ws,
                 tenant_id: "nobody-#{ctx.n}",
                 actor_id: "user:test"
               )
    end
  end
end
