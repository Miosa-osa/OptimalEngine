defmodule OptimalEngine.RelationshipTenantTest do
  @moduledoc """
  A relationship is recorded for the tenant that makes it, between entities of
  that tenant. Two tenants can share a bare workspace id, so the workspace id
  does not say whose an entity is: relating another tenant's entities is
  refused as if they were absent, and the edge carries its own tenant, not a
  fixed `default`.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{EntityRegistry, RelationshipRegistry, Store}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    a = "rel-a-#{n}"
    b = "rel-b-#{n}"

    for tenant <- [a, b], do: {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

    %{n: n, a: a, b: b, ws: "shared-rel-#{n}"}
  end

  defp entity(tenant, workspace, kind, name) do
    {:ok, %{id: id}} =
      EntityRegistry.register(%{
        tenant_id: tenant,
        workspace_id: workspace,
        entity_kind: kind,
        canonical_name: name,
        created_by: "test"
      })

    id
  end

  # A person and an organization of the tenant.
  defp pair(tenant, workspace, n) do
    {entity(tenant, workspace, "person", "Person #{tenant} #{n}"),
     entity(tenant, workspace, "organization", "Org #{tenant} #{n}")}
  end

  defp relationship(workspace, from, to) do
    %{
      workspace_id: workspace,
      from_entity_id: from,
      relationship_type: "member_of",
      to_entity_id: to,
      actor_id: "test:reviewer"
    }
  end

  defp edge_tenant(id) do
    {:ok, [[tenant]]} =
      Store.raw_query("SELECT tenant_id FROM relationship_edges WHERE id = ?1", [id])

    tenant
  end

  describe "relate" do
    test "records the edge under the tenant that makes it", %{a: a, b: b, ws: ws, n: n} do
      {person_a, org_a} = pair(a, ws, n)
      {person_b, org_b} = pair(b, ws, n)

      assert {:ok, %{id: edge_a}} =
               RelationshipRegistry.relate(relationship(ws, person_a, org_a), tenant_id: a)

      assert {:ok, %{id: edge_b}} =
               RelationshipRegistry.relate(relationship(ws, person_b, org_b), tenant_id: b)

      assert edge_tenant(edge_a) == a
      assert edge_tenant(edge_b) == b
    end

    test "refuses entities of another tenant that share the workspace id",
         %{a: a, b: b, ws: ws, n: n} do
      {person_a, org_a} = pair(a, ws, n)
      {_person_b, org_b} = pair(b, ws, n)

      assert {:error, :not_found} =
               RelationshipRegistry.relate(relationship(ws, person_a, org_a), tenant_id: b)

      # One end that is the tenant's and one that is not.
      assert {:error, :not_found} =
               RelationshipRegistry.relate(relationship(ws, person_a, org_b), tenant_id: a)

      assert {:ok, [[0]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM relationship_edges WHERE from_object_id = ?1",
                 [person_a]
               )
    end

    test "without a tenant still records under the default tenant", %{ws: ws, n: n} do
      {person, org} = pair("default", ws, n)

      assert {:ok, %{id: edge}} = RelationshipRegistry.relate(relationship(ws, person, org))
      assert edge_tenant(edge) == "default"
    end
  end

  describe "over HTTP" do
    defp key(tenant) do
      {:ok, %{key: key}} =
        ApiKey.mint(%{
          tenant_id: tenant,
          name: "relationships",
          scopes: ["read", "topology:write"],
          workspace_scope: ["*"]
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

    test "the key's tenant relates its own entities and not another tenant's",
         %{a: a, b: b, ws: ws, n: n} do
      {person_a, org_a} = pair(a, ws, n)
      body = relationship(ws, person_a, org_a) |> Map.delete(:actor_id)

      assert {422, %{"error" => error}} = post("/api/entity-relationships", body, key(b))
      assert error =~ "not_found"

      assert {201, %{"id" => edge}} = post("/api/entity-relationships", body, key(a))
      assert edge_tenant(edge) == a
    end
  end
end
