defmodule OptimalEngine.Graph.EdgeScopeTest do
  @moduledoc """
  Graph edges are scoped by tenant and workspace (the migration that created
  `graph_edges`):

    * an edge is unique within its tenant and workspace, so the same entity
      pair in two workspaces is two edges (the baseline `edges` table kept
      only the first workspace's)
    * every edge carries its workspace's tenant (`edges.tenant_id` was never
      written), for an unregistered `<tenant>:<slug>` id the tenant it names
    * reads are scoped to one tenant's workspace, so a second tenant reads
      only its own edges and the default tenant never reads another's
    * the migration copies the baseline edges with each workspace's tenant,
      gives legacy default-tenant contexts and entities their workspace's
      tenant, and running it again changes nothing
    * the graph backfill writes the edges an upgrade needs again, semantic
      and claim edges included
    * bundles carry a tenant's edges, and an older bundle's `edges` rows
      import into `graph_edges`
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Bridge.Knowledge, as: BridgeKnowledge
  alias OptimalEngine.Context
  alias OptimalEngine.CorpusOrganizer
  alias OptimalEngine.Graph
  alias OptimalEngine.Graph.Analyzer
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  setup do
    n = System.unique_integer([:positive])
    tenant = "edges-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Edges tenant"})
    org = "#{tenant}:org"

    {:ok, _} =
      OptimalEngine.Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, other} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "notes", name: "Notes"})

    {:ok, own} = Workspace.create(%{slug: "edges-#{n}", name: "Edges #{n}"})

    %{n: n, tenant: tenant, other: other.id, own: own.id}
  end

  defp context!(id, workspace_id, entities, content \\ nil, sn_ratio \\ 0.7) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      Store.insert_context(%Context{
        id: id,
        uri: "optimal://nodes/notes/#{id}.md",
        type: :signal,
        path: "/tmp/#{id}.md",
        title: "ctx #{id}",
        content: content || "content #{id}",
        l0_abstract: "SIGNAL | note | #{id}",
        l1_overview: "overview",
        node: "notes",
        sn_ratio: sn_ratio,
        entities: entities,
        created_at: now,
        modified_at: now,
        routed_to: [],
        workspace_id: workspace_id,
        metadata: %{}
      })

    id
  end

  defp scopes(id) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT DISTINCT tenant_id, workspace_id FROM graph_edges WHERE source_id = ?1 OR target_id = ?1",
        [id]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  describe "writes" do
    test "the same entity pair keeps its edge in two workspaces of two tenants", ctx do
      pair = ["Ada#{ctx.n}", "Grace#{ctx.n}"]
      context!("own-#{ctx.n}", ctx.own, pair)
      context!("other-#{ctx.n}", ctx.other, pair)

      for ws <- [ctx.own, ctx.other] do
        assert {:ok, [%{target_id: target}]} =
                 Graph.edges_for("Ada#{ctx.n}", relation: "co_occurs", workspace_id: ws)

        assert target == "Grace#{ctx.n}"
      end
    end

    test "an asserted edge between shared names is kept in each workspace", ctx do
      :ok = Graph.assert_edge("Lin#{ctx.n}", "Mo#{ctx.n}", "knows", workspace_id: ctx.own)
      :ok = Graph.assert_edge("Lin#{ctx.n}", "Mo#{ctx.n}", "knows", workspace_id: ctx.other)

      assert {:ok, [_]} = Graph.edges_for("Lin#{ctx.n}", workspace_id: ctx.own)
      assert {:ok, [_]} = Graph.edges_for("Lin#{ctx.n}", workspace_id: ctx.other)
    end

    test "every edge carries its workspace's tenant", ctx do
      id = context!("tenant-#{ctx.n}", ctx.other, ["Tess#{ctx.n}"])
      :ok = Graph.assert_edge(id, "Uma#{ctx.n}", "mentions", workspace_id: ctx.other)
      :ok = Graph.create_claim_edges("claim-#{ctx.n}", ["Tess#{ctx.n}"], workspace_id: ctx.other)

      assert scopes(id) == [{ctx.tenant, ctx.other}]
      assert scopes("claim-#{ctx.n}") == [{ctx.tenant, ctx.other}]

      own = context!("own-tenant-#{ctx.n}", ctx.own, ["Tess#{ctx.n}"])
      assert scopes(own) == [{"default", ctx.own}]

      # A workspace that is not registered belongs to the default tenant, as
      # its contexts do.
      :ok =
        Graph.assert_edge("adhoc-#{ctx.n}", "Vic#{ctx.n}", "knows", workspace_id: "adhoc-#{ctx.n}")

      assert scopes("adhoc-#{ctx.n}") == [{"default", "adhoc-#{ctx.n}"}]
    end

    test "a moved context takes its edges to the target workspace", ctx do
      {:ok, target} = Workspace.create(%{slug: "edges-target-#{ctx.n}", name: "Target #{ctx.n}"})
      intake!(ctx.own)

      id = context!("move-#{ctx.n}", ctx.own, ["Wren#{ctx.n}"])
      assert {:ok, _} = CorpusOrganizer.move_context(id, target.id, tenant_id: "default")
      assert scopes(id) == [{"default", target.id}]
    end

    test "a moved context of another tenant takes only its edges in the source workspace along",
         ctx do
      {:ok, intake} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "knowledge-intake",
          name: "Intake"
        })

      id = context!("cross-#{ctx.n}", intake.id, ["Yara#{ctx.n}"])

      # An edge naming the context in a third workspace is not the moved
      # context's and stays where it is.
      {:ok, stray} = Workspace.create(%{slug: "edges-stray-#{ctx.n}", name: "Stray #{ctx.n}"})
      :ok = Graph.assert_edge("Zed#{ctx.n}", id, "mentioned_in", workspace_id: stray.id)

      assert {:ok, _} = CorpusOrganizer.move_context(id, ctx.other, tenant_id: ctx.tenant)

      assert Enum.sort(scopes(id)) ==
               Enum.sort([{ctx.tenant, ctx.other}, {"default", stray.id}])

      assert {:ok, [_]} =
               Graph.edges_for("Yara#{ctx.n}", workspace_id: ctx.other, tenant_id: ctx.tenant)

      assert {:ok, []} = Graph.edges_for("Yara#{ctx.n}", workspace_id: intake.id)
    end
  end

  # Points the corpus organizer's intake at `workspace` for one test.
  defp intake!(workspace) do
    original = Application.get_env(:optimal_engine, :corpus_source_workspace)
    Application.put_env(:optimal_engine, :corpus_source_workspace, workspace)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:optimal_engine, :corpus_source_workspace),
        else: Application.put_env(:optimal_engine, :corpus_source_workspace, original)
    end)
  end

  describe "reads" do
    setup ctx do
      pair = ["Ada#{ctx.n}", "Grace#{ctx.n}"]
      own = context!("own-#{ctx.n}", ctx.own, pair)
      other = context!("other-#{ctx.n}", ctx.other, pair)
      %{own_id: own, other_id: other, pair: pair}
    end

    test "a second tenant reads its own edges and nothing in another tenant's name", ctx do
      opts = [workspace_id: ctx.other, tenant_id: ctx.tenant]
      assert {:ok, [_]} = Graph.edges_for("Ada#{ctx.n}", [relation: "co_occurs"] ++ opts)
      assert {:ok, [other_id]} = Graph.related_contexts("Ada#{ctx.n}", opts)
      assert other_id == ctx.other_id
      assert {:ok, %{"total_edges" => total}} = Graph.stats(opts)
      assert total > 0

      # The same workspace read in the default tenant's name is empty.
      wrong = [workspace_id: ctx.other, tenant_id: "default"]
      assert {:ok, []} = Graph.edges_for("Ada#{ctx.n}", [relation: "co_occurs"] ++ wrong)
      assert {:ok, []} = Graph.related_contexts("Ada#{ctx.n}", wrong)
      assert {:ok, []} = Graph.subgraph(ctx.other_id, 1, wrong)
      assert {:ok, %{"total_edges" => 0}} = Graph.stats(wrong)
      assert {:ok, []} = Graph.top_entities(10, wrong)
      assert {:ok, []} = Graph.sample_edges(10, wrong)
      assert {:ok, []} = Graph.graph_candidates(["Ada#{ctx.n}"], 2, wrong)
      assert {:ok, []} = Analyzer.hubs(wrong)
      assert {:ok, []} = Analyzer.clusters(wrong)
      assert {:ok, []} = Analyzer.triangles([skip_llm: true] ++ wrong)
      assert {:ok, 0} = Graph.count(wrong)
    end

    test "the default tenant never reads another tenant's edges", ctx do
      # Its own workspace holds only its own context.
      assert {:ok, [own_id]} = Graph.related_contexts("Ada#{ctx.n}", workspace_id: ctx.own)
      assert own_id == ctx.own_id

      assert {:ok, candidates} = Graph.graph_candidates(["Ada#{ctx.n}"], 2, workspace_id: ctx.own)
      refute ctx.other_id in candidates

      {:ok, clusters} = Analyzer.clusters(workspace_id: ctx.own)
      refute ctx.other_id in Enum.flat_map(clusters, &MapSet.to_list/1)

      # The tenant's count covers only its workspaces.
      assert {:ok, count} = Graph.count(tenant_id: ctx.tenant)
      assert {:ok, ^count} = Graph.count(workspace_id: ctx.other)
    end

    test "a search in one tenant ranks the same whether another tenant has edges or not", ctx do
      n = ctx.n
      other_tenant = "edges-b-#{n}"
      {:ok, _} = Tenant.create(%{id: other_tenant, name: "Edges tenant B"})

      {:ok, _} =
        OptimalEngine.Organization.create(%{
          id: "#{other_tenant}:org",
          tenant_id: other_tenant,
          slug: "org",
          name: "Org"
        })

      {:ok, b} =
        Workspace.create(%{
          tenant_id: other_tenant,
          organization_id: "#{other_tenant}:org",
          slug: "notes",
          name: "Notes"
        })

      # Tenant A's two documents both match the query; the first ranks higher
      # on its own, and only the second names the entities tenant B will link.
      linked = for i <- 1..5, do: "Quux#{n}-#{i}"

      first =
        context!("search-a-#{n}", ctx.other, ["Plain#{n}"], "The zorblax#{n} launch notes.", 0.9)

      second =
        context!("search-b-#{n}", ctx.other, linked, "The zorblax#{n} launch notes, again.", 0.5)

      # Documents without the query term keep its full-text weight above zero
      # however small the rest of the store is.
      for i <- 1..6,
          do: context!("filler-#{n}-#{i}", ctx.other, [], "Unrelated planning memo #{i}.")

      scope = [workspace_id: ctx.other, tenant_id: ctx.tenant]

      search = fn ->
        {:ok, results} = OptimalEngine.Retrieval.Search.search("zorblax#{n}", scope)
        Enum.map(results, &{&1.id, &1.score})
      end

      assembled = fn ->
        {:ok, results} = OptimalEngine.Retrieval.ContextAssembler.fused_search("zorblax#{n}", scope)
        Enum.map(results, &{&1.id, &1.score})
      end

      searched = search.()
      fused = assembled.()
      assert Enum.map(searched, &elem(&1, 0)) == [first, second]
      assert Enum.all?(searched, fn {_id, score} -> score > 0 end)
      assert Enum.map(fused, &elem(&1, 0)) == [first, second]

      # Tenant B links the query term to every entity of the second document,
      # in its own workspace.
      for entity <- linked do
        :ok = Graph.assert_edge("zorblax#{n}", entity, "knows", workspace_id: b.id)
      end

      assert_same_ranking(search.(), searched)
      assert_same_ranking(assembled.(), fused)

      # The same edges in tenant A's own workspace do lift the second document
      # above the first, so the comparisons above would see a boost.
      for entity <- linked do
        :ok = Graph.assert_edge("zorblax#{n}", entity, "knows", workspace_id: ctx.other)
      end

      assert Enum.map(search.(), &elem(&1, 0)) == [second, first]
    end

    test "another tenant's edges do not boost or describe the default workspace", ctx do
      :ok =
        Graph.assert_edge("zorblax#{ctx.n}", "Quuxium#{ctx.n}", "knows", workspace_id: ctx.other)

      result = %{entities: ["Quuxium#{ctx.n}"], score: 1.0}

      assert [%{score: 1.0}] = BridgeKnowledge.graph_boost([result], "zorblax#{ctx.n}")
      assert {:ok, markdown} = BridgeKnowledge.context_for("zorblax#{ctx.n}")
      refute markdown =~ "Quuxium#{ctx.n}"

      # In the tenant's own workspace the same edge does boost and describe.
      assert [%{score: 1.1}] =
               BridgeKnowledge.graph_boost([result], "zorblax#{ctx.n}", workspace_id: ctx.other)

      assert {:ok, markdown} =
               BridgeKnowledge.context_for("zorblax#{ctx.n}", workspace_id: ctx.other)

      assert markdown =~ "Quuxium#{ctx.n}"
    end
  end

  # Same ids in the same order; scores equal up to the time decay between the
  # two searches (seconds against a half-life of hours, then rounded).
  defp assert_same_ranking(results, expected) do
    assert Enum.map(results, &elem(&1, 0)) == Enum.map(expected, &elem(&1, 0))

    Enum.zip(results, expected)
    |> Enum.each(fn {{_, actual}, {_, wanted}} -> assert_in_delta actual, wanted, 0.0002 end)
  end

  describe "the graph edges migration" do
    defp legacy_edge!(id, source, target, workspace_id) do
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO edges (id, source_id, target_id, relation, weight, valid_from, workspace_id)
          VALUES (?1, ?2, ?3, 'knows', 0.5, '2026-01-01T00:00:00Z', ?4)
          """,
          [id, source, target, workspace_id]
        )
    end

    defp migration do
      Enum.find(OptimalEngine.Store.Migrations.all(), fn {_version, description, _statements} ->
        description == "graph edges keyed by tenant and workspace"
      end)
    end

    defp migrate! do
      {_version, _description, statements} = migration()
      for {_label, sql} <- statements, do: {:ok, _} = Store.raw_query(sql, [])
    end

    defp graph_rows(ids) do
      {:ok, rows} =
        Store.raw_query(
          "SELECT id, tenant_id, workspace_id, source_id, target_id, relation, weight, valid_from FROM graph_edges WHERE id IN (#{Enum.join(ids, ", ")}) ORDER BY id",
          []
        )

      rows
    end

    test "copies the baseline edges with each workspace's tenant, and running again changes nothing",
         ctx do
      # Edge ids are kept, so the baseline rows take ids no graph edge has.
      {:ok, [[base]]} =
        Store.raw_query(
          "SELECT MAX(COALESCE((SELECT MAX(id) FROM graph_edges), 0), COALESCE((SELECT MAX(id) FROM edges), 0)) + 1000",
          []
        )

      ids = [base + 1, base + 2, base + 3, base + 4]
      legacy_edge!(base + 1, "MigA#{ctx.n}", "MigB#{ctx.n}", ctx.own)
      legacy_edge!(base + 2, "MigC#{ctx.n}", "MigD#{ctx.n}", ctx.other)
      legacy_edge!(base + 3, "MigE#{ctx.n}", "MigF#{ctx.n}", "unregistered-#{ctx.n}")
      # An unregistered id that names a tenant takes it.
      legacy_edge!(base + 4, "MigG#{ctx.n}", "MigH#{ctx.n}", "#{ctx.tenant}:loose-#{ctx.n}")

      migrate!()

      expected = [
        [
          base + 1,
          "default",
          ctx.own,
          "MigA#{ctx.n}",
          "MigB#{ctx.n}",
          "knows",
          0.5,
          "2026-01-01T00:00:00Z"
        ],
        [
          base + 2,
          ctx.tenant,
          ctx.other,
          "MigC#{ctx.n}",
          "MigD#{ctx.n}",
          "knows",
          0.5,
          "2026-01-01T00:00:00Z"
        ],
        [
          base + 3,
          "default",
          "unregistered-#{ctx.n}",
          "MigE#{ctx.n}",
          "MigF#{ctx.n}",
          "knows",
          0.5,
          "2026-01-01T00:00:00Z"
        ],
        [
          base + 4,
          ctx.tenant,
          "#{ctx.tenant}:loose-#{ctx.n}",
          "MigG#{ctx.n}",
          "MigH#{ctx.n}",
          "knows",
          0.5,
          "2026-01-01T00:00:00Z"
        ]
      ]

      assert graph_rows(ids) == expected
      assert {:ok, [_]} = Graph.edges_for("MigC#{ctx.n}", workspace_id: ctx.other)

      # The first edge written after the backfill takes an id above every kept one.
      :ok = Graph.assert_edge("MigNew#{ctx.n}", "MigNext#{ctx.n}", "knows", workspace_id: ctx.own)

      assert {:ok, [[new_id]]} =
               Store.raw_query("SELECT id FROM graph_edges WHERE source_id = ?1", [
                 "MigNew#{ctx.n}"
               ])

      assert new_id > base + 4

      migrate!()
      assert graph_rows(ids) == expected

      assert {:ok, [[3]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM graph_edges WHERE source_id IN (?1, ?2, ?3)",
                 ["MigA#{ctx.n}", "MigC#{ctx.n}", "MigE#{ctx.n}"]
               )

      # The baseline table is left as it was.
      assert {:ok, [[4]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM edges WHERE id IN (#{Enum.join(ids, ", ")})",
                 []
               )
    end

    test "gives legacy default-tenant contexts and entities their workspace's tenant", ctx do
      loose = "#{ctx.tenant}:loose-#{ctx.n}"
      bare = "bare-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: "else-#{ctx.n}", name: "Someone else"})

      # Rows written before writes took their workspace's tenant, and one row of
      # another tenant that the repair must leave.
      rows = [
        {"leg-own-#{ctx.n}", ctx.other, "default"},
        {"leg-loose-#{ctx.n}", loose, "default"},
        {"leg-bare-#{ctx.n}", bare, "default"},
        {"leg-foreign-#{ctx.n}", ctx.other, "else-#{ctx.n}"}
      ]

      for {id, workspace, tenant} <- rows do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at, modified_at) VALUES (?1, ?2, ?3, 'signal', ?1, 'legacy', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z')",
            [id, tenant, workspace]
          )

        {:ok, _} =
          Store.raw_query(
            "INSERT INTO entities (context_id, name, type, tenant_id, workspace_id) VALUES (?1, ?2, 'person', ?3, ?4)",
            [id, "Ent-" <> id, tenant, workspace]
          )
      end

      migrate!()
      migrate!()

      expected = [
        {"leg-own-#{ctx.n}", ctx.tenant},
        {"leg-loose-#{ctx.n}", ctx.tenant},
        {"leg-bare-#{ctx.n}", "default"},
        {"leg-foreign-#{ctx.n}", "else-#{ctx.n}"}
      ]

      for {id, tenant} <- expected do
        assert {:ok, [[^tenant]]} =
                 Store.raw_query("SELECT tenant_id FROM contexts WHERE id = ?1", [id])

        assert {:ok, [[^tenant]]} =
                 Store.raw_query("SELECT tenant_id FROM entities WHERE context_id = ?1", [id])
      end
    end

    test "is recorded in schema_migrations" do
      {version, _description, _statements} = migration()

      assert {:ok, [[^version]]} =
               Store.raw_query("SELECT version FROM schema_migrations WHERE version = ?1", [
                 version
               ])
    end
  end

  describe "a workspace id that is not registered" do
    test "a <tenant>:<slug> id gives its rows that tenant, and a bare id the default", ctx do
      loose = "#{ctx.tenant}:loose-#{ctx.n}"
      nobody = "nobody-#{ctx.n}:loose"

      context!("loose-#{ctx.n}", loose, ["Lia#{ctx.n}", "Lou#{ctx.n}"])
      context!("nobody-#{ctx.n}", nobody, ["Nia#{ctx.n}", "Nou#{ctx.n}"])

      assert {:ok, [[tenant]]} =
               Store.raw_query("SELECT tenant_id FROM contexts WHERE id = ?1", ["loose-#{ctx.n}"])

      assert tenant == ctx.tenant
      assert scopes("loose-#{ctx.n}") == [{ctx.tenant, loose}]
      assert Graph.scope(workspace_id: loose) == {ctx.tenant, loose}

      assert {:ok, [_]} =
               Graph.edges_for("Lia#{ctx.n}", workspace_id: loose, relation: "mentioned_in")

      # A prefix that names no tenant is not one.
      assert scopes("nobody-#{ctx.n}") == [{"default", nobody}]
      assert Graph.scope(workspace_id: nobody) == {"default", nobody}
    end

    test "two tenants keep the same entity edge under one bare id, each reading its own", ctx do
      bare = "shared-bare-#{ctx.n}"

      for tenant <- [ctx.tenant, "default"] do
        {:ok, _} =
          Store.raw_query(
            "INSERT OR IGNORE INTO graph_edges (tenant_id, workspace_id, source_id, target_id, relation) VALUES (?1, ?2, ?3, ?4, 'works_with')",
            [tenant, bare, "Ann#{ctx.n}", "Ben#{ctx.n}"]
          )
      end

      assert {:ok, [[2]]} =
               Store.raw_query("SELECT COUNT(*) FROM graph_edges WHERE workspace_id = ?1", [bare])

      for tenant <- [ctx.tenant, "default"] do
        assert {:ok, [%{target_id: target}]} =
                 Graph.edges_for("Ann#{ctx.n}", workspace_id: bare, tenant_id: tenant)

        assert target == "Ben#{ctx.n}"
      end
    end
  end

  describe "the graph backfill" do
    test "writes a context's structural, semantic and claim edges again", ctx do
      id = context!("fill-#{ctx.n}", ctx.other, ["Fay#{ctx.n}", "Gus#{ctx.n}"])

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash) VALUES (?1, ?2, ?3, ?1)",
          ["pkg-#{ctx.n}", ctx.tenant, ctx.other]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, ?5, 'Fay works with Gus.')",
          ["claim-#{ctx.n}", ctx.tenant, ctx.other, "pkg-#{ctx.n}", id]
        )

      # The edges an upgrade lost.
      {:ok, _} = Store.raw_query("DELETE FROM graph_edges WHERE workspace_id = ?1", [ctx.other])

      assert {:ok, %{contexts: 1, claims: 1, edges_before: 0, edges_after: after_count}} =
               Graph.backfill(workspace_id: ctx.other)

      assert after_count > 0

      {:ok, rows} =
        Store.raw_query(
          "SELECT DISTINCT relation, tenant_id FROM graph_edges WHERE workspace_id = ?1 ORDER BY relation",
          [ctx.other]
        )

      assert rows ==
               Enum.map(
                 ~w(about co_occurs co_occurs_with lives_in mentioned_in mentions),
                 &[&1, ctx.tenant]
               )

      assert {:ok, [_]} =
               Graph.edges_for("Fay#{ctx.n}", workspace_id: ctx.other, relation: "co_occurs_with")

      # A second run adds nothing.
      assert {:ok, %{edges_before: ^after_count, edges_after: ^after_count}} =
               Graph.backfill(workspace_id: ctx.other)
    end

    test "is no longer needed for a workspace once one has run for it or for every workspace",
         ctx do
      status = fn ws ->
        {:ok, status} = Graph.backfill_status(ws)
        status
      end

      assert status.(ctx.own) == %{backfill_needed: false, legacy_edges: 0}

      for ws <- [ctx.own, ctx.other] do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO edges (source_id, target_id, relation, workspace_id) VALUES (?1, ?2, 'knows', ?3)",
            ["Old#{ctx.n}", "Old2#{ctx.n}-#{ws}", ws]
          )
      end

      assert status.(ctx.own) == %{backfill_needed: true, legacy_edges: 1}
      # The release entry point a release build runs it with.
      assert :ok = OptimalEngine.Release.graph_backfill(workspace_id: ctx.own, claims: false)
      assert status.(ctx.own) == %{backfill_needed: false, legacy_edges: 1}
      assert status.(ctx.other).backfill_needed

      # A run over every workspace is recorded without a workspace.
      {:ok, _} = Store.raw_query("INSERT INTO graph_backfills (workspace_id) VALUES (NULL)", [])

      on_exit(fn ->
        Store.raw_query("DELETE FROM graph_backfills WHERE workspace_id IS NULL", [])
      end)

      refute status.(ctx.other).backfill_needed
    end
  end

  describe "bundles" do
    setup ctx do
      context!("bundle-#{ctx.n}", ctx.other, ["Bea#{ctx.n}", "Cy#{ctx.n}"])
      path = Path.join(System.tmp_dir!(), "edges-bundle-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    # One test database stands in for two Engines: the source gives the
    # workspace up first (text ids are unique per database), which also
    # removes the tenant's edges from it.
    defp move_out!(ctx) do
      assert {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.other, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.other, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.other, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      assert scopes("bundle-#{ctx.n}") == []
      manifest
    end

    defp imported_edges(ctx, summary) do
      Graph.edges_for("Bea#{ctx.n}",
        relation: "co_occurs",
        workspace_id: summary.workspace_id,
        tenant_id: summary.tenant_id
      )
    end

    test "a second tenant's bundle carries its edges into the importing tenant", ctx do
      manifest = move_out!(ctx)
      tables = Map.new(manifest["tables"], &{&1["name"], &1["rows"]})
      assert tables["graph_edges"] > 0
      refute Map.has_key?(tables, "edges")

      target = "edges-target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Target"})
      assert {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, [%{target_id: cy}]} = imported_edges(ctx, summary)
      assert cy == "Cy#{ctx.n}"
      assert scopes("bundle-#{ctx.n}") == [{target, summary.workspace_id}]
    end

    test "an older Engine's bundle imports its edges into graph_edges", ctx do
      move_out!(ctx)
      legacy!(ctx.path)

      target = "edges-legacy-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Legacy target"})
      assert {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)
      assert summary.rows["edges"] > 0

      assert {:ok, [%{target_id: cy}]} = imported_edges(ctx, summary)
      assert cy == "Cy#{ctx.n}"
      assert scopes("bundle-#{ctx.n}") == [{target, summary.workspace_id}]

      # A merge keeps the edges already there.
      assert {:ok, merged} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true, mode: :merge)

      assert merged.rows["edges"] == 0
    end

    # Rewrites a bundle as an Engine before migration 75 wrote it: the graph
    # edges travel as the `edges` table.
    defp legacy!(path) do
      staging = Path.join(System.tmp_dir!(), "edges-legacy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(staging)

      try do
        :ok =
          :erl_tar.extract(String.to_charlist(path), [
            :compressed,
            {:cwd, String.to_charlist(staging)}
          ])

        File.rename!(
          Path.join([staging, "tables", "graph_edges.jsonl"]),
          Path.join([staging, "tables", "edges.jsonl"])
        )

        manifest =
          Path.join(staging, "manifest.json")
          |> File.read!()
          |> Jason.decode!()
          |> Map.delete("bundle_sha256")
          |> Map.update!("tables", fn tables ->
            Enum.map(tables, fn
              %{"name" => "graph_edges"} = table -> %{table | "name" => "edges"}
              table -> table
            end)
          end)

        manifest =
          Map.put(manifest, "bundle_sha256", OptimalEngine.Authority.CanonicalJSON.hash(manifest))

        File.write!(Path.join(staging, "manifest.json"), Jason.encode!(manifest))

        entries =
          staging
          |> Path.join("**")
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(&{String.to_charlist(Path.relative_to(&1, staging)), String.to_charlist(&1)})

        :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
      after
        File.rm_rf(staging)
      end
    end
  end
end
