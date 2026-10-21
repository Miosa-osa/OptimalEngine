defmodule OptimalEngine.GraphTenantTest do
  @moduledoc """
  The graph routes show a key the contexts of its own tenant. Two tenants can
  share a bare workspace id, and the graph is read through the contexts table:
  every node, edge, entity count and analysis has to be limited to the
  tenant's contexts, or one tenant sees the other's titles, abstracts, links
  and entity names.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    a = "graph-a-#{n}"
    b = "graph-b-#{n}"
    ws = "shared-graph-#{n}"

    for tenant <- [a, b], do: {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

    # Each tenant has two contexts in the same node, both mentioning the same
    # two entities, joined by a link: the shape every graph query looks at.
    for {tenant, tag} <- [{a, "a"}, {b, "b"}] do
      ids = for i <- 1..2, do: "g-#{tag}#{i}-#{n}"

      for id <- ids do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO contexts (id, tenant_id, workspace_id, node, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, 'notes', ?4, ?5, 'Body.', '2026-10-20T09:00:00Z', '{}')",
            [id, tenant, ws, "optimal://notes/#{id}.md", "Title of #{id}"]
          )

        for name <- ["Acme", "Bolt"] do
          {:ok, _} =
            Store.raw_query(
              "INSERT INTO entities (context_id, name, type, workspace_id) VALUES (?1, ?2, 'organization', ?3)",
              [id, name, ws]
            )
        end
      end

      [first, second] = ids

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO edges (source_id, target_id, relation, weight, workspace_id) VALUES (?1, ?2, 'related', 1.0, ?3)",
          [first, second, ws]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO edges (source_id, target_id, relation, weight, workspace_id) VALUES (?1, 'notes', 'cross_ref', 1.0, ?2)",
          [first, ws]
        )
    end

    %{n: n, a: a, b: b, ws: ws}
  end

  defp key(tenant) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "graph",
        scopes: ["read"],
        workspace_scope: ["*"]
      })

    key
  end

  defp get(path, token) do
    response =
      conn(:get, path)
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    {response.status, Jason.decode!(response.resp_body)}
  end

  defp mine?(id, tag), do: String.starts_with?(id, "g-#{tag}")

  describe "GET /api/graph" do
    test "shows the key's tenant's contexts, links, entities and nodes only",
         %{a: a, b: b, ws: ws} do
      assert {200, graph} = get("/api/graph?workspace=#{ws}", key(a))

      assert length(graph["contexts"]) == 2
      assert Enum.all?(graph["contexts"], &mine?(&1["id"], "a"))

      assert graph["edges"] != []

      assert Enum.all?(graph["edges"], fn edge ->
               mine?(edge["source"], "a") and mine?(edge["target"], "a")
             end)

      # Two contexts of the tenant mention each of the two entities.
      assert Enum.sort(Enum.map(graph["entities"], & &1["name"])) == ["Acme", "Bolt"]
      assert Enum.all?(graph["entities"], &(&1["count"] == 2))
      assert [%{"node" => "notes", "context_count" => 2}] = graph["nodes"]
      assert graph["stats"]["context_count"] == 2

      assert {200, other} = get("/api/graph?workspace=#{ws}", key(b))
      assert Enum.all?(other["contexts"], &mine?(&1["id"], "b"))
    end
  end

  describe "the node and optimal graph routes" do
    test "show the key's tenant's contexts only", %{a: a, ws: ws} do
      assert {200, %{"contexts" => contexts, "edges" => edges}} =
               get("/api/node/notes?workspace=#{ws}", key(a))

      assert length(contexts) == 2
      assert Enum.all?(contexts, &mine?(&1["id"], "a"))
      assert edges != []
      assert Enum.all?(edges, &(mine?(&1["source"], "a") or mine?(&1["target"], "a")))

      assert {200, %{"entities" => entities, "edges" => relations}} =
               get("/api/optimal/graph?workspace=#{ws}", key(a))

      assert Enum.all?(entities, &(&1["connections"] == 2))
      # Acme and Bolt appear together in two contexts of the tenant.
      assert relations != []
      assert Enum.all?(relations, &(&1["weight"] == 2.0))

      assert {200, %{"files" => files}} =
               get("/api/optimal/nodes/notes/files?workspace=#{ws}", key(a))

      assert length(files) == 2
      assert Enum.all?(files, &String.contains?(&1["path"], "g-a"))
    end
  end

  describe "the reflection of entity gaps" do
    test "counts the key's tenant's contexts only", %{a: a, ws: ws} do
      assert {200, %{"gaps" => gaps}} = get("/api/graph/reflect?workspace=#{ws}&min=2", key(a))
      assert [%{"cooccurrences" => 2}] = Enum.filter(gaps, &(&1["source"] == "Acme"))
    end
  end
end
