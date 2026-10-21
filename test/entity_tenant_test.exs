defmodule OptimalEngine.EntityTenantTest do
  @moduledoc """
  The entity reads and decisions are bound to the caller's tenant. Two
  tenants can share a bare workspace id (one nobody registered), so a
  workspace id alone does not say whose a mention or an entity is: the review
  queue, the candidates a mention is matched with, the dashboard's entity
  clusters, the target of a link or a merge, and an entity read by id all
  look at the tenant as well.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{DataSteward, EntityRegistry, EntityResolution, Store}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    a = "ent-a-#{n}"
    b = "ent-b-#{n}"

    for tenant <- [a, b], do: {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

    %{n: n, a: a, b: b, ws: "shared-ent-#{n}"}
  end

  defp context(tenant, workspace, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, ?4, 'Row', 'Row.', '2026-10-20T09:00:00Z', '{}')",
        [id, tenant, workspace, "optimal://inbox/#{id}.md"]
      )
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

  # A mention of `surface` found in a context of the tenant.
  defp mention(tenant, workspace, surface, n) do
    context_id = "ctx-#{tenant}-#{n}-#{String.replace(surface, " ", "-")}"
    context(tenant, workspace, context_id)

    {:ok, %{id: id}} =
      EntityResolution.resolve(
        %{workspace_id: workspace, surface_text: surface, context_id: context_id},
        tenant_id: tenant
      )

    id
  end

  defp decide(id, decision, workspace, tenant, extra) do
    EntityResolution.decide(
      id,
      decision,
      [workspace_id: workspace, actor_id: "user:reviewer", tenant_id: tenant] ++ extra
    )
  end

  describe "the review queue and the entity clusters" do
    test "list the tenant's own mentions of a workspace both use", %{a: a, b: b, ws: ws, n: n} do
      mine = mention(a, ws, "Alice Anders", n)
      theirs = mention(b, ws, "Bob Brandt", n)

      assert {:ok, queue} = EntityResolution.queue(ws, tenant_id: a)
      ids = Enum.map(queue, & &1.id)
      assert mine in ids
      refute theirs in ids

      assert {:ok, clusters} = DataSteward.entity_clusters(ws, a)
      mentions = Enum.flat_map(clusters, & &1.mentions)
      assert mine in Enum.map(mentions, & &1.id)
      refute theirs in Enum.map(mentions, & &1.id)

      assert {:ok, other} = EntityResolution.queue(ws, tenant_id: b)
      assert theirs in Enum.map(other, & &1.id)
      refute mine in Enum.map(other, & &1.id)
    end

    test "the dashboard clusters only the tenant's mentions", %{a: a, b: b, ws: ws, n: n} do
      theirs = mention(b, ws, "Bob Brandt", n)

      assert {:ok, %{entity_clusters: clusters}} = DataSteward.dashboard(ws, tenant_id: a)
      refute theirs in (clusters |> Enum.flat_map(& &1.mentions) |> Enum.map(& &1.id))
    end
  end

  describe "the candidates a mention is matched with" do
    test "are the tenant's entities, not another tenant's in the same workspace",
         %{a: a, b: b, ws: ws, n: n} do
      mine = entity(a, ws, "Casey Cole #{n}")
      theirs = entity(b, ws, "Casey Cole #{n}")

      assert {:ok, %{candidates: candidates}} =
               EntityResolution.resolve(
                 %{workspace_id: ws, surface_text: "Casey Cole #{n}"},
                 tenant_id: b
               )

      assert Enum.map(candidates, & &1.id) == [theirs]
      refute mine in Enum.map(candidates, & &1.id)
    end
  end

  describe "linking a mention" do
    test "to an entity of another tenant, or of another workspace, is refused",
         %{a: a, b: b, ws: ws, n: n} do
      mention_id = mention(a, ws, "Dana Dee", n)
      foreign = entity(b, ws, "Dana Dee #{n}")
      elsewhere = entity(a, "other-ws-#{n}", "Dana Dee #{n}")
      own = entity(a, ws, "Dana Dee #{n}")

      assert {:error, :entity_not_found} =
               decide(mention_id, :link, ws, a, entity_id: foreign)

      assert {:error, :entity_not_found} =
               decide(mention_id, :link, ws, a, entity_id: elsewhere)

      assert {:ok, [["unresolved"]]} =
               Store.raw_query("SELECT resolution_state FROM entity_mentions WHERE id = ?1", [
                 mention_id
               ])

      assert {:ok, %{entity_id: ^own}} = decide(mention_id, :link, ws, a, entity_id: own)
    end
  end

  describe "linking a mention to an entity id that is not text" do
    test "is refused, not skipped", %{a: a, ws: ws, n: n} do
      mention_id = mention(a, ws, "Hal Hart", n)

      for entity_id <- [12_345, 1.5, true, %{"id" => "x"}, ["x"]] do
        assert {:error, :entity_not_found} =
                 decide(mention_id, :link, ws, a, entity_id: entity_id)
      end

      assert {:error, :entity_id_required} = decide(mention_id, :link, ws, a, entity_id: nil)

      assert {:ok, [["unresolved"]]} =
               Store.raw_query("SELECT resolution_state FROM entity_mentions WHERE id = ?1", [
                 mention_id
               ])
    end

    test "is refused over HTTP too", %{a: a, ws: ws, n: n} do
      mention_id = mention(a, ws, "Ida Ives", n)

      assert {422, %{"error" => error}} =
               call(
                 :post,
                 "/api/entity-mentions/#{mention_id}/decision",
                 %{workspace: ws, decision: "link", entity_id: 12_345},
                 key(a)
               )

      assert error =~ "entity_not_found"
    end
  end

  describe "merging" do
    test "repoints the tenant's mentions of the loser and not another tenant's",
         %{a: a, b: b, ws: ws, n: n} do
      loser = entity(a, ws, "Jo Jay #{n}")
      winner = entity(a, ws, "Joanne Jay #{n}")
      mine = mention(a, ws, "Jo Jay", n)
      theirs = mention(b, ws, "J. Jay", n)

      # Both mentions were resolved to the loser (the other tenant's by an
      # earlier version, which did not check the entity it was linked to).
      for id <- [mine, theirs] do
        {:ok, _} =
          Store.raw_query(
            "UPDATE entity_mentions SET resolved_entity_id = ?1, resolution_state = 'linked' WHERE id = ?2",
            [loser, id]
          )
      end

      assert {:ok, _} =
               EntityRegistry.merge(loser, winner,
                 workspace_id: ws,
                 tenant_id: a,
                 actor_id: "user:reviewer",
                 reason: "same person"
               )

      resolved = fn id ->
        {:ok, [[entity_id]]} =
          Store.raw_query("SELECT resolved_entity_id FROM entity_mentions WHERE id = ?1", [id])

        entity_id
      end

      assert resolved.(mine) == winner
      assert resolved.(theirs) == loser
    end

    test "into or out of an entity of another tenant is refused, and nothing changes",
         %{a: a, b: b, ws: ws, n: n} do
      mine = entity(a, ws, "Eli Ewing #{n}")
      also_mine = entity(a, ws, "Eli E. #{n}")
      theirs = entity(b, ws, "Eli Ewing #{n}")

      merge = fn loser, winner, tenant ->
        EntityRegistry.merge(loser, winner,
          workspace_id: ws,
          tenant_id: tenant,
          actor_id: "user:reviewer",
          reason: "same person"
        )
      end

      assert {:error, :entity_not_found} = merge.(mine, theirs, a)
      assert {:error, :entity_not_found} = merge.(theirs, mine, a)
      assert {:ok, %{lifecycle_state: "active"}} = EntityRegistry.get(mine, ws, tenant_id: a)
      assert {:ok, %{lifecycle_state: "active"}} = EntityRegistry.get(theirs, ws, tenant_id: b)

      assert {:ok, %{merged: ^mine, into: ^also_mine}} = merge.(mine, also_mine, a)
    end
  end

  describe "reading an entity" do
    test "by id finds the tenant's and not another tenant's in the same workspace",
         %{a: a, b: b, ws: ws, n: n} do
      mine = entity(a, ws, "Fran Fox #{n}")

      assert {:ok, %{id: ^mine}} = EntityRegistry.get(mine, ws, tenant_id: a)
      assert {:error, :not_found} = EntityRegistry.get(mine, ws, tenant_id: b)

      mine_other = entity(a, ws, "Fran F. #{n}")

      assert {:ok, _} =
               EntityRegistry.merge(mine, mine_other,
                 workspace_id: ws,
                 tenant_id: a,
                 actor_id: "user:reviewer",
                 reason: "same person"
               )

      assert {:ok, [_]} = EntityRegistry.history(mine, ws, tenant_id: a)
      assert {:ok, []} = EntityRegistry.history(mine, ws, tenant_id: b)
    end
  end

  describe "over HTTP" do
    defp key(tenant) do
      {:ok, %{key: key}} =
        ApiKey.mint(%{
          tenant_id: tenant,
          name: "entities",
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

    test "another tenant sharing the workspace id finds none of it", %{a: a, b: b, ws: ws, n: n} do
      mine = entity(a, ws, "Gil Grant #{n}")
      other = entity(a, ws, "Gil G. #{n}")
      mention_id = mention(a, ws, "Gil Grant", n)

      assert {200, %{"id" => ^mine}} =
               call(:get, "/api/entities/#{mine}?workspace=#{ws}", nil, key(a))

      assert {404, _} = call(:get, "/api/entities/#{mine}?workspace=#{ws}", nil, key(b))
      assert {404, _} = call(:get, "/api/entities/#{mine}/projection?workspace=#{ws}", nil, key(b))

      assert {200, %{"history" => []}} =
               call(:get, "/api/entities/#{mine}/history?workspace=#{ws}", nil, key(b))

      assert {200, %{"items" => items}} =
               call(:get, "/api/entities/review?workspace=#{ws}", nil, key(b))

      refute mention_id in Enum.map(items, & &1["id"])

      assert {422, %{"error" => foreign_merge}} =
               call(
                 :post,
                 "/api/entities/#{mine}/merge",
                 %{workspace: ws, winner_entity_id: other},
                 key(b)
               )

      assert foreign_merge =~ "entity_not_found"

      assert {422, %{"error" => foreign_link}} =
               call(
                 :post,
                 "/api/entity-mentions/#{mention_id}/decision",
                 %{workspace: ws, decision: "link", entity_id: mine},
                 key(b)
               )

      assert foreign_link =~ "mention_not_found"
    end
  end
end
