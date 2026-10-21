defmodule OptimalEngine.EntityMentionTenantTest do
  @moduledoc """
  A mention carries the tenant that wrote it (`entity_mentions.tenant_id`).
  Two tenants can share a bare workspace id (one nobody registered), and a
  mention that names no context and no source package has nothing else to say
  whose it is: it belongs to its writer, so the other tenant neither lists nor
  decides it. A mention written before the column has no tenant and keeps the
  earlier rule (the tenant of the context or source package it names, else
  the workspace). The entity quality report counts the caller's rows only.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{DataSteward, EntityRegistry, EntityResolution, Memory, Store}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    a = "mnt-a-#{n}"
    b = "mnt-b-#{n}"

    for tenant <- [a, b], do: {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

    %{n: n, a: a, b: b, ws: "shared-mnt-#{n}"}
  end

  defp raw(sql, params) do
    {:ok, rows} = Store.raw_query(sql, params)
    rows
  end

  defp context(tenant, workspace, id) do
    raw(
      "INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, ?4, 'Row', 'Row.', '2026-10-20T09:00:00Z', '{}')",
      [id, tenant, workspace, "optimal://inbox/#{id}.md"]
    )
  end

  defp package(tenant, workspace, text) do
    {:ok, _} =
      Memory.create(%{
        content: text,
        workspace_id: workspace,
        tenant_id: tenant,
        actor_id: "user:reviewer"
      })

    [[package_id]] =
      raw(
        "SELECT source_package_id FROM claims WHERE tenant_id = ?1 AND workspace_id = ?2 AND claim_text = ?3",
        [tenant, workspace, text]
      )

    package_id
  end

  defp entity(tenant, workspace, name) do
    {:ok, %{id: id}} =
      EntityRegistry.register(%{
        tenant_id: tenant,
        workspace_id: workspace,
        entity_kind: "person",
        canonical_name: name,
        created_by: "test"
      })

    id
  end

  defp merge(loser, winner, workspace, tenant) do
    EntityRegistry.merge(loser, winner,
      workspace_id: workspace,
      tenant_id: tenant,
      actor_id: "user:reviewer",
      reason: "same person"
    )
  end

  # A mention that names neither a context nor a source package.
  defp parentless(tenant, workspace, surface) do
    {:ok, %{id: id}} =
      EntityResolution.resolve(%{workspace_id: workspace, surface_text: surface},
        tenant_id: tenant
      )

    id
  end

  # A mention written before the tenant column: no tenant on the row.
  defp legacy(id, workspace, context_id) do
    raw(
      "INSERT INTO entity_mentions (id, workspace_id, context_id, surface_text, normalized_text) VALUES (?1, ?2, ?3, 'Legacy Name', 'legacy name')",
      [id, workspace, context_id]
    )

    id
  end

  defp tenant_of(id) do
    [[tenant]] = raw("SELECT tenant_id FROM entity_mentions WHERE id = ?1", [id])
    tenant
  end

  defp queued(workspace, tenant) do
    {:ok, items} = EntityResolution.queue(workspace, tenant_id: tenant, limit: 500)
    Enum.map(items, & &1.id)
  end

  defp decide(id, decision, workspace, tenant, extra \\ []) do
    EntityResolution.decide(
      id,
      decision,
      [workspace_id: workspace, actor_id: "user:reviewer", tenant_id: tenant] ++ extra
    )
  end

  defp key(tenant) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "mentions",
        scopes: ["read", "topology:write"],
        workspace_scope: ["*"]
      })

    key
  end

  defp call(method, path, body, token) do
    response =
      conn(method, path, if(body, do: Jason.encode!(body)))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    {response.status, Jason.decode!(response.resp_body)}
  end

  describe "writing a mention" do
    test "records the writer's tenant, with or without a context", %{a: a, ws: ws, n: n} do
      context(a, ws, "mnt-ctx-#{n}")

      {:ok, %{id: with_context}} =
        EntityResolution.resolve(
          %{workspace_id: ws, surface_text: "Ida Ivers", context_id: "mnt-ctx-#{n}"},
          tenant_id: a
        )

      assert tenant_of(with_context) == a
      assert tenant_of(parentless(a, ws, "Jon Jarvis")) == a
    end

    test "records the default tenant when none is given", %{ws: ws} do
      {:ok, %{id: id}} = EntityResolution.resolve(%{workspace_id: ws, surface_text: "Kay Kent"})
      assert tenant_of(id) == "default"
    end

    test "over HTTP records the key's tenant", %{a: a, ws: ws} do
      assert {201, %{"id" => id}} =
               call(
                 :post,
                 "/api/entity-mentions",
                 %{workspace_id: ws, surface_text: "Lia Lund"},
                 key(a)
               )

      assert tenant_of(id) == a
    end
  end

  describe "a mention with no context and no source package" do
    test "is listed and clustered for its writer and not for another tenant sharing the id",
         %{a: a, b: b, ws: ws} do
      mine = parentless(a, ws, "Mona Marsh")
      theirs = parentless(b, ws, "Ned North")

      assert mine in queued(ws, a)
      refute theirs in queued(ws, a)
      assert theirs in queued(ws, b)
      refute mine in queued(ws, b)

      {:ok, clusters_a} = DataSteward.entity_clusters(ws, a)
      {:ok, clusters_b} = DataSteward.entity_clusters(ws, b)
      ids = fn clusters -> clusters |> Enum.flat_map(& &1.mentions) |> Enum.map(& &1.id) end

      assert mine in ids.(clusters_a)
      refute theirs in ids.(clusters_a)
      assert theirs in ids.(clusters_b)
      refute mine in ids.(clusters_b)
    end

    test "cannot be decided by another tenant sharing the id, and stays unresolved",
         %{a: a, b: b, ws: ws, n: n} do
      mine = parentless(a, ws, "Opal Orr #{n}")
      theirs_entity = entity(b, ws, "Opal Orr")

      assert {:error, :mention_not_found} = decide(mine, :reject, ws, b)
      assert {:error, :mention_not_found} = decide(mine, :new_entity, ws, b)
      assert {:error, :mention_not_found} = decide(mine, :link, ws, b, entity_id: theirs_entity)

      assert [["unresolved", nil]] =
               raw(
                 "SELECT resolution_state, resolved_entity_id FROM entity_mentions WHERE id = ?1",
                 [
                   mine
                 ]
               )

      assert {:ok, %{decision: :reject}} = decide(mine, :reject, ws, a)
    end

    test "is neither listed nor decided over HTTP by another tenant", %{a: a, b: b, ws: ws} do
      mine = parentless(a, ws, "Pia Park")

      assert {200, %{"items" => items_a}} =
               call(:get, "/api/entities/review?workspace=#{ws}", nil, key(a))

      assert mine in Enum.map(items_a, & &1["id"])

      assert {200, %{"items" => items_b}} =
               call(:get, "/api/entities/review?workspace=#{ws}", nil, key(b))

      refute mine in Enum.map(items_b, & &1["id"])

      assert {422, %{"error" => error}} =
               call(
                 :post,
                 "/api/entity-mentions/#{mine}/decision",
                 %{workspace: ws, decision: "reject"},
                 key(b)
               )

      assert error =~ "mention_not_found"
    end

    test "is repointed by its writer's merge", %{a: a, ws: ws} do
      loser = entity(a, ws, "Quin Quade")
      winner = entity(a, ws, "Quin Q. Quade")
      mine = parentless(a, ws, "Quin Quade")

      assert {:ok, _} = decide(mine, :link, ws, a, entity_id: loser)
      assert {:ok, _} = merge(loser, winner, ws, a)

      assert [[^winner]] =
               raw("SELECT resolved_entity_id FROM entity_mentions WHERE id = ?1", [mine])
    end
  end

  describe "a mention written before the column" do
    test "that names no row is listed to every tenant sharing the workspace, as before",
         %{a: a, b: b, ws: ws, n: n} do
      id = legacy("mnt-legacy-free-#{n}", ws, nil)

      assert tenant_of(id) == nil
      assert id in queued(ws, a)
      assert id in queued(ws, b)
    end

    test "that names a context is the tenant of that context's, as before",
         %{a: a, b: b, ws: ws, n: n} do
      context(a, ws, "mnt-legacy-ctx-#{n}")
      id = legacy("mnt-legacy-owned-#{n}", ws, "mnt-legacy-ctx-#{n}")

      assert id in queued(ws, a)
      refute id in queued(ws, b)
      assert {:error, :mention_not_found} = decide(id, :reject, ws, b)
      assert {:ok, _} = decide(id, :reject, ws, a)
    end
  end

  describe "a single tenant" do
    test "reads and decides its mentions as before", %{ws: ws, n: n} do
      context("default", ws, "mnt-default-ctx-#{n}")

      {:ok, %{id: with_context}} =
        EntityResolution.resolve(%{
          workspace_id: ws,
          surface_text: "Rhea Rowe #{n}",
          context_id: "mnt-default-ctx-#{n}"
        })

      {:ok, %{id: free}} =
        EntityResolution.resolve(%{workspace_id: ws, surface_text: "Sam Shaw #{n}"})

      {:ok, items} = EntityResolution.queue(ws)
      ids = Enum.map(items, & &1.id)
      assert with_context in ids and free in ids

      for id <- [with_context, free] do
        assert {:ok, %{decision: :new_entity, entity_id: entity_id}} =
                 EntityResolution.decide(id, :new_entity,
                   workspace_id: ws,
                   actor_id: "user:reviewer"
                 )

        assert [[tenant]] =
                 raw("SELECT tenant_id FROM canonical_entities WHERE id = ?1", [entity_id])

        assert tenant == "default"
      end

      {:ok, after_items} = EntityResolution.queue(ws)
      refute Enum.any?(after_items, &(&1.id in [with_context, free]))
    end
  end

  describe "migration 74" do
    test "fills the tenant from the context, else the source package, and runs again harmlessly",
         %{a: a, b: b, ws: ws, n: n} do
      context(a, ws, "mnt-bf-ctx-#{n}")
      package_b = package(b, ws, "Package of b #{n}")

      rows = [
        {"mnt-bf-context-#{n}", "mnt-bf-ctx-#{n}", nil, nil},
        {"mnt-bf-package-#{n}", nil, package_b, nil},
        {"mnt-bf-both-#{n}", "mnt-bf-ctx-#{n}", package_b, nil},
        {"mnt-bf-empty-#{n}", "", "", nil},
        {"mnt-bf-gone-#{n}", "mnt-bf-no-such-context-#{n}", nil, nil},
        {"mnt-bf-free-#{n}", nil, nil, nil},
        {"mnt-bf-kept-#{n}", "mnt-bf-ctx-#{n}", nil, "kept-#{n}"}
      ]

      for {id, context_id, package_id, tenant} <- rows do
        raw(
          "INSERT INTO entity_mentions (id, workspace_id, context_id, source_package_id, surface_text, normalized_text, tenant_id) VALUES (?1, ?2, ?3, ?4, 'Name', 'name', ?5)",
          [id, ws, context_id, package_id, tenant]
        )
      end

      {74, _description, statements} = List.keyfind(OptimalEngine.Store.Migrations.all(), 74, 0)

      # Every statement runs twice, as a re-run would: the column add is a
      # duplicate (tolerated, as the migration runner does), the rest change
      # nothing the second time.
      for _run <- 1..2, {label, sql} <- statements do
        case Store.raw_query(sql, []) do
          {:ok, _} -> :ok
          {:error, message} -> assert message =~ "duplicate column", "#{label}: #{message}"
        end
      end

      assert tenant_of("mnt-bf-context-#{n}") == a
      assert tenant_of("mnt-bf-package-#{n}") == b
      # The context comes first when a mention names both.
      assert tenant_of("mnt-bf-both-#{n}") == a
      # A mention that names nothing that exists stays without a tenant.
      assert tenant_of("mnt-bf-empty-#{n}") == nil
      assert tenant_of("mnt-bf-gone-#{n}") == nil
      assert tenant_of("mnt-bf-free-#{n}") == nil
      # A tenant already recorded is not overwritten.
      assert tenant_of("mnt-bf-kept-#{n}") == "kept-#{n}"
    end
  end

  describe "the entity quality report" do
    setup %{a: a, b: b, ws: ws, n: n} do
      entity(a, ws, "Tess Tate #{n}")
      loser = entity(a, ws, "Tess T. Tate #{n}")
      winner = entity(a, ws, "Tess Tate-Wren #{n}")
      assert {:ok, _} = merge(loser, winner, ws, a)

      parentless(a, ws, "Uma Upton #{n}")
      context(a, ws, "mnt-q-ctx-#{n}")

      {:ok, _} =
        EntityResolution.resolve(
          %{workspace_id: ws, surface_text: "Vic Vale #{n}", context_id: "mnt-q-ctx-#{n}"},
          tenant_id: a
        )

      entity(b, ws, "Wes West #{n}")
      parentless(b, ws, "Xan Xu #{n}")
      :ok
    end

    test "counts the caller's entities, mentions and lineage only", %{a: a, b: b, ws: ws} do
      assert {:ok, quality_a} = OptimalEngine.EntityQuality.run(ws, tenant_id: a)
      assert quality_a.unresolved_mentions == 2
      assert quality_a.canonical_entities == 2
      assert quality_a.lineage_events == 1

      assert {:ok, quality_b} = OptimalEngine.EntityQuality.run(ws, tenant_id: b)
      assert quality_b.unresolved_mentions == 1
      assert quality_b.canonical_entities == 1
      assert quality_b.lineage_events == 0
    end

    test "over HTTP answers for the key's tenant", %{a: a, b: b, ws: ws} do
      assert {200, %{"unresolved_mentions" => 2, "canonical_entities" => 2}} =
               call(:get, "/api/entities/quality?workspace=#{ws}", nil, key(a))

      assert {200, %{"unresolved_mentions" => 1, "canonical_entities" => 1, "lineage_events" => 0}} =
               call(:get, "/api/entities/quality?workspace=#{ws}", nil, key(b))
    end

    test "reports a tenant with nothing in the workspace as healthy" do
      tenant = "mnt-empty-#{System.unique_integer([:positive])}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Empty"})
      ws = "shared-mnt-empty-#{System.unique_integer([:positive])}"

      assert {:ok, %{status: "healthy", unresolved_mentions: 0, canonical_entities: 0}} =
               OptimalEngine.EntityQuality.run(ws, tenant_id: tenant)
    end

    test "is the quality the dashboard reports", %{b: b, ws: ws} do
      assert {:ok, %{entity_quality: %{unresolved_mentions: 1, canonical_entities: 1}}} =
               DataSteward.dashboard(ws, tenant_id: b)
    end
  end
end
