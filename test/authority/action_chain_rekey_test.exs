defmodule OptimalEngine.Authority.ActionChainRekeyTest do
  @moduledoc """
  An operator's id repair (`DataSteward.rename_workspace/3`,
  `DataSteward.repair_orphan_scope/3`) moves a workspace's rows to a new id.
  Signed evidence stays as it was written, so an agent action chain recorded
  under the old id must still verify afterwards, be found under the new id,
  and keep refusing a step that was moved by hand or "explained" by a
  re-key record that is not a signed, correctly placed entry of the chain.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.{Router, ViabilityAPI}
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority
  alias OptimalEngine.Authority.{ActionChain, CanonicalJSON, Evidence, Integrity, Keys}
  alias OptimalEngine.{DataSteward, Organization, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "rekey-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Rekey #{n}"})
    organization = Organization.default_for(tenant)

    {:ok, workspace} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: organization,
        slug: "ops",
        name: "Ops"
      })

    %{n: n, tenant: tenant, organization: organization, workspace: workspace.id}
  end

  # A request, approval, action and result, all recorded under `workspace`.
  defp chain(tenant, workspace) do
    {:ok, request} =
      ActionChain.record(
        tenant,
        %{
          workspace_id: workspace,
          stage: "request",
          action: "deploy",
          resource: "optimal://#{workspace}/service"
        },
        "agent:deployer"
      )

    correlation = request["correlation_id"]

    for stage <- ~w(approval action result) do
      {:ok, _} =
        ActionChain.record(
          tenant,
          %{workspace_id: workspace, stage: stage, correlation_id: correlation},
          "agent:deployer"
        )
    end

    correlation
  end

  # The slug changes (the id stays), then the steward makes the id match.
  defp repair_id(tenant, from_id, new_slug) do
    {:ok, _} = Workspace.update(from_id, %{slug: new_slug})
    target = "#{tenant}:#{new_slug}"
    {:ok, result} = DataSteward.rename_workspace(from_id, target, actor_id: "user:steward")
    {target, result}
  end

  defp trace!(tenant, id) do
    {:ok, trace} = ActionChain.trace(tenant, id)
    trace
  end

  defp verified(trace), do: Enum.map(trace.steps, & &1["verified"])

  defp move_steps(tenant, correlation, to) do
    {:ok, _} =
      Store.raw_query(
        "UPDATE authority_action_steps SET workspace_id = ?1 WHERE tenant_id = ?2 AND correlation_id = ?3",
        [to, tenant, correlation]
      )
  end

  defp next_seq(tenant) do
    {:ok, [[seq]]} =
      Store.raw_query(
        "SELECT COALESCE(MAX(tenant_seq), 0) + 1 FROM authority_evidence WHERE tenant_id = ?1",
        [tenant]
      )

    seq
  end

  # Writes an evidence row the way a database administrator could: fields as
  # given, nothing signed or chained unless the caller copies a real entry.
  defp insert_entry(entry) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO authority_evidence
          (id, tenant_id, tenant_seq, kind, jti, subject, action, resource, workspace_id,
           detail, prev_hash, hash, kid, signature, recorded_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
        """,
        [
          entry["id"],
          entry["tenant_id"],
          entry["seq"],
          entry["kind"],
          entry["jti"],
          entry["subject"],
          entry["action"],
          entry["resource"],
          entry["workspace_id"],
          CanonicalJSON.encode(entry["detail"]),
          entry["prev_hash"],
          entry["hash"],
          entry["kid"],
          entry["signature"],
          entry["recorded_at"]
        ]
      )
  end

  defp forged_rekey(tenant, from, to) do
    %{
      "id" => "ev_forged_#{System.unique_integer([:positive])}",
      "tenant_id" => tenant,
      "seq" => next_seq(tenant),
      "kind" => "workspace.rekeyed",
      "subject" => "user:nobody",
      "action" => "write",
      "resource" => "optimal://#{to}",
      "workspace_id" => to,
      "detail" => %{"from" => from, "to" => to, "by" => "user:nobody"},
      "prev_hash" => String.duplicate("0", 64),
      "hash" => String.duplicate("a", 64),
      "kid" => "forged",
      "signature" => "forged",
      "recorded_at" => "2026-10-20T00:00:00.000000Z"
    }
  end

  defp rekeys(tenant), do: Evidence.list(tenant, kind: "workspace.rekeyed")

  defp without_authority_key do
    key = System.get_env("OPTIMAL_AUTHORITY_KEY")
    System.delete_env("OPTIMAL_AUTHORITY_KEY")
    on_exit(fn -> if key, do: System.put_env("OPTIMAL_AUTHORITY_KEY", key) end)
  end

  describe "a chain across a repair" do
    test "recorded under the old id, it verifies and is found under the new id",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      before = trace!(tenant, correlation)
      assert before.verified
      assert before.workspace_id == old

      {target, result} = repair_id(tenant, old, "ops-renamed")
      assert result.rekey_recorded

      trace = trace!(tenant, correlation)
      assert trace.verified
      assert trace.workspace_id == target
      assert trace.findings == []

      assert Enum.map(trace.steps, &{&1["stage"], &1["verified"], &1["workspace_id"]}) ==
               [
                 {"request", true, target},
                 {"approval", true, target},
                 {"action", true, target},
                 {"result", true, target}
               ]

      assert [%{correlation_id: ^correlation, steps: 4}] = ActionChain.list(tenant, [target])
      assert ActionChain.list(tenant, [old]) == []
      assert {:ok, _} = Evidence.verify(tenant)
    end

    test "the repair is itself recorded in the signed evidence",
         %{tenant: tenant, workspace: old} do
      {target, _result} = repair_id(tenant, old, "ops-recorded")

      assert [entry] = rekeys(tenant)
      assert entry["subject"] == "user:steward"
      assert entry["action"] == "write"
      assert entry["workspace_id"] == target
      assert entry["detail"]["from"] == old
      assert entry["detail"]["to"] == target
      assert :ok = Evidence.verify_one(tenant, entry)
    end

    test "a step recorded after the repair, under the new id, verifies with the rest",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {target, _result} = repair_id(tenant, old, "ops-later")

      assert {:ok, reply} =
               ActionChain.record(
                 tenant,
                 %{workspace_id: target, stage: "reply", correlation_id: correlation},
                 "agent:deployer"
               )

      assert reply["workspace_id"] == target

      trace = trace!(tenant, correlation)
      assert verified(trace) == [true, true, true, true, true]
      assert trace.workspace_id == target

      # The chain belongs to the new id now; the old one is refused.
      assert {:error, :workspace_mismatch} =
               ActionChain.record(
                 tenant,
                 %{workspace_id: old, stage: "reply", correlation_id: correlation},
                 "agent:deployer"
               )
    end

    test "two repairs in a row verify, step by step", %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {middle, _} = repair_id(tenant, old, "ops-middle")
      {last, _} = repair_id(tenant, middle, "ops-last")

      trace = trace!(tenant, correlation)

      assert Enum.map(trace.steps, &{&1["stage"], &1["verified"], &1["workspace_id"]}) ==
               [
                 {"request", true, last},
                 {"approval", true, last},
                 {"action", true, last},
                 {"result", true, last}
               ]

      assert trace.verified
      assert [%{correlation_id: ^correlation}] = ActionChain.list(tenant, [last])
      assert {:ok, _} = Evidence.verify(tenant)
    end

    test "a repair and its reverse (A to B to A) verify", %{tenant: tenant, workspace: a} do
      correlation = chain(tenant, a)
      {b, _} = repair_id(tenant, a, "ops-b")
      {back, _} = repair_id(tenant, b, "ops")

      assert back == a
      trace = trace!(tenant, correlation)
      assert verified(trace) == [true, true, true, true]
      assert trace.workspace_id == a
    end

    test "an id used again after a repair has its own chain, and both verify",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      first = chain(tenant, orphan)

      assert {:ok, %{rekey_recorded: true}} =
               DataSteward.repair_orphan_scope(orphan, registered, actor_id: "user:steward")

      second = chain(tenant, orphan)

      assert trace!(tenant, first).workspace_id == registered
      assert trace!(tenant, second).workspace_id == orphan
      assert verified(trace!(tenant, first)) == [true, true, true, true]
      assert verified(trace!(tenant, second)) == [true, true, true, true]

      # The repair came before the second chain, so it cannot explain a step of
      # that chain being found under the registered id.
      move_steps(tenant, second, registered)
      assert verified(trace!(tenant, second)) == [false, false, false, false]
      assert verified(trace!(tenant, first)) == [true, true, true, true]
    end

    test "a chain recorded under an unregistered id verifies once the id is repaired",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      correlation = chain(tenant, orphan)
      assert trace!(tenant, correlation).workspace_id == orphan

      assert {:ok, result} =
               DataSteward.repair_orphan_scope(orphan, registered, actor_id: "user:steward")

      assert result.rekey_recorded

      trace = trace!(tenant, correlation)
      assert trace.verified
      assert trace.workspace_id == registered
      assert [%{correlation_id: ^correlation}] = ActionChain.list(tenant, [registered])
      assert {:ok, _} = Evidence.verify(tenant)
    end

    test "an orphan repair that moves no rows records nothing",
         %{tenant: tenant, workspace: registered, n: n} do
      assert {:ok, result} =
               DataSteward.repair_orphan_scope("#{tenant}:empty-#{n}", registered,
                 actor_id: "user:steward"
               )

      assert result.updated_records == 0
      refute result.rekey_recorded
      assert rekeys(tenant) == []
    end
  end

  describe "a step that is not explained by a signed re-key" do
    test "moved to another workspace by hand does not verify",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {_target, _result} = repair_id(tenant, old, "ops-moved")
      assert verified(trace!(tenant, correlation)) == [true, true, true, true]

      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_action_steps SET workspace_id = ?1 WHERE tenant_id = ?2 AND correlation_id = ?3 AND seq = 2",
          ["#{tenant}:elsewhere", tenant, correlation]
        )

      trace = trace!(tenant, correlation)
      refute trace.verified
      assert verified(trace) == [true, false, true, true]
    end

    test "edited by hand does not verify", %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {_target, _result} = repair_id(tenant, old, "ops-edited")

      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_action_steps SET summary = 'edited' WHERE tenant_id = ?1 AND correlation_id = ?2 AND seq = 3",
          [tenant, correlation]
        )

      assert verified(trace!(tenant, correlation)) == [true, true, false, true]
    end

    test "moved by hand and explained by an unsigned re-key row does not verify",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      assert verified(trace!(tenant, correlation)) == [true, true, true, true]

      target = "#{tenant}:forged-target"
      insert_entry(forged_rekey(tenant, old, target))
      move_steps(tenant, correlation, target)

      trace = trace!(tenant, correlation)
      assert verified(trace) == [false, false, false, false]
      refute trace.verified
    end

    test "an unsigned re-key row cannot move an engine-recorded chain either",
         %{tenant: tenant, workspace: old} do
      request_id = "req-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Evidence.append(tenant, "approval.requested", %{
          subject: "user:requester",
          action: "write",
          resource: "optimal://#{old}/service",
          workspace_id: old,
          detail: %{"request_id" => request_id}
        })

      target = "#{tenant}:forged-target"
      insert_entry(forged_rekey(tenant, old, target))

      assert trace!(tenant, request_id).workspace_id == old

      route =
        conn(:get, "/api/agent-actions/#{request_id}?workspace=#{target}")
        |> assign(:current_tenant, tenant)
        |> ViabilityAPI.actions_trace(request_id)

      assert route.status == 404
    end

    test "a re-key row whose detail is not a map is ignored", %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      target = "#{tenant}:junk-target"
      move_steps(tenant, correlation, target)

      for detail <- [[], "text", %{"from" => 1, "to" => 2}, %{"from" => old}] do
        insert_entry(Map.put(forged_rekey(tenant, old, target), "detail", detail))
      end

      assert verified(trace!(tenant, correlation)) == [false, false, false, false]
    end

    test "a re-key signed by a key that was revoked is not trusted",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {:ok, _} = Keys.rotate(tenant, "evidence")
      {:ok, newer} = Keys.active(tenant, "evidence")

      {_target, _result} = repair_id(tenant, old, "ops-revoked")
      assert verified(trace!(tenant, correlation)) == [true, true, true, true]

      # The steps were signed by the retired key; the re-key by the new one.
      assert :ok = Keys.revoke(tenant, newer.kid)
      assert verified(trace!(tenant, correlation)) == [false, false, false, false]
    end

    test "a re-key copied from another tenant is not trusted", %{
      tenant: tenant,
      workspace: old,
      n: n
    } do
      correlation = chain(tenant, old)
      {target, _result} = repair_id(tenant, old, "ops-copied")
      [real] = rekeys(tenant)

      # Another tenant whose chain was signed under the same ids, with the
      # first tenant's re-key row copied in.
      other = "rekey-other-#{n}"
      {:ok, _} = Tenant.create(%{id: other, name: "Other #{n}"})
      stolen = chain(other, old)
      move_steps(other, stolen, target)
      assert verified(trace!(other, stolen)) == [false, false, false, false]

      insert_entry(
        Map.merge(real, %{
          "id" => "ev_copy_#{n}",
          "tenant_id" => other,
          "seq" => next_seq(other)
        })
      )

      assert verified(trace!(other, stolen)) == [false, false, false, false]
      assert verified(trace!(tenant, correlation)) == [true, true, true, true]
    end

    test "a re-key copied to another position in the chain is not trusted",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {_target, _result} = repair_id(tenant, old, "ops-position")
      [real] = rekeys(tenant)
      assert verified(trace!(tenant, correlation)) == [true, true, true, true]

      {:ok, _} =
        Store.raw_query("DELETE FROM authority_evidence WHERE id = ?1", [real["id"]])

      assert verified(trace!(tenant, correlation)) == [false, false, false, false]

      insert_entry(Map.merge(real, %{"id" => "ev_moved", "seq" => next_seq(tenant) + 40}))
      assert verified(trace!(tenant, correlation)) == [false, false, false, false]
    end

    test "a re-key whose link to the entry before it is broken is not trusted",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {_target, _result} = repair_id(tenant, old, "ops-link")
      [real] = rekeys(tenant)

      # The entry before the re-key goes missing: the re-key no longer sits
      # where it was signed.
      {:ok, _} =
        Store.raw_query(
          "DELETE FROM authority_evidence WHERE tenant_id = ?1 AND tenant_seq = ?2",
          [tenant, real["seq"] - 1]
        )

      assert verified(trace!(tenant, correlation)) == [false, false, false, false]
      assert {:error, _} = Evidence.verify(tenant)
    end
  end

  describe "an engine-recorded chain across a repair" do
    test "is found under the new id", %{tenant: tenant, workspace: old} do
      request_id = "req-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Evidence.append(tenant, "approval.requested", %{
          subject: "user:requester",
          action: "write",
          resource: "optimal://#{old}/service",
          workspace_id: old,
          detail: %{"request_id" => request_id}
        })

      assert trace!(tenant, request_id).workspace_id == old

      {target, _result} = repair_id(tenant, old, "ops-native")

      trace = trace!(tenant, request_id)
      assert trace.verified
      assert trace.workspace_id == target

      route = fn workspace ->
        conn(:get, "/api/agent-actions/#{request_id}?workspace=#{workspace}")
        |> assign(:current_tenant, tenant)
        |> ViabilityAPI.actions_trace(request_id)
      end

      assert route.(target).status == 200
      assert route.(old).status == 404
    end
  end

  describe "over HTTP" do
    test "the repair reports rekey_recorded, the chain is found under the new id, the old id is told",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {:ok, _} = Workspace.update(old, %{slug: "ops-http"})
      target = "#{tenant}:ops-http"

      {:ok, %{key: key}} =
        ApiKey.mint(%{tenant_id: tenant, name: "steward", scopes: ["*"], workspace_scope: ["*"]})

      call = fn method, path, body ->
        connection =
          if body,
            do:
              conn(method, path, Jason.encode!(body))
              |> put_req_header("content-type", "application/json"),
            else: conn(method, path)

        response =
          connection
          |> put_req_header("authorization", "Bearer " <> key)
          |> Router.call(Router.init([]))

        {response.status, Jason.decode!(response.resp_body)}
      end

      assert {200, %{"rekey_recorded" => true, "target_workspace_id" => ^target}} =
               call.(:post, "/api/data-steward/workspaces/rename", %{
                 workspace: old,
                 source_workspace_id: old,
                 target_workspace_id: target
               })

      assert {200, %{"chains" => [%{"correlation_id" => ^correlation}]}} =
               call.(:get, "/api/agent-actions?workspace=#{target}", nil)

      assert {200, %{"verified" => true, "workspace_id" => ^target}} =
               call.(:get, "/api/agent-actions/#{correlation}?workspace=#{target}", nil)

      assert {409, %{"error" => "not_a_workspace_id", "workspace_id" => ^target}} =
               call.(:get, "/api/agent-actions?workspace=#{old}", nil)
    end
  end

  describe "when the Engine cannot sign evidence" do
    test "a repair of a workspace with signed rows is refused and moves nothing",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {:ok, _} = Workspace.update(old, %{slug: "ops-nokey"})
      without_authority_key()

      assert {:error, :evidence_key_unavailable} =
               DataSteward.rename_workspace(old, "#{tenant}:ops-nokey", actor_id: "user:steward")

      assert {:ok, %{id: ^old}} = Workspace.get(old)
      assert {:error, :not_found} = Workspace.get("#{tenant}:ops-nokey")

      assert {:ok, [[4]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM authority_action_steps WHERE workspace_id = ?1 AND correlation_id = ?2",
                 [old, correlation]
               )

      assert rekeys(tenant) == []
    end

    test "an orphan repair of signed rows is refused too",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      correlation = chain(tenant, orphan)
      without_authority_key()

      assert {:error, :evidence_key_unavailable} =
               DataSteward.repair_orphan_scope(orphan, registered, actor_id: "user:steward")

      assert {:ok, [[4]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM authority_action_steps WHERE workspace_id = ?1 AND correlation_id = ?2",
                 [orphan, correlation]
               )
    end

    test "a workspace with no signed rows is repaired, with a warning and no record",
         %{tenant: tenant, workspace: old} do
      {:ok, _} = Workspace.update(old, %{slug: "ops-quiet"})
      without_authority_key()

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   DataSteward.rename_workspace(old, "#{tenant}:ops-quiet",
                     actor_id: "user:steward"
                   )

          refute result.rekey_recorded
        end)

      assert log =~ "will not be recorded as evidence"
      assert {:ok, %{id: target}} = Workspace.get("#{tenant}:ops-quiet")
      assert target == "#{tenant}:ops-quiet"
    end

    test "a step is not recorded at all, rather than recorded without evidence",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      without_authority_key()

      assert {:error, {:evidence_failed, _reason}} =
               ActionChain.record(
                 tenant,
                 %{workspace_id: old, stage: "reply", correlation_id: correlation},
                 "agent:deployer"
               )

      assert {:ok, [[4]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM authority_action_steps WHERE correlation_id = ?1",
                 [correlation]
               )
    end
  end

  describe "atomicity" do
    defp refuse_evidence(kind) do
      :ok =
        Store.raw_execute(
          """
          CREATE TRIGGER rekey_test_refuses
          BEFORE INSERT ON authority_evidence
          WHEN NEW.kind = '#{kind}'
          BEGIN SELECT RAISE(ABORT, 'refused by the test'); END
          """,
          []
        )

      on_exit(fn -> Store.raw_execute("DROP TRIGGER IF EXISTS rekey_test_refuses", []) end)
    end

    test "if the record cannot be written, no row moves and no re-key exists",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {:ok, _} = Workspace.update(old, %{slug: "ops-atomic"})
      refuse_evidence("workspace.rekeyed")

      assert_raise MatchError, fn ->
        DataSteward.rename_workspace(old, "#{tenant}:ops-atomic", actor_id: "user:steward")
      end

      assert {:ok, %{id: ^old}} = Workspace.get(old)
      assert {:error, :not_found} = Workspace.get("#{tenant}:ops-atomic")

      assert {:ok, [[4]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM authority_action_steps WHERE workspace_id = ?1 AND correlation_id = ?2",
                 [old, correlation]
               )

      assert rekeys(tenant) == []
    end

    test "a step and its evidence are written together or not at all",
         %{tenant: tenant, workspace: old} do
      refuse_evidence("agent_action.step")

      assert_raise MatchError, fn ->
        ActionChain.record(
          tenant,
          %{workspace_id: old, stage: "request", action: "deploy"},
          "agent:deployer"
        )
      end

      assert {:ok, [[0]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM authority_action_steps WHERE tenant_id = ?1",
                 [tenant]
               )

      assert {:ok, [[0]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1 AND node = 'agent-actions'",
                 [tenant]
               )
    end
  end

  describe "grants issued before a repair" do
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

    defp admit(token, tenant, workspace) do
      Authority.admit(token, %{
        tenant_id: tenant,
        subject: "agent:analyst",
        workspace_id: workspace,
        action: "compute",
        resource: "optimal://#{workspace}/memory/report-1",
        command: %{"sum" => "amount"},
        amounts: %{}
      })
    end

    test "still admit under the new id, and only the new id", %{tenant: tenant, workspace: old} do
      publish_policy!(tenant, old)
      grant = grant!(tenant, old)
      {target, _result} = repair_id(tenant, old, "ops-grants")

      assert {:error, :wrong_workspace} = admit(grant.token, tenant, "#{tenant}:elsewhere")
      assert {:ok, _} = admit(grant.token, tenant, target)
      assert %{findings: []} = Integrity.scan(tenant)
    end

    test "do not admit under another id because of a repair that came before them",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      publish_policy!(tenant, orphan)
      chain(tenant, orphan)

      assert {:ok, %{rekey_recorded: true}} =
               DataSteward.repair_orphan_scope(orphan, registered, actor_id: "user:steward")

      # Issued after the repair, under the orphan id: the repair does not
      # make that id mean the registered workspace.
      grant = grant!(tenant, orphan)
      assert {:error, :wrong_workspace} = admit(grant.token, tenant, registered)
      assert {:ok, _} = admit(grant.token, tenant, orphan)
    end

    test "are not made to admit by an unsigned re-key row", %{tenant: tenant, workspace: old} do
      publish_policy!(tenant, old)
      grant = grant!(tenant, old)
      target = "#{tenant}:forged-target"
      insert_entry(forged_rekey(tenant, old, target))

      assert {:error, :wrong_workspace} = admit(grant.token, tenant, target)
    end

    test "keep their row with the workspace, and the integrity scan finds nothing",
         %{tenant: tenant, workspace: old} do
      publish_policy!(tenant, old)
      grant = grant!(tenant, old)
      assert %{findings: []} = Integrity.scan(tenant)

      {target, _result} = repair_id(tenant, old, "ops-rows")

      assert {:ok, [[^target]]} =
               Store.raw_query("SELECT workspace_id FROM authority_grants WHERE jti = ?1", [
                 grant.jti
               ])

      assert %{findings: []} = Integrity.scan(tenant)
      assert {:ok, _} = Evidence.verify(tenant)
    end
  end

  # Every table a workspace id repair can reach that carries a hash,
  # signature, checksum or similar column. A new one has to be classified, so
  # nobody adds a signed table the steward would quietly re-key.
  describe "the tables a repair reaches" do
    @classes %{
      # The steward does not re-key it (DataSteward.not_rekeyed_tables/0).
      authority_evidence: :left_alone,
      # Re-keyed, and verified against the id inside its signed entry.
      authority_action_steps: :verified_against_signed_id,
      # Hashes of content, a payload, a command, a file or a bundle: the id
      # column is not part of what they cover.
      asset_adapter_runs: :hash_excludes_workspace,
      asset_extractions: :hash_excludes_workspace,
      assets: :hash_excludes_workspace,
      authority_grants: :hash_excludes_workspace,
      authority_requests: :hash_excludes_workspace,
      citations: :hash_excludes_workspace,
      data_files: :hash_excludes_workspace,
      data_schema_migrations: :hash_excludes_workspace,
      memories: :hash_excludes_workspace,
      memory_embeddings: :hash_excludes_workspace,
      memory_path_priors: :hash_excludes_workspace,
      model_adapters: :hash_excludes_workspace,
      model_call_runs: :hash_excludes_workspace,
      projection_revisions: :hash_excludes_workspace,
      source_packages: :hash_excludes_workspace,
      sync_mutations: :hash_excludes_workspace,
      tool_call_runs: :hash_excludes_workspace,
      training_examples: :hash_excludes_workspace,
      uri_redirects: :hash_excludes_workspace,
      # Not signed: a de-duplication key built from the id, so a loop seen
      # again after a repair is not matched with the one that moved.
      open_loops: :unsigned_key_includes_workspace
    }

    @hashlike ~r/(hash|sha256|signature|checksum|digest|fingerprint|dedupe|etag|nonce|seal|(^|_)mac($|_)|(^|_)sha($|_))/

    test "each is classified, so a new signed table has to be considered" do
      {:ok, rows} =
        Store.raw_query(
          """
          SELECT m.name, c.name FROM sqlite_master m, pragma_table_info(m.name) c
          WHERE m.type = 'table'
            AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) w WHERE w.name = 'workspace_id')
          ORDER BY m.name, c.name
          """,
          []
        )

      found =
        rows
        |> Enum.filter(fn [_table, column] -> Regex.match?(@hashlike, column) end)
        |> Enum.map(fn [table, _column] -> String.to_atom(table) end)
        |> Enum.uniq()
        |> Enum.sort()

      assert found == @classes |> Map.keys() |> Enum.sort(),
             "a table with a hash-like column and a workspace_id is not classified (or one was removed)"
    end

    test "the classes agree with what the steward re-keys" do
      left_alone = for {table, :left_alone} <- @classes, do: Atom.to_string(table)
      rekeyed = for {table, class} <- @classes, class != :left_alone, do: Atom.to_string(table)

      assert Enum.all?(left_alone, &(&1 in DataSteward.not_rekeyed_tables()))
      refute Enum.any?(rekeyed, &(&1 in DataSteward.not_rekeyed_tables()))
    end
  end

  describe "reading re-keys" do
    test "is by tenant, kind and sequence, from an index (migration 76)" do
      assert {:ok, [[1]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_authority_evidence_kind'",
                 []
               )

      assert {:ok, [[76]]} = Store.raw_query("SELECT MAX(version) FROM schema_migrations", [])
    end
  end
end
