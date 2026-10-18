defmodule OptimalEngine.AuthorityTest do
  @moduledoc """
  Optimal Authority: policy, decisions, grants, admission, evidence, and
  integrity. Each test runs in its own tenant so evidence chains and packs
  never interact.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Authority

  alias OptimalEngine.Authority.{
    Admission,
    CanonicalJSON,
    Evidence,
    Grants,
    Integrity,
    JWS,
    Keys,
    Policy
  }

  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "authority-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Authority #{n}"})
    workspace = "#{tenant}:ops"
    resource = "optimal://#{workspace}/memory/report-1"

    pack = %{
      "name" => "ops",
      "rules" => [
        %{
          "id" => "agents-read",
          "effect" => "allow",
          "subjects" => ["agent:*"],
          "actions" => ["read", "compute"],
          "resources" => ["optimal://#{workspace}/**"],
          "data_classes" => ["internal"],
          "max_ttl_seconds" => 600,
          "ceiling" => %{"records" => 100},
          "delegable" => true
        },
        %{"id" => "exports-ask", "effect" => "ask", "actions" => ["export"]},
        %{"id" => "no-restricted", "effect" => "deny", "data_classes" => ["restricted"]}
      ]
    }

    {:ok, _policy} = Authority.publish_policy(tenant, "workspace", workspace, pack, "user:owner")

    %{tenant: tenant, workspace: workspace, resource: resource, pack: pack}
  end

  defp grant!(ctx, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "subject" => "agent:analyst",
          "action" => "compute",
          "resource" => ctx.resource,
          "workspace_id" => ctx.workspace,
          "command" => %{"sum" => "amount"}
        },
        attrs
      )

    {:ok, grant} = Authority.issue_grant(ctx.tenant, attrs, "user:owner")
    grant
  end

  defp request(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        tenant_id: ctx.tenant,
        subject: "agent:analyst",
        workspace_id: ctx.workspace,
        action: "compute",
        resource: ctx.resource,
        command: %{"sum" => "amount"},
        amounts: %{"records" => 3}
      },
      overrides
    )
  end

  defp sign_custom(ctx, claims) do
    {:ok, key} = Keys.active(ctx.tenant, "grant")
    JWS.sign(claims, Grants.typ(), key.kid, key.private_key)
  end

  defp kinds(ctx), do: ctx.tenant |> Evidence.list() |> Enum.map(& &1["kind"])

  describe "policy packs" do
    test "validation names every problem" do
      assert {:error, errors} =
               Policy.validate(%{
                 "rules" => [
                   %{"id" => "a", "effect" => "maybe"},
                   %{"id" => "a", "effect" => "allow", "subjects" => []},
                   %{"effect" => "deny", "data_classes" => ["secret"], "extra" => 1}
                 ]
               })

      text = Enum.join(errors, "\n")
      assert text =~ "name is required"
      assert text =~ "effect must be allow, ask, or deny"
      assert text =~ "subjects must be a non-empty list"
      assert text =~ "unknown data class"
      assert text =~ "id is required"
      assert text =~ "unknown fields"
      assert text =~ "duplicate rule id a"
    end

    test "publishing versions a scope and keeps the hash stable", ctx do
      first = Policy.active(ctx.tenant, "workspace", ctx.workspace)
      assert first.version == 1
      assert first.hash == Policy.hash(first.document)

      {:ok, second} =
        Authority.publish_policy(ctx.tenant, "workspace", ctx.workspace, ctx.pack, "user:owner")

      assert second.version == 2
      assert second.hash == first.hash
      assert {:ok, %{status: "superseded"}} = Policy.get(ctx.tenant, first.id)
    end

    test "glob patterns: * stays inside a segment, ** crosses segments" do
      assert Policy.glob?("agent:*", "agent:one")
      refute Policy.glob?("agent:*", "agent:one/sub")
      assert Policy.glob?("optimal://ws/**", "optimal://ws/a/b/c")
      refute Policy.glob?("optimal://ws/*", "optimal://ws/a/b")
      refute Policy.glob?("optimal://ws/**", "optimal://other/a")
    end

    test "loosening is detected rule by rule", ctx do
      old = ctx.pack
      [read, ask, deny] = old["rules"]

      cases = [
        {%{old | "rules" => [read, ask]}, "removed_deny_rule"},
        {%{old | "rules" => [read, %{ask | "effect" => "allow"}, deny]}, "effect_ask_to_allow"},
        {%{old | "rules" => [%{read | "subjects" => ["agent:*", "app:*"]}, ask, deny]},
         "subjects_widened"},
        {%{old | "rules" => [%{read | "max_ttl_seconds" => 6000}, ask, deny]}, "max_ttl_increased"},
        {%{old | "rules" => [Map.delete(read, "ceiling"), ask, deny]}, "ceiling_increased"},
        {%{
           old
           | "rules" => [read, ask, %{deny | "data_classes" => ["confidential", "restricted"]}]
         }, nil},
        {%{old | "rules" => old["rules"] ++ [%{"id" => "new", "effect" => "allow"}]},
         "added_allow_rule"}
      ]

      for {new, expected} <- cases do
        {:ok, old_doc} = Policy.validate(old)
        {:ok, new_doc} = Policy.validate(new)
        changes = Policy.loosening(old_doc, new_doc) |> Enum.map(& &1["change"])

        if expected,
          do: assert(expected in changes, "#{expected} not in #{inspect(changes)}"),
          else: assert(changes == [], "widening a deny is not loosening: #{inspect(changes)}")
      end
    end

    test "in enforce mode a loosening needs an authority:loosen grant", ctx do
      admin_pack = %{
        "name" => "admins",
        "rules" => [
          %{
            "id" => "loosen",
            "effect" => "allow",
            "subjects" => ["user:owner"],
            "actions" => ["authority:loosen"]
          }
        ]
      }

      {:ok, _} =
        Authority.publish_policy(ctx.tenant, "tenant", ctx.tenant, admin_pack, "user:owner")

      :ok = Authority.set_mode(ctx.tenant, "enforce", "user:owner")
      looser = %{ctx.pack | "rules" => Enum.take(ctx.pack["rules"], 2)}

      assert {:error, :loosening_requires_grant} =
               Authority.publish_policy(
                 ctx.tenant,
                 "workspace",
                 ctx.workspace,
                 looser,
                 "user:owner"
               )

      {:ok, grant} =
        Authority.issue_grant(
          ctx.tenant,
          %{
            "subject" => "user:owner",
            "action" => "authority:loosen",
            "resource" => Authority.policy_resource("workspace", ctx.workspace)
          },
          "user:owner"
        )

      assert {:ok, policy} =
               Authority.publish_policy(
                 ctx.tenant,
                 "workspace",
                 ctx.workspace,
                 looser,
                 "user:owner",
                 grant: grant.token
               )

      assert [%{"change" => "removed_deny_rule"}] = policy.loosening
      assert "policy.loosened" in kinds(ctx)
    end
  end

  describe "decisions" do
    test "default deny when nothing matches", ctx do
      decision =
        Authority.decide(%{
          tenant_id: ctx.tenant,
          subject: "agent:x",
          action: "write",
          resource: ctx.resource
        })

      assert decision.effect == :deny
      assert decision.reason == "no_matching_rule"
    end

    test "allow, ask and deny with limits", ctx do
      base = %{
        tenant_id: ctx.tenant,
        workspace_id: ctx.workspace,
        subject: "agent:x",
        resource: ctx.resource
      }

      allow = Authority.decide(Map.put(base, :action, "read"))
      assert allow.effect == :allow
      assert allow.rule_id == "agents-read"
      assert allow.max_ttl_seconds == 600
      assert allow.ceiling == %{"records" => 100}
      assert allow.delegable

      assert Authority.decide(Map.put(base, :action, "export")).effect == :ask

      deny = Authority.decide(Map.merge(base, %{action: "read", data_class: "restricted"}))
      assert deny.effect == :deny
      assert deny.rule_id == "no-restricted"
    end

    test "a deny in any scope beats an allow in another", ctx do
      {:ok, _} =
        Authority.publish_policy(
          ctx.tenant,
          "tenant",
          ctx.tenant,
          %{
            "name" => "tenant",
            "rules" => [
              %{"id" => "freeze-agent", "effect" => "deny", "subjects" => ["agent:frozen"]}
            ]
          },
          "user:owner"
        )

      decision =
        Authority.decide(%{
          tenant_id: ctx.tenant,
          workspace_id: ctx.workspace,
          subject: "agent:frozen",
          action: "read",
          resource: ctx.resource
        })

      assert decision.effect == :deny
      assert decision.rule_id == "freeze-agent"
    end

    test "a local deny wins over every rule", ctx do
      {:ok, deny} =
        Authority.add_local_deny(
          ctx.tenant,
          %{"subject" => "agent:*", "action" => "read"},
          "user:owner"
        )

      decision =
        Authority.decide(%{
          tenant_id: ctx.tenant,
          workspace_id: ctx.workspace,
          subject: "agent:x",
          action: "read",
          resource: ctx.resource
        })

      assert decision.effect == :deny
      assert decision.local_deny_id == deny.id
    end
  end

  describe "grant issuance and lifecycle" do
    test "issued grants carry exact, signed claims", ctx do
      grant = grant!(ctx)
      optimal = grant.claims["optimal"]

      assert grant.claims["iss"] == Grants.issuer()
      assert grant.claims["aud"] == Grants.audience()
      assert grant.claims["exp"] - grant.claims["nbf"] == 600
      assert optimal["command_sha256"] == CanonicalJSON.hash(%{"sum" => "amount"})
      assert optimal["ceiling"] == %{"records" => 100}
      assert optimal["max_uses"] == 1
      assert optimal["rule"] == "agents-read"
      assert "grant.issued" in kinds(ctx)
    end

    test "issuance follows the decision", ctx do
      assert {:error, :denied, _} =
               Authority.issue_grant(
                 ctx.tenant,
                 %{"subject" => "agent:x", "action" => "write", "resource" => ctx.resource},
                 "user:owner"
               )

      assert {:error, :approval_required, _} =
               Authority.issue_grant(
                 ctx.tenant,
                 %{
                   "subject" => "agent:x",
                   "action" => "export",
                   "resource" => ctx.resource,
                   "workspace_id" => ctx.workspace
                 },
                 "user:owner"
               )

      assert {:error, :ttl_exceeds_policy, _} =
               Authority.issue_grant(
                 ctx.tenant,
                 grant_attrs(ctx, %{"ttl_seconds" => 601}),
                 "user:owner"
               )

      assert {:error, :ceiling_exceeds_policy, _} =
               Authority.issue_grant(
                 ctx.tenant,
                 grant_attrs(ctx, %{"ceiling" => %{"records" => 101}}),
                 "user:owner"
               )

      assert "decision.denied" in kinds(ctx)
      assert "decision.ask" in kinds(ctx)
    end

    test "approval: no self-approval, one grant per approved request", ctx do
      attrs = %{
        "subject" => "agent:x",
        "action" => "export",
        "resource" => ctx.resource,
        "workspace_id" => ctx.workspace
      }

      {:ok, request, decision} = Authority.request_approval(ctx.tenant, attrs, "agent:x")
      assert decision.effect == :ask
      assert {:error, :self_approval} = Authority.approve(ctx.tenant, request.id, "agent:x")

      assert {:ok, approved, grant} = Authority.approve(ctx.tenant, request.id, "user:owner")
      assert approved.status == "approved"
      assert grant.claims["optimal"]["approval"] == request.id

      assert {:error, :not_pending} = Authority.approve(ctx.tenant, request.id, "user:owner")

      assert {:error, :approval_required, _} =
               Authority.issue_grant(
                 ctx.tenant,
                 Map.put(attrs, "approval_id", request.id),
                 "user:owner"
               )

      assert Enum.take(kinds(ctx), -4) |> Enum.member?("approval.approved")
    end

    test "narrowing only shrinks", ctx do
      parent = grant!(ctx, %{"max_uses" => 3, "delegable" => true})

      assert {:ok, child} =
               Authority.narrow_grant(
                 ctx.tenant,
                 parent.jti,
                 %{
                   "subject" => "agent:helper",
                   "ttl_seconds" => 60,
                   "ceiling" => %{"records" => 10}
                 },
                 "agent:analyst"
               )

      assert child.claims["optimal"]["parent"] == parent.jti
      assert child.claims["sub"] == "agent:helper"

      for {attrs, reason} <- [
            {%{"action" => "read"}, :action_not_narrower},
            {%{"resource" => "optimal://#{ctx.workspace}/other"}, :resource_not_narrower},
            {%{"data_class" => "confidential"}, :data_class_not_narrower},
            {%{"ttl_seconds" => 6_000}, :expiry_not_narrower},
            {%{"ceiling" => %{"records" => 1_000}}, :ceiling_not_narrower},
            {%{"ceiling" => %{}}, :ceiling_not_narrower},
            {%{"command" => %{"sum" => "other"}}, :command_not_narrower},
            {%{"max_uses" => 5}, :parent_uses_exhausted}
          ] do
        assert {:error, ^reason, _} =
                 Authority.narrow_grant(ctx.tenant, parent.jti, attrs, "agent:analyst"),
               inspect(attrs)
      end

      not_delegable = grant!(ctx)

      assert {:error, :not_delegable, _} =
               Authority.narrow_grant(
                 ctx.tenant,
                 not_delegable.jti,
                 %{"subject" => "agent:helper"},
                 "agent:analyst"
               )
    end

    test "suspend, restore and revoke cascade through narrowed grants", ctx do
      parent = grant!(ctx, %{"max_uses" => 2, "delegable" => true})

      {:ok, child} =
        Authority.narrow_grant(
          ctx.tenant,
          parent.jti,
          %{"subject" => "agent:helper"},
          "agent:analyst"
        )

      {:ok, _} = Authority.suspend_grant(ctx.tenant, parent.jti, "user:owner")
      assert {:error, :suspended} = Admission.in_force(ctx.tenant, child.jti)
      {:ok, _} = Authority.restore_grant(ctx.tenant, parent.jti, "user:owner")
      assert :ok = Admission.in_force(ctx.tenant, child.jti)

      assert {:ok, [parent_jti, child_jti]} =
               Authority.revoke_grant(ctx.tenant, parent.jti, "user:owner", "test")

      assert {parent_jti, child_jti} == {parent.jti, child.jti}
      assert {:ok, %{status: "revoked"}} = Grants.fetch(ctx.tenant, child.jti)
      assert {:error, :invalid_state} = Grants.restore(ctx.tenant, parent.jti)
    end
  end

  defp grant_attrs(ctx, extra) do
    Map.merge(
      %{
        "subject" => "agent:analyst",
        "action" => "compute",
        "resource" => ctx.resource,
        "workspace_id" => ctx.workspace
      },
      extra
    )
  end

  describe "admission" do
    test "an exact, fresh grant is admitted once and recorded", ctx do
      grant = grant!(ctx)
      assert {:ok, admission} = Authority.admit(grant.token, request(ctx))
      assert admission.jti == grant.jti
      assert "grant.admitted" in kinds(ctx)
      assert {:ok, %{status: "consumed", uses: 1}} = Grants.fetch(ctx.tenant, grant.jti)
    end

    test "every binding field is enforced", ctx do
      for {override, reason} <- [
            {%{subject: "agent:other"}, :wrong_subject},
            {%{tenant_id: "default"}, :unknown_key},
            {%{workspace_id: "#{ctx.tenant}:elsewhere"}, :wrong_workspace},
            {%{action: "read"}, :wrong_action},
            {%{resource: "optimal://#{ctx.workspace}/memory/report-2"}, :wrong_resource},
            {%{data_class: "confidential"}, :wrong_data_class},
            {%{command: %{"sum" => "salary"}}, :command_mismatch},
            {%{audience: "another-enforcer"}, :wrong_audience}
          ] do
        grant = grant!(ctx)

        assert {:error, ^reason} = Authority.admit(grant.token, request(ctx, override)),
               inspect(override)

        # A refused admission never spends the use.
        assert {:ok, _} = Authority.admit(grant.token, request(ctx))
      end
    end

    test "a replay is refused, including concurrent replays", ctx do
      grant = grant!(ctx)
      assert {:ok, _} = Authority.admit(grant.token, request(ctx))
      assert {:error, :replayed} = Authority.admit(grant.token, request(ctx))

      racing = grant!(ctx)

      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> Authority.admit(racing.token, request(ctx)) end) end)
        |> Enum.map(&Task.await(&1, 15_000))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :replayed})) == 7
    end

    test "tampering is refused", ctx do
      grant = grant!(ctx)
      [header, payload, signature] = String.split(grant.token, ".")
      {:ok, claims} = payload |> JWS.decode64() |> then(fn {:ok, json} -> Jason.decode(json) end)

      widened = put_in(claims, ["optimal", "resource"], "optimal://#{ctx.workspace}/**")
      forged = JWS.encode64(CanonicalJSON.encode(widened))

      assert {:error, :bad_signature} =
               Authority.admit(Enum.join([header, forged, signature], "."), request(ctx))

      flipped =
        signature
        |> JWS.decode64()
        |> elem(1)
        |> :binary.bin_to_list()
        |> List.update_at(0, &Bitwise.bxor(&1, 1))

      assert {:error, :bad_signature} =
               Authority.admit(
                 Enum.join([header, payload, JWS.encode64(:binary.list_to_bin(flipped))], "."),
                 request(ctx)
               )

      other_kid =
        JWS.encode64(Jason.encode!(%{"alg" => "EdDSA", "kid" => "nope", "typ" => Grants.typ()}))

      assert {:error, :unknown_key} =
               Authority.admit(Enum.join([other_kid, payload, signature], "."), request(ctx))

      none = JWS.encode64(Jason.encode!(%{"alg" => "none", "kid" => "x", "typ" => Grants.typ()}))

      assert {:error, :algorithm_not_allowed} =
               Authority.admit(Enum.join([none, payload, ""], "."), request(ctx))

      assert {:ok, _} = Authority.admit(grant.token, request(ctx))
    end

    test "time windows", ctx do
      now = System.os_time(:second)
      expired = grant!(ctx, %{"not_before" => now - 700, "ttl_seconds" => 600})
      assert {:error, :expired} = Authority.admit(expired.token, request(ctx))

      future = grant!(ctx, %{"not_before" => now + 300})
      assert {:error, :not_yet_valid} = Authority.admit(future.token, request(ctx))

      base = grant!(ctx).claims

      assert {:error, :issued_in_future} =
               Authority.admit(sign_custom(ctx, %{base | "iat" => now + 600}), request(ctx))

      assert {:error, :lifetime_exceeds_limit} =
               Authority.admit(
                 sign_custom(ctx, %{base | "exp" => now + Grants.max_ttl() + 600}),
                 request(ctx)
               )
    end

    test "a signed grant that was never registered is refused", ctx do
      claims = %{grant!(ctx).claims | "jti" => "grt_unregistered"}
      assert {:error, :not_registered} = Authority.admit(sign_custom(ctx, claims), request(ctx))
    end

    test "a missing grant is refused", ctx do
      assert {:error, :missing_grant} = Authority.admit(nil, request(ctx))
      assert {:error, :missing_grant} = Authority.admit("", request(ctx))
    end

    test "revoked before dispatch, and revoked during execution withholds the result", ctx do
      before = grant!(ctx)
      {:ok, _} = Authority.revoke_grant(ctx.tenant, before.jti, "user:owner")
      assert {:error, :revoked} = Authority.admit(before.token, request(ctx))

      during = grant!(ctx)
      assert {:ok, admission} = Authority.admit(during.token, request(ctx))
      assert :ok = Authority.checkpoint(ctx.tenant, admission.jti)
      {:ok, _} = Authority.revoke_grant(ctx.tenant, during.jti, "user:owner", "stop")
      assert {:error, :revoked} = Authority.checkpoint(ctx.tenant, admission.jti)
      assert {:error, :revoked} = Authority.release(ctx.tenant, admission.jti, %{"sum" => 60})
      assert "action.withheld" in kinds(ctx)

      done = grant!(ctx)
      {:ok, admission} = Authority.admit(done.token, request(ctx))
      assert :ok = Authority.release(ctx.tenant, admission.jti, %{"sum" => 60})
      assert "action.completed" in kinds(ctx)
    end

    test "a local deny survives a fresh, valid grant", ctx do
      grant = grant!(ctx)

      {:ok, deny} =
        Authority.add_local_deny(
          ctx.tenant,
          %{"subject" => "agent:analyst", "workspace_id" => ctx.workspace},
          "user:owner"
        )

      assert {:error, :local_deny} = Authority.admit(grant.token, request(ctx))

      {:ok, _} = Authority.lift_local_deny(ctx.tenant, deny.id, "user:owner")
      assert {:ok, _} = Authority.admit(grant.token, request(ctx))
    end

    test "ceilings are enforced and unmeasurable ones refuse", ctx do
      grant = grant!(ctx, %{"ceiling" => %{"records" => 5}})

      assert {:error, :ceiling_exceeded} =
               Authority.admit(grant.token, request(ctx, %{amounts: %{"records" => 6}}))

      assert {:ok, _} = Authority.admit(grant.token, request(ctx, %{amounts: %{"records" => 5}}))

      spend = grant!(ctx, %{"ceiling" => %{"records" => 5, "usd_spend" => 10}})
      assert {:error, :constraint_not_enforceable} = Authority.admit(spend.token, request(ctx))
      assert "could_not_enforce" in kinds(ctx)
    end

    test "grants signed by a revoked key stop verifying; rotation keeps old grants valid", ctx do
      old = grant!(ctx)
      {:ok, _new_key} = Authority.rotate_key(ctx.tenant, "grant", "user:owner")
      assert {:ok, _} = Authority.admit(old.token, request(ctx))

      compromised = grant!(ctx)
      [header | _] = String.split(compromised.token, ".")
      {:ok, header} = header |> JWS.decode64() |> then(fn {:ok, json} -> Jason.decode(json) end)
      :ok = Keys.revoke(ctx.tenant, header["kid"])
      assert {:error, :key_revoked} = Authority.admit(compromised.token, request(ctx))
    end
  end

  describe "outside issuers and disconnected behavior" do
    setup ctx do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      kid = Keys.thumbprint(public)
      jwks = %{"keys" => [Map.put(Keys.jwk(public), "kid", kid)]}

      {:ok, _} =
        Authority.register_issuer(ctx.tenant, "partner-authority", jwks, "user:owner",
          max_staleness_seconds: 60
        )

      sign = fn extra ->
        now = System.os_time(:second)

        claims =
          Map.merge(
            %{
              "iss" => "partner-authority",
              "aud" => Grants.audience(),
              "sub" => "agent:analyst",
              "iat" => now,
              "nbf" => now,
              "exp" => now + 300,
              "jti" => "ext_" <> Integer.to_string(System.unique_integer([:positive])),
              "optimal" => %{
                "tenant" => ctx.tenant,
                "workspace" => ctx.workspace,
                "action" => "compute",
                "resource" => ctx.resource,
                "data_class" => "internal",
                "command_sha256" => CanonicalJSON.hash(%{"sum" => "amount"}),
                "max_uses" => 1
              }
            },
            extra
          )

        {claims["jti"], JWS.sign(claims, Grants.typ(), kid, private)}
      end

      %{sign: sign}
    end

    test "outside grants verify against pinned keys and are one-use", ctx do
      {_jti, token} = ctx.sign.(%{})
      assert {:ok, %{origin: "external"}} = Authority.admit(token, request(ctx))
      assert {:error, :replayed} = Authority.admit(token, request(ctx))

      {_jti, unknown} = ctx.sign.(%{"iss" => "stranger"})
      assert {:error, :untrusted_issuer} = Authority.admit(unknown, request(ctx))
    end

    test "known revocations hold, a stale feed fails closed, and a push reconnects", ctx do
      {revoked_jti, revoked} = ctx.sign.(%{})

      {:ok, 1} =
        Authority.receive_revocations(ctx.tenant, "partner-authority", [%{"jti" => revoked_jti}])

      assert {:error, :revoked} = Authority.admit(revoked, request(ctx))

      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_issuers SET revocations_synced_at = datetime('now', '-10 minutes') WHERE tenant_id = ?1",
          [ctx.tenant]
        )

      {_jti, fresh} = ctx.sign.(%{})
      assert {:error, :authority_unavailable} = Authority.admit(fresh, request(ctx))
      assert {:error, :revoked} = Authority.admit(revoked, request(ctx))

      {:ok, 0} = Authority.receive_revocations(ctx.tenant, "partner-authority", [])
      assert {:ok, _} = Authority.admit(fresh, request(ctx))
    end

    test "a local deny also stops outside grants", ctx do
      {:ok, _} = Authority.add_local_deny(ctx.tenant, %{"action" => "compute"}, "user:owner")
      {_jti, token} = ctx.sign.(%{})
      assert {:error, :local_deny} = Authority.admit(token, request(ctx))
    end
  end

  describe "evidence chain" do
    test "verifies, exports and verifies offline", ctx do
      grant = grant!(ctx)
      {:ok, _} = Authority.admit(grant.token, request(ctx))
      assert {:ok, %{entries: n, head: head}} = Evidence.verify(ctx.tenant)
      assert n >= 3
      assert {:ok, checkpoint} = Evidence.checkpoint(ctx.tenant, "external-anchor-1")
      assert checkpoint["hash"] == head

      bundle = ctx.tenant |> Evidence.export() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, %{head: ^head}} = Evidence.verify_export(bundle)

      tampered =
        update_in(bundle, ["entries", Access.at(1), "detail"], &Map.put(&1, "by", "someone-else"))

      assert {:error, %{reason: :hash_mismatch}} = Evidence.verify_export(tampered)
    end

    test "a changed, removed or reordered entry is detected", ctx do
      for _ <- 1..3, do: grant!(ctx)
      assert {:ok, _} = Evidence.verify(ctx.tenant)
      {:ok, _} = Evidence.checkpoint(ctx.tenant)

      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_evidence SET detail = '{\"by\":\"someone-else\"}' WHERE tenant_id = ?1 AND tenant_seq = 2",
          [ctx.tenant]
        )

      assert {:error, %{seq: 2, reason: :hash_mismatch}} = Evidence.verify(ctx.tenant)
    end

    test "a deleted entry leaves a gap", ctx do
      for _ <- 1..3, do: grant!(ctx)

      {:ok, _} =
        Store.raw_query("DELETE FROM authority_evidence WHERE tenant_id = ?1 AND tenant_seq = 2", [
          ctx.tenant
        ])

      assert {:error, %{reason: :sequence_gap}} = Evidence.verify(ctx.tenant)
    end

    test "swapping two entries breaks the links", ctx do
      for _ <- 1..3, do: grant!(ctx)

      {:ok, _} =
        Store.raw_query(
          """
          UPDATE authority_evidence SET tenant_seq = CASE tenant_seq WHEN 2 THEN 1002 WHEN 3 THEN 2 END
          WHERE tenant_id = ?1 AND tenant_seq IN (2, 3)
          """,
          [ctx.tenant]
        )

      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_evidence SET tenant_seq = 3 WHERE tenant_id = ?1 AND tenant_seq = 1002",
          [ctx.tenant]
        )

      assert {:error, %{reason: reason}} = Evidence.verify(ctx.tenant)
      assert reason in [:broken_link, :hash_mismatch]
    end
  end

  describe "integrity scan" do
    test "a clean tenant has no findings", ctx do
      grant!(ctx)
      assert %{findings: []} = Integrity.scan(ctx.tenant)
    end

    test "changes made outside authority are reported", ctx do
      grant = grant!(ctx)
      revoked = grant!(ctx)
      {:ok, _} = Authority.revoke_grant(ctx.tenant, revoked.jti, "user:owner")
      {:ok, deny} = Authority.add_local_deny(ctx.tenant, %{"subject" => "agent:z"}, "user:owner")
      policy = Policy.active(ctx.tenant, "workspace", ctx.workspace)

      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_grants SET expires_at = expires_at + 86400 WHERE jti = ?1",
          [grant.jti]
        )

      {:ok, _} =
        Store.raw_query("UPDATE authority_grants SET status = 'active' WHERE jti = ?1", [
          revoked.jti
        ])

      {:ok, _} = Store.raw_query("DELETE FROM authority_local_denies WHERE id = ?1", [deny.id])

      {:ok, _} =
        Store.raw_query("UPDATE authority_policies SET document = ?2 WHERE id = ?1", [
          policy.id,
          CanonicalJSON.encode(%{
            "name" => "ops",
            "rules" => [%{"id" => "all", "effect" => "allow"}]
          })
        ])

      findings = Integrity.scan(ctx.tenant, record: true).findings
      kinds = Enum.map(findings, &{&1["finding"], &1["id"]})

      assert {"grant_changed_outside_authority", grant.jti} in kinds
      assert {"grant_changed_outside_authority", revoked.jti} in kinds
      assert {"local_deny_removed_outside_authority", deny.id} in kinds
      assert {"policy_changed_outside_authority", policy.id} in kinds
      assert "integrity.finding" in kinds(ctx)
    end
  end

  describe "effective state" do
    test "reads back the rules, grants in force and local denies for a subject", ctx do
      grant = grant!(ctx, %{"max_uses" => 2})
      spent = grant!(ctx)
      {:ok, _} = Authority.admit(spent.token, request(ctx))

      {:ok, _} =
        Authority.add_local_deny(
          ctx.tenant,
          %{"subject" => "agent:*", "action" => "export"},
          "user:owner"
        )

      state = Authority.effective(ctx.tenant, "agent:analyst", ctx.workspace)
      assert Enum.map(state["rules"], & &1["id"]) == ["agents-read", "exports-ask", "no-restricted"]
      assert [%{"jti" => jti, "remaining_uses" => 2}] = state["grants"]
      assert jti == grant.jti
      assert [%{action: "export"}] = state["local_denies"]
      assert state["mode"] == "off"
    end
  end
end
