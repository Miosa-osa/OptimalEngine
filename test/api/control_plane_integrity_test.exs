defmodule OptimalEngine.API.ControlPlaneIntegrityTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias OptimalEngine.{Memory, MemoryCore, Organization, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.API.Router

  setup do
    workspace = "default:control-plane-#{System.unique_integer([:positive])}"
    {:ok, _} = Memory.create(%{content: "Unreviewed observation", workspace_id: workspace})
    {:ok, [claim]} = MemoryCore.pending_claims(workspace_id: workspace)
    %{workspace: workspace, claim: claim}
  end

  defp request(path, body, token \\ nil) do
    connection =
      conn(:post, path, Jason.encode!(body)) |> put_req_header("content-type", "application/json")

    connection =
      if token,
        do: put_req_header(connection, "authorization", "Bearer " <> token),
        else: connection

    Router.call(connection, Router.init([]))
  end

  defp key(workspace, scopes) do
    {:ok, _} =
      OptimalEngine.Identity.Principal.upsert(%{
        id: "reviewer:authenticated",
        tenant_id: "default",
        kind: :user,
        display_name: "Reviewer"
      })

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        name: "integrity",
        tenant_id: "default",
        workspace_scope: [workspace],
        scopes: scopes,
        principal_id: "reviewer:authenticated"
      })

    token
  end

  test "observation writer cannot promote by supplying a reviewer identity", %{
    workspace: workspace,
    claim: claim
  } do
    token = key(workspace, ["write"])

    response =
      request(
        "/api/memory-core/claims/#{claim.id}/promote",
        %{workspace: workspace, actor_id: "user:admin", verifier_id: "user:admin"},
        token
      )

    assert response.status == 403

    assert {:ok, [[0]]} =
             Store.raw_query("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1", [workspace])
  end

  test "anonymous observation cannot use implicit anonymous identity as approval", %{
    workspace: workspace,
    claim: claim
  } do
    response = request("/api/memory-core/claims/#{claim.id}/promote", %{workspace: workspace})
    assert response.status == 403
  end

  test "authenticated reviewer cannot impersonate another verifier", %{
    workspace: workspace,
    claim: claim
  } do
    token = key(workspace, ["claims:review"])

    response =
      request(
        "/api/memory-core/claims/#{claim.id}/promote",
        %{workspace: workspace, verifier_id: "user:admin"},
        token
      )

    assert response.status == 403
  end

  test "explicit reviewer can promote persisted evidence", %{workspace: workspace, claim: claim} do
    token = key(workspace, ["claims:review"])

    response =
      request("/api/memory-core/claims/#{claim.id}/promote", %{workspace: workspace}, token)

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["fact"]["verifier_id"] == "reviewer:authenticated"
  end

  test "read-only key cannot mutate topology or import observations", %{workspace: workspace} do
    token = key(workspace, ["read"])

    for {path, body} <- [
          {"/api/nodes", %{workspace: workspace, name: "Injected", kind: "team"}},
          {"/api/batch/import/memories",
           %{workspace: workspace, memories: [%{content: "injected"}]}}
        ] do
      assert request(path, body, token).status == 403
    end
  end

  test "alternate batch intake cannot label an observation as canonical truth", %{
    workspace: workspace
  } do
    token = key(workspace, ["write"])

    response =
      request(
        "/api/batch/import/memories",
        %{
          workspace: workspace,
          memories: [
            %{
              content: "Unverified imported inference",
              status: "accepted",
              verification_status: "verified",
              fact_type: "fact",
              actor_id: "user:admin"
            }
          ]
        },
        token
      )

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["imported"] == 1

    assert {:ok, [[0]]} =
             Store.raw_query("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1", [workspace])

    assert {:ok, claims} = MemoryCore.pending_claims(workspace_id: workspace)
    assert Enum.any?(claims, &(&1.claim_text == "Unverified imported inference"))
  end

  test "write grant cannot mint broader grants or bypass review with trailing slash", %{
    workspace: workspace,
    claim: claim
  } do
    token = key(workspace, ["write"])
    assert request("/api/auth/keys", %{name: "escalated", scopes: ["*"]}, token).status == 403

    assert request(
             "/api/memory-core/claims/#{claim.id}/promote/",
             %{workspace: workspace, actor_id: "user:admin"},
             token
           ).status == 403
  end

  test "ordinary writer cannot reach alternate topology and policy mutations", %{
    workspace: workspace
  } do
    token = key(workspace, ["write"])

    for path <- [
          "/api/organizations",
          "/api/entities",
          "/api/entities/missing/merge",
          "/api/entity-mentions",
          "/api/entity-mentions/missing/decision",
          "/api/entity-relationships",
          "/api/review/routing/missing",
          "/api/data-steward/routes/decide",
          "/api/maintenance/corpus-organization"
        ] do
      assert request(path, %{workspace: workspace}, token).status == 403, path
    end

    connection =
      conn(:put, "/api/storage/workspaces/#{workspace}/policy", Jason.encode!(%{use_cases: []}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert connection.status == 403
  end

  test "read grant can use retrieval POST without mutation authority", %{workspace: workspace} do
    token = key(workspace, ["read"])

    response =
      request(
        "/api/rag",
        %{
          workspace: workspace,
          query: "observation",
          skip_intent: true,
          skip_wiki: true,
          hybrid_limit: 2
        },
        token
      )

    assert response.status == 200
  end

  test "authenticated callers cannot replace their tenant through query or body", %{
    workspace: workspace
  } do
    token = key(workspace, ["*"])

    response =
      conn(:get, "/api/workspaces?tenant=foreign-tenant")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert response.status == 403

    assert request(
             "/api/organizations",
             %{tenant: "foreign-tenant", slug: "injected", name: "Injected"},
             token
           ).status == 403
  end

  test "a foreign tenant on a search is refused, as tenant or tenant_id", %{workspace: workspace} do
    token = key(workspace, ["read"])

    for field <- ["tenant", "tenant_id"] do
      response =
        conn(
          :get,
          "/api/search?" <>
            URI.encode_query(%{
              "q" => "observation",
              "workspace" => workspace,
              field => "foreign-tenant"
            })
        )
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init([]))

      assert response.status == 403
      assert Jason.decode!(response.resp_body)["error"] == "tenant_scope_denied"
    end
  end

  test "a write whose body names a foreign tenant_id is refused before it writes", %{
    workspace: workspace
  } do
    token = key(workspace, ["write"])
    content = "Written into another tenant #{System.unique_integer([:positive])}"

    response =
      request(
        "/api/memory",
        %{content: content, workspace: workspace, tenant_id: "foreign-tenant"},
        token
      )

    assert response.status == 403
    assert Jason.decode!(response.resp_body)["error"] == "tenant_scope_denied"

    assert {:ok, [[0]]} =
             Store.raw_query("SELECT COUNT(*) FROM memories WHERE content = ?1", [content])
  end

  test "a key of one tenant that names another tenant's workspace reads nothing of it" do
    n = System.unique_integer([:positive])
    {tenant_a, tenant_b} = {"cp-a-#{n}", "cp-b-#{n}"}

    [workspace_a, workspace_b] =
      for tenant <- [tenant_a, tenant_b] do
        {:ok, _} = Tenant.create(%{id: tenant, name: tenant})

        {:ok, _} =
          Organization.create(%{id: "#{tenant}:org", tenant_id: tenant, slug: "org", name: "Org"})

        {:ok, workspace} =
          Workspace.create(%{
            tenant_id: tenant,
            organization_id: "#{tenant}:org",
            slug: "main",
            name: "Main"
          })

        workspace.id
      end

    secret = "only-in-tenant-b-#{n}"

    {:ok, _} =
      Memory.create(%{
        content: "#{secret} is tenant B's",
        workspace_id: workspace_b,
        tenant_id: tenant_b
      })

    assert {:ok, [[1]]} =
             Store.raw_query("SELECT COUNT(*) FROM memories WHERE content LIKE ?1", [
               "#{secret}%"
             ])

    # The strongest key tenant A holds: every scope and every workspace.
    {:ok, %{key: token}} =
      ApiKey.mint(%{tenant_id: tenant_a, name: "a-admin", scopes: ["*"], workspace_scope: ["*"]})

    get = fn path ->
      conn(:get, path)
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))
    end

    responses = [
      get.("/api/search?" <> URI.encode_query(%{"q" => secret, "workspace" => workspace_b})),
      request(
        "/api/rag",
        %{workspace: workspace_b, query: secret, skip_intent: true, skip_wiki: true},
        token
      ),
      get.("/api/batch/export/memories?" <> URI.encode_query(%{"workspace" => workspace_b}))
    ]

    for response <- responses do
      assert response.status in [403, 404]
      refute response.resp_body =~ secret
    end

    # The same key reads its own tenant's workspace.
    assert get.("/api/batch/export/memories?" <> URI.encode_query(%{"workspace" => workspace_a})).status ==
             200
  end

  test "omitted tenant resolves to the authenticated tenant instead of default" do
    tenant = "control-plane-tenant-#{System.unique_integer([:positive])}"
    {:ok, _} = OptimalEngine.Tenancy.Tenant.create(%{id: tenant, name: "Scoped tenant"})
    {:ok, %{key: token}} = ApiKey.mint(%{tenant_id: tenant, name: "reader", scopes: ["read"]})

    response =
      conn(:get, "/api/organizations")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["tenant_id"] == tenant
  end
end
