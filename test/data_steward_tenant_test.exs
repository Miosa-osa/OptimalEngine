defmodule OptimalEngine.DataStewardTenantTest do
  @moduledoc """
  The steward's id repairs act inside the caller's tenant. A source or target
  workspace of another tenant is refused as if it were absent, an archived
  workspace of another tenant is never an unregistered source, rows another
  tenant wrote under an id both use stay where they are (a rename refuses an
  id they share), the tables with no tenant column are moved by tracing each
  row to its tenant through a parent row, the checks and the move happen in
  one transaction, a repair that has nothing of the caller's to move says
  only that, and the HTTP routes authorize the source and target ids they
  name like any workspace.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority.Evidence

  alias OptimalEngine.{
    CorpusOrganizer,
    DataSteward,
    EntityResolution,
    Memory,
    Organization,
    Store,
    Workspace
  }

  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    a = "stew-a-#{n}"
    b = "stew-b-#{n}"

    for tenant <- [a, b] do
      {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

      {:ok, _} =
        Workspace.create(%{
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "ops",
          name: "Ops"
        })
    end

    %{n: n, a: a, b: b, a_ws: "#{a}:ops", b_ws: "#{b}:ops"}
  end

  defp context(tenant, workspace, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, ?4, 'Row', 'Row.', '2026-10-20T09:00:00Z', '{}')",
        [id, tenant, workspace, "optimal://inbox/#{id}.md"]
      )
  end

  defp holder(id) do
    {:ok, [[workspace, tenant]]} =
      Store.raw_query("SELECT workspace_id, tenant_id FROM contexts WHERE id = ?1", [id])

    {tenant, workspace}
  end

  defp steward(tenant), do: [tenant_id: tenant, actor_id: "user:steward"]

  defp raw(sql, params) do
    {:ok, _} = Store.raw_query(sql, params)
  end

  # The tables a repair traces to a tenant through a parent row.
  defp traced_tables do
    ~w(entity_aliases entity_identifiers entity_lineage entity_mentions resolution_decisions
       memory_association_paths memory_reconstruction_outcomes memory_consolidation_proposals)
  end

  # A source package of the tenant, made by a memory written to `workspace`.
  defp package(tenant, workspace, text) do
    {:ok, _} =
      Memory.create(%{
        content: text,
        workspace_id: workspace,
        tenant_id: tenant,
        actor_id: "user:steward"
      })

    {:ok, [[package_id]]} =
      Store.raw_query(
        "SELECT source_package_id FROM claims WHERE tenant_id = ?1 AND workspace_id = ?2 AND claim_text = ?3",
        [tenant, workspace, text]
      )

    package_id
  end

  defp mention(id, workspace, context_id, package_id) do
    raw(
      "INSERT INTO entity_mentions (id, workspace_id, context_id, source_package_id, surface_text, normalized_text) VALUES (?1, ?2, ?3, ?4, 'Name', 'name')",
      [id, workspace, context_id, package_id]
    )
  end

  defp pending_claim(tenant, workspace, text) do
    package(tenant, workspace, text)

    {:ok, [[id]]} =
      Store.raw_query(
        "SELECT id FROM claims WHERE tenant_id = ?1 AND workspace_id = ?2 AND claim_text = ?3",
        [tenant, workspace, text]
      )

    id
  end

  defp claim_state(id) do
    {:ok, [[state]]} = Store.raw_query("SELECT lifecycle_state FROM claims WHERE id = ?1", [id])
    state
  end

  # One row in each table with no tenant column, all of the tenant's, tagged
  # `tag`: the entity and mention rows hang off a canonical entity and a
  # context of the tenant, the memory rows off a run of the tenant. Rows with
  # no parent (`free-<tag>`, and the path feedback) cannot be traced.
  defp seed_unscoped(tenant, workspace, tag) do
    {entity, other} = {"ent-#{tag}", "ent2-#{tag}"}

    for id <- [entity, other] do
      raw(
        "INSERT INTO canonical_entities (id, tenant_id, workspace_id, entity_kind, canonical_name, normalized_name) VALUES (?1, ?2, ?3, 'person', ?1, ?1)",
        [id, tenant, workspace]
      )
    end

    raw(
      "INSERT INTO entity_aliases (id, workspace_id, entity_id, alias, normalized_alias) VALUES (?1, ?2, ?3, 'a', 'a')",
      ["alias-#{tag}", workspace, entity]
    )

    raw(
      "INSERT INTO entity_identifiers (id, workspace_id, entity_id, namespace, identifier_value, normalized_value) VALUES (?1, ?2, ?3, 'ns', ?4, ?4)",
      ["ident-#{tag}", workspace, entity, tag]
    )

    raw(
      "INSERT INTO entity_lineage (id, workspace_id, predecessor_entity_id, successor_entity_id, operation, reason, actor_id) VALUES (?1, ?2, ?3, ?4, 'merge', 'r', 'user:steward')",
      ["lineage-#{tag}", workspace, entity, other]
    )

    context(tenant, workspace, "ctx-seed-#{tag}")
    mention("mention-#{tag}", workspace, "ctx-seed-#{tag}", nil)
    mention("free-#{tag}", workspace, nil, nil)

    raw(
      "INSERT INTO resolution_decisions (id, workspace_id, mention_id, decision, actor_id) VALUES (?1, ?2, ?3, 'link', 'user:steward')",
      ["decision-#{tag}", workspace, "mention-#{tag}"]
    )

    raw(
      "INSERT INTO memory_reconstruction_runs (id, tenant_id, workspace_id, query, step_budget, token_budget) VALUES (?1, ?2, ?3, 'q', 1, 1)",
      ["run-#{tag}", tenant, workspace]
    )

    raw(
      "INSERT INTO memory_association_paths (id, run_id, workspace_id, intent, cue) VALUES (?1, ?2, ?3, 'i', 'c')",
      ["path-#{tag}", "run-#{tag}", workspace]
    )

    raw(
      "INSERT INTO memory_reconstruction_outcomes (id, run_id, workspace_id, outcome, score) VALUES (?1, ?2, ?3, 'success', 1.0)",
      ["outcome-#{tag}", "run-#{tag}", workspace]
    )

    raw(
      "INSERT INTO memory_consolidation_proposals (id, workspace_id, proposal_type, rationale, metadata) VALUES (?1, ?2, 'recurring_association_path', 'r', ?3)",
      ["proposal-#{tag}", workspace, Jason.encode!(%{"path_ids" => ["path-#{tag}"]})]
    )

    raw(
      "INSERT INTO sync_capture (table_name, operation, workspace_id, entity_key, row_data) VALUES ('contexts', 'create', ?1, ?2, ?3)",
      [workspace, tag, Jason.encode!(%{"tenant_id" => tenant, "id" => tag})]
    )

    raw(
      "INSERT INTO memory_path_feedback (workspace_id, object_type, object_id) VALUES (?1, 'memory', ?2)",
      [workspace, tag]
    )
  end

  # Where the row tagged `tag` of a table with no tenant column is now.
  defp unscoped_workspace(table, tag) do
    {column, value} =
      case table do
        "entity_aliases" ->
          {"id", "alias-#{tag}"}

        "entity_identifiers" ->
          {"id", "ident-#{tag}"}

        "entity_lineage" ->
          {"id", "lineage-#{tag}"}

        "entity_mentions" ->
          {"id",
           if(String.starts_with?(tag, ["free-", "pkg-", "planted", "foreign-", "mv-"]),
             do: tag,
             else: "mention-#{tag}"
           )}

        "resolution_decisions" ->
          {"id", "decision-#{tag}"}

        "memory_association_paths" ->
          {"id", "path-#{tag}"}

        "memory_reconstruction_outcomes" ->
          {"id", "outcome-#{tag}"}

        "memory_consolidation_proposals" ->
          {"id", "proposal-#{tag}"}

        "sync_capture" ->
          {"entity_key", tag}

        "memory_path_feedback" ->
          {"object_id", tag}
      end

    {:ok, [[workspace]]} =
      Store.raw_query("SELECT workspace_id FROM \"#{table}\" WHERE #{column} = ?1", [value])

    workspace
  end

  describe "rename_workspace" do
    test "a source workspace of another tenant is not found, and nothing moves",
         %{a: a, b: b, b_ws: b_ws, n: n} do
      context(b, b_ws, "b-row-#{n}")

      assert {:error, :source_workspace_not_found} =
               DataSteward.rename_workspace(b_ws, "#{b}:ops", steward(a))

      {:ok, _} = Workspace.update(b_ws, %{slug: "ops-b-new"})

      assert {:error, :source_workspace_not_found} =
               DataSteward.rename_workspace(b_ws, "#{b}:ops-b-new", steward(a))

      assert {:ok, %{id: ^b_ws}} = Workspace.get(b_ws)
      assert holder("b-row-#{n}") == {b, b_ws}
    end

    test "is refused when another tenant wrote rows under the source id, and nothing moves",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      context(a, a_ws, "a-row-#{n}")
      context(b, a_ws, "stray-row-#{n}")

      {:ok, _} = Workspace.update(a_ws, %{slug: "ops-a-new"})
      target = "#{a}:ops-a-new"

      assert {:error, :workspace_id_shared} =
               DataSteward.rename_workspace(a_ws, target, steward(a))

      assert {:ok, %{id: ^a_ws}} = Workspace.get(a_ws)
      assert {:error, :not_found} = Workspace.get(target)
      assert holder("a-row-#{n}") == {a, a_ws}
      assert holder("stray-row-#{n}") == {b, a_ws}
    end

    test "is refused when another tenant's rows are only in tables with no tenant column",
         %{a: a, b_ws: b_ws, a_ws: a_ws, b: b, n: n} do
      context(b, b_ws, "ctx-b-foreign-#{n}")
      mention("foreign-#{n}", a_ws, "ctx-b-foreign-#{n}", nil)

      {:ok, _} = Workspace.update(a_ws, %{slug: "ops-foreign"})

      assert {:error, :workspace_id_shared} =
               DataSteward.rename_workspace(a_ws, "#{a}:ops-foreign", steward(a))

      assert {:ok, %{id: ^a_ws}} = Workspace.get(a_ws)
      assert unscoped_workspace("entity_mentions", "foreign-#{n}") == a_ws
    end

    test "refuses to go on when it cannot tell whether the id holds rows",
         %{a_ws: a_ws, a: a} do
      broken = [%{name: "no_such_table_in_the_schema", tenant_scoped?: true}]

      assert {:ok, {:error, reason1}} =
               Store.transaction(fn txn ->
                 {:ok, DataSteward.target_free_of_rows(txn, broken, a_ws)}
               end)

      assert {:ok, {:error, reason2}} =
               Store.transaction(fn txn ->
                 {:ok, DataSteward.check_id_not_shared(txn, broken, a_ws, a)}
               end)

      refute reason1 in [:target_workspace_has_rows, :workspace_id_shared]
      refute reason2 in [:target_workspace_has_rows, :workspace_id_shared]
    end

    test "checks the shape of the target before looking for it", %{a: a, a_ws: a_ws, b_ws: b_ws} do
      # A workspace of another tenant exists, but a target that is not the
      # source's own tenant:slug is refused for its shape, not for existing.
      assert {:error, :target_must_match_tenant_and_slug} =
               DataSteward.rename_workspace(a_ws, b_ws, steward(a))
    end

    test "does not lose a change made to the workspace while the rename runs",
         %{a: a, a_ws: a_ws} do
      {:ok, _} = Workspace.update(a_ws, %{slug: "ops-a-live"})

      updater =
        Task.async(fn ->
          Stream.iterate(1, &(&1 + 1))
          |> Enum.reduce_while(nil, fn i, last ->
            case Workspace.update(a_ws, %{description: "description #{i}"}) do
              {:ok, _} -> {:cont, "description #{i}"}
              {:error, _} -> {:halt, last}
            end
          end)
        end)

      Process.sleep(20)
      assert {:ok, _} = DataSteward.rename_workspace(a_ws, "#{a}:ops-a-live", steward(a))
      last = Task.await(updater, 30_000)

      # Every update that reported success is on the renamed workspace.
      assert {:ok, %{description: description}} = Workspace.get("#{a}:ops-a-live")
      assert description == last
    end
  end

  describe "repair_orphan_scope" do
    test "a target workspace of another tenant is not registered for the caller",
         %{a: a, b_ws: b_ws, n: n} do
      orphan = "orphan-#{n}"
      context(a, orphan, "a-orphan-#{n}")

      assert {:error, :target_workspace_not_registered} =
               DataSteward.repair_orphan_scope(orphan, b_ws, steward(a))

      assert holder("a-orphan-#{n}") == {a, orphan}
    end

    test "an archived workspace of another tenant is registered, never an orphan source",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      {:ok, archived} =
        Workspace.create(%{
          tenant_id: b,
          organization_id: Organization.default_for(b),
          slug: "gone",
          name: "Gone"
        })

      context(b, archived.id, "b-archived-#{n}")
      :ok = Workspace.archive(archived.id)

      assert {:error, :source_workspace_is_registered} =
               DataSteward.repair_orphan_scope(archived.id, a_ws, steward(a))

      assert holder("b-archived-#{n}") == {b, archived.id}
    end

    test "an archived workspace of the caller's own tenant can still be repaired from",
         %{a: a, a_ws: a_ws, n: n} do
      {:ok, archived} =
        Workspace.create(%{
          tenant_id: a,
          organization_id: Organization.default_for(a),
          slug: "gone",
          name: "Gone"
        })

      context(a, archived.id, "a-archived-#{n}")
      :ok = Workspace.archive(archived.id)

      assert {:ok, %{updated_records: updated}} =
               DataSteward.repair_orphan_scope(archived.id, a_ws, steward(a))

      assert updated >= 1
      assert holder("a-archived-#{n}") == {a, a_ws}
    end

    test "moves the caller's rows only from an id two tenants used",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      shared = "shared-orphan-#{n}"
      context(a, shared, "a-shared-#{n}")
      context(b, shared, "b-shared-#{n}")

      assert {:ok, _} = DataSteward.repair_orphan_scope(shared, a_ws, steward(a))

      assert holder("a-shared-#{n}") == {a, a_ws}
      assert holder("b-shared-#{n}") == {b, shared}
    end
  end

  describe "writing a mention" do
    test "needs its context and source package to be the tenant's, in the mention's workspace",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      orphan = "mention-orphan-#{n}"
      context(a, orphan, "ctx-a-#{n}")
      context(a, a_ws, "ctx-a-elsewhere-#{n}")
      package_a = package(a, orphan, "Package of a #{n}")
      base = %{workspace_id: orphan, surface_text: "Name #{n}"}

      for tenant <- [b, a] do
        expected = if tenant == a, do: :ok, else: :error

        assert {^expected, _} =
                 EntityResolution.resolve(Map.put(base, :context_id, "ctx-a-#{n}"),
                   tenant_id: tenant
                 )

        assert {^expected, _} =
                 EntityResolution.resolve(Map.put(base, :source_package_id, package_a),
                   tenant_id: tenant
                 )
      end

      assert {:error, :context_not_found} =
               EntityResolution.resolve(Map.put(base, :context_id, "ctx-a-#{n}"), tenant_id: b)

      assert {:error, :source_package_not_found} =
               EntityResolution.resolve(Map.put(base, :source_package_id, package_a),
                 tenant_id: b
               )

      # The tenant's own context in another workspace is not the mention's.
      assert {:error, :context_not_found} =
               EntityResolution.resolve(Map.put(base, :context_id, "ctx-a-elsewhere-#{n}"),
                 tenant_id: a
               )
    end

    test "is refused over HTTP when it points at another tenant's context or package",
         %{a: a, b: b, n: n} do
      orphan = "mention-http-#{n}"
      context(a, orphan, "ctx-a-#{n}")
      context(b, orphan, "ctx-b-#{n}")
      package_a = package(a, orphan, "Package of a #{n}")
      token = key(b, ["*"])
      body = %{workspace_id: orphan, surface_text: "Name"}

      assert {422, %{"error" => context_error}} =
               post("/api/entity-mentions", Map.put(body, :context_id, "ctx-a-#{n}"), token)

      assert context_error =~ "context_not_found"

      assert {422, %{"error" => package_error}} =
               post("/api/entity-mentions", Map.put(body, :source_package_id, package_a), token)

      assert package_error =~ "source_package_not_found"

      assert {201, %{"id" => _}} =
               post("/api/entity-mentions", Map.put(body, :context_id, "ctx-b-#{n}"), token)
    end

    test "is decided by the tenant it belongs to, not by another tenant sharing the workspace id",
         %{a: a, b: b, n: n} do
      orphan = "mention-decide-#{n}"
      context(a, orphan, "ctx-a-#{n}")

      assert {:ok, %{id: mention_id}} =
               EntityResolution.resolve(
                 %{workspace_id: orphan, surface_text: "Name", context_id: "ctx-a-#{n}"},
                 tenant_id: a
               )

      decide = fn tenant ->
        EntityResolution.decide(mention_id, :reject,
          workspace_id: orphan,
          actor_id: "user:steward",
          tenant_id: tenant
        )
      end

      assert {:error, :mention_not_found} = decide.(b)
      assert {:ok, %{decision: :reject}} = decide.(a)
    end

    test "with an empty context or package id is stored as having none, and can be decided",
         %{a: a, n: n} do
      orphan = "mention-empty-#{n}"

      assert {:ok, %{id: mention_id}} =
               EntityResolution.resolve(
                 %{
                   workspace_id: orphan,
                   surface_text: "Name",
                   context_id: "",
                   source_package_id: ""
                 },
                 tenant_id: a
               )

      assert {:ok, [[nil, nil]]} =
               Store.raw_query(
                 "SELECT context_id, source_package_id FROM entity_mentions WHERE id = ?1",
                 [mention_id]
               )

      assert {:ok, %{decision: :reject}} =
               EntityResolution.decide(mention_id, :reject,
                 workspace_id: orphan,
                 actor_id: "user:steward",
                 tenant_id: a
               )
    end

    test "stored with an empty id by an earlier version reads as having none",
         %{a: a, n: n} do
      orphan = "mention-stored-empty-#{n}"
      mention("stored-empty-#{n}", orphan, "", "")

      assert {:ok, %{decision: :reject}} =
               EntityResolution.decide("stored-empty-#{n}", :reject,
                 workspace_id: orphan,
                 actor_id: "user:steward",
                 tenant_id: a
               )
    end

    test "whose context is gone reads as having none", %{a: a, n: n} do
      orphan = "mention-gone-#{n}"
      context(a, orphan, "ctx-gone-#{n}")

      assert {:ok, %{id: mention_id}} =
               EntityResolution.resolve(
                 %{workspace_id: orphan, surface_text: "Name", context_id: "ctx-gone-#{n}"},
                 tenant_id: a
               )

      raw("DELETE FROM contexts WHERE id = ?1", ["ctx-gone-#{n}"])

      assert {:ok, %{decision: :reject}} =
               EntityResolution.decide(mention_id, :reject,
                 workspace_id: orphan,
                 actor_id: "user:steward",
                 tenant_id: a
               )
    end

    test "that makes a new entity makes it the tenant's", %{a: a, n: n} do
      orphan = "mention-entity-#{n}"
      context(a, orphan, "ctx-a-#{n}")

      assert {:ok, %{id: mention_id}} =
               EntityResolution.resolve(
                 %{workspace_id: orphan, surface_text: "Northwind #{n}", context_id: "ctx-a-#{n}"},
                 tenant_id: a
               )

      assert {:ok, %{entity_id: entity_id}} =
               EntityResolution.decide(mention_id, :new_entity,
                 workspace_id: orphan,
                 actor_id: "user:steward",
                 tenant_id: a
               )

      assert {:ok, [[^a]]} =
               Store.raw_query("SELECT tenant_id FROM canonical_entities WHERE id = ?1", [entity_id])
    end
  end

  describe "moving an intake context" do
    test "moves the mentions and decisions that hang off it and its source packages",
         %{n: n} do
      intake = CorpusOrganizer.source_workspace()
      context("default", intake, "mv-ctx-#{n}")
      on_exit(fn -> raw("DELETE FROM contexts WHERE id = ?1", ["mv-ctx-#{n}"]) end)

      # A package the context's claims came from, and a mention from each.
      package_id = package("default", "mv-package-ws-#{n}", "Moves with the context #{n}")

      raw("UPDATE claims SET signal_id = ?1 WHERE source_package_id = ?2", [
        "mv-ctx-#{n}",
        package_id
      ])

      mention("mv-context-#{n}", intake, "mv-ctx-#{n}", nil)
      mention("mv-package-#{n}", intake, nil, package_id)

      raw(
        "INSERT INTO resolution_decisions (id, workspace_id, mention_id, decision, actor_id) VALUES (?1, ?2, ?3, 'link', 'user:steward')",
        ["mv-decision-#{n}", intake, "mv-context-#{n}"]
      )

      {:ok, target} =
        Workspace.create(%{
          tenant_id: "default",
          organization_id: Organization.default_for("default"),
          slug: "mv-target-#{n}",
          name: "Move target"
        })

      assert {:ok, _} = CorpusOrganizer.move_context("mv-ctx-#{n}", target.id)

      assert unscoped_workspace("entity_mentions", "mv-context-#{n}") == target.id
      assert unscoped_workspace("entity_mentions", "mv-package-#{n}") == target.id

      assert {:ok, [[workspace]]} =
               Store.raw_query("SELECT workspace_id FROM resolution_decisions WHERE id = ?1", [
                 "mv-decision-#{n}"
               ])

      assert workspace == target.id
    end
  end

  describe "decide_claims" do
    test "a claim of another tenant is not found, whichever workspace the caller names",
         %{a: a, b: b, a_ws: a_ws, b_ws: b_ws, n: n} do
      claim = pending_claim(b, b_ws, "Only tenant b holds this claim #{n}")

      for workspace <- [a_ws, b_ws] do
        assert {:ok, %{requested: 1, completed: 0, failed: 1}} =
                 DataSteward.decide_claims(
                   [claim],
                   :reject,
                   [workspace_id: workspace] ++ steward(a)
                 )
      end

      assert claim_state(claim) == "pending"

      assert {:ok, %{completed: 1}} =
               DataSteward.decide_claims([claim], :reject, [workspace_id: b_ws] ++ steward(b))

      assert claim_state(claim) == "rejected"
    end
  end

  describe "repair_orphan_scope when there is nothing of the caller's to move" do
    test "says only that, whatever other tenants hold under the id", %{a: a, b: b, a_ws: a_ws, n: n} do
      orphan = "orphan-#{n}"

      assert {:error, :nothing_to_repair} =
               DataSteward.repair_orphan_scope(orphan, a_ws, steward(a))

      # Another tenant's rows, in a table with and one without a tenant column.
      context(b, orphan, "b-only-#{n}")
      seed_unscoped(b, orphan, "b#{n}")

      assert {:error, :nothing_to_repair} =
               DataSteward.repair_orphan_scope(orphan, a_ws, steward(a))

      assert holder("b-only-#{n}") == {b, orphan}
    end
  end

  describe "the active workspace of the caller's own tenant" do
    test "is never an orphan source", %{a: a, a_ws: a_ws, n: n} do
      {:ok, other} =
        Workspace.create(%{
          tenant_id: a,
          organization_id: Organization.default_for(a),
          slug: "second",
          name: "Second"
        })

      context(a, other.id, "a-active-#{n}")

      assert {:error, :source_workspace_is_registered} =
               DataSteward.repair_orphan_scope(other.id, a_ws, steward(a))

      assert holder("a-active-#{n}") == {a, other.id}
    end
  end

  # The tables with a workspace_id column and no tenant_id column. A repair
  # moves a row of one of them when a row it points at belongs to the tenant.
  describe "tables with no tenant column, traced to a tenant through a parent row" do
    test "an orphan repair moves the caller's rows and leaves another tenant's under the id",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      orphan = "shared-orphan-#{n}"
      context(a, orphan, "ctx-a#{n}")
      context(b, orphan, "ctx-b#{n}")
      seed_unscoped(a, orphan, "a#{n}")
      seed_unscoped(b, orphan, "b#{n}")

      assert {:ok, result} = DataSteward.repair_orphan_scope(orphan, a_ws, steward(a))

      moved = Enum.map(result.tables, & &1.table)

      for table <- traced_tables() do
        assert table in moved, "#{table} was not moved"
        assert unscoped_workspace(table, "a#{n}") == a_ws, "#{table}: the caller's row"
        assert unscoped_workspace(table, "b#{n}") == orphan, "#{table}: another tenant's row"
      end

      # What cannot be traced to a tenant stays, and is reported. Captured sync
      # changes are left too: they carry the old id inside the change itself,
      # and the moved rows are captured afresh under the new one.
      assert unscoped_workspace("entity_mentions", "free-a#{n}") == orphan
      assert unscoped_workspace("memory_path_feedback", "a#{n}") == orphan
      assert unscoped_workspace("sync_capture", "a#{n}") == orphan
      assert unscoped_workspace("sync_capture", "b#{n}") == orphan

      for table <- ["memory_path_feedback", "sync_capture"] do
        assert %{rows: rows} = Enum.find(result.unscoped_tables, &(&1.table == table))
        assert rows >= 2
      end

      refute Enum.any?(result.unscoped_tables, &(&1.table in traced_tables()))
    end

    test "a mention is traced through its source package as well as its context",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      orphan = "package-orphan-#{n}"
      package_a = package(a, orphan, "Package of a #{n}")
      package_b = package(b, orphan, "Package of b #{n}")
      mention("pkg-a#{n}", orphan, nil, package_a)
      mention("pkg-b#{n}", orphan, nil, package_b)

      assert {:ok, _} = DataSteward.repair_orphan_scope(orphan, a_ws, steward(a))

      assert unscoped_workspace("entity_mentions", "pkg-a#{n}") == a_ws
      assert unscoped_workspace("entity_mentions", "pkg-b#{n}") == orphan
    end

    test "a mention of another tenant that points at the caller's row in another workspace stays",
         %{a: a, a_ws: a_ws, n: n} do
      orphan = "planted-orphan-#{n}"
      context(a, orphan, "ctx-a-own-#{n}")
      context(a, a_ws, "ctx-a-elsewhere-#{n}")
      mention("planted-#{n}", orphan, "ctx-a-elsewhere-#{n}", nil)

      assert {:ok, _} = DataSteward.repair_orphan_scope(orphan, a_ws, steward(a))

      assert unscoped_workspace("entity_mentions", "planted-#{n}") == orphan
    end

    test "a repair that would move only rows hanging off the caller's rows elsewhere moves and signs nothing",
         %{a: a, a_ws: a_ws, n: n} do
      orphan = "planted-only-#{n}"
      context(a, a_ws, "ctx-a-elsewhere-#{n}")
      mention("planted-only-#{n}", orphan, "ctx-a-elsewhere-#{n}", nil)

      assert {:error, :nothing_to_repair} =
               DataSteward.repair_orphan_scope(orphan, a_ws, steward(a))

      assert unscoped_workspace("entity_mentions", "planted-only-#{n}") == orphan
      assert Evidence.list(a, kind: "workspace.rekeyed") == []
    end

    test "every such table in the schema is either traced or reported" do
      {:ok, rows} =
        Store.raw_query(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
          []
        )

      unscoped =
        rows
        |> List.flatten()
        |> Enum.filter(fn table ->
          {:ok, columns} = Store.raw_query("PRAGMA table_info(\"#{table}\")", [])
          names = Enum.map(columns, &Enum.at(&1, 1))
          "workspace_id" in names and "tenant_id" not in names
        end)
        |> Enum.reject(&(&1 in ["steward_tenantless_test"]))
        |> Enum.sort()

      %{traced: traced, untraced: untraced} = DataSteward.unscoped_tables()
      assert unscoped == Enum.sort(traced ++ untraced)
      assert Enum.sort(traced) == Enum.sort(traced_tables())
    end
  end

  describe "tables with no tenant column" do
    setup do
      :ok =
        Store.raw_execute(
          "CREATE TABLE IF NOT EXISTS steward_tenantless_test (workspace_id TEXT NOT NULL, note TEXT)",
          []
        )

      on_exit(fn -> Store.raw_execute("DROP TABLE IF EXISTS steward_tenantless_test", []) end)
    end

    defp tenantless(workspace) do
      {:ok, [[count]]} =
        Store.raw_query(
          "SELECT COUNT(*) FROM steward_tenantless_test WHERE workspace_id = ?1",
          [workspace]
        )

      count
    end

    defp tenantless_row(workspace) do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO steward_tenantless_test (workspace_id, note) VALUES (?1, 'x')",
          [workspace]
        )
    end

    test "an orphan repair leaves them where they are and says so",
         %{a: a, a_ws: a_ws, n: n} do
      orphan = "orphan-#{n}"
      context(a, orphan, "a-orphan-#{n}")
      tenantless_row(orphan)
      tenantless_row(orphan)

      assert {:ok, result} = DataSteward.repair_orphan_scope(orphan, a_ws, steward(a))

      assert result.unscoped_tables == [%{table: "steward_tenantless_test", rows: 2}]
      assert tenantless(orphan) == 2
      assert tenantless(a_ws) == 0
      assert holder("a-orphan-#{n}") == {a, a_ws}
    end

    test "a rename moves them, because the source is registered to the caller",
         %{a: a, a_ws: a_ws} do
      tenantless_row(a_ws)
      {:ok, _} = Workspace.update(a_ws, %{slug: "ops-moved"})
      target = "#{a}:ops-moved"

      assert {:ok, _} = DataSteward.rename_workspace(a_ws, target, steward(a))
      assert tenantless(target) == 1
      assert tenantless(a_ws) == 0
    end
  end

  describe "the dashboard" do
    test "lists the caller's orphan scopes only", %{a: a, b: b, n: n} do
      context(a, "orphan-a-#{n}", "a-dash-#{n}")
      context(b, "orphan-b-#{n}", "b-dash-#{n}")

      assert {:ok, scopes} = DataSteward.orphan_scopes(a)
      ids = Enum.map(scopes, & &1.workspace_id)
      assert "orphan-a-#{n}" in ids
      refute "orphan-b-#{n}" in ids
    end
  end

  describe "over HTTP" do
    defp key(tenant, workspaces) do
      {:ok, %{key: key}} =
        ApiKey.mint(%{
          tenant_id: tenant,
          name: "steward",
          scopes: ["read", "topology:write"],
          workspace_scope: workspaces
        })

      key
    end

    defp post(path, body, token) do
      response =
        conn(:post, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init([]))

      {response.status, Jason.decode!(response.resp_body)}
    end

    defp get(path, token) do
      response =
        conn(:get, path)
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init([]))

      {response.status, Jason.decode!(response.resp_body)}
    end

    test "the dashboard lists the caller's orphan scopes and not another tenant's",
         %{a: a, b: b, a_ws: a_ws, n: n} do
      context(a, "orphan-a-#{n}", "a-dash-http-#{n}")
      context(b, "orphan-b-#{n}", "b-dash-http-#{n}")

      assert {200, %{"orphan_scopes" => scopes}} =
               get("/api/data-steward/dashboard?workspace=#{a_ws}", key(a, ["*"]))

      ids = Enum.map(scopes, & &1["workspace_id"])
      assert "orphan-a-#{n}" in ids
      refute "orphan-b-#{n}" in ids
    end

    test "a tenant named in the request that is not the key's is refused",
         %{a: a, b: b, a_ws: a_ws, b_ws: b_ws, n: n} do
      claim = pending_claim(b, b_ws, "Refused over http #{n}")
      token = key(a, ["*"])

      for {path, body} <- [
            {"/api/data-steward/workspaces/repair",
             %{source_workspace_id: "orphan-#{n}", target_workspace_id: a_ws, tenant_id: b}},
            {"/api/data-steward/claims/decide",
             %{ids: [claim], decision: "reject", workspace: a_ws, tenant_id: b}},
            {"/api/data-steward/recheck", %{workspace: a_ws, tenant_id: b}}
          ] do
        assert {403, %{"error" => "tenant_scope_denied"}} = post(path, body, token), path
      end

      assert {403, %{"error" => "tenant_scope_denied"}} =
               get("/api/data-steward/dashboard?workspace=#{a_ws}&tenant=#{b}", token)

      assert claim_state(claim) == "pending"
    end

    test "an active workspace of the caller's tenant is refused as a source, and a repair of nothing says so",
         %{a: a, a_ws: a_ws, n: n} do
      token = key(a, ["*"])

      {:ok, other} =
        Workspace.create(%{
          tenant_id: a,
          organization_id: Organization.default_for(a),
          slug: "second",
          name: "Second"
        })

      assert {422, %{"error" => registered}} =
               post(
                 "/api/data-steward/workspaces/repair",
                 %{source_workspace_id: other.id, target_workspace_id: a_ws},
                 token
               )

      assert registered =~ "source_workspace_is_registered"

      assert {422, %{"error" => nothing}} =
               post(
                 "/api/data-steward/workspaces/repair",
                 %{source_workspace_id: "#{a}:nothing-#{n}", target_workspace_id: a_ws},
                 token
               )

      assert nothing =~ "nothing_to_repair"
    end

    test "a source or target of another tenant is refused as absent, and nothing moves",
         %{a: a, b: b, a_ws: a_ws, b_ws: b_ws, n: n} do
      context(b, "#{b}:orphan-#{n}", "b-http-#{n}")
      context(b, b_ws, "b-http-ws-#{n}")
      token = key(a, ["*"])

      assert {404, _} =
               post(
                 "/api/data-steward/workspaces/repair",
                 %{
                   workspace: a_ws,
                   source_workspace_id: "#{b}:orphan-#{n}",
                   target_workspace_id: a_ws
                 },
                 token
               )

      assert {404, _} =
               post(
                 "/api/data-steward/workspaces/repair",
                 %{workspace: a_ws, source_workspace_id: "orphan-#{n}", target_workspace_id: b_ws},
                 token
               )

      assert {404, _} =
               post(
                 "/api/data-steward/workspaces/rename",
                 %{workspace: a_ws, source_workspace_id: b_ws, target_workspace_id: "#{b}:ops"},
                 token
               )

      assert holder("b-http-#{n}") == {b, "#{b}:orphan-#{n}"}
      assert holder("b-http-ws-#{n}") == {b, b_ws}
    end

    test "a key restricted to some workspaces must hold the source and the target",
         %{a: a, a_ws: a_ws, n: n} do
      orphan = "#{a}:orphan-#{n}"
      context(a, orphan, "a-http-#{n}")
      body = %{source_workspace_id: orphan, target_workspace_id: a_ws}

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post("/api/data-steward/workspaces/repair", body, key(a, [a_ws]))

      assert holder("a-http-#{n}") == {a, orphan}

      assert {403, %{"error" => "workspace_scope_denied"}} =
               post("/api/data-steward/workspaces/repair", body, key(a, [orphan]))

      assert {200, %{"updated_records" => updated}} =
               post("/api/data-steward/workspaces/repair", body, key(a, [orphan, a_ws]))

      assert updated >= 1
      assert holder("a-http-#{n}") == {a, a_ws}
    end

    test "a keyed caller in a tenant other than the default can use the routes at all",
         %{a: a, a_ws: a_ws} do
      {:ok, _} = Workspace.update(a_ws, %{slug: "ops-http-new"})
      target = "#{a}:ops-http-new"

      assert {200, %{"target_workspace_id" => ^target}} =
               post(
                 "/api/data-steward/workspaces/rename",
                 %{source_workspace_id: a_ws, target_workspace_id: target},
                 key(a, ["*"])
               )
    end
  end
end
