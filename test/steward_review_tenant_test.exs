defmodule OptimalEngine.StewardReviewTenantTest do
  @moduledoc """
  The routing review queue and the steward's repairs act inside the caller's
  tenant.

  Every tenant has its own intake workspace. Another tenant's records cannot
  be listed, accepted, rejected or moved, a target must be an active workspace
  of the caller's tenant and inside the key's scope, a record keeps one
  tenant on every row it owns, and the node type and hierarchy repairs touch
  the caller's rows only.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{CorpusOrganizer, DataSteward, HierarchyAudit, Organization}
  alias OptimalEngine.{Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @default_intake "default:knowledge-intake"

  setup do
    n = System.unique_integer([:positive])
    a = "rev-a-#{n}"
    b = "rev-b-#{n}"

    for tenant <- [a, b] do
      {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

      for slug <- ~w(ops ops-two knowledge-intake) do
        {:ok, _} =
          Workspace.create(%{
            tenant_id: tenant,
            organization_id: Organization.default_for(tenant),
            slug: slug,
            name: slug
          })
      end
    end

    {:ok, x} = Workspace.create(%{slug: "rev-x-#{n}", name: "Default X #{n}"})
    {:ok, y} = Workspace.create(%{slug: "rev-y-#{n}", name: "Default Y #{n}"})

    on_exit(fn ->
      for table <- ~w(claims source_packages chunks contexts) do
        Store.raw_query("DELETE FROM #{table} WHERE id LIKE ?1", ["rv#{n}-%"])
      end
    end)

    %{
      n: n,
      a: a,
      b: b,
      a_ws: "#{a}:ops",
      a_ws2: "#{a}:ops-two",
      a_intake: "#{a}:knowledge-intake",
      b_ws: "#{b}:ops",
      b_intake: "#{b}:knowledge-intake",
      x: x.id,
      y: y.id
    }
  end

  # -- helpers -----------------------------------------------------------------

  defp record(tenant, workspace, id, proposed \\ nil) do
    review = %{"routing_review" => %{"state" => "review", "proposed_workspace_id" => proposed}}

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts
          (id, tenant_id, workspace_id, uri, title, l0_abstract, content, created_at, modified_at, metadata)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'Body.', '2026-10-20T09:00:00Z', '2026-10-20T09:00:00Z', ?7)
        """,
        [
          id,
          tenant,
          workspace,
          "optimal://inbox/#{id}.md",
          "Title #{id}",
          "Abstract #{id}",
          Jason.encode!(review)
        ]
      )

    id
  end

  # A chunk, a source package, a claim, an entity and an edge the record owns.
  # The writers of entities and edges do not label their tenant, so those two
  # carry the unscoped default, as they do in a store.
  defp derived(tenant, workspace, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, workspace_id, signal_id, scale, text) VALUES (?1, ?2, ?3, ?4, 'document', 'x')",
        [id <> "-chunk", tenant, workspace, id]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash) VALUES (?1, ?2, ?3, ?1)",
        [id <> "-pkg", tenant, workspace]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, ?5, 'A claim.')",
        [id <> "-claim", tenant, workspace, id <> "-pkg", id]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO entities (context_id, name, type, workspace_id) VALUES (?1, 'Ada', 'person', ?2)",
        [id, workspace]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO edges (source_id, target_id, relation, weight, workspace_id) VALUES (?1, ?2, 'related', 1.0, ?3)",
        [id, id <> "-peer", workspace]
      )
  end

  defp derived_rows(id) do
    for {table, column, value} <- [
          {"chunks", "id", id <> "-chunk"},
          {"source_packages", "id", id <> "-pkg"},
          {"claims", "id", id <> "-claim"},
          {"entities", "context_id", id},
          {"edges", "source_id", id}
        ] do
      {:ok, rows} =
        Store.raw_query(
          "SELECT tenant_id, workspace_id FROM #{table} WHERE #{column} = ?1",
          [value]
        )

      {table, rows}
    end
  end

  defp holder(id) do
    {:ok, [[workspace, tenant]]} =
      Store.raw_query("SELECT workspace_id, tenant_id FROM contexts WHERE id = ?1", [id])

    {tenant, workspace}
  end

  defp review_state(id) do
    {:ok, [[state]]} =
      Store.raw_query(
        "SELECT json_extract(metadata, '$.routing_review.state') FROM contexts WHERE id = ?1",
        [id]
      )

    state
  end

  defp key(tenant, scopes, workspaces \\ ["*"]) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "reviewer",
        scopes: scopes,
        workspace_scope: workspaces
      })

    key
  end

  defp call(method, path, body, token) do
    request =
      if method == :get do
        conn(:get, path)
      else
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      end

    response =
      request
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    {response.status, Jason.decode!(response.resp_body)}
  end

  defp get(path, token), do: call(:get, path, nil, token)
  defp post(path, body, token), do: call(:post, path, body, token)

  # A tenant other than the default names one of its workspaces on every
  # request; the default tenant's implicit workspace is its own.
  defp queue(workspace), do: "/api/review/routing?workspace=#{workspace}&limit=500"

  defp ids(items), do: Enum.map(items, & &1["id"])

  defp with_text(id, text) do
    {:ok, _} =
      Store.raw_query("UPDATE contexts SET title = ?2, content = ?2 WHERE id = ?1", [id, text])

    id
  end

  # -- the queue ---------------------------------------------------------------

  describe "listing the routing queue" do
    test "shows the caller's own intake and no other tenant's", ctx do
      mine = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-listed", ctx.a_ws)
      theirs = record(ctx.b, ctx.b_intake, "rv#{ctx.n}-b-listed", ctx.b_ws)
      default = record("default", @default_intake, "rv#{ctx.n}-d-listed", ctx.x)

      assert {200, %{"items" => items}} = get(queue(ctx.a_ws), key(ctx.a, ["read"]))
      assert mine in ids(items)
      refute theirs in ids(items)
      refute default in ids(items)

      assert {200, %{"items" => items}} = get(queue("default"), key("default", ["read"]))
      assert default in ids(items)
      refute mine in ids(items)
    end

    test "the abstract of another tenant's record is never returned", ctx do
      record("default", @default_intake, "rv#{ctx.n}-d-abstract", ctx.x)

      assert {200, body} = get(queue(ctx.a_ws), key(ctx.a, ["read"]))
      refute Jason.encode!(body) =~ "Abstract rv#{ctx.n}-d-abstract"
    end

    test "the steward dashboard clusters the caller's intake only", ctx do
      mine = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-cluster", ctx.a_ws)
      default = record("default", @default_intake, "rv#{ctx.n}-d-cluster", ctx.x)

      assert {200, %{"route_clusters" => clusters}} =
               get("/api/data-steward/dashboard?workspace=#{ctx.a_ws}", key(ctx.a, ["read"]))

      listed = for cluster <- clusters, item <- cluster["items"], do: item["id"]
      assert mine in listed
      refute default in listed
    end

    test "the hierarchy audit reports the caller's tenant only", ctx do
      {:ok, _} =
        Store.raw_query("UPDATE workspaces SET organization_id = NULL WHERE id = ?1", [ctx.b_ws])

      assert {:ok, %{checks: checks}} = HierarchyAudit.run(ctx.b)
      assert flagged?(checks, ctx.b_ws)

      assert {:ok, %{checks: checks}} = HierarchyAudit.run(ctx.a)
      refute flagged?(checks, ctx.b_ws)

      assert {200, %{"hierarchy" => %{"checks" => checks}}} =
               get("/api/data-steward/dashboard?workspace=#{ctx.a_ws}", key(ctx.a, ["read"]))

      refute Enum.any?(checks, fn check ->
               Enum.any?(check["issues"], &(ctx.b_ws in [&1["id"], &1["related_id"]]))
             end)
    end
  end

  defp flagged?(checks, workspace_id) do
    Enum.any?(checks, fn check ->
      Enum.any?(check.issues, &(workspace_id in [&1[:id], &1[:related_id]]))
    end)
  end

  # -- decisions ---------------------------------------------------------------

  describe "deciding a record" do
    test "accepting files an own record into an own workspace, every row keeps one tenant",
         ctx do
      id = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-accept", ctx.a_ws)
      derived(ctx.a, ctx.a_intake, id)

      assert {200, _} =
               post(
                 "/api/review/routing/#{id}",
                 %{decision: "accept", workspace: ctx.a_ws},
                 key(ctx.a, ["topology:write"])
               )

      assert holder(id) == {ctx.a, ctx.a_ws}
      assert review_state(id) == "accepted"

      for {table, rows} <- derived_rows(id) do
        assert rows == [[ctx.a, ctx.a_ws]], table
      end
    end

    test "an accepted record is read from its new workspace, not from the cache", ctx do
      id = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-cache", ctx.a_ws)
      assert {:ok, %{workspace_id: workspace}} = Store.get_context(id)
      assert workspace == ctx.a_intake

      assert {200, _} =
               post(
                 "/api/review/routing/#{id}",
                 %{decision: "accept", workspace: ctx.a_ws},
                 key(ctx.a, ["topology:write"])
               )

      assert {:ok, %{workspace_id: workspace}} = Store.get_context(id)
      assert workspace == ctx.a_ws
    end

    test "an edge to another tenant's record stays where it is", ctx do
      id = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-edge", ctx.a_ws)
      foreign = record(ctx.b, ctx.b_intake, "rv#{ctx.n}-b-edge", ctx.b_ws)
      derived(ctx.a, ctx.a_intake, id)

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO edges (source_id, target_id, relation, weight, workspace_id) VALUES (?1, ?2, 'related', 1.0, ?3)",
          [id, foreign, ctx.a_intake]
        )

      assert {200, _} =
               post(
                 "/api/review/routing/#{id}",
                 %{decision: "accept", workspace: ctx.a_ws},
                 key(ctx.a, ["topology:write"])
               )

      {:ok, rows} =
        Store.raw_query("SELECT target_id, workspace_id FROM edges WHERE source_id = ?1", [id])

      assert Enum.sort(rows) == Enum.sort([[id <> "-peer", ctx.a_ws], [foreign, ctx.a_intake]])
    end

    test "rows another tenant wrote under the record are not moved with it", ctx do
      id = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-stray", ctx.a_ws)
      stray = "rv#{ctx.n}-stray-chunk"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO chunks (id, tenant_id, workspace_id, signal_id, scale, text) VALUES (?1, ?2, ?3, ?4, 'document', 'x')",
          [stray, ctx.b, ctx.b_ws, id]
        )

      assert {200, _} =
               post(
                 "/api/review/routing/#{id}",
                 %{decision: "accept", workspace: ctx.a_ws},
                 key(ctx.a, ["topology:write"])
               )

      assert {:ok, [[ctx.b, ctx.b_ws]]} ==
               Store.raw_query("SELECT tenant_id, workspace_id FROM chunks WHERE id = ?1", [stray])
    end

    test "another tenant's record cannot be accepted, moved or rejected", ctx do
      accepted = record("default", @default_intake, "rv#{ctx.n}-d-accept", ctx.x)
      rejected = record("default", @default_intake, "rv#{ctx.n}-d-reject", ctx.x)
      batch = record("default", @default_intake, "rv#{ctx.n}-d-batch", ctx.x)
      reviewer = key(ctx.a, ["topology:write"])

      assert {422, %{"error" => error}} =
               post(
                 "/api/review/routing/#{accepted}",
                 %{decision: "accept", workspace: ctx.a_ws},
                 reviewer
               )

      assert error =~ "not_found_or_not_in_intake"

      assert {422, _} =
               post(
                 "/api/review/routing/#{rejected}",
                 %{decision: "reject", workspace: ctx.a_ws},
                 reviewer
               )

      assert {200, %{"completed" => 0, "failed" => 2}} =
               post(
                 "/api/data-steward/routes/decide",
                 %{
                   decision: "accept",
                   workspace: ctx.a_ws,
                   items: [
                     %{id: batch, target_workspace_id: ctx.a_ws},
                     %{id: accepted, target_workspace_id: ctx.a_ws}
                   ]
                 },
                 reviewer
               )

      assert {200, %{"completed" => 0, "failed" => 1}} =
               post(
                 "/api/data-steward/routes/decide",
                 %{decision: "reject", workspace: ctx.a_ws, items: [%{id: rejected}]},
                 reviewer
               )

      for id <- [accepted, rejected, batch] do
        assert holder(id) == {"default", @default_intake}
        assert review_state(id) == "review"
      end
    end

    test "a record that is not in the tenant's intake is neither rejected nor filed", ctx do
      elsewhere = record(ctx.a, ctx.a_ws, "rv#{ctx.n}-a-elsewhere")
      reviewer = key(ctx.a, ["topology:write"])

      assert {422, _} =
               post(
                 "/api/review/routing/#{elsewhere}",
                 %{decision: "reject", workspace: ctx.a_ws},
                 reviewer
               )

      assert {422, _} =
               post(
                 "/api/review/routing/#{elsewhere}",
                 %{decision: "accept", workspace: ctx.a_ws2},
                 reviewer
               )

      assert holder(elsewhere) == {ctx.a, ctx.a_ws}
      assert review_state(elsewhere) == "review"
    end

    test "a record is not filed into another tenant's workspace", ctx do
      own = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-inject", ctx.a_ws)
      default = record("default", @default_intake, "rv#{ctx.n}-d-inject", ctx.x)

      assert {404, _} =
               post(
                 "/api/review/routing/#{own}",
                 %{decision: "accept", workspace: ctx.b_ws},
                 key(ctx.a, ["topology:write"])
               )

      # The target of a batch item is authorized like any workspace the
      # request names.
      assert {404, _} =
               post(
                 "/api/data-steward/routes/decide",
                 %{
                   decision: "accept",
                   workspace: ctx.a_ws,
                   items: [%{id: own, target_workspace_id: ctx.b_ws}]
                 },
                 key(ctx.a, ["topology:write"])
               )

      assert {404, _} =
               post(
                 "/api/data-steward/routes/decide",
                 %{decision: "accept", items: [%{id: default, target_workspace_id: ctx.b_ws}]},
                 key("default", ["topology:write"])
               )

      assert holder(own) == {ctx.a, ctx.a_intake}
      assert holder(default) == {"default", @default_intake}
    end

    test "a target must be an active workspace of the tenant", ctx do
      id = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-target", ctx.a_ws)
      reviewer = key(ctx.a, ["topology:write"])
      :ok = Workspace.archive(ctx.a_ws2)

      for target <- ["#{ctx.a}:nowhere", ctx.a_ws2] do
        assert {422, %{"error" => error}} =
                 post(
                   "/api/review/routing/#{id}",
                   %{decision: "accept", workspace: target},
                   reviewer
                 )

        assert error =~ "target_workspace_not_registered"

        assert {200, %{"completed" => 0, "results" => [%{"result" => %{"ok" => false}}]}} =
                 post(
                   "/api/data-steward/routes/decide",
                   %{
                     decision: "accept",
                     workspace: ctx.a_ws,
                     items: [%{id: id, target_workspace_id: target}]
                   },
                   reviewer
                 )
      end

      assert {200, %{"completed" => 0}} =
               post(
                 "/api/data-steward/routes/decide",
                 %{decision: "accept", workspace: ctx.a_ws, items: [%{id: id}]},
                 reviewer
               )

      assert holder(id) == {ctx.a, ctx.a_intake}
      assert review_state(id) == "review"
    end

    test "a key restricted to some workspaces needs the intake in its scope", ctx do
      id = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-intake-scope", ctx.a_ws)
      narrow = key(ctx.a, ["read", "topology:write"], [ctx.a_ws])

      assert {403, %{"error" => "workspace_scope_denied"}} = get(queue(ctx.a_ws), narrow)

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post(
                 "/api/review/routing/#{id}",
                 %{decision: "reject", workspace: ctx.a_ws},
                 narrow
               )

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post(
                 "/api/data-steward/routes/decide",
                 %{decision: "reject", workspace: ctx.a_ws, items: [%{id: id}]},
                 narrow
               )

      assert review_state(id) == "review"

      wide = key(ctx.a, ["read", "topology:write"], [ctx.a_ws, ctx.a_intake])
      assert {200, %{"items" => items}} = get(queue(ctx.a_ws), wide)
      assert id in ids(items)
    end

    test "a key restricted to some workspaces files only into those", ctx do
      id = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-scoped", ctx.a_ws)
      narrow = key(ctx.a, ["topology:write"], [ctx.a_ws, ctx.a_intake])

      body = fn target ->
        %{
          decision: "accept",
          workspace: ctx.a_ws,
          items: [%{id: id, target_workspace_id: target}]
        }
      end

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post("/api/data-steward/routes/decide", body.(ctx.a_ws2), narrow)

      assert holder(id) == {ctx.a, ctx.a_intake}

      assert {200, %{"completed" => 1}} =
               post("/api/data-steward/routes/decide", body.(ctx.a_ws), narrow)

      assert holder(id) == {ctx.a, ctx.a_ws}
    end

    test "the default tenant files its own records inside the default tenant", ctx do
      id = record("default", @default_intake, "rv#{ctx.n}-d-own", ctx.x)

      assert {200, %{"completed" => 1}} =
               post(
                 "/api/data-steward/routes/decide",
                 %{decision: "accept", items: [%{id: id, target_workspace_id: ctx.y}]},
                 key("default", ["topology:write"])
               )

      assert holder(id) == {"default", ctx.y}
    end

    test "malformed items fail one by one", ctx do
      id = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-items", ctx.a_ws)

      assert {200, %{"requested" => 3, "completed" => 1, "failed" => 2}} =
               post(
                 "/api/data-steward/routes/decide",
                 %{
                   decision: "accept",
                   workspace: ctx.a_ws,
                   items: [
                     "not an item",
                     %{target_workspace_id: ctx.a_ws},
                     %{id: id, target_workspace_id: ctx.a_ws}
                   ]
                 },
                 key(ctx.a, ["topology:write"])
               )
    end
  end

  # -- the organizer -------------------------------------------------------------

  describe "the intake workspace" do
    test "is one per tenant, named after the tenant", ctx do
      assert CorpusOrganizer.source_workspace("default") == @default_intake
      assert CorpusOrganizer.source_workspace(ctx.a) == ctx.a_intake
      assert CorpusOrganizer.source_workspace(ctx.b) == ctx.b_intake
    end

    test "a configured intake belongs to the tenant that owns it", ctx do
      original = Application.get_env(:optimal_engine, :corpus_source_workspace)
      Application.put_env(:optimal_engine, :corpus_source_workspace, ctx.a_ws)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:optimal_engine, :corpus_source_workspace),
          else: Application.put_env(:optimal_engine, :corpus_source_workspace, original)
      end)

      assert CorpusOrganizer.source_workspace(ctx.a) == ctx.a_ws
      assert CorpusOrganizer.source_workspace(ctx.b) == ctx.b_intake
      assert CorpusOrganizer.source_workspace() == ctx.a_ws
    end

    test "an intake that is not registered belongs to the default tenant", ctx do
      original = Application.get_env(:optimal_engine, :corpus_source_workspace)
      Application.put_env(:optimal_engine, :corpus_source_workspace, "legacy-#{ctx.n}:inbox")

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:optimal_engine, :corpus_source_workspace),
          else: Application.put_env(:optimal_engine, :corpus_source_workspace, original)
      end)

      assert CorpusOrganizer.source_workspace("default") == "legacy-#{ctx.n}:inbox"
      assert CorpusOrganizer.source_workspace(ctx.a) == ctx.a_intake
    end

    test "the slug of the intake is configuration", ctx do
      Application.put_env(:optimal_engine, :corpus_intake_slug, "front-door")
      on_exit(fn -> Application.delete_env(:optimal_engine, :corpus_intake_slug) end)

      assert CorpusOrganizer.source_workspace(ctx.a) == "#{ctx.a}:front-door"
      assert CorpusOrganizer.source_workspace("default") == "default:front-door"
    end

    test "move_context moves a record of the tenant only", ctx do
      own = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-move", ctx.a_ws)
      default = record("default", @default_intake, "rv#{ctx.n}-d-move", ctx.x)

      assert {:error, :not_found_or_not_in_intake} =
               CorpusOrganizer.move_context(default, ctx.a_ws, tenant_id: ctx.a)

      assert {:error, :not_found_or_not_in_intake} =
               CorpusOrganizer.move_context(own, ctx.a_ws, tenant_id: ctx.b)

      assert {:error, :target_workspace_not_registered} =
               CorpusOrganizer.move_context(own, ctx.b_ws, tenant_id: ctx.a)

      assert {:ok, %{workspace_id: workspace}} =
               CorpusOrganizer.move_context(own, ctx.a_ws, tenant_id: ctx.a)

      assert workspace == ctx.a_ws
      assert holder(default) == {"default", @default_intake}
    end

    test "the deployment's routing rules place a tenant's records in its own workspaces only",
         ctx do
      original = Application.get_env(:optimal_engine, :corpus_routing_rules)

      Application.put_env(:optimal_engine, :corpus_routing_rules, %{
        ctx.x => [{"zebra marker", 10}],
        ctx.a_ws => [{"aardvark marker", 10}]
      })

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:optimal_engine, :corpus_routing_rules),
          else: Application.put_env(:optimal_engine, :corpus_routing_rules, original)
      end)

      zebra = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-zebra") |> with_text("zebra marker")

      aardvark =
        record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-aardvark") |> with_text("aardvark marker")

      assert {:ok, preview} = CorpusOrganizer.preview(tenant_id: ctx.a)
      assert [%{id: ^aardvark, workspace_id: workspace}] = preview.high_confidence
      assert workspace == ctx.a_ws
      assert zebra in Enum.map(preview.unresolved, & &1.id)
      refute Jason.encode!(preview) =~ ctx.x

      assert {:ok, %{moved: 1}} =
               CorpusOrganizer.apply_high_confidence(preview: preview, tenant_id: ctx.a)

      assert holder(aardvark) == {ctx.a, ctx.a_ws}
      assert holder(zebra) == {ctx.a, ctx.a_intake}
    end

    test "the exact-duplicate sweep stays inside the tenant", ctx do
      a_ids = for i <- 1..2, do: record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-dup#{i}")
      b_ids = for i <- 1..2, do: record(ctx.b, ctx.b_intake, "rv#{ctx.n}-b-dup#{i}")

      assert_raise ArgumentError, fn -> CorpusOrganizer.deduplicate_exact([]) end

      assert {:ok, %{archived_exact_duplicates: 1}} =
               CorpusOrganizer.deduplicate_exact(tenant_id: ctx.a)

      archived = fn ids ->
        {:ok, [[count]]} =
          Store.raw_query(
            "SELECT COUNT(*) FROM contexts WHERE id IN (?1, ?2) AND archived_at IS NOT NULL",
            ids
          )

        count
      end

      assert archived.(a_ids) == 1
      assert archived.(b_ids) == 0
    end

    test "the maintenance organizer needs a key that holds the whole tenant", ctx do
      narrow = key(ctx.a, ["admin"], [ctx.a_ws, ctx.a_intake])

      assert {403, %{"error" => "workspace_scope_denied"}} =
               get("/api/maintenance/corpus-organization", narrow)

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post("/api/maintenance/corpus-organization", %{deduplicate_exact: true}, narrow)
    end

    test "the maintenance organizer previews and queues the caller's intake only", ctx do
      mine = record(ctx.a, ctx.a_intake, "rv#{ctx.n}-a-organize")
      default = record("default", @default_intake, "rv#{ctx.n}-d-organize")
      sql = "UPDATE contexts SET metadata = '{}' WHERE id IN (?1, ?2)"
      {:ok, _} = Store.raw_query(sql, [mine, default])
      admin = key(ctx.a, ["*"])

      assert {200, preview} = get("/api/maintenance/corpus-organization", admin)
      listed = Jason.encode!(preview)
      assert listed =~ mine
      refute listed =~ default

      assert {200, _} =
               post("/api/maintenance/corpus-organization", %{queue_remaining: true}, admin)

      assert review_state(mine) == "unresolved"
      assert review_state(default) == nil
    end
  end

  # -- repair_node_types ---------------------------------------------------------

  defp node_type(tenant, workspace, slug) do
    {:ok, _} =
      Store.raw_query(
        "INSERT OR IGNORE INTO node_types (id, tenant_id, workspace_id, slug, name) VALUES (?1, ?2, ?3, ?4, ?4)",
        ["#{workspace}:#{slug}", tenant, workspace, slug]
      )
  end

  defp node(tenant, workspace, slug, kind) do
    id = "#{workspace}:node:#{slug}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO nodes (id, tenant_id, workspace_id, slug, name, kind) VALUES (?1, ?2, ?3, ?4, ?4, ?5)",
        [id, tenant, workspace, slug, kind]
      )

    id
  end

  defp node_row(id) do
    {:ok, [[kind, type]]} =
      Store.raw_query("SELECT kind, node_type_id FROM nodes WHERE id = ?1", [id])

    {kind, type}
  end

  describe "repair_node_types" do
    setup ctx do
      for {tenant, workspace} <- [{ctx.a, ctx.a_ws}, {ctx.b, ctx.b_ws}, {"default", ctx.x}] do
        node_type(tenant, workspace, "entity")
      end

      %{
        a_node: node(ctx.a, ctx.a_ws, "legacy", "org"),
        b_node: node(ctx.b, ctx.b_ws, "legacy", "org"),
        d_node: node("default", ctx.x, "legacy", "org")
      }
    end

    test "retypes the caller's nodes and leaves every other tenant's as they were", ctx do
      assert {:ok, updated} =
               DataSteward.repair_node_types(tenant_id: ctx.a, actor_id: "user:steward")

      assert node_row(ctx.a_node) == {"org", "#{ctx.a_ws}:entity"}
      assert node_row(ctx.b_node) == {"org", nil}
      assert node_row(ctx.d_node) == {"org", nil}
      assert updated == 1
    end

    test "over HTTP, for a key that holds the whole tenant", ctx do
      assert {200, %{"updated_nodes" => updated}} =
               post(
                 "/api/data-steward/nodes/repair-types",
                 %{workspace: ctx.b_ws},
                 key(ctx.b, ["topology:write"])
               )

      assert node_row(ctx.b_node) == {"org", "#{ctx.b_ws}:entity"}
      assert node_row(ctx.a_node) == {"org", nil}
      assert node_row(ctx.d_node) == {"org", nil}
      assert updated == 1
    end

    test "a key restricted to some workspaces cannot run a tenant-wide repair", ctx do
      narrow = key(ctx.a, ["topology:write"], [ctx.a_ws])

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post("/api/data-steward/nodes/repair-types", %{workspace: ctx.a_ws}, narrow)

      assert node_row(ctx.a_node) == {"org", nil}
    end
  end

  # -- repair_deterministic_hierarchy --------------------------------------------

  defp organization(workspace_id) do
    {:ok, [[organization]]} =
      Store.raw_query("SELECT organization_id FROM workspaces WHERE id = ?1", [workspace_id])

    organization
  end

  describe "repair_deterministic_hierarchy" do
    setup ctx do
      {:ok, ventures} =
        Organization.create(%{
          id: "#{ctx.a}:ventures",
          tenant_id: ctx.a,
          slug: "ventures",
          name: "Ventures"
        })

      {:ok, foreign} =
        Organization.create(%{
          id: "#{ctx.b}:ventures",
          tenant_id: ctx.b,
          slug: "ventures",
          name: "Ventures"
        })

      suite = fn tenant ->
        {:ok, workspace} =
          Workspace.create(%{
            tenant_id: tenant,
            organization_id: Organization.default_for(tenant),
            slug: "suite-#{ctx.n}",
            name: "Alpha Suite #{ctx.n}"
          })

        workspace.id
      end

      %{
        ventures: ventures.id,
        foreign_org: foreign.id,
        a_suite: suite.(ctx.a),
        b_suite: suite.(ctx.b),
        mapping: %{
          "organizations" => [
            %{"organization_id" => ventures.id, "name_contains" => "alpha suite"}
          ]
        }
      }
    end

    defp repair(ctx, mapping) do
      DataSteward.repair_deterministic_hierarchy(
        tenant_id: ctx.a,
        actor_id: "user:steward",
        mapping: mapping
      )
    end

    test "moves the caller's matching workspaces to the organization the caller names", ctx do
      assert {:ok, %{workspace_owners_updated: 1, nodes_retyped: 0}} = repair(ctx, ctx.mapping)

      assert organization(ctx.a_suite) == ctx.ventures
      assert organization(ctx.b_suite) == Organization.default_for(ctx.b)
      assert organization(ctx.a_ws) == Organization.default_for(ctx.a)
    end

    test "only workspaces in the organization named as the source move", ctx do
      other = "#{ctx.a}:other"
      {:ok, _} = Organization.create(%{id: other, tenant_id: ctx.a, slug: "other", name: "Other"})

      {:ok, _} =
        Store.raw_query("UPDATE workspaces SET organization_id = ?1 WHERE id = ?2", [
          other,
          ctx.a_suite
        ])

      assert {:ok, %{workspace_owners_updated: 0}} = repair(ctx, ctx.mapping)

      rule = ctx.mapping["organizations"] |> hd() |> Map.put("from_organization_id", other)
      assert {:ok, %{workspace_owners_updated: 1}} = repair(ctx, %{"organizations" => [rule]})
      assert organization(ctx.a_suite) == ctx.ventures
    end

    test "an organization of another tenant is not an owner the caller can name", ctx do
      rule = %{"organization_id" => ctx.foreign_org, "name_contains" => "alpha suite"}

      assert {:error, :organization_not_found} = repair(ctx, %{"organizations" => [rule]})
      assert organization(ctx.a_suite) == Organization.default_for(ctx.a)
      assert organization(ctx.b_suite) == Organization.default_for(ctx.b)
    end

    test "a rule that matches on nothing is refused rather than matching everything", ctx do
      rule = %{"organization_id" => ctx.ventures}

      assert {:error, {:invalid_mapping, _}} = repair(ctx, %{"organizations" => [rule]})
      assert organization(ctx.a_ws) == Organization.default_for(ctx.a)
    end

    test "a match text is literal, not a pattern", ctx do
      for text <- ["%", "_", "\\", "alpha%suite", "alpha_suite"] do
        rule = %{"organization_id" => ctx.ventures, "name_contains" => text}

        assert {:ok, %{workspace_owners_updated: 0}} = repair(ctx, %{"organizations" => [rule]}),
               text
      end

      assert organization(ctx.a_suite) == Organization.default_for(ctx.a)
    end

    test "a match text ignores the case of ASCII letters, and may match the description", ctx do
      {:ok, _} =
        Store.raw_query("UPDATE workspaces SET description = 'The Gamma line' WHERE id = ?1", [
          ctx.a_ws
        ])

      rules = [
        %{"organization_id" => ctx.ventures, "name_contains" => "ALPHA SUITE"},
        %{"organization_id" => ctx.ventures, "description_contains" => "gamma LINE"}
      ]

      assert {:ok, %{workspace_owners_updated: 2}} = repair(ctx, %{"organizations" => rules})
      assert organization(ctx.a_suite) == ctx.ventures
      assert organization(ctx.a_ws) == ctx.ventures
    end

    test "a mapping is bounded", ctx do
      rules = for i <- 1..51, do: %{"organization_id" => ctx.ventures, "name_contains" => "n#{i}"}

      assert {:error, {:invalid_mapping, _}} = repair(ctx, %{"organizations" => rules})
    end

    test "no mapping, no repair", ctx do
      for mapping <- [nil, %{}, %{"organizations" => [], "node_kinds" => []}] do
        assert {:error, :mapping_required} = repair(ctx, mapping)
      end

      assert {:error, :mapping_required} =
               DataSteward.repair_deterministic_hierarchy(
                 tenant_id: ctx.a,
                 actor_id: "user:steward"
               )
    end

    test "retypes the nodes the caller names in a workspace of the caller's tenant", ctx do
      for slug <- ~w(operation project), do: node_type(ctx.a, ctx.a_ws, slug)
      node_type(ctx.b, ctx.b_ws, "operation")
      tasks = node(ctx.a, ctx.a_ws, "tasks", "workspace")
      projects = node(ctx.a, ctx.a_ws, "projects", "workspace")
      other = node(ctx.a, ctx.a_ws, "notes", "workspace")
      untyped = node(ctx.a, ctx.a_ws, "stuff", "workspace")
      foreign = node(ctx.b, ctx.b_ws, "tasks", "workspace")

      mapping = %{
        "node_kinds" => [
          %{
            "workspace_id" => ctx.a_ws,
            "kinds" => %{"tasks" => "operation", "projects" => "project", "stuff" => "ghost"}
          }
        ]
      }

      assert {:ok, %{nodes_retyped: 2, workspace_owners_updated: 0}} = repair(ctx, mapping)

      assert node_row(tasks) == {"operation", "#{ctx.a_ws}:operation"}
      assert node_row(projects) == {"project", "#{ctx.a_ws}:project"}
      assert node_row(other) == {"workspace", nil}
      # A kind the workspace has no active node type for leaves the node as it was.
      assert node_row(untyped) == {"workspace", nil}
      assert node_row(foreign) == {"workspace", nil}
    end

    test "a node of another kind is not retyped", ctx do
      node_type(ctx.a, ctx.a_ws, "operation")
      tasks = node(ctx.a, ctx.a_ws, "tasks", "team")

      mapping = %{
        "node_kinds" => [%{"workspace_id" => ctx.a_ws, "kinds" => %{"tasks" => "operation"}}]
      }

      assert {:ok, %{nodes_retyped: 0}} = repair(ctx, mapping)
      assert node_row(tasks) == {"team", nil}
    end

    test "a workspace of another tenant, or an archived one, cannot be named", ctx do
      :ok = Workspace.archive(ctx.a_ws2)

      for workspace <- [ctx.b_ws, ctx.a_ws2] do
        mapping = %{
          "node_kinds" => [%{"workspace_id" => workspace, "kinds" => %{"tasks" => "operation"}}]
        }

        assert {:error, :workspace_not_found} = repair(ctx, mapping)
      end
    end

    test "over HTTP, the mapping comes with the request and the key holds the whole tenant",
         ctx do
      steward = key(ctx.a, ["topology:write"])
      path = "/api/data-steward/hierarchy/repair-deterministic"

      assert {200, %{"workspace_owners_updated" => 1}} =
               post(path, %{workspace: ctx.a_ws, mapping: ctx.mapping}, steward)

      assert organization(ctx.a_suite) == ctx.ventures
      assert organization(ctx.b_suite) == Organization.default_for(ctx.b)

      assert {422, %{"error" => error}} = post(path, %{workspace: ctx.a_ws}, steward)
      assert error =~ "mapping_required"

      narrow = key(ctx.a, ["topology:write"], [ctx.a_ws])

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post(path, %{workspace: ctx.a_ws, mapping: ctx.mapping}, narrow)
    end
  end
end
