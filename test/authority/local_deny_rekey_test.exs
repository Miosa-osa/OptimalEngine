defmodule OptimalEngine.Authority.LocalDenyRekeyTest do
  @moduledoc """
  A local deny is the one control no grant overrides, so an operator's
  workspace id repair must never leave it silently matching nothing. A deny
  written for the old id keeps applying as written and also applies to the
  new id (and, after a merge, to the workspace the rows were merged into),
  whichever door the request comes through: a decision, an admission, or the
  HTTP data routes under enforcement.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority
  alias OptimalEngine.Authority.{Keys, LocalDeny}
  alias OptimalEngine.{DataSteward, Organization, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "deny-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Deny #{n}"})

    {:ok, workspace} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: Organization.default_for(tenant),
        slug: "ops",
        name: "Ops"
      })

    %{n: n, tenant: tenant, workspace: workspace.id}
  end

  defp repair_id(tenant, from_id, new_slug) do
    {:ok, _} = Workspace.update(from_id, %{slug: new_slug})
    target = "#{tenant}:#{new_slug}"

    {:ok, _} =
      DataSteward.rename_workspace(from_id, target, tenant_id: tenant, actor_id: "user:steward")

    target
  end

  defp deny!(tenant, attrs) do
    {:ok, deny} = Authority.add_local_deny(tenant, attrs, "user:owner")
    deny
  end

  defp request(tenant, workspace, overrides \\ %{}) do
    Map.merge(
      %{
        tenant_id: tenant,
        subject: "agent:analyst",
        workspace_id: workspace,
        action: "compute",
        resource: "optimal://#{workspace}/memory/report-1",
        command: %{"sum" => "amount"},
        amounts: %{}
      },
      overrides
    )
  end

  defp denied?(tenant, workspace, overrides \\ %{}),
    do: not is_nil(LocalDeny.matching(tenant, request(tenant, workspace, overrides)))

  describe "a deny written for the old id" do
    test "applies as written, and to the new id after a rename",
         %{tenant: tenant, workspace: old} do
      deny!(tenant, %{"workspace_id" => old, "resource" => "optimal://#{old}/**"})
      assert denied?(tenant, old)

      target = repair_id(tenant, old, "ops-denied")

      assert denied?(tenant, target)
      # Both names stay denied: a request that still says the old id too.
      assert denied?(tenant, old)
      # Another workspace is not caught by it.
      refute denied?(tenant, "#{tenant}:elsewhere")
    end

    test "with no workspace of its own still follows the id in its resource pattern",
         %{tenant: tenant, workspace: old} do
      deny!(tenant, %{"resource" => "optimal://#{old}/**", "subject" => "agent:*"})
      target = repair_id(tenant, old, "ops-nil")

      assert denied?(tenant, target)
      refute denied?(tenant, target, %{subject: "user:someone"})
      refute denied?(tenant, "#{tenant}:elsewhere")
    end

    test "applies to the workspace the rows were merged into",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, ?4, 'Row', 'Row.', '2026-10-20T09:00:00Z', '{}')",
          ["deny-row-#{n}", tenant, orphan, "optimal://inbox/deny-row-#{n}.md"]
        )

      deny!(tenant, %{"workspace_id" => orphan, "resource" => "optimal://#{orphan}/**"})
      refute denied?(tenant, registered)

      assert {:ok, %{rekey_recorded: true}} =
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      assert denied?(tenant, registered)
      assert denied?(tenant, orphan)
    end

    test "still applies when the key that signed the repair is revoked",
         %{tenant: tenant, workspace: old} do
      deny!(tenant, %{"workspace_id" => old, "resource" => "optimal://#{old}/**"})
      {:ok, _} = Keys.rotate(tenant, "evidence")
      {:ok, newer} = Keys.active(tenant, "evidence")
      target = repair_id(tenant, old, "ops-revoked")

      assert :ok = Keys.revoke(tenant, newer.kid)

      assert denied?(tenant, old)
      assert denied?(tenant, target)
    end

    test "applies to the new id even when the repair record is only a row in the table",
         %{tenant: tenant, workspace: old} do
      deny!(tenant, %{"workspace_id" => old, "resource" => "optimal://#{old}/**"})
      target = "#{tenant}:forged-target"

      # Following can only add denials, so it does not need the record to be
      # signed: a forged row can widen a deny, never lift one.
      {:ok, [[seq]]} =
        Store.raw_query(
          "SELECT COALESCE(MAX(tenant_seq), 0) + 1 FROM authority_evidence WHERE tenant_id = ?1",
          [tenant]
        )

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO authority_evidence
            (id, tenant_id, tenant_seq, kind, subject, action, resource, workspace_id, detail,
             prev_hash, hash, kid, signature, recorded_at)
          VALUES ('ev_forged', ?1, ?2, 'workspace.rekeyed', 'user:nobody', 'write', 'optimal://x', 'x',
                  ?3, 'p', 'h', 'k', 's', '2026-10-20T00:00:00Z')
          """,
          [
            tenant,
            seq,
            Jason.encode!(%{
              "from" => old,
              "to" => target,
              "by" => "user:nobody",
              "mode" => "rename"
            })
          ]
        )

      assert denied?(tenant, target)
    end

    test "is exact about an id used again: a deny written for the new workspace of that id",
         %{tenant: tenant, workspace: old, n: n} do
      target = repair_id(tenant, old, "ops-moved-away")

      # The id `old` is a different workspace now, and gets its own deny.
      {:ok, reused} =
        Workspace.create(%{
          id: old,
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "ops-again-#{n}",
          name: "Again"
        })

      deny!(tenant, %{"workspace_id" => reused.id, "resource" => "optimal://#{reused.id}/**"})

      assert denied?(tenant, reused.id)
      # The deny was written after the repair, so it does not reach the
      # workspace the old rows moved to.
      refute denied?(tenant, target)
    end
  end

  describe "through the authority doors" do
    defp publish_policy!(tenant, workspace) do
      pack = %{
        "name" => "ops",
        "rules" => [
          %{
            "id" => "agents-compute",
            "effect" => "allow",
            "subjects" => ["agent:*"],
            "actions" => ["compute"],
            "resources" => ["optimal://#{workspace}/**"],
            "data_classes" => ["internal"],
            "max_ttl_seconds" => 600
          }
        ]
      }

      {:ok, _} = Authority.publish_policy(tenant, "workspace", workspace, pack, "user:owner")
    end

    defp grant!(tenant, workspace) do
      {:ok, grant} =
        Authority.issue_grant(
          tenant,
          %{
            "subject" => "agent:analyst",
            "action" => "compute",
            "resource" => "optimal://#{workspace}/memory/report-1",
            "workspace_id" => workspace,
            "command" => %{"sum" => "amount"}
          },
          "user:owner"
        )

      grant
    end

    test "a decision under the new id is denied by the old id's deny",
         %{tenant: tenant, workspace: old} do
      deny!(tenant, %{"workspace_id" => old, "resource" => "optimal://#{old}/**"})
      target = repair_id(tenant, old, "ops-decide")

      decision = Authority.decide(request(tenant, target))
      assert decision.effect == :deny
      assert decision.reason == "local_deny"
    end

    test "a grant issued before the repair does not get past the old id's deny",
         %{tenant: tenant, workspace: old} do
      publish_policy!(tenant, old)
      grant = grant!(tenant, old)
      deny!(tenant, %{"workspace_id" => old, "resource" => "optimal://#{old}/**"})

      target = repair_id(tenant, old, "ops-admit")

      assert {:error, :local_deny} = Authority.admit(grant.token, request(tenant, target))
    end

    test "a grant and a deny from before a merge: the grant stays out, the deny reaches",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, ?4, 'Row', 'Row.', '2026-10-20T09:00:00Z', '{}')",
          ["merge-row-#{n}", tenant, orphan, "optimal://inbox/merge-row-#{n}.md"]
        )

      publish_policy!(tenant, orphan)
      grant = grant!(tenant, orphan)
      deny!(tenant, %{"workspace_id" => orphan, "resource" => "optimal://#{orphan}/**"})

      assert {:ok, %{rekey_recorded: true}} =
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      # A merge is not a rename: the grant was issued for the orphan id and is
      # not carried to the workspace that already existed.
      assert {:error, :wrong_workspace} = Authority.admit(grant.token, request(tenant, registered))
      # The deny is: it widens, it never lifts.
      assert denied?(tenant, registered)
    end
  end

  describe "over the HTTP data routes under enforcement" do
    test "a request under the new id is refused by the old id's deny, with its reason",
         %{tenant: tenant, workspace: old} do
      {:ok, %{key: key}} =
        ApiKey.mint(%{tenant_id: tenant, name: "reader", scopes: ["read"], workspace_scope: ["*"]})

      :ok = Authority.set_mode(tenant, "enforce", "user:owner")
      deny!(tenant, %{"workspace_id" => old, "resource" => "optimal://#{old}/**"})

      get = fn workspace ->
        response =
          conn(:get, "/api/loops?workspace=#{workspace}")
          |> put_req_header("authorization", "Bearer " <> key)
          |> Router.call(Router.init([]))

        {response.status, Jason.decode!(response.resp_body)}
      end

      assert {403, %{"error" => "authority_denied", "reason" => "local_deny"}} = get.(old)

      target = repair_id(tenant, old, "ops-http-deny")

      assert {403, %{"error" => "authority_denied", "reason" => "local_deny"}} = get.(target)
    end
  end
end
