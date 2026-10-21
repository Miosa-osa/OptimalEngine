defmodule OptimalEngine.Store.BareWorkspaceTenantTest do
  @moduledoc """
  A write under a bare, unregistered workspace id never lands in another
  tenant's rows.

  Two tenants can share a bare workspace id, so the workspace row cannot say
  whose a write is. A context carries the tenant it is written for: the
  writer stores the row under that tenant, and under no other. A write that
  does not name a tenant keeps the old rule (the registered workspace's
  tenant, else the tenant of the row it replaces, else `default`). A named
  tenant that does not own the registered workspace is refused, and so is a
  write that would replace a row another tenant holds.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Connectors.{PullScheduler, Transform}
  alias OptimalEngine.{ChatSession, Context, Graph, Organization, Store, Workspace}
  alias OptimalEngine.Pipeline.{Indexer, Intake}
  alias OptimalEngine.Store.Vectors
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    a = "bare-a-#{n}"
    b = "bare-b-#{n}"

    for tenant <- [a, b], do: {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

    %{n: n, a: a, b: b, ws: "shared-bare-#{n}"}
  end

  # `struct/2` drops a key the struct does not define, so the same fixture
  # runs against a Context with or without a tenant field.
  defp context(id, workspace, fields \\ []) do
    struct(
      Context,
      Keyword.merge(
        [
          id: id,
          uri: "optimal://#{workspace}/#{id}",
          type: :resource,
          title: "Title #{id}",
          content: "Body of #{id}.",
          node: "notes",
          entities: ["Acme Corp", "Bolt Inc"],
          workspace_id: workspace
        ],
        fields
      )
    )
  end

  defp row(id) do
    {:ok, rows} =
      Store.raw_query("SELECT tenant_id, workspace_id, content FROM contexts WHERE id = ?1", [id])

    case rows do
      [[tenant, workspace, content]] -> %{tenant: tenant, workspace: workspace, content: content}
      [] -> nil
    end
  end

  defp tenant_of(id), do: (row(id) || %{}) |> Map.get(:tenant)

  # A chunk and a claim that name the context as their signal.
  defp children!(signal_id, workspace, tenant \\ "default") do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, workspace_id) VALUES (?1, ?2, ?3, 'document', 'Body', ?4)",
        ["chunk-#{signal_id}", tenant, signal_id, workspace]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash) VALUES (?1, ?2, ?3, ?4)",
        ["package-#{signal_id}", tenant, workspace, "hash-#{signal_id}"]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, ?5, 'A claim')",
        ["claim-#{signal_id}", tenant, workspace, "package-#{signal_id}", signal_id]
      )
  end

  defp vector_tenants(context_id) do
    {:ok, rows} =
      Store.raw_query("SELECT DISTINCT tenant_id FROM vectors WHERE context_id = ?1", [context_id])

    rows |> List.flatten() |> Enum.sort()
  end

  defp child_tenants(table, signal_id) do
    {:ok, rows} =
      Store.raw_query("SELECT DISTINCT tenant_id FROM #{table} WHERE signal_id = ?1", [signal_id])

    rows |> List.flatten() |> Enum.sort()
  end

  defp entity_tenants(id) do
    {:ok, rows} = Store.raw_query("SELECT tenant_id FROM entities WHERE context_id = ?1", [id])
    rows |> List.flatten() |> Enum.uniq()
  end

  defp edge_tenants(workspace, where, params) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT DISTINCT tenant_id FROM graph_edges WHERE workspace_id = ?1 AND (#{where}) ORDER BY 1",
        [workspace | params]
      )

    List.flatten(rows)
  end

  defp register(tenant, slug) do
    {:ok, workspace} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: Organization.default_for(tenant),
        slug: slug,
        name: String.capitalize(slug)
      })

    workspace.id
  end

  describe "Store.insert_context/1 under a bare workspace id" do
    test "a named tenant owns the row it writes", %{a: a, ws: ws, n: n} do
      id = "bare-own-#{n}"
      assert :ok = Store.insert_context(context(id, ws, tenant_id: a))

      assert tenant_of(id) == a
      assert row(id).workspace == ws
      assert entity_tenants(id) == [a]
      assert edge_tenants(ws, "source_id = ?2 OR target_id = ?2", [id]) == [a]
    end

    test "two tenants share the bare id and each keeps its own row", %{a: a, b: b, ws: ws, n: n} do
      assert :ok = Store.insert_context(context("bare-a-#{n}", ws, tenant_id: a))
      assert :ok = Store.insert_context(context("bare-b-#{n}", ws, tenant_id: b))

      assert tenant_of("bare-a-#{n}") == a
      assert tenant_of("bare-b-#{n}") == b

      # The entity pair is the same in both, and each tenant has its own edge.
      assert edge_tenants(ws, "relation = 'co_occurs' AND source_id = 'Acme Corp'", []) ==
               Enum.sort([a, b])
    end

    test "a write that names no tenant stays in the default tenant", %{ws: ws, n: n} do
      id = "bare-unnamed-#{n}"
      assert :ok = Store.insert_context(context(id, ws))

      assert tenant_of(id) == "default"
    end

    test "a rewrite that names no tenant keeps the tenant of the row", %{a: a, ws: ws, n: n} do
      id = "bare-keep-#{n}"
      assert :ok = Store.insert_context(context(id, ws, tenant_id: a))
      assert :ok = Store.insert_context(context(id, ws, content: "Edited body."))

      assert %{tenant: ^a, content: "Edited body."} = row(id)
    end

    test "a write to a registered workspace that names no tenant is the owner's", %{a: a, n: n} do
      workspace = register(a, "owned")
      id = "bare-owned-#{n}"
      assert :ok = Store.insert_context(context(id, workspace))

      assert tenant_of(id) == a
    end

    test "the default tenant writes into a registered workspace as its owner", %{a: a, n: n} do
      workspace = register(a, "operator")
      id = "bare-operator-#{n}"
      assert :ok = Store.insert_context(context(id, workspace, tenant_id: "default"))

      assert tenant_of(id) == a
    end

    test "a tenant that does not own the registered workspace is refused", %{a: a, b: b, n: n} do
      workspace = register(a, "foreign")
      id = "bare-foreign-#{n}"

      assert {:error, {:workspace_tenant_mismatch, ^workspace, ^b, ^a}} =
               Store.insert_context(context(id, workspace, tenant_id: b))

      assert row(id) == nil
    end

    test "a row another tenant holds is not replaced", %{a: a, b: b, ws: ws, n: n} do
      id = "bare-held-#{n}"
      assert :ok = Store.insert_context(context(id, ws, tenant_id: a, content: "Tenant a."))

      assert {:error, {:context_id_in_use, ^id}} =
               Store.insert_context(context(id, ws, tenant_id: b, content: "Tenant b."))

      assert %{tenant: ^a, content: "Tenant a."} = row(id)

      # The default tenant's write does not replace it either.
      assert {:error, {:context_id_in_use, ^id}} =
               Store.insert_context(context(id, ws, tenant_id: "default", content: "Default."))

      assert %{tenant: ^a, content: "Tenant a."} = row(id)
    end

    test "the owner of a workspace registered later takes over its rows", %{a: a, ws: ws, n: n} do
      # Rows written under a bare id before the workspace was registered are
      # relabelled by the rewrite that follows registration: the registry is
      # the authority for the workspace.
      id = "bare-later-#{n}"
      assert :ok = Store.insert_context(context(id, ws))
      assert tenant_of(id) == "default"

      # A workspace row written when any id was accepted: `Workspace.create/1`
      # takes only the ids of the tenant's namespace now.
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, organization_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?4, 'Late', 'active', '{}')",
          [ws, a, Organization.default_for(a), "late-#{n}"]
        )

      assert :ok = Store.insert_context(context(id, ws))
      assert tenant_of(id) == a
    end

    test "the takeover relabels the chunks and claims of the context too", %{a: a, ws: ws, n: n} do
      id = "bare-later-kids-#{n}"
      other = "bare-later-other-#{n}"
      assert :ok = Store.insert_context(context(id, ws))
      assert :ok = Store.insert_context(context(other, ws))
      for signal <- [id, other], do: children!(signal, ws)

      for signal <- [id, other],
          do: assert(:ok = Vectors.store(signal, [0.1, 0.2], workspace_id: ws))

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, organization_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?4, 'Late', 'active', '{}')",
          [ws, a, Organization.default_for(a), "late-kids-#{n}"]
        )

      assert :ok = Store.insert_context(context(id, ws))

      assert tenant_of(id) == a
      assert child_tenants("chunks", id) == [a]
      assert child_tenants("claims", id) == [a]
      assert vector_tenants(id) == [a]

      # A context the owner has not rewritten keeps its own.
      assert tenant_of(other) == "default"
      assert child_tenants("chunks", other) == ["default"]
      assert child_tenants("claims", other) == ["default"]
      assert vector_tenants(other) == ["default"]
    end

    test "a rewrite that keeps the tenant leaves the children of the context alone", ctx do
      %{a: a, ws: ws, n: n} = ctx
      id = "bare-same-kids-#{n}"
      assert :ok = Store.insert_context(context(id, ws, tenant_id: a))
      children!(id, ws, a)

      assert :ok = Store.insert_context(context(id, ws, tenant_id: a, content: "Again."))

      assert child_tenants("chunks", id) == [a]
      assert child_tenants("claims", id) == [a]
    end

    test "a workspace id that a tenant's prefix names is that tenant's", %{a: a, b: b, n: n} do
      # Nobody registered it, but `<tenant>:` says whose it is.
      workspace = "#{a}:unregistered-#{n}"
      assert :ok = Store.insert_context(context("prefix-unnamed-#{n}", workspace))
      assert tenant_of("prefix-unnamed-#{n}") == a

      assert :ok = Store.insert_context(context("prefix-own-#{n}", workspace, tenant_id: a))
      assert tenant_of("prefix-own-#{n}") == a

      assert {:error, {:workspace_tenant_mismatch, ^workspace, ^b, ^a}} =
               Store.insert_context(context("prefix-foreign-#{n}", workspace, tenant_id: b))

      assert row("prefix-foreign-#{n}") == nil
    end
  end

  describe "Store.insert_contexts/1" do
    test "labels each context with its own tenant", %{a: a, b: b, ws: ws, n: n} do
      assert {:ok, 2} =
               Store.insert_contexts([
                 context("batch-a-#{n}", ws, tenant_id: a),
                 context("batch-b-#{n}", ws, tenant_id: b)
               ])

      assert tenant_of("batch-a-#{n}") == a
      assert tenant_of("batch-b-#{n}") == b
    end

    test "a batch that would replace another tenant's row writes nothing", ctx do
      %{a: a, b: b, ws: ws, n: n} = ctx
      held = "batch-held-#{n}"
      assert :ok = Store.insert_context(context(held, ws, tenant_id: a, content: "Tenant a."))

      assert {:error, {:context_id_in_use, ^held}} =
               Store.insert_contexts([
                 context("batch-fresh-#{n}", ws, tenant_id: b),
                 context(held, ws, tenant_id: b, content: "Tenant b.")
               ])

      assert row("batch-fresh-#{n}") == nil
      assert %{tenant: ^a, content: "Tenant a."} = row(held)

      # The cache holds nothing of the batch that did not commit.
      assert {:error, :not_found} = Store.get_context("batch-fresh-#{n}")
    end
  end

  describe "ContextTenant.resolve/1" do
    alias OptimalEngine.Store.ContextTenant

    defp decide(fields) do
      ContextTenant.resolve(
        Map.merge(
          %{id: "c", workspace_id: "w", stated: nil, owner: nil, existing: nil},
          Map.new(fields)
        )
      )
    end

    test "decides the tenant from what is named, registered and held" do
      assert {:ok, "default"} = decide([])
      assert {:ok, "t1"} = decide(stated: "t1")
      assert {:ok, "t1"} = decide(owner: "t1")
      assert {:ok, "t1"} = decide(stated: "t1", owner: "t1")
      assert {:ok, "t1"} = decide(stated: "default", owner: "t1")
      assert {:ok, "t1"} = decide(existing: {"t1", "w"})
      assert {:ok, "t2"} = decide(stated: "t2", existing: {"t2", "w"})
      assert {:ok, "default"} = decide(stated: "", existing: {"default", "w"})
    end

    test "refuses a tenant that does not own the workspace" do
      assert {:error, {:workspace_tenant_mismatch, "w", "t2", "t1"}} =
               decide(stated: "t2", owner: "t1")
    end

    test "refuses to replace a row of another tenant under a bare workspace id" do
      assert {:error, {:context_id_in_use, "c"}} = decide(stated: "t2", existing: {"t1", "w"})
      assert {:error, {:context_id_in_use, "c"}} = decide(stated: "default", existing: {"t1", "w"})
      assert {:error, {:context_id_in_use, "c"}} = decide(stated: "t2", existing: {"default", "w"})
    end

    test "a workspace with an owner keeps its ids apart by itself" do
      assert {:ok, "t1"} = decide(owner: "t1", existing: {"default", "w"})
      assert {:ok, "t1"} = decide(owner: "t1", existing: {"t2", "other"})
      assert {:ok, "t1"} = decide(stated: "t1", owner: "t1", existing: {"t2", "w"})
    end
  end

  describe "the graph edges of a context" do
    setup %{a: a, b: b, ws: ws, n: n} do
      ids = {"edges-a-#{n}", "edges-b-#{n}"}
      assert :ok = Store.insert_context(context(elem(ids, 0), ws, tenant_id: a))
      assert :ok = Store.insert_context(context(elem(ids, 1), ws, tenant_id: b))

      # Edges are derived data: drop them, and write them again.
      {:ok, _} = Store.raw_query("DELETE FROM graph_edges WHERE workspace_id = ?1", [ws])
      %{ids: ids}
    end

    defp assert_edges_follow_contexts(ws, {id_a, id_b}, a, b) do
      assert edge_tenants(ws, "source_id = ?2 OR target_id = ?2", [id_a]) == [a]
      assert edge_tenants(ws, "source_id = ?2 OR target_id = ?2", [id_b]) == [b]

      assert edge_tenants(ws, "relation = 'co_occurs' AND source_id = 'Acme Corp'", []) ==
               Enum.sort([a, b])
    end

    test "rebuild writes each context's edges for that context's tenant", ctx do
      assert {:ok, _count} = Graph.rebuild(workspace_id: ctx.ws)
      assert_edges_follow_contexts(ctx.ws, ctx.ids, ctx.a, ctx.b)
    end

    test "backfill writes each context's edges for that context's tenant", ctx do
      assert {:ok, _summary} = Graph.backfill(workspace_id: ctx.ws, claims: false)
      assert_edges_follow_contexts(ctx.ws, ctx.ids, ctx.a, ctx.b)
    end
  end

  describe "the edges written with a context" do
    test "carry the tenant of the context the moment it is inserted", ctx do
      %{a: a, b: b, ws: ws, n: n} = ctx
      id_a = "inserted-a-#{n}"
      id_b = "inserted-b-#{n}"
      assert :ok = Store.insert_context(context(id_a, ws, tenant_id: a))
      assert :ok = Store.insert_context(context(id_b, ws, tenant_id: b))

      assert edge_tenants(ws, "source_id = ?2 OR target_id = ?2", [id_a]) == [a]
      assert edge_tenants(ws, "source_id = ?2 OR target_id = ?2", [id_b]) == [b]

      assert edge_tenants(ws, "relation = 'co_occurs' AND source_id = 'Acme Corp'", []) ==
               Enum.sort([a, b])
    end
  end

  describe "Vectors.store/3" do
    test "a vector stored before its context takes the named tenant", %{a: a, ws: ws, n: n} do
      id = "bare-vec-#{n}"
      assert :ok = Vectors.store(id, [1.0, 0.0, 0.0], workspace_id: ws, tenant_id: a)

      assert {:ok, [[^a]]} =
               Store.raw_query("SELECT tenant_id FROM vectors WHERE context_id = ?1", [id])
    end

    test "a vector stored with no tenant stays in the default tenant", %{ws: ws, n: n} do
      id = "bare-vec-unnamed-#{n}"
      assert :ok = Vectors.store(id, [1.0, 0.0, 0.0], workspace_id: ws)

      assert {:ok, [["default"]]} =
               Store.raw_query("SELECT tenant_id FROM vectors WHERE context_id = ?1", [id])
    end

    test "a vector follows the tenant of its context", %{a: a, b: b, ws: ws, n: n} do
      id = "bare-vec-ctx-#{n}"
      assert :ok = Store.insert_context(context(id, ws, tenant_id: a))
      assert :ok = Vectors.store(id, [1.0, 0.0, 0.0], workspace_id: ws, tenant_id: b)

      assert {:ok, [[^a]]} =
               Store.raw_query("SELECT tenant_id FROM vectors WHERE context_id = ?1", [id])
    end
  end

  describe "the writers that build a context" do
    setup do
      root = Path.join(System.tmp_dir!(), "bare_tenant_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      original_root = Application.get_env(:optimal_engine, :root_path)
      Application.put_env(:optimal_engine, :root_path, root)

      on_exit(fn ->
        if original_root,
          do: Application.put_env(:optimal_engine, :root_path, original_root),
          else: Application.delete_env(:optimal_engine, :root_path)

        File.rm_rf!(root)
      end)

      %{root: root}
    end

    test "intake writes the context for the tenant that ingests", %{a: a, b: b, ws: ws} do
      for {tenant, text} <- [
            {a, "Tenant a reviewed the pricing plan on Tuesday."},
            {b, "Tenant b reviewed the hiring plan on Wednesday."}
          ] do
        assert {:ok, result} =
                 Intake.process(text, tenant_id: tenant, workspace_id: ws, write_files: false)

        assert tenant_of(result.context.id) == tenant
        assert row(result.context.id).workspace == ws
      end
    end

    test "intake without a tenant keeps the old rule", %{ws: ws} do
      assert {:ok, result} =
               Intake.process("The unnamed tenant reviewed the plan.",
                 workspace_id: ws,
                 write_files: false
               )

      assert tenant_of(result.context.id) == "default"
    end

    test "one source id ingested by two tenants into a bare id does not collide", ctx do
      %{a: a, b: b, ws: ws} = ctx

      assert {:ok, first} =
               Intake.process("Tenant a notes the renewal terms.",
                 tenant_id: a,
                 workspace_id: ws,
                 write_files: false,
                 source_id: "doc-1"
               )

      assert tenant_of(first.context.id) == a

      # The second tenant's item has the same source id, so the same row id:
      # it is refused, and tenant a's row is untouched.
      id = first.context.id

      assert {:error, {:context_id_in_use, ^id}} =
               Intake.process("Tenant b notes the vendor terms.",
                 tenant_id: b,
                 workspace_id: ws,
                 write_files: false,
                 source_id: "doc-1"
               )

      assert %{tenant: ^a, content: "Tenant a notes the renewal terms."} = row(id)
    end

    test "a refused intake writes no file", %{a: a, b: b, ws: ws, root: root} do
      files = fn -> root |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort() end

      assert {:ok, first} =
               Intake.process("Tenant a files the renewal terms.",
                 tenant_id: a,
                 workspace_id: ws,
                 source_id: "doc-file"
               )

      Process.sleep(200)
      written = files.()
      assert written != []

      id = first.context.id

      assert {:error, {:context_id_in_use, ^id}} =
               Intake.process("Tenant b files the vendor terms.",
                 tenant_id: b,
                 workspace_id: ws,
                 source_id: "doc-file"
               )

      Process.sleep(200)
      assert files.() == written
    end

    test "the connector sink counts the Signals intake refuses", %{a: a, b: b, ws: ws, n: n} do
      signal =
        Transform.new_signal(%{
          id: "sig-#{n}",
          title: "Renewal #{n}",
          content: "The renewal terms for #{n} are attached.",
          path: "scripted://item-#{n}",
          genre: "message",
          entities: []
        })

      sink = PullScheduler.intake_sink()

      scope = fn tenant ->
        %{tenant_id: tenant, workspace_id: ws, config: %{}, connector_id: "c"}
      end

      capture_log(fn ->
        assert {:ok, 0} = sink.([signal], scope.(a))
        assert {:ok, 1} = sink.([signal], scope.(b))
      end)

      assert {:ok, [[^a]]} =
               Store.raw_query(
                 "SELECT tenant_id FROM contexts WHERE workspace_id = ?1 AND title = ?2",
                 [ws, "Renewal #{n}"]
               )
    end

    test "POST /api/ingest with a tenant key writes the row for that tenant", %{a: a, b: b, ws: ws} do
      for {tenant, text} <- [
            {a, "Tenant a agreed the launch date on Monday."},
            {b, "Tenant b agreed the budget on Thursday."}
          ] do
        {:ok, %{key: key}} =
          ApiKey.mint(%{
            tenant_id: tenant,
            name: "ingest",
            scopes: ["read", "write"],
            workspace_scope: ["*"]
          })

        conn =
          :post
          |> conn("/api/ingest", Jason.encode!(%{"text" => text, "workspace" => ws}))
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> key)
          |> Router.call(Router.init([]))

        assert conn.status == 200, conn.resp_body
        %{"signal_id" => id} = Jason.decode!(conn.resp_body)
        assert tenant_of(id) == tenant
      end
    end

    test "POST /api/batch/import/signals writes each signal for the importing tenant", ctx do
      %{a: a, b: b, ws: ws, n: n} = ctx

      for {tenant, tag} <- [{a, "alpha"}, {b, "beta"}] do
        {:ok, %{key: key}} =
          ApiKey.mint(%{
            tenant_id: tenant,
            name: "batch",
            scopes: ["read", "write"],
            workspace_scope: ["*"]
          })

        body = %{
          "workspace" => ws,
          "signals" => [%{"content" => "Batch #{tag} signal #{n} about the quarterly plan."}]
        }

        conn =
          :post
          |> conn("/api/batch/import/signals", Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> key)
          |> Router.call(Router.init([]))

        assert conn.status == 200, conn.resp_body
        assert %{"imported" => 1} = Jason.decode!(conn.resp_body)

        assert {:ok, [[^tenant]]} =
                 Store.raw_query(
                   "SELECT tenant_id FROM contexts WHERE workspace_id = ?1 AND content LIKE ?2",
                   [ws, "Batch #{tag} signal #{n}%"]
                 )
      end
    end

    test "the indexer writes a file for the tenant that indexes it", %{a: a, ws: ws, root: root} do
      path = Path.join(root, "bare-note.md")
      File.write!(path, "# Bare note\n\nThe tenant keeps this note.\n")

      assert {:ok, context} =
               Indexer.index_file(path, workspace_id: ws, tenant_id: a, skip_vlm: true)

      assert tenant_of(context.id) == a
    end

    test "a committed chat session is written for the committing tenant", %{a: a, ws: ws, n: n} do
      {:ok, normalized} =
        ChatSession.normalize(%{
          "workspace" => ws,
          "correlation_id" => "chat-#{n}",
          "title" => "Launch planning",
          "source" => "chat-client",
          "messages" => [
            %{
              "role" => "user",
              "content" => "We decided to move the launch review to Thursday.",
              "at" => "2026-10-18T09:00:00Z"
            },
            %{
              "role" => "assistant",
              "content" => "Noted.",
              "at" => "2026-10-18T09:00:05Z"
            }
          ]
        })

      assert {:ok, %{session_id: session_id}, :created} =
               ChatSession.commit(a, ws, "agent:x", normalized)

      assert tenant_of(session_id) == a
    end
  end
end
