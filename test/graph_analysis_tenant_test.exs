defmodule OptimalEngine.GraphAnalysisTenantTest do
  @moduledoc """
  The graph analyses (hubs, triangles, clusters, reflect) answer only for a
  workspace that is registered to the caller's tenant, and read its graph
  edges in that tenant. A workspace id that nobody registered can be written
  by two tenants at once: every member list, hub name and context id would
  cross if it were read for either.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Organization, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @routes ["hubs", "triangles", "clusters", "reflect"]

  setup do
    n = System.unique_integer([:positive])
    a = "ana-a-#{n}"
    b = "ana-b-#{n}"
    shared = "shared-ana-#{n}"

    ops =
      for tenant <- [a, b], into: %{} do
        {:ok, _} = Tenant.create(%{id: tenant, name: "Tenant #{tenant}"})

        {:ok, workspace} =
          Workspace.create(%{
            tenant_id: tenant,
            organization_id: Organization.default_for(tenant),
            slug: "ops",
            name: "Ops"
          })

        {tenant, workspace.id}
      end

    # A tenant's graph in a workspace: a hub with twelve neighbours that are
    # not linked to each other (hubs, open triangles and one cluster), and two
    # contexts that mention the same two entities (a gap to reflect on).
    for {tenant, tag} <- [{a, "a"}, {b, "b"}],
        {workspace, where} <- [{shared, "s"}, {ops[tenant], "r"}] do
      hub = "hub-#{tag}-#{where}-#{n}"

      for i <- 1..12, do: edge(hub, "leaf-#{tag}#{i}-#{where}-#{n}", workspace, tenant)

      for i <- 1..2 do
        id = "ctx-#{tag}#{i}-#{where}-#{n}"

        {:ok, _} =
          Store.raw_query(
            "INSERT INTO contexts (id, tenant_id, workspace_id, node, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, 'notes', ?4, 'Title', 'Body.', '2026-10-20T09:00:00Z', '{}')",
            [id, tenant, workspace, "optimal://notes/#{id}.md"]
          )

        for name <- ["Acme #{tag}", "Bolt #{tag}"] do
          {:ok, _} =
            Store.raw_query(
              "INSERT INTO entities (context_id, name, type, workspace_id) VALUES (?1, ?2, 'organization', ?3)",
              [id, name, workspace]
            )
        end
      end
    end

    %{n: n, a: a, b: b, shared: shared, ops: ops}
  end

  defp edge(source, target, workspace, tenant) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO graph_edges (source_id, target_id, relation, weight, workspace_id, tenant_id) VALUES (?1, ?2, 'related', 1.0, ?3, ?4)",
        [source, target, workspace, tenant]
      )
  end

  defp key(tenant) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "analysis",
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

    {response.status, response.resp_body}
  end

  describe "a workspace id nobody registered" do
    test "answers none of the analyses, whoever asks and whoever wrote under it",
         %{a: a, b: b, shared: shared} do
      for tenant <- [a, b], route <- @routes do
        path = "/api/graph/#{route}?workspace=#{shared}&min=1"

        assert {404, body} = get(path, key(tenant))
        assert Jason.decode!(body) == %{"error" => "workspace not found"}, path
      end
    end
  end

  describe "a workspace registered to the caller's tenant" do
    test "shows its own hubs, triangles, clusters and gaps and not the other tenant's",
         %{a: a, b: b, n: n, ops: ops} do
      for {tenant, tag, other} <- [{a, "a", "b"}, {b, "b", "a"}] do
        workspace = ops[tenant]

        assert {200, hubs} = get("/api/graph/hubs?workspace=#{workspace}", key(tenant))
        assert hubs =~ "hub-#{tag}-r-#{n}"
        refute hubs =~ "-#{other}-"

        assert {200, triangles} =
                 get("/api/graph/triangles?workspace=#{workspace}", key(tenant))

        assert triangles =~ "hub-#{tag}-r-#{n}"
        refute triangles =~ "-#{other}-"

        assert {200, clusters} = get("/api/graph/clusters?workspace=#{workspace}", key(tenant))
        assert clusters =~ "leaf-#{tag}1-r-#{n}"
        refute clusters =~ "-#{other}-"

        assert {200, gaps} = get("/api/graph/reflect?workspace=#{workspace}&min=2", key(tenant))
        assert gaps =~ "Acme #{tag}"
        refute gaps =~ "Acme #{other}"
      end
    end

    test "is not shown to a key of another tenant", %{a: a, b: b, ops: ops} do
      for route <- @routes do
        assert {404, _} = get("/api/graph/#{route}?workspace=#{ops[a]}", key(b))
      end
    end
  end

  describe "the default workspace of the default tenant" do
    test "still answers every analysis" do
      for route <- @routes do
        assert {200, _} = get("/api/graph/#{route}", key("default"))
      end
    end
  end

  describe "triangles" do
    test "never returns more than a hundred, whatever the limit", %{a: a, ops: ops} do
      # Twelve unlinked neighbours of one hub make 132 open triangles.
      assert {200, all} =
               get("/api/graph/triangles?workspace=#{ops[a]}&limit=100000", key(a))

      assert length(Jason.decode!(all)["triangles"]) == 100

      assert {200, few} = get("/api/graph/triangles?workspace=#{ops[a]}&limit=5", key(a))
      assert length(Jason.decode!(few)["triangles"]) == 5
    end
  end
end
