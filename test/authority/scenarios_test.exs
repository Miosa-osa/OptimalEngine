defmodule OptimalEngine.Authority.ScenariosTest do
  @moduledoc """
  End-to-end authority scenarios over the HTTP API, with an owner, an agent,
  and an outside enforcer each holding their own API key:

  1. An approved computation runs once and its result is released, with a
     verifiable evidence chain.
  2. The same grant presented again, or by eight callers at once, runs once.
  3. A grant presented for a different command or resource is refused and
     spends nothing.
  4. A grant revoked before dispatch is refused; one revoked during the run
     has its result withheld.
  5. A local deny stops even a fresh grant from an outside authority; an
     outside authority whose revocation feed went stale is refused until it
     reconnects.

  Plus the Engine's own routes under enforce and observe modes, and the
  scope each authority route requires.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority.{CanonicalJSON, Evidence, Grants, JWS, Keys}
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    tenant = "scenario-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Scenario #{n}"})
    workspace = "#{tenant}:finance"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'finance', 'Finance', 'active', '{}')",
        [workspace, tenant]
      )

    for {id, kind} <- [
          {"user:owner-#{n}", :user},
          {"user:approver-#{n}", :user},
          {"agent:analyst-#{n}", :agent},
          {"service:enforcer-#{n}", :service}
        ] do
      {:ok, _} = Principal.upsert(%{id: id, tenant_id: tenant, kind: kind, display_name: id})
    end

    # Principal ids are global across tenants, so each test names its own.
    agent_id = "agent:analyst-#{n}"
    owner = mint(tenant, "user:owner-#{n}", ["*"])
    approver = mint(tenant, "user:approver-#{n}", ["read", "authority:approve"])
    agent = mint(tenant, agent_id, ["read", "write"])
    enforcer = mint(tenant, "service:enforcer-#{n}", ["read", "authority:enforce"])

    pack = %{
      "name" => "finance",
      "rules" => [
        %{
          "id" => "agent-computes",
          "effect" => "allow",
          "subjects" => [agent_id],
          "actions" => ["compute"],
          "resources" => ["optimal://#{workspace}/datasets/**"],
          "max_ttl_seconds" => 300,
          "ceiling" => %{"records" => 10}
        },
        %{
          "id" => "agent-reads",
          "effect" => "allow",
          "subjects" => ["agent:*"],
          "actions" => ["read", "search"]
        },
        %{"id" => "members-everything", "effect" => "allow", "subjects" => ["user:*"]},
        %{
          "id" => "agent-writes-ask",
          "effect" => "ask",
          "subjects" => ["agent:*"],
          "actions" => ["write"]
        }
      ]
    }

    with_auth(fn ->
      conn =
        call(:post, "/api/authority/policies", owner, %{
          "scope_type" => "workspace",
          "scope_id" => workspace,
          "pack" => pack
        })

      assert conn.status == 201
    end)

    %{
      agent_id: agent_id,
      tenant: tenant,
      workspace: workspace,
      owner: owner,
      approver: approver,
      agent: agent,
      enforcer: enforcer
    }
  end

  defp mint(tenant, principal, scopes) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: principal,
        principal_id: principal,
        scopes: scopes,
        workspace_scope: ["*"]
      })

    key
  end

  defp call(method, path, token, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp with_auth(fun) do
    original = Application.get_env(:optimal_engine, :auth, [])

    Application.put_env(
      :optimal_engine,
      :auth,
      Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
    )

    try do
      fun.()
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end

  defp issue(ctx, extra \\ %{}) do
    conn =
      call(
        :post,
        "/api/authority/grants",
        ctx.owner,
        Map.merge(
          %{
            "subject" => ctx.agent_id,
            "action" => "compute",
            "resource" => "optimal://#{ctx.workspace}/datasets/q3",
            "workspace_id" => ctx.workspace,
            "command" => %{"op" => "sum", "field" => "amount"}
          },
          extra
        )
      )

    assert conn.status == 201, conn.resp_body
    body(conn)
  end

  defp admit(ctx, token, extra \\ %{}) do
    call(
      :post,
      "/api/authority/admit",
      ctx.enforcer,
      Map.merge(
        %{
          "grant" => token,
          "subject" => ctx.agent_id,
          "workspace_id" => ctx.workspace,
          "action" => "compute",
          "resource" => "optimal://#{ctx.workspace}/datasets/q3",
          "command" => %{"op" => "sum", "field" => "amount"},
          "amounts" => %{"records" => 3}
        },
        extra
      )
    )
  end

  defp kinds(ctx), do: ctx.tenant |> Evidence.list() |> Enum.map(& &1["kind"])

  test "1. an approved computation runs once and its result is released", ctx do
    with_auth(fn ->
      grant = issue(ctx)
      conn = admit(ctx, grant["token"])
      assert conn.status == 200
      assert %{"admitted" => true, "jti" => jti} = body(conn)

      assert call(:post, "/api/authority/checkpoint", ctx.enforcer, %{"jti" => jti}).status == 200

      conn =
        call(:post, "/api/authority/release", ctx.enforcer, %{
          "jti" => jti,
          "result" => %{"sum" => 60}
        })

      assert %{"released" => true} = body(conn)

      conn = call(:get, "/api/authority/evidence/verify", ctx.owner)
      assert %{"valid" => true} = body(conn)

      export = call(:get, "/api/authority/evidence/export", ctx.owner) |> body()
      assert {:ok, _} = Evidence.verify_export(export)

      for kind <- ["policy.published", "grant.issued", "grant.admitted", "action.completed"],
          do: assert(kind in kinds(ctx), kind)
    end)
  end

  test "2. the same grant runs once, even when presented by eight callers at once", ctx do
    with_auth(fn ->
      grant = issue(ctx)
      assert admit(ctx, grant["token"]).status == 200
      assert %{"reason" => "replayed"} = admit(ctx, grant["token"]) |> body()

      racing = issue(ctx)

      statuses =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> admit(ctx, racing["token"]).status end) end)
        |> Enum.map(&Task.await(&1, 20_000))

      assert Enum.frequencies(statuses) == %{200 => 1, 403 => 7}
    end)
  end

  test "3. a changed command or resource is refused and spends nothing", ctx do
    with_auth(fn ->
      grant = issue(ctx)

      assert %{"reason" => "command_mismatch"} =
               admit(ctx, grant["token"], %{"command" => %{"op" => "sum", "field" => "salary"}})
               |> body()

      assert %{"reason" => "wrong_resource"} =
               admit(ctx, grant["token"], %{
                 "resource" => "optimal://#{ctx.workspace}/datasets/payroll"
               })
               |> body()

      assert %{"reason" => "ceiling_exceeded"} =
               admit(ctx, grant["token"], %{"amounts" => %{"records" => 11}}) |> body()

      assert admit(ctx, grant["token"]).status == 200
    end)
  end

  test "4. revoked before dispatch is refused; revoked during the run withholds the result", ctx do
    with_auth(fn ->
      before = issue(ctx)

      assert call(:post, "/api/authority/grants/#{before["jti"]}/revoke", ctx.owner, %{
               "reason" => "changed plan"
             }).status == 200

      assert %{"reason" => "revoked"} = admit(ctx, before["token"]) |> body()

      during = issue(ctx)
      assert admit(ctx, during["token"]).status == 200

      assert call(:post, "/api/authority/grants/#{during["jti"]}/revoke", ctx.owner, %{}).status ==
               200

      assert call(:post, "/api/authority/checkpoint", ctx.enforcer, %{"jti" => during["jti"]}).status ==
               409

      conn =
        call(:post, "/api/authority/release", ctx.enforcer, %{
          "jti" => during["jti"],
          "result" => %{"sum" => 60}
        })

      assert conn.status == 409
      assert %{"released" => false, "reason" => "revoked"} = body(conn)
      assert "action.withheld" in kinds(ctx)
    end)
  end

  test "5. a local deny and a lost authority both fail closed", ctx do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    kid = Keys.thumbprint(public)

    with_auth(fn ->
      conn =
        call(:post, "/api/authority/issuers", ctx.owner, %{
          "issuer" => "partner-authority",
          "jwks" => %{"keys" => [Map.put(Keys.jwk(public), "kid", kid)]},
          "max_staleness_seconds" => 60
        })

      assert conn.status == 201

      outside = fn ->
        now = System.os_time(:second)

        JWS.sign(
          %{
            "iss" => "partner-authority",
            "aud" => Grants.audience(),
            "sub" => ctx.agent_id,
            "iat" => now,
            "nbf" => now,
            "exp" => now + 120,
            "jti" => "partner-#{System.unique_integer([:positive])}",
            "optimal" => %{
              "tenant" => ctx.tenant,
              "workspace" => ctx.workspace,
              "action" => "compute",
              "resource" => "optimal://#{ctx.workspace}/datasets/q3",
              "data_class" => "internal",
              "command_sha256" => CanonicalJSON.hash(%{"op" => "sum", "field" => "amount"})
            }
          },
          Grants.typ(),
          kid,
          private
        )
      end

      deny =
        call(:post, "/api/authority/local-denies", ctx.owner, %{
          "subject" => ctx.agent_id,
          "workspace_id" => ctx.workspace,
          "reason" => "data owner hold"
        })
        |> body()

      assert %{"reason" => "local_deny"} = admit(ctx, outside.()) |> body()
      assert call(:delete, "/api/authority/local-denies/#{deny["id"]}", ctx.owner).status == 200
      assert admit(ctx, outside.()).status == 200

      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_issuers SET revocations_synced_at = datetime('now', '-1 hour') WHERE tenant_id = ?1",
          [ctx.tenant]
        )

      stale = outside.()
      assert %{"reason" => "authority_unavailable"} = admit(ctx, stale) |> body()

      assert call(:post, "/api/authority/issuers/partner-authority/revocations", ctx.owner, %{
               "revocations" => []
             }).status == 200

      assert admit(ctx, stale).status == 200
    end)
  end

  describe "the Engine's own routes under authority" do
    test "enforce: reads pass, an agent write needs approval, and the approved grant admits it",
         ctx do
      with_auth(fn ->
        assert call(:put, "/api/authority/settings", ctx.owner, %{"mode" => "enforce"}).status ==
                 200

        assert call(:get, "/api/memory?workspace=#{ctx.workspace}", ctx.agent).status == 200

        write = %{"workspace" => ctx.workspace, "content" => "agent observation"}
        conn = call(:post, "/api/memory", ctx.agent, write)
        assert conn.status == 403
        assert %{"error" => "approval_required"} = body(conn)

        resource = "optimal://#{ctx.workspace}/memory"

        request =
          call(:post, "/api/authority/requests", ctx.agent, %{
            "action" => "write",
            "resource" => resource,
            "workspace_id" => ctx.workspace,
            "justification" => "record the observation"
          })
          |> body()

        assert request["status"] == "pending"
        request_id = request["request"]["id"]

        assert call(:post, "/api/authority/requests/#{request_id}/approve", ctx.agent).status == 403

        approved =
          call(:post, "/api/authority/requests/#{request_id}/approve", ctx.approver) |> body()

        token = approved["grant"]["token"]

        conn = call(:post, "/api/memory", ctx.agent, write, [{"x-optimal-grant", token}])
        assert conn.status in [200, 201], conn.resp_body

        conn = call(:post, "/api/memory", ctx.agent, write, [{"x-optimal-grant", token}])
        assert %{"error" => "grant_denied", "reason" => "replayed"} = body(conn)
      end)
    end

    test "observe: refusals are recorded and nothing is blocked", ctx do
      with_auth(fn ->
        assert call(:put, "/api/authority/settings", ctx.owner, %{"mode" => "observe"}).status ==
                 200

        conn =
          call(:post, "/api/memory", ctx.agent, %{
            "workspace" => ctx.workspace,
            "content" => "observed write"
          })

        assert conn.status in [200, 201]
        assert "decision.observed" in kinds(ctx)
      end)
    end

    test "a restricted workspace refuses agents", ctx do
      {:ok, _} =
        Store.raw_query(
          "UPDATE workspaces SET metadata = '{\"data_class\":\"restricted\"}' WHERE id = ?1",
          [ctx.workspace]
        )

      deny_pack = %{
        "name" => "tenant",
        "rules" => [
          %{
            "id" => "no-restricted-agents",
            "effect" => "deny",
            "subjects" => ["agent:*"],
            "data_classes" => ["restricted"]
          }
        ]
      }

      with_auth(fn ->
        assert call(:post, "/api/authority/policies", ctx.owner, %{
                 "scope_type" => "tenant",
                 "pack" => deny_pack
               }).status == 201

        assert call(:put, "/api/authority/settings", ctx.owner, %{"mode" => "enforce"}).status ==
                 200

        conn = call(:get, "/api/memory?workspace=#{ctx.workspace}", ctx.agent)
        assert conn.status == 403
        assert %{"error" => "authority_denied", "rule" => "no-restricted-agents"} = body(conn)
        assert call(:get, "/api/memory?workspace=#{ctx.workspace}", ctx.owner).status == 200
      end)
    end
  end

  describe "authority route scopes" do
    test "each role reaches only its routes", ctx do
      with_auth(fn ->
        grant_body = %{
          "subject" => ctx.agent_id,
          "action" => "compute",
          "resource" => "optimal://#{ctx.workspace}/datasets/q3",
          "workspace_id" => ctx.workspace
        }

        assert call(:post, "/api/authority/grants", ctx.agent, grant_body).status == 403
        assert call(:post, "/api/authority/admit", ctx.agent, %{"grant" => "x"}).status == 403
        assert call(:get, "/api/authority/evidence", ctx.agent).status == 403

        assert call(:put, "/api/authority/settings", ctx.approver, %{"mode" => "enforce"}).status ==
                 403

        assert call(:post, "/api/authority/local-denies", ctx.enforcer, %{}).status == 403

        assert call(:get, "/api/authority/keys", ctx.agent).status == 200
        assert call(:get, "/api/authority/effective", ctx.agent).status == 200
        assert call(:get, "/api/authority/effective?subject=user:owner", ctx.agent).status == 403

        assert call(:post, "/api/authority/decide", ctx.agent, Map.delete(grant_body, "subject")).status ==
                 200

        assert call(
                 :post,
                 "/api/authority/requests",
                 ctx.agent,
                 Map.put(grant_body, "subject", "agent:other")
               ).status == 403
      end)
    end
  end
end
