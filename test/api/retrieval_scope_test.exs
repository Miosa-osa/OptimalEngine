defmodule OptimalEngine.API.RetrievalScopeTest do
  @moduledoc """
  HTTP retrieval answers inside the caller's tenant, honors access lists for
  keyed callers, and carries the tenant's inherited org policy.

  * Tenant: `/api/rag`, `/api/recall/*`, `/api/grep`, `/api/search` and
    `GET /api/memory` read only the authenticated tenant's memories, even when
    two tenants use the same bare workspace id.
  * Access lists: for a keyed caller, a resource with no ACL rows is readable
    (the key's workspace scope already covers it), grant rows restrict a
    resource to the principals and groups they name, and a deny row wins over
    any grant. An anonymous local caller is the trusted operator and is not
    filtered.
  * Org policy: `/api/search` returns matching org policy memories labeled
    `inherited: true` with their `source_workspace_id`, and `/api/rag` and
    `/api/recall/*` carry `org_policy`, under the same deny-wins rules as
    `GET /api/org-policy`.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.{ACL, Group, Principal}
  alias OptimalEngine.{Authority, Memory, Organization, OrgPolicy, Scope, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    # Recall analyzes intent with a local model when one answers; point the
    # client at a closed port so the fallback analyzer runs deterministically.
    ollama = Application.get_env(:optimal_engine, :ollama)

    Application.put_env(
      :optimal_engine,
      :ollama,
      Keyword.put(ollama || [], :host, "http://127.0.0.1:9")
    )

    on_exit(fn -> Application.put_env(:optimal_engine, :ollama, ollama) end)

    # The test database outlives a run, so names carry a random part.
    %{n: Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)}
  end

  defp tenant(prefix, n) do
    id = "#{prefix}-#{n}"
    {:ok, _} = Tenant.create(%{id: id, name: "#{prefix} #{n}"})
    id
  end

  defp workspace(tenant, slug) do
    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: Organization.default_for(tenant),
        slug: slug,
        name: String.capitalize(slug)
      })

    ws.id
  end

  defp key(tenant, workspaces, principal, scopes \\ ["read", "write"]) do
    {:ok, _} =
      Principal.upsert(%{id: principal, tenant_id: tenant, kind: :agent, display_name: principal})

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "retrieval-scope-test",
        scopes: scopes,
        workspace_scope: workspaces,
        principal_id: principal
      })

    token
  end

  defp request(method, path, token, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp json(conn) do
    assert conn.status == 200, "#{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp rag(token, workspace, query) do
    request(:post, "/api/rag", token, %{
      "query" => query,
      "workspace" => workspace,
      "skip_intent" => true,
      "skip_wiki" => true
    })
    |> json()
  end

  defp search_contents(token, workspace, q) do
    request(:get, "/api/search?q=#{q}&workspace=#{workspace}&limit=50", token)
    |> json()
    |> Map.fetch!("results")
    |> Enum.map(& &1["content"])
    |> Enum.join("\n")
  end

  defp grep_snippets(token, workspace, q) do
    request(:get, "/api/grep?q=#{q}&workspace=#{workspace}", token)
    |> json()
    |> Map.fetch!("results")
    |> Enum.map(& &1["snippet"])
    |> Enum.join("\n")
  end

  describe "tenant" do
    setup %{n: n} do
      tenant_a = tenant("tret-a", n)
      tenant_b = tenant("tret-b", n)
      shared = "shared-#{n}"

      key_a = key(tenant_a, [shared], "agent:a-#{n}")
      key_b = key(tenant_b, [shared], "agent:b-#{n}")

      {:ok, _} =
        Memory.create(%{
          tenant_id: tenant_a,
          workspace_id: shared,
          content: "memalpha#{n} the quarterly plan belongs to the north team"
        })

      {:ok, _} =
        Memory.create(%{
          tenant_id: tenant_b,
          workspace_id: shared,
          content: "membravo#{n} the quarterly plan belongs to the south team"
        })

      %{shared: shared, key_a: key_a, key_b: key_b}
    end

    test "GET /api/memory lists only the caller's tenant", ctx do
      body = request(:get, "/api/memory?workspace=#{ctx.shared}", ctx.key_b) |> json()
      contents = Enum.map_join(body["memories"], "\n", & &1["content"])

      assert contents =~ "membravo#{ctx.n}"
      refute contents =~ "memalpha#{ctx.n}"
      assert body["pagination"]["total"] == length(body["memories"])
    end

    test "GET /api/grep reads the caller's tenant", ctx do
      assert grep_snippets(ctx.key_a, ctx.shared, "memalpha#{ctx.n}") =~ "north team"
      refute grep_snippets(ctx.key_b, ctx.shared, "memalpha#{ctx.n}") =~ "north team"
      assert grep_snippets(ctx.key_b, ctx.shared, "membravo#{ctx.n}") =~ "south team"
    end

    test "GET /api/search reads the caller's tenant", ctx do
      assert search_contents(ctx.key_a, ctx.shared, "quarterly") =~ "north team"
      refute search_contents(ctx.key_b, ctx.shared, "quarterly") =~ "north team"
    end

    test "POST /api/rag answers from the caller's tenant", ctx do
      assert rag(ctx.key_a, ctx.shared, "memalpha#{ctx.n}")["envelope"]["body"] =~ "north team"
      refute rag(ctx.key_b, ctx.shared, "memalpha#{ctx.n}")["envelope"]["body"] =~ "north team"
      assert rag(ctx.key_b, ctx.shared, "membravo#{ctx.n}")["envelope"]["body"] =~ "south team"
    end

    test "GET /api/recall answers from the caller's tenant", ctx do
      path = "/api/recall/where?thing=memalpha#{ctx.n}&workspace=#{ctx.shared}"

      assert request(:get, path, ctx.key_a) |> json() |> get_in(["envelope", "body"]) =~
               "north team"

      refute request(:get, path, ctx.key_b) |> json() |> get_in(["envelope", "body"]) =~
               "north team"
    end
  end

  describe "access lists for keyed retrieval" do
    setup %{n: n} do
      tenant = tenant("tret-acl", n)
      docs = workspace(tenant, "docs")
      reader = "agent:reader-#{n}"
      other = "agent:other-#{n}"
      reader_key = key(tenant, [docs], reader)
      other_key = key(tenant, [docs], other)

      {:ok, _} = Group.upsert(%{id: "group:editors-#{n}", name: "Editors", tenant_id: tenant})
      :ok = Group.add_member(reader, "group:editors-#{n}")

      open = memory(tenant, docs, "aclopen#{n} roadmap for the spring release")
      granted = memory(tenant, docs, "aclgranted#{n} roadmap for the board only")
      denied = memory(tenant, docs, "acldenied#{n} roadmap for the editors")

      :ok =
        ACL.grant(%{
          tenant_id: tenant,
          resource_uri: uri(granted),
          principal_id: other,
          permission: :read
        })

      :ok =
        ACL.grant(%{
          tenant_id: tenant,
          resource_uri: uri(denied),
          group_id: "group:editors-#{n}",
          permission: :read
        })

      :ok = ACL.deny(%{tenant_id: tenant, resource_uri: uri(denied), principal_id: reader})

      # The default when authentication is required; absence of rows must
      # still not deny a key that is scoped to the workspace.
      original = Application.get_env(:optimal_engine, :acl_absent)
      Application.put_env(:optimal_engine, :acl_absent, :deny)
      on_exit(fn -> Application.put_env(:optimal_engine, :acl_absent, original) end)

      %{
        docs: docs,
        reader_key: reader_key,
        other_key: other_key,
        open: open,
        granted: granted,
        denied: denied
      }
    end

    defp memory(tenant, workspace, content) do
      {:ok, mem} = Memory.create(%{tenant_id: tenant, workspace_id: workspace, content: content})
      mem
    end

    defp uri(mem), do: "optimal://memory/#{mem.workspace_id}/#{mem.id}"

    test "search: no rows is readable, rows restrict, a deny row wins", ctx do
      reader = search_contents(ctx.reader_key, ctx.docs, "roadmap")
      assert reader =~ "aclopen#{ctx.n}"
      refute reader =~ "aclgranted#{ctx.n}"
      refute reader =~ "acldenied#{ctx.n}"

      other = search_contents(ctx.other_key, ctx.docs, "roadmap")
      assert other =~ "aclopen#{ctx.n}"
      assert other =~ "aclgranted#{ctx.n}"
      refute other =~ "acldenied#{ctx.n}"
    end

    test "grep and rag apply the same rows", ctx do
      snippets = grep_snippets(ctx.reader_key, ctx.docs, "roadmap")
      assert snippets =~ "aclopen#{ctx.n}"
      refute snippets =~ "aclgranted#{ctx.n}"
      refute snippets =~ "acldenied#{ctx.n}"

      body = rag(ctx.reader_key, ctx.docs, "roadmap")["envelope"]["body"]
      assert body =~ "aclopen#{ctx.n}"
      refute body =~ "aclgranted#{ctx.n}"
      refute body =~ "acldenied#{ctx.n}"
    end

    test "an anonymous local caller is the trusted operator and is not filtered", ctx do
      local = "acl-local-#{ctx.n}"
      granted = memory("default", local, "localgranted#{ctx.n} roadmap for the board only")
      denied = memory("default", local, "localdenied#{ctx.n} roadmap for the editors")

      :ok =
        ACL.grant(%{resource_uri: uri(granted), principal_id: "agent:someone", permission: :read})

      :ok =
        ACL.deny(%{
          resource_uri: uri(denied),
          principal_id: OptimalEngine.API.Actor.local_operator()
        })

      all = search_contents(nil, local, "roadmap")
      assert all =~ "localgranted#{ctx.n}"
      assert all =~ "localdenied#{ctx.n}"
    end

    test "a deny row wins over a direct grant", ctx do
      tenant = ctx.open.tenant_id

      :ok =
        ACL.grant(%{
          tenant_id: tenant,
          resource_uri: uri(ctx.open),
          principal_id: "agent:reader-#{ctx.n}",
          permission: :admin
        })

      :ok =
        ACL.deny(%{
          tenant_id: tenant,
          resource_uri: uri(ctx.open),
          principal_id: "agent:reader-#{ctx.n}"
        })

      refute ACL.can?("agent:reader-#{ctx.n}", uri(ctx.open), :read,
               tenant_id: tenant,
               absent: :allow
             )

      refute search_contents(ctx.reader_key, ctx.docs, "roadmap") =~ "aclopen#{ctx.n}"
    end
  end

  describe "org policy" do
    setup %{n: n} do
      tenant = tenant("tret-org", n)
      org = workspace(tenant, "org")
      sales = workspace(tenant, "sales")

      {:ok, policy} =
        Memory.create(%{
          tenant_id: tenant,
          workspace_id: org,
          content: "orgrule#{n} every outbound quote needs a second reviewer",
          metadata: %{"kind" => "policy"}
        })

      {:ok, _note} =
        Memory.create(%{
          tenant_id: tenant,
          workspace_id: org,
          content: "orgsecret#{n} board discussion about the outbound quote process",
          metadata: %{"kind" => "note"}
        })

      {:ok, _own} =
        Memory.create(%{
          tenant_id: tenant,
          workspace_id: sales,
          content: "salesnote#{n} outbound quote template lives in the shared drive"
        })

      {:ok, _} = OrgPolicy.designate(tenant, org, "user:admin-#{n}")

      %{
        tenant: tenant,
        org: org,
        sales: sales,
        policy: policy,
        sales_key: key(tenant, [sales], "agent:sales-#{n}"),
        org_key: key(tenant, [org], "agent:org-#{n}")
      }
    end

    defp search(token, workspace, q) do
      request(:get, "/api/search?q=#{q}&workspace=#{workspace}&limit=50", token)
      |> json()
      |> Map.fetch!("results")
    end

    test "search from a workspace returns matching org policy, labeled with its source", ctx do
      [hit] = search(ctx.sales_key, ctx.sales, "orgrule#{ctx.n}")

      assert hit["id"] == ctx.policy.id
      assert hit["inherited"] == true
      assert hit["source_workspace_id"] == ctx.org
      assert hit["uri"] == "optimal://#{ctx.org}/memory/#{ctx.policy.id}"

      assert search(ctx.sales_key, ctx.sales, "orgsecret#{ctx.n}") == []
    end

    test "search mixes the workspace's own results, labeled as not inherited", ctx do
      results = search(ctx.sales_key, ctx.sales, "outbound")
      by_inherited = Enum.group_by(results, & &1["inherited"])

      assert [%{"source_workspace_id" => source}] = by_inherited[true]
      assert source == ctx.org
      assert Enum.all?(by_inherited[false], &(&1["source_workspace_id"] == ctx.sales))
      assert Enum.any?(by_inherited[false], &(&1["content"] =~ "salesnote#{ctx.n}"))
      refute Enum.any?(results, &(&1["content"] =~ "orgsecret#{ctx.n}"))
    end

    test "in the org section itself the policy is its own", ctx do
      [hit] = search(ctx.org_key, ctx.org, "orgrule#{ctx.n}")
      assert hit["inherited"] == false
      assert hit["source_workspace_id"] == ctx.org
    end

    test "rag and recall carry the org policy the workspace follows", ctx do
      body = rag(ctx.sales_key, ctx.sales, "outbound quote")

      assert [%{"id" => id, "inherited" => true, "source_workspace_id" => org}] =
               body["org_policy"]["memories"]

      assert id == ctx.policy.id
      assert org == ctx.org

      recall =
        request(:get, "/api/recall/who?topic=outbound+quote&workspace=#{ctx.sales}", ctx.sales_key)
        |> json()

      assert [%{"id" => ^id}] = recall["org_policy"]["memories"]
    end

    test "an org section that does not share keeps its policy out of search and rag", ctx do
      {:ok, _} = Scope.set_share_up(ctx.tenant, ctx.org, "none", "user:admin")

      assert search(ctx.sales_key, ctx.sales, "orgrule#{ctx.n}") == []

      policy = rag(ctx.sales_key, ctx.sales, "outbound quote")["org_policy"]
      assert policy["memories"] == []
      assert policy["withheld_reason"] == "org_section_not_shared"
    end

    test "under enforcement a local deny withholds the policy from search", ctx do
      pack = %{
        "name" => "reads",
        "rules" => [%{"id" => "all-read", "effect" => "allow", "actions" => ["read", "search"]}]
      }

      {:ok, _} = Authority.publish_policy(ctx.tenant, "tenant", ctx.tenant, pack, "user:admin")
      :ok = Authority.set_mode(ctx.tenant, "enforce", "user:admin")

      try do
        assert [_] = search(ctx.sales_key, ctx.sales, "orgrule#{ctx.n}")

        {:ok, _} =
          Authority.add_local_deny(
            ctx.tenant,
            %{
              "subject" => "agent:sales-#{ctx.n}",
              "action" => "read",
              "resource" => "optimal://#{ctx.org}/**"
            },
            "user:admin"
          )

        assert search(ctx.sales_key, ctx.sales, "orgrule#{ctx.n}") == []
        assert rag(ctx.sales_key, ctx.sales, "outbound quote")["org_policy"]["withheld"] == 1
      after
        :ok = Authority.set_mode(ctx.tenant, "off", "user:admin")
      end
    end
  end
end
