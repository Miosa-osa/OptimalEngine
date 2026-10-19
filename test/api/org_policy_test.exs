defmodule OptimalEngine.API.OrgPolicyTest do
  @moduledoc """
  Org policy flows down: memories in the tenant's org section marked as
  policy are readable from every workspace of the tenant (labeled with their
  source and `inherited: true`) in boot, context assembly and the policy
  listing, and are never writable from those workspaces. Nothing else of the
  org section is readable from them, and a deny wins.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.{Authority, Memory, Organization, OrgPolicy, Scope, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    tenant = "orgpol-#{n}"
    other = "orgpol-other-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Org #{n}"})
    {:ok, _} = Tenant.create(%{id: other, name: "Other #{n}"})

    {:ok, org} = workspace(tenant, "org")
    {:ok, sales} = workspace(tenant, "sales")
    {:ok, ops} = workspace(tenant, "ops")
    {:ok, foreign} = workspace(other, "sales")

    {:ok, policy} =
      Memory.create(%{
        tenant_id: tenant,
        workspace_id: org.id,
        content: "Every outbound quote needs a second reviewer.",
        metadata: %{"kind" => "policy"}
      })

    {:ok, private_note} =
      Memory.create(%{
        tenant_id: tenant,
        workspace_id: org.id,
        content: "Board discussion about the reorganisation.",
        metadata: %{"kind" => "note"}
      })

    # A memory marked policy outside the org section never flows anywhere.
    {:ok, local_policy} =
      Memory.create(%{
        tenant_id: tenant,
        workspace_id: ops.id,
        content: "Ops keeps its own runbook.",
        metadata: %{"kind" => "policy"}
      })

    admin = key(tenant, ["*"], ["*"], "user:admin-#{n}")
    {:ok, _} = OrgPolicy.designate(tenant, org.id, "user:admin-#{n}")

    %{
      n: n,
      tenant: tenant,
      other: other,
      org: org.id,
      sales: sales.id,
      ops: ops.id,
      foreign: foreign.id,
      policy: policy,
      private_note: private_note,
      local_policy: local_policy,
      admin: admin,
      sales_key: key(tenant, [sales.id], ["read", "write"], "agent:sales-#{n}"),
      org_writer: key(tenant, [org.id], ["read", "write"], "user:org-writer-#{n}"),
      foreign_key: key(other, [foreign.id], ["read", "write"], "agent:foreign-#{n}")
    }
  end

  defp workspace(tenant, slug) do
    Workspace.create(%{
      tenant_id: tenant,
      organization_id: Organization.default_for(tenant),
      slug: slug,
      name: String.capitalize(slug)
    })
  end

  defp key(tenant, workspaces, scopes, principal, metadata \\ %{}) do
    kind = if String.starts_with?(principal, "user:"), do: :user, else: :agent

    {:ok, _} =
      Principal.upsert(%{id: principal, tenant_id: tenant, kind: kind, display_name: principal})

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "org-policy-test",
        scopes: scopes,
        workspace_scope: workspaces,
        principal_id: principal,
        metadata: metadata
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

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp ids(memories), do: Enum.map(memories, & &1["id"])

  describe "designating the org section" do
    test "needs admin, names a workspace of the tenant, and is recorded", ctx do
      assert request(:get, "/api/org-section", ctx.sales_key) |> json() |> Map.get("workspace_id") ==
               ctx.org

      conn = request(:put, "/api/org-section", ctx.org_writer, %{"workspace_id" => ctx.org})
      assert conn.status == 403
      assert json(conn)["error"] == "permission_scope_denied"

      conn = request(:put, "/api/org-section", ctx.admin, %{"workspace_id" => ctx.foreign})
      assert conn.status == 404

      conn = request(:put, "/api/org-section", ctx.admin, %{"workspace_id" => ctx.sales})
      assert conn.status == 200
      assert %{"workspace_id" => sales, "previous" => org, "flows_down" => true} = json(conn)
      assert {sales, org} == {ctx.sales, ctx.org}

      kinds = ctx.tenant |> Authority.Evidence.list() |> Enum.map(& &1["kind"])
      assert "settings.changed" in kinds

      conn = request(:delete, "/api/org-section", ctx.admin)
      assert conn.status == 200
      assert json(conn)["workspace_id"] == nil
      assert OrgPolicy.org_workspace(ctx.tenant) == nil
    end

    test "each tenant has its own org section", ctx do
      assert request(:get, "/api/org-section", ctx.foreign_key) |> json() |> Map.get("workspace_id") ==
               nil
    end
  end

  describe "reading from a workspace" do
    test "the policy listing shows org policy as inherited and nothing else", ctx do
      conn = request(:get, "/api/org-policy?workspace=#{ctx.sales}", ctx.sales_key)
      assert conn.status == 200
      body = json(conn)
      assert body["workspace_id"] == ctx.sales
      assert body["org_workspace_id"] == ctx.org
      assert body["inherited"] == true
      assert ids(body["memories"]) == [ctx.policy.id]

      [memory] = body["memories"]
      assert memory["inherited"] == true
      assert memory["source_workspace_id"] == ctx.org
      assert memory["uri"] == "optimal://#{ctx.org}/memory/#{ctx.policy.id}"
      assert memory["content"] == "Every outbound quote needs a second reviewer."
    end

    test "boot carries the org policy", ctx do
      conn = request(:get, "/api/boot?workspace=#{ctx.sales}", ctx.sales_key)
      assert conn.status == 200
      policy = json(conn)["org_policy"]
      assert policy["org_workspace_id"] == ctx.org
      assert ids(policy["memories"]) == [ctx.policy.id]
      assert hd(policy["memories"])["inherited"] == true
    end

    test "context assembly carries the org policy", ctx do
      conn =
        request(:post, "/api/assemble", ctx.sales_key, %{
          "workspace" => ctx.sales,
          "query" => "quotes"
        })

      assert conn.status == 200
      policy = json(conn)["org_policy"]
      assert ids(policy["memories"]) == [ctx.policy.id]
      assert hd(policy["memories"])["source_workspace_id"] == ctx.org
    end

    test "the org section itself sees its policy as its own", ctx do
      body = request(:get, "/api/org-policy?workspace=#{ctx.org}", ctx.org_writer) |> json()
      assert body["inherited"] == false
      assert [%{"inherited" => false, "source_workspace_id" => org}] = body["memories"]
      assert org == ctx.org
    end

    test "a policy memory reads by id from the workspace; other org content does not", ctx do
      conn = request(:get, "/api/memory/#{ctx.policy.id}?workspace=#{ctx.sales}", ctx.sales_key)
      assert conn.status == 200
      assert json(conn)["inherited"] == true
      assert json(conn)["source_workspace_id"] == ctx.org

      # Other org content is not there for this workspace at all.
      conn =
        request(:get, "/api/memory/#{ctx.private_note.id}?workspace=#{ctx.sales}", ctx.sales_key)

      assert conn.status == 404
      assert json(conn)["error"] == "memory not found"

      # Naming the org section is refused; policy is readable, not its history.
      for path <- [
            "/api/memory?workspace=#{ctx.org}",
            "/api/org-policy?workspace=#{ctx.org}",
            "/api/search?q=reorganisation&workspace=#{ctx.org}",
            "/api/memory/#{ctx.policy.id}/versions?workspace=#{ctx.sales}",
            "/api/memory/#{ctx.policy.id}/relations?workspace=#{ctx.sales}"
          ] do
        assert request(:get, path, ctx.sales_key).status == 403, path
      end

      body = request(:get, "/api/boot?workspace=#{ctx.sales}", ctx.sales_key) |> json()
      refute ctx.private_note.id in ids(body["org_policy"]["memories"])
      refute ctx.local_policy.id in ids(body["org_policy"]["memories"])
    end

    test "only the latest live version of a policy flows", ctx do
      {:ok, v2} =
        Memory.update(ctx.policy.id, %{content: "Every outbound quote needs two reviewers."})

      {:ok, retired} =
        Memory.create(%{
          tenant_id: ctx.tenant,
          workspace_id: ctx.org,
          content: "Retired rule.",
          metadata: %{"kind" => "policy"}
        })

      :ok = Memory.forget(retired.id, reason: "retired")

      body = request(:get, "/api/org-policy?workspace=#{ctx.sales}", ctx.sales_key) |> json()
      assert ids(body["memories"]) == [v2.id]
    end

    test "another tenant never sees this tenant's policy", ctx do
      body = request(:get, "/api/org-policy?workspace=#{ctx.foreign}", ctx.foreign_key) |> json()
      assert body["org_workspace_id"] == nil
      assert body["memories"] == []

      conn =
        request(:get, "/api/memory/#{ctx.policy.id}?workspace=#{ctx.foreign}", ctx.foreign_key)

      assert conn.status == 404
    end

    test "no org section means no inherited policy", ctx do
      :ok = OrgPolicy.clear(ctx.tenant, "user:admin")
      body = request(:get, "/api/org-policy?workspace=#{ctx.sales}", ctx.sales_key) |> json()
      assert body["org_workspace_id"] == nil
      assert body["memories"] == []

      assert request(:get, "/api/memory/#{ctx.policy.id}?workspace=#{ctx.sales}", ctx.sales_key).status ==
               404
    end

    test "a data key is confined to /api/data", ctx do
      data_key =
        key(ctx.tenant, [ctx.sales], ["read"], "app:data-#{ctx.n}", %{
          "data_access" => %{"owner" => "app"}
        })

      assert request(:get, "/api/org-policy?workspace=#{ctx.sales}", data_key).status == 403
      assert request(:get, "/api/org-section", data_key).status == 403
    end
  end

  describe "writing from a workspace" do
    test "creating, updating, forgetting or deleting a policy memory is refused", ctx do
      conn =
        request(:post, "/api/memory", ctx.sales_key, %{
          "workspace" => ctx.org,
          "content" => "Sales may skip review.",
          "metadata" => %{"kind" => "policy"}
        })

      assert conn.status == 403

      for {method, path, body} <- [
            {:post, "/api/memory/#{ctx.policy.id}/update", %{"content" => "No review needed."}},
            {:post, "/api/memory/#{ctx.policy.id}/forget", %{}},
            {:post, "/api/memory/#{ctx.policy.id}/extend", %{"content" => "Except sales."}},
            {:post, "/api/memory/#{ctx.policy.id}/derive", %{"content" => "Derived."}},
            {:delete, "/api/memory/#{ctx.policy.id}?workspace=#{ctx.sales}", nil}
          ] do
        body = if body, do: Map.put(body, "workspace", ctx.sales), else: nil
        conn = request(method, path, ctx.sales_key, body)
        assert conn.status == 403, path
        assert json(conn)["error"] == "workspace_scope_denied"
      end

      assert {:ok, %{content: "Every outbound quote needs a second reviewer.", is_forgotten: false}} =
               Memory.get(ctx.policy.id)
    end

    test "a key that can write the org section manages policy", ctx do
      conn =
        request(:post, "/api/memory", ctx.org_writer, %{
          "workspace" => ctx.org,
          "content" => "Contracts above the limit need the owner's approval.",
          "metadata" => %{"kind" => "policy"}
        })

      assert conn.status == 201
      created = json(conn)["id"]

      conn =
        request(:post, "/api/memory/#{created}/forget", ctx.org_writer, %{"workspace" => ctx.org})

      assert conn.status == 204

      body = request(:get, "/api/org-policy?workspace=#{ctx.sales}", ctx.sales_key) |> json()
      assert ids(body["memories"]) == [ctx.policy.id]
    end
  end

  describe "deny wins" do
    test "an org section that does not share keeps its policy inside", ctx do
      {:ok, _} = Scope.set_share_up(ctx.tenant, ctx.org, "none", "user:admin")
      body = request(:get, "/api/org-policy?workspace=#{ctx.sales}", ctx.sales_key) |> json()
      assert body["memories"] == []
      assert body["withheld_reason"] == "org_section_not_shared"

      assert request(:get, "/api/memory/#{ctx.policy.id}?workspace=#{ctx.sales}", ctx.sales_key).status ==
               404
    end

    test "under enforcement a local deny on the org section withholds its policy", ctx do
      pack = %{
        "name" => "reads",
        "rules" => [%{"id" => "all-read", "effect" => "allow", "actions" => ["read", "search"]}]
      }

      {:ok, _} = Authority.publish_policy(ctx.tenant, "tenant", ctx.tenant, pack, "user:admin")
      :ok = Authority.set_mode(ctx.tenant, "enforce", "user:admin")

      try do
        body = request(:get, "/api/org-policy?workspace=#{ctx.sales}", ctx.sales_key) |> json()
        assert ids(body["memories"]) == [ctx.policy.id]

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

        conn = request(:get, "/api/org-policy?workspace=#{ctx.sales}", ctx.sales_key)
        assert conn.status == 200
        assert json(conn)["memories"] == []
        assert json(conn)["withheld"] == 1

        conn = request(:get, "/api/memory/#{ctx.policy.id}?workspace=#{ctx.sales}", ctx.sales_key)
        assert conn.status == 404

        kinds = ctx.tenant |> Authority.Evidence.list() |> Enum.map(& &1["kind"])
        assert "decision.denied" in kinds
      after
        :ok = Authority.set_mode(ctx.tenant, "off", "user:admin")
      end
    end
  end
end
