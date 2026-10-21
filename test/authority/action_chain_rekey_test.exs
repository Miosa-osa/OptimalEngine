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

  alias OptimalEngine.Authority.{
    ActionChain,
    CanonicalJSON,
    Evidence,
    Grants,
    Integrity,
    JWS,
    Keys,
    WorkspaceRekeys
  }

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

    {:ok, result} =
      DataSteward.rename_workspace(from_id, target, tenant_id: tenant, actor_id: "user:steward")

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
      "detail" => %{"from" => from, "to" => to, "by" => "user:nobody", "mode" => "rename"},
      "prev_hash" => String.duplicate("0", 64),
      "hash" => String.duplicate("a", 64),
      "kid" => "forged",
      "signature" => "forged",
      "recorded_at" => "2026-10-20T00:00:00.000000Z"
    }
  end

  defp rekeys(tenant), do: Evidence.list(tenant, kind: "workspace.rekeyed")

  # Changes the mode recorded in a signed re-key, the way a database writer could.
  defp edit_mode(tenant, seq, mode) do
    [entry] = Evidence.list(tenant, kind: "workspace.rekeyed") |> Enum.filter(&(&1["seq"] == seq))
    detail = Map.put(entry["detail"], "mode", mode)

    {:ok, _} =
      Store.raw_query(
        "UPDATE authority_evidence SET detail = ?1 WHERE tenant_id = ?2 AND tenant_seq = ?3",
        [CanonicalJSON.encode(detail), tenant, seq]
      )
  end

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
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

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
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      assert result.rekey_recorded

      trace = trace!(tenant, correlation)
      assert trace.verified
      assert trace.workspace_id == registered
      assert [%{correlation_id: ^correlation}] = ActionChain.list(tenant, [registered])
      assert {:ok, _} = Evidence.verify(tenant)
    end

    test "an orphan repair that moves no rows is refused and records nothing",
         %{tenant: tenant, workspace: registered, n: n} do
      assert {:error, :nothing_to_repair} =
               DataSteward.repair_orphan_scope("#{tenant}:empty-#{n}", registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

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
               DataSteward.rename_workspace(old, "#{tenant}:ops-nokey",
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

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
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

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
                     tenant_id: tenant,
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
        DataSteward.rename_workspace(old, "#{tenant}:ops-atomic",
          tenant_id: tenant,
          actor_id: "user:steward"
        )
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

  describe "renaming onto an id that already holds rows" do
    test "is refused, so a rename is the same workspace under a new id, and merging first makes it one",
         %{tenant: tenant, workspace: old, n: n} do
      {:ok, _} = Workspace.update(old, %{slug: "ops-held"})
      target = "#{tenant}:ops-held"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_at, metadata) VALUES (?1, ?2, ?3, ?4, 'Row', 'Row.', '2026-10-20T09:00:00Z', '{}')",
          ["held-#{n}", tenant, target, "optimal://inbox/held-#{n}.md"]
        )

      assert {:error, :target_workspace_has_rows} =
               DataSteward.rename_workspace(old, target,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      assert {:ok, %{id: ^old}} = Workspace.get(old)
      assert {:error, :not_found} = Workspace.get(target)
      assert rekeys(tenant) == []

      # The rows are the workspace's own: merge them in, then rename.
      assert {:ok, %{updated_records: updated}} =
               DataSteward.repair_orphan_scope(target, old,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      assert updated >= 1

      assert {:ok, %{rekey_recorded: true}} =
               DataSteward.rename_workspace(old, target,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      assert {:ok, [[^target]]} =
               Store.raw_query("SELECT workspace_id FROM contexts WHERE id = ?1", ["held-#{n}"])
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
      # The grant is for the workspace as it is now: the id it was issued for
      # is not a second door into it.
      assert {:error, :wrong_workspace} = admit(grant.token, tenant, old)
      assert {:ok, _} = admit(grant.token, tenant, target)
      assert %{findings: []} = Integrity.scan(tenant)
    end

    test "do not admit under an old id that names a different workspace now",
         %{tenant: tenant, workspace: old} do
      publish_policy!(tenant, old)
      grant = grant!(tenant, old)
      {target, _result} = repair_id(tenant, old, "ops-reused")

      {:ok, _reused} =
        Workspace.create(%{
          id: old,
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "ops-new-workspace",
          name: "A different workspace with the old id"
        })

      assert {:error, :wrong_workspace} = admit(grant.token, tenant, old)
      assert {:ok, _} = admit(grant.token, tenant, target)
    end

    test "issued for an unregistered id are not carried into the workspace it was merged into",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      publish_policy!(tenant, orphan)
      grant = grant!(tenant, orphan)
      chain(tenant, orphan)

      assert {:ok, %{rekey_recorded: true}} =
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      # The target has its own data and its own policy; a grant for the orphan
      # id never covered either.
      assert {:error, :wrong_workspace} = admit(grant.token, tenant, registered)
    end

    test "issued for an unregistered id do not admit under that id once its rows were merged away",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      publish_policy!(tenant, orphan)
      grant = grant!(tenant, orphan)
      chain(tenant, orphan)

      assert {:ok, %{rekey_recorded: true}} =
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      # The rows left the id, and the grant is not carried to the workspace
      # they went to: it admits nowhere.
      assert {:error, :wrong_workspace} = admit(grant.token, tenant, orphan)
      assert {:error, :wrong_workspace} = admit(grant.token, tenant, registered)
    end

    test "issued for an unregistered id do not admit under it when another workspace took it",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      publish_policy!(tenant, orphan)
      grant = grant!(tenant, orphan)
      chain(tenant, orphan)

      assert {:ok, _} =
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      {:ok, _reused} =
        Workspace.create(%{
          id: orphan,
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "orphan-id-reused",
          name: "A different workspace with the orphan id"
        })

      assert {:error, :wrong_workspace} = admit(grant.token, tenant, orphan)
      assert {:error, :wrong_workspace} = admit(grant.token, tenant, registered)
    end

    test "are not made to follow a merge by editing its recorded mode to rename",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      publish_policy!(tenant, orphan)
      grant = grant!(tenant, orphan)
      chain(tenant, orphan)

      assert {:ok, _} =
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      [%{seq: seq}] = WorkspaceRekeys.list(tenant)
      edit_mode(tenant, seq, "rename")

      # The signed hash covers the mode, so the edited entry explains nothing.
      assert WorkspaceRekeys.list(tenant) == []
      assert {:error, :wrong_workspace} = admit(grant.token, tenant, registered)
    end

    test "from an outside issuer are taken as written, whatever id a local grant has",
         %{tenant: tenant, workspace: old} do
      publish_policy!(tenant, old)
      local = grant!(tenant, old)

      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      kid = Keys.thumbprint(public)
      jwks = %{"keys" => [Map.put(Keys.jwk(public), "kid", kid)]}

      {:ok, _} =
        Authority.register_issuer(tenant, "partner-authority", jwks, "user:owner",
          max_staleness_seconds: 60
        )

      now = System.os_time(:second)

      claims = %{
        "iss" => "partner-authority",
        "aud" => Grants.audience(),
        "sub" => "agent:analyst",
        "iat" => now,
        "nbf" => now,
        "exp" => now + 300,
        # The outside issuer picks the same id as the local grant.
        "jti" => local.jti,
        "optimal" => %{
          "tenant" => tenant,
          "workspace" => old,
          "action" => "compute",
          "resource" => "optimal://#{old}/memory/report-1",
          "data_class" => "internal",
          "command_sha256" => CanonicalJSON.hash(%{"sum" => "amount"}),
          "max_uses" => 1
        }
      }

      token = JWS.sign(claims, Grants.typ(), kid, private)
      {target, _result} = repair_id(tenant, old, "ops-outside")

      assert {:error, :wrong_workspace} = admit(token, tenant, target)
    end

    test "do not admit under another id because of a repair that came before them",
         %{tenant: tenant, workspace: registered, n: n} do
      orphan = "#{tenant}:orphan-#{n}"
      publish_policy!(tenant, orphan)
      chain(tenant, orphan)

      assert {:ok, %{rekey_recorded: true}} =
               DataSteward.repair_orphan_scope(orphan, registered,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

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
    test "is by tenant, kind and sequence, from an index" do
      assert {:ok, [[1]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_authority_evidence_kind'",
                 []
               )
    end
  end

  describe "a row that is not what it should be" do
    test "does not stop a chain from being traced when its detail is not JSON",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO authority_evidence
            (id, tenant_id, tenant_seq, kind, detail, prev_hash, hash, kid, signature, recorded_at)
          VALUES ('ev_junk_trace', ?1, ?2, 'settings.changed', '{not json', 'p', 'h', 'k', 's',
                  '2026-10-20T00:00:00.000000Z')
          """,
          [tenant, next_seq(tenant)]
        )

      assert {:ok, trace} = ActionChain.trace(tenant, correlation)
      assert length(trace.steps) == 4
    end

    test "whose detail is not JSON does not stop the evidence from being read, and fails closed",
         %{tenant: tenant} do
      {:ok, _} = Authority.add_local_deny(tenant, %{"action" => "compute"}, "user:owner")
      seq = next_seq(tenant)

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO authority_evidence
            (id, tenant_id, tenant_seq, kind, detail, prev_hash, hash, kid, signature, recorded_at)
          VALUES ('ev_junk', ?1, ?2, 'workspace.rekeyed', '{not json', 'p', 'h', 'k', 's',
                  '2026-10-20T00:00:00.000000Z')
          """,
          [tenant, seq]
        )

      log = capture_log(fn -> assert List.last(Evidence.list(tenant))["seq"] == seq end)
      assert log =~ "ev_junk"

      # Said once per entry, not on every read.
      assert capture_log(fn ->
               assert WorkspaceRekeys.list(tenant) == []
               assert {:error, %{seq: ^seq}} = Evidence.verify(tenant)
               assert List.last(Evidence.list(tenant))["seq"] == seq
             end) == ""
    end
  end

  describe "which re-keys count" do
    test "an unsigned re-key behind a forged predecessor whose hash matches is still not trusted",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      target = "#{tenant}:forged-target"

      # Two hand-written rows: a predecessor, and a re-key whose prev_hash is
      # that predecessor's hash, so its link to "the entry before it" holds.
      # Neither is signed, and trust comes from the signature, not the link.
      predecessor = Map.put(forged_rekey(tenant, "x", "y"), "kind", "settings.changed")
      insert_entry(predecessor)

      rekey =
        tenant
        |> forged_rekey(old, target)
        |> Map.merge(%{"seq" => predecessor["seq"] + 1, "prev_hash" => predecessor["hash"]})

      insert_entry(rekey)
      assert Evidence.linked?(tenant, rekey)

      move_steps(tenant, correlation, target)
      assert verified(trace!(tenant, correlation)) == [false, false, false, false]
    end

    test "a rename edited to a merge no longer explains the steps it moved",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {target, _result} = repair_id(tenant, old, "ops-edited")
      assert verified(trace!(tenant, correlation)) == [true, true, true, true]

      [%{seq: seq}] = WorkspaceRekeys.list(tenant)
      edit_mode(tenant, seq, "merge")

      assert WorkspaceRekeys.list(tenant) == []
      assert verified(trace!(tenant, correlation)) == [false, false, false, false]
      assert [%{correlation_id: ^correlation}] = ActionChain.list(tenant, [target])
    end

    test "only the re-keys reachable from the ids asked about are checked",
         %{tenant: tenant, workspace: first, n: n} do
      {:ok, second} =
        Workspace.create(%{
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "second",
          name: "Second"
        })

      {first_target, _} = repair_id(tenant, first, "first-new")
      {:ok, _} = Workspace.update(second.id, %{slug: "second-new"})

      assert {:ok, _} =
               DataSteward.rename_workspace(second.id, "#{tenant}:second-new",
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      {:ok, _} = Workspace.update(first_target, %{slug: "first-newer"})

      assert {:ok, _} =
               DataSteward.rename_workspace(first_target, "#{tenant}:first-newer",
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      all = WorkspaceRekeys.list(tenant)
      assert length(all) == 3

      # From the first workspace, both hops of its own chain and nothing of the other.
      assert [%{from: ^first}, %{from: ^first_target}] =
               WorkspaceRekeys.list(tenant, near: [first])

      assert [%{from: from}] = WorkspaceRekeys.list(tenant, near: [second.id])
      assert from == second.id
      assert WorkspaceRekeys.list(tenant, near: ["#{tenant}:unrelated-#{n}"]) == []

      # Only the repairs after a position.
      [%{seq: first_seq} | _] = all

      assert [%{from: ^first_target}] =
               WorkspaceRekeys.list(tenant, near: [first, first_target], after: first_seq)
    end

    test "following the re-keys reachable from an id gives what following all of them gives" do
      :rand.seed(:exsss, {7, 11, 13})
      ids = ~w(a b c d e f)

      for _ <- 1..300 do
        rekeys =
          for seq <- Enum.take_random(1..30, :rand.uniform(9) - 1) |> Enum.sort() do
            from = Enum.random(ids)

            %{
              seq: seq,
              from: from,
              to: Enum.random(ids -- [from]),
              mode: Enum.random([:rename, :merge])
            }
          end

        for id <- ids, after_seq <- [0, 3, 12, 29], modes <- [:any, [:rename], [:merge]] do
          near = WorkspaceRekeys.reachable(rekeys, [id], after_seq)

          assert WorkspaceRekeys.current(near, id, after_seq, modes) ==
                   WorkspaceRekeys.current(rekeys, id, after_seq, modes)
        end
      end
    end

    test "only the re-keys after an entry apply to it, and a merge is not a rename" do
      rekeys = [
        %{seq: 10, from: "a", to: "b", mode: :rename},
        %{seq: 20, from: "b", to: "c", mode: :merge},
        %{seq: 30, from: "c", to: "d", mode: :rename}
      ]

      assert WorkspaceRekeys.current(rekeys, "a", 0) == "d"
      assert WorkspaceRekeys.current(rekeys, "a", 9) == "d"
      # At or below the re-key's own position it does not apply.
      assert WorkspaceRekeys.current(rekeys, "a", 10) == "a"
      assert WorkspaceRekeys.current(rekeys, "a", 11) == "a"
      assert WorkspaceRekeys.current(rekeys, "b", 20) == "b"
      assert WorkspaceRekeys.current(rekeys, "c", 29) == "d"

      # Grants follow renames only: the merge into "c" is a different workspace.
      assert WorkspaceRekeys.current(rekeys, "a", 0, [:rename]) == "b"
      assert WorkspaceRekeys.current(rekeys, "c", 0, [:rename]) == "d"

      assert WorkspaceRekeys.current_resource(rekeys, "optimal://a/**", 0) ==
               "optimal://d/**"

      assert WorkspaceRekeys.current_resource(rekeys, "optimal://a", 0, [:rename]) ==
               "optimal://b"

      assert WorkspaceRekeys.current_resource(rekeys, "other://a/x", 0) == "other://a/x"
    end

    test "a repair is recorded with its mode: a rename, or a merge into a registered workspace",
         %{tenant: tenant, workspace: old, n: n} do
      {_target, _result} = repair_id(tenant, old, "ops-mode")
      assert [%{mode: :rename}] = WorkspaceRekeys.list(tenant)

      orphan = "#{tenant}:orphan-#{n}"
      chain(tenant, orphan)

      {:ok, registered} =
        Workspace.create(%{
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "merged-into",
          name: "Merged into"
        })

      assert {:ok, _} =
               DataSteward.repair_orphan_scope(orphan, registered.id,
                 tenant_id: tenant,
                 actor_id: "user:steward"
               )

      assert [%{mode: :rename}, %{mode: :merge}] = WorkspaceRekeys.list(tenant)
    end
  end

  describe "a step recorded while a repair runs" do
    test "ends up under the new id or is refused, never split from its chain",
         %{tenant: tenant, workspace: old} do
      correlation = chain(tenant, old)
      {:ok, _} = Workspace.update(old, %{slug: "ops-race"})
      target = "#{tenant}:ops-race"

      writers =
        for _ <- 1..4 do
          Task.async(fn ->
            for _ <- 1..15 do
              ActionChain.record(
                tenant,
                %{workspace_id: old, stage: "reply", correlation_id: correlation},
                "agent:deployer"
              )
            end
          end)
        end

      repairer =
        Task.async(fn ->
          DataSteward.rename_workspace(old, target, tenant_id: tenant, actor_id: "user:steward")
        end)

      results = writers |> Enum.flat_map(&Task.await(&1, 60_000))
      assert {:ok, %{rekey_recorded: true}} = Task.await(repairer, 60_000)

      assert Enum.all?(results, fn
               {:ok, _step} -> true
               {:error, :workspace_mismatch} -> true
             end)

      recorded = Enum.count(results, &match?({:ok, _}, &1))

      trace = trace!(tenant, correlation)
      assert length(trace.steps) == 4 + recorded
      assert trace.verified
      assert Enum.uniq(Enum.map(trace.steps, & &1["workspace_id"])) == [target]
      assert [%{correlation_id: ^correlation}] = ActionChain.list(tenant, [target])
      assert ActionChain.list(tenant, [old]) == []
      assert {:ok, _} = Evidence.verify(tenant)

      # Every entry took its own sequence number: no gap, no repeat.
      {:ok, rows} =
        Store.raw_query(
          "SELECT tenant_seq FROM authority_evidence WHERE tenant_id = ?1 ORDER BY tenant_seq",
          [tenant]
        )

      seqs = List.flatten(rows)
      assert seqs == Enum.to_list(1..length(seqs))
    end
  end
end
