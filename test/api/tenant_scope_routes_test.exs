defmodule OptimalEngine.API.TenantScopeRoutesTest do
  @moduledoc """
  The graph, node and batch export routes read the requester's tenant as well
  as the requested workspace.

  Two tenants and the default tenant keep rows under one bare, unregistered
  workspace id. A caller reads only its own tenant's rows there: the default
  tenant's anonymously, another tenant's with its key. On a registered
  workspace, another tenant's key is answered 404.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.RateLimiter
  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Context
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Memory
  alias OptimalEngine.Organization
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  @opts Router.init([])

  setup do
    RateLimiter.reset()
    n = Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    tenant_a = "tsr-a-#{n}"
    tenant_b = "tsr-b-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant_a, name: "A #{n}"})
    {:ok, _} = Tenant.create(%{id: tenant_b, name: "B #{n}"})
    shared = "shared-#{n}"

    foreign_row!("ctx-a-#{n}", tenant_a, shared, "AlphaEnt#{n}")
    foreign_row!("ctx-b-#{n}", tenant_b, shared, "BravoEnt#{n}")
    own = own_row!("ctx-d-#{n}", shared, "DeltaEnt#{n}")

    {:ok, _} =
      Memory.create(%{tenant_id: tenant_a, workspace_id: shared, content: "memalpha#{n} north"})

    {:ok, _} =
      Memory.create(%{tenant_id: tenant_b, workspace_id: shared, content: "membravo#{n} south"})

    {:ok, _} = Memory.create(%{workspace_id: shared, content: "memdelta#{n} east"})

    %{
      n: n,
      tenant_a: tenant_a,
      tenant_b: tenant_b,
      shared: shared,
      own: own,
      key_b: key(tenant_b, [shared], "agent:tsr-b-#{n}"),
      foreign: ["ctx-a-#{n}", "ctx-b-#{n}", "AlphaEnt#{n}", "BravoEnt#{n}"]
    }
  end

  # A row another tenant keeps under the bare id: a context, its entity and
  # its graph edges, all carrying that tenant.
  defp foreign_row!(id, tenant, workspace, entity) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, node, entities,
                              created_at, modified_at)
        VALUES (?1, ?2, ?3, 'signal', ?1, 'tenant row', 'notes', ?4,
                '2026-10-20T10:00:00Z', '2026-10-20T10:00:00Z')
        """,
        [id, tenant, workspace, Jason.encode!([entity])]
      )

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO entities (context_id, name, type, tenant_id, workspace_id) VALUES (?1, ?2, 'person', ?3, ?4)",
        [id, entity, tenant, workspace]
      )

    for {source, target, relation} <- [{entity, id, "mentioned_in"}, {id, "notes", "lives_in"}] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO graph_edges (tenant_id, workspace_id, source_id, target_id, relation) VALUES (?1, ?2, ?3, ?4, ?5)",
          [tenant, workspace, source, target, relation]
        )
    end
  end

  # A row written the ordinary way: it takes the workspace's tenant, the
  # default tenant's for a bare unregistered id.
  defp own_row!(id, workspace, entity) do
    now = DateTime.utc_now()

    :ok =
      Store.insert_context(%Context{
        id: id,
        uri: "optimal://nodes/notes/#{id}.md",
        type: :signal,
        path: "/tmp/#{id}.md",
        title: id,
        content: "default row",
        l0_abstract: "SIGNAL | note | #{id}",
        l1_overview: "overview",
        node: "notes",
        sn_ratio: 0.7,
        entities: [entity],
        created_at: now,
        modified_at: now,
        routed_to: [],
        workspace_id: workspace,
        metadata: %{}
      })

    id
  end

  defp key(tenant, workspaces, principal) do
    {:ok, _} =
      Principal.upsert(%{id: principal, tenant_id: tenant, kind: :agent, display_name: principal})

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "tenant-scope-routes-test",
        scopes: ["read", "write"],
        workspace_scope: workspaces,
        principal_id: principal
      })

    token
  end

  defp get(path, token \\ nil) do
    conn = conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp post(path, payload, token) do
    conn(:post, path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(@opts)
  end

  defp body(conn) do
    assert conn.status == 200, "#{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp refute_foreign(text, ctx) do
    for id <- ctx.foreign, do: refute(text =~ id, "#{id} leaked")
  end

  test "GET /api/graph shows only the caller's tenant", ctx do
    body = get("/api/graph?workspace=#{ctx.shared}") |> body()

    assert Enum.map(body["contexts"], & &1["id"]) == [ctx.own]
    assert Enum.map(body["entities"], & &1["name"]) == ["DeltaEnt#{ctx.n}"]
    refute_foreign(Jason.encode!(body), ctx)
  end

  test "GET /api/node/:id shows only the caller's tenant", ctx do
    body = get("/api/node/notes?workspace=#{ctx.shared}") |> body()

    assert Enum.map(body["contexts"], & &1["id"]) == [ctx.own]
    assert body["edges"] != []
    refute_foreign(Jason.encode!(body), ctx)
  end

  test "GET /api/optimal/graph shows only the caller's tenant", ctx do
    body = get("/api/optimal/graph?workspace=#{ctx.shared}") |> body()

    assert Enum.map(body["entities"], & &1["name"]) == ["DeltaEnt#{ctx.n}"]
    refute_foreign(Jason.encode!(body), ctx)
  end

  test "GET /api/batch/export/signals and /memories export only the caller's tenant", ctx do
    signals = get("/api/batch/export/signals?workspace=#{ctx.shared}") |> body()
    assert Enum.map(signals["signals"], & &1["id"]) == [ctx.own]

    memories = get("/api/batch/export/memories?workspace=#{ctx.shared}") |> body()
    contents = Enum.map_join(memories["memories"], "\n", & &1["content"])
    assert contents =~ "memdelta#{ctx.n}"
    refute contents =~ "memalpha#{ctx.n}"
    refute contents =~ "membravo#{ctx.n}"
  end

  test "another tenant's key reads only its own rows under the bare workspace id", ctx do
    body = get("/api/graph?workspace=#{ctx.shared}", ctx.key_b) |> body()
    assert Enum.map(body["contexts"], & &1["id"]) == ["ctx-b-#{ctx.n}"]
    assert Enum.map(body["entities"], & &1["name"]) == ["BravoEnt#{ctx.n}"]

    node = get("/api/node/notes?workspace=#{ctx.shared}", ctx.key_b) |> body()
    assert Enum.map(node["contexts"], & &1["id"]) == ["ctx-b-#{ctx.n}"]
    assert node["edges"] != []
    refute Jason.encode!(node) =~ "ctx-a-#{ctx.n}"
    refute Jason.encode!(node) =~ ctx.own

    signals = get("/api/batch/export/signals?workspace=#{ctx.shared}", ctx.key_b) |> body()
    assert Enum.map(signals["signals"], & &1["id"]) == ["ctx-b-#{ctx.n}"]

    memories = get("/api/batch/export/memories?workspace=#{ctx.shared}", ctx.key_b) |> body()
    contents = Enum.map_join(memories["memories"], "\n", & &1["content"])
    assert contents =~ "membravo#{ctx.n}"
    refute contents =~ "memalpha#{ctx.n}"
    refute contents =~ "memdelta#{ctx.n}"
  end

  test "another tenant's key gets 404 on a registered workspace's graph, node and export routes",
       ctx do
    {:ok, ws} =
      Workspace.create(%{
        tenant_id: ctx.tenant_a,
        organization_id: Organization.default_for(ctx.tenant_a),
        slug: "notes",
        name: "Notes"
      })

    id = own_row!("ctx-reg-#{ctx.n}", ws.id, "EchoEnt#{ctx.n}")
    key_a = key(ctx.tenant_a, [ws.id], "agent:tsr-a-#{ctx.n}")
    # Every workspace is in this key's scope, so only the tenant refuses it.
    key_b = key(ctx.tenant_b, ["*"], "agent:tsr-b-all-#{ctx.n}")

    for path <- [
          "/api/graph",
          "/api/graph/hubs",
          "/api/graph/triangles",
          "/api/graph/clusters",
          "/api/graph/reflect",
          "/api/node/notes",
          "/api/optimal/graph",
          "/api/batch/export/signals",
          "/api/batch/export/memories",
          "/api/batch/export/workspace"
        ] do
      conn = get("#{path}?workspace=#{ws.id}", key_b)
      assert conn.status == 404, "#{path}: #{conn.status} #{conn.resp_body}"
    end

    body = get("/api/graph?workspace=#{ws.id}", key_a) |> body()
    assert Enum.map(body["contexts"], & &1["id"]) == [id]
    assert Enum.map(body["entities"], & &1["name"]) == ["EchoEnt#{ctx.n}"]

    # Its own tenant's key imports memories into it and exports it whole.
    memories = %{"workspace" => ws.id, "memories" => [%{"content" => "memecho#{ctx.n} west"}]}
    assert %{"imported" => 1} = post("/api/batch/import/memories", memories, key_a) |> body()

    snapshot = get("/api/batch/export/workspace?workspace=#{ws.id}", key_a) |> body()
    assert snapshot["tenant_id"] == ctx.tenant_a
    assert Enum.map(snapshot["signals"], & &1["id"]) == [id]
    assert Enum.map(snapshot["memories"], & &1["content"]) == ["memecho#{ctx.n} west"]
  end
end
