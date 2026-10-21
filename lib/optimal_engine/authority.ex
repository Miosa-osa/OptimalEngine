defmodule OptimalEngine.Authority do
  @moduledoc """
  Optimal Authority: one model for who or what may read, search, write,
  share, export, erase, sync, or act, for people, agents, and apps alike.

  Authority comes from the institution. Policy packs (System 5) say what is
  allowed, what needs approval, and what is denied; nothing creates
  authority on its own, and delegation only narrows. The pieces:

  * `OptimalEngine.Authority.Policy` - versioned, hash-identified packs per
    tenant, workspace, or subject; deny wins; default deny.
  * `OptimalEngine.Authority.Decision` - the decision point.
  * `OptimalEngine.Authority.Grants` - signed, short-lived, registered grants
    (`optimal-grant+jws`, Ed25519, RFC 8785 canonical claims) and their
    lifecycle: issue, narrow, suspend, restore, revoke, expire.
  * `OptimalEngine.Authority.Requests` - approval for what policy asks for.
  * `OptimalEngine.Authority.Admission` - the enforcement point.
  * `OptimalEngine.Authority.LocalDeny` - the stop no grant overrides.
  * `OptimalEngine.Authority.Issuers` - outside authorities and disconnected
    behavior.
  * `OptimalEngine.Authority.Evidence` - the signed, hash-chained record.
  * `OptimalEngine.Authority.Integrity` - changes made outside authority.

  This module is the facade: each state change goes through here so it is
  recorded as evidence exactly once.
  """

  alias OptimalEngine.Authority.{
    Admission,
    Decision,
    Evidence,
    Grants,
    Integrity,
    Issuers,
    Keys,
    LocalDeny,
    Policy,
    Requests,
    Settings
  }

  alias OptimalEngine.Store

  # -- decisions ---------------------------------------------------------------

  @doc "Decides a request. With `record: true` a deny or ask is recorded."
  @spec decide(map(), keyword()) :: Decision.t()
  def decide(request, opts \\ []) do
    decision = Decision.decide(request)

    if Keyword.get(opts, :record, false) and decision.effect != :allow do
      request = Decision.normalize(request)

      Evidence.append(request.tenant_id, decision_kind(decision.effect), %{
        subject: request.subject,
        action: request.action,
        resource: request.resource,
        workspace_id: request.workspace_id,
        detail: decision_detail(decision)
      })
    end

    decision
  end

  # -- policy ------------------------------------------------------------------

  @doc """
  Publishes a pack. A pack that loosens the one it replaces needs a grant
  for action `authority:loosen` on the pack's scope resource when the tenant
  enforces authority; otherwise the loosening is published and flagged.
  """
  @spec publish_policy(String.t(), String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def publish_policy(tenant_id, scope_type, scope_id, document, published_by, opts \\ []) do
    with {:ok, normalized} <- Policy.validate(document) do
      previous = Policy.active(tenant_id, scope_type, scope_id)
      loosening = Policy.loosening(previous && previous.document, normalized)
      resource = policy_resource(scope_type, scope_id)

      with :ok <- loosening_authorized(tenant_id, loosening, resource, published_by, opts),
           {:ok, policy, _previous} <-
             Policy.publish(tenant_id, scope_type, scope_id, normalized, published_by) do
        Evidence.append(tenant_id, "policy.published", %{
          subject: published_by,
          action: "authority:publish",
          resource: resource,
          detail: Map.put(Integrity.policy_detail(policy), "loosening", loosening)
        })

        if loosening != [] do
          Evidence.append(tenant_id, "policy.loosened", %{
            subject: published_by,
            action: "authority:publish",
            resource: resource,
            detail: %{
              "policy_id" => policy.id,
              "changes" => loosening,
              "authorized_by_grant" => opts[:grant] != nil
            }
          })
        end

        {:ok, Map.put(policy, :loosening, loosening)}
      end
    end
  end

  @doc "The resource URI that names a pack scope (for loosening grants)."
  @spec policy_resource(String.t(), String.t()) :: String.t()
  def policy_resource(scope_type, scope_id),
    do: "optimal://authority/policies/#{scope_type}/#{scope_id}"

  @doc """
  A starting pack by data class: members and agents may read and search
  public and internal data, members may write it; confidential exports,
  shares and erasure need approval; agents never touch restricted data;
  restricted data never leaves by export or share.
  """
  @spec default_pack() :: map()
  def default_pack do
    %{
      "name" => "default-by-data-class",
      "rules" => [
        %{
          "id" => "read-open-data",
          "effect" => "allow",
          "subjects" => ["user:**", "agent:**", "app:**", "api_key:**", "local:**"],
          "actions" => ["read", "search"],
          "data_classes" => ["public", "internal"],
          "max_ttl_seconds" => 3_600
        },
        %{
          "id" => "members-write-open-data",
          "effect" => "allow",
          "subjects" => ["user:**", "local:**"],
          "actions" => ["write", "sync"],
          "data_classes" => ["public", "internal"],
          "max_ttl_seconds" => 3_600
        },
        %{
          "id" => "agents-write-with-approval",
          "effect" => "ask",
          "subjects" => ["agent:**", "app:**"],
          "actions" => ["write"],
          "data_classes" => ["internal"],
          "max_ttl_seconds" => 900
        },
        %{
          "id" => "confidential-read-members",
          "effect" => "allow",
          "subjects" => ["user:**", "local:**"],
          "actions" => ["read", "search"],
          "data_classes" => ["confidential"],
          "max_ttl_seconds" => 900
        },
        %{
          "id" => "sensitive-moves-need-approval",
          "effect" => "ask",
          "actions" => ["export", "share", "erase"],
          "data_classes" => ["internal", "confidential"],
          "max_ttl_seconds" => 900
        },
        %{
          "id" => "no-restricted-for-agents",
          "effect" => "deny",
          "subjects" => ["agent:**", "app:**"],
          "data_classes" => ["restricted"]
        },
        %{
          "id" => "restricted-never-leaves",
          "effect" => "deny",
          "actions" => ["export", "share"],
          "data_classes" => ["restricted"]
        }
      ]
    }
  end

  # -- grants ------------------------------------------------------------------

  @doc "Issues a grant (see `Grants.issue/3`) and records it."
  @spec issue_grant(String.t(), map(), String.t()) :: {:ok, map()} | {:error, atom(), map()}
  def issue_grant(tenant_id, attrs, issued_by) do
    case Grants.issue(tenant_id, attrs, issued_by) do
      {:ok, grant} ->
        record_grant(tenant_id, "grant.issued", grant, issued_by)
        {:ok, grant}

      {:error, reason, detail} ->
        if detail[:decision] && detail.decision.effect != :allow do
          attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

          Evidence.append(tenant_id, decision_kind(detail.decision.effect), %{
            subject: attrs["subject"],
            action: attrs["action"],
            resource: attrs["resource"],
            workspace_id: attrs["workspace_id"],
            detail: Map.put(decision_detail(detail.decision), "requested_by", issued_by)
          })
        end

        {:error, reason, detail}
    end
  end

  @doc "Narrows a grant (see `Grants.narrow/4`) and records it."
  @spec narrow_grant(String.t(), String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, atom(), map()}
  def narrow_grant(tenant_id, parent_jti, attrs, narrowed_by) do
    with {:ok, grant} <- Grants.narrow(tenant_id, parent_jti, attrs, narrowed_by) do
      record_grant(tenant_id, "grant.narrowed", grant, narrowed_by)
      {:ok, grant}
    end
  end

  @doc "Suspends a grant and records it."
  @spec suspend_grant(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def suspend_grant(tenant_id, jti, by, reason \\ nil) do
    with {:ok, grant} <- Grants.suspend(tenant_id, jti) do
      Evidence.append(tenant_id, "grant.suspended", %{
        jti: jti,
        subject: grant.subject,
        detail: %{"by" => by, "reason" => reason}
      })

      {:ok, grant}
    end
  end

  @doc "Restores a suspended grant and records it."
  @spec restore_grant(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def restore_grant(tenant_id, jti, by) do
    with {:ok, grant} <- Grants.restore(tenant_id, jti) do
      Evidence.append(tenant_id, "grant.restored", %{
        jti: jti,
        subject: grant.subject,
        detail: %{"by" => by}
      })

      {:ok, grant}
    end
  end

  @doc "Revokes a grant and everything narrowed from it, recording each."
  @spec revoke_grant(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, atom()}
  def revoke_grant(tenant_id, jti, by, reason \\ nil) do
    with {:ok, jtis} <- Grants.revoke(tenant_id, jti, by, reason) do
      Enum.each(jtis, fn revoked ->
        Evidence.append(tenant_id, "grant.revoked", %{
          jti: revoked,
          detail: %{
            "by" => by,
            "reason" => reason,
            "cascade_from" => if(revoked == jti, do: nil, else: jti)
          }
        })
      end)

      {:ok, jtis}
    end
  end

  # -- enforcement -------------------------------------------------------------

  defdelegate admit(token, request, opts \\ []), to: Admission
  defdelegate checkpoint(tenant_id, jti, context \\ %{}), to: Admission
  defdelegate release(tenant_id, jti, result, context \\ %{}), to: Admission

  # -- approvals ---------------------------------------------------------------

  @doc "Files an approval request and records it when it waits for approval."
  @spec request_approval(String.t(), map(), String.t()) ::
          {:ok, :allowed | map(), Decision.t()} | {:error, atom(), map()}
  def request_approval(tenant_id, attrs, requested_by) do
    case Requests.create(tenant_id, attrs, requested_by) do
      {:ok, %{} = request, decision} ->
        Evidence.append(tenant_id, "approval.requested", %{
          subject: request.subject,
          action: request.action,
          resource: request.resource,
          workspace_id: request.workspace_id,
          detail:
            Map.merge(decision_detail(decision), %{
              "request_id" => request.id,
              "requested_by" => requested_by
            })
        })

        {:ok, request, decision}

      other ->
        other
    end
  end

  @doc "Approves a request and issues the grant it asked for."
  @spec approve(String.t(), String.t(), String.t()) :: {:ok, map(), map()} | {:error, atom()}
  def approve(tenant_id, request_id, approver) do
    with {:ok, request} <- Requests.approve(tenant_id, request_id, approver) do
      Evidence.append(tenant_id, "approval.approved", %{
        subject: request.subject,
        action: request.action,
        resource: request.resource,
        workspace_id: request.workspace_id,
        detail: %{"request_id" => request.id, "approver" => approver}
      })

      attrs =
        %{
          "subject" => request.subject,
          "action" => request.action,
          "resource" => request.resource,
          "workspace_id" => request.workspace_id,
          "data_class" => request.data_class,
          "ttl_seconds" => request.ttl_seconds,
          "command_sha256" => request.command_sha256,
          "approval_id" => request.id
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      case issue_grant(tenant_id, attrs, approver) do
        {:ok, grant} -> {:ok, request, grant}
        {:error, reason, _detail} -> {:error, reason}
      end
    end
  end

  @doc "Denies a request and records it."
  @spec deny_request(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def deny_request(tenant_id, request_id, approver, reason \\ nil) do
    with {:ok, request} <- Requests.deny(tenant_id, request_id, approver, reason) do
      Evidence.append(tenant_id, "approval.denied", %{
        subject: request.subject,
        action: request.action,
        resource: request.resource,
        detail: %{"request_id" => request.id, "approver" => approver, "reason" => reason}
      })

      {:ok, request}
    end
  end

  # -- local denies ------------------------------------------------------------

  @doc "Adds a local deny and records it."
  @spec add_local_deny(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_local_deny(tenant_id, attrs, by) do
    # The deny and its record commit together, so a workspace id repair
    # cannot land between them and be recorded as older than the deny. An
    # Engine that cannot sign evidence still adds the deny: it is a stop.
    key = Evidence.signing_key(tenant_id)

    Store.transaction(fn txn ->
      with {:ok, deny} <- LocalDeny.add_in(txn, tenant_id, attrs, by),
           :ok <- record_deny(txn, key, tenant_id, deny, by) do
        {:ok, deny}
      end
    end)
  end

  defp record_deny(_txn, nil, _tenant_id, _deny, _by), do: :ok

  defp record_deny(txn, key, tenant_id, deny, by) do
    {:ok, _entry} =
      Evidence.append_in(txn, key, tenant_id, "local_deny.added", %{
        subject: deny.subject,
        action: deny.action,
        resource: deny.resource,
        workspace_id: deny.workspace_id,
        detail: %{"deny_id" => deny.id, "by" => by, "reason" => deny.reason}
      })

    :ok
  end

  @doc "Lifts a local deny and records it."
  @spec lift_local_deny(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def lift_local_deny(tenant_id, id, by) do
    with {:ok, deny} <- LocalDeny.lift(tenant_id, id, by) do
      Evidence.append(tenant_id, "local_deny.lifted", %{
        subject: deny.subject,
        action: deny.action,
        resource: deny.resource,
        detail: %{"deny_id" => deny.id, "by" => by}
      })

      {:ok, deny}
    end
  end

  # -- outside issuers ---------------------------------------------------------

  @doc "Registers an outside issuer and records it."
  @spec register_issuer(String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def register_issuer(tenant_id, issuer, jwks, by, opts \\ []) do
    with {:ok, registered} <- Issuers.register(tenant_id, issuer, jwks, opts) do
      kids = Enum.map(jwks["keys"], & &1["kid"])

      Evidence.append(tenant_id, "issuer.registered", %{
        detail: %{"issuer" => issuer, "kids" => kids, "by" => by}
      })

      {:ok, registered}
    end
  end

  @doc "Records revocations pushed by an outside issuer."
  @spec receive_revocations(String.t(), String.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def receive_revocations(tenant_id, issuer, revocations) do
    with {:ok, count} <- Issuers.record_revocations(tenant_id, issuer, revocations) do
      Evidence.append(tenant_id, "revocations.received", %{
        detail: %{"issuer" => issuer, "jtis" => Enum.map(revocations, & &1["jti"])}
      })

      {:ok, count}
    end
  end

  @doc """
  Records a receipt from an outside enforcer (for example a MIOSA surface):
  `kind` is `external.receipt` or `could_not_enforce`.
  """
  @spec record_receipt(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def record_receipt(tenant_id, receipt, reported_by) do
    kind =
      if receipt["outcome"] == "could_not_enforce",
        do: "could_not_enforce",
        else: "external.receipt"

    Evidence.append(tenant_id, kind, %{
      jti: receipt["jti"],
      subject: receipt["subject"],
      action: receipt["action"],
      resource: receipt["resource"],
      workspace_id: receipt["workspace_id"],
      detail:
        Map.merge(Map.drop(receipt, ~w(jti subject action resource workspace_id)), %{
          "reported_by" => reported_by
        })
    })
  end

  # -- settings, keys, state ---------------------------------------------------

  @doc "Sets the tenant's route enforcement mode and records it."
  @spec set_mode(String.t(), String.t(), String.t()) :: :ok | {:error, :invalid_mode}
  def set_mode(tenant_id, mode, by) do
    with :ok <- Settings.put_mode(tenant_id, mode, by) do
      Evidence.append(tenant_id, "settings.changed", %{detail: %{"mode" => mode, "by" => by}})
      :ok
    end
  end

  @doc "Rotates a signing key and records it."
  @spec rotate_key(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rotate_key(tenant_id, purpose, by) do
    with {:ok, key} <- Keys.rotate(tenant_id, purpose) do
      Evidence.append(tenant_id, "key.rotated", %{
        detail: %{"purpose" => purpose, "kid" => key.kid, "by" => by}
      })

      {:ok, Map.delete(key, :private_key)}
    end
  end

  @doc """
  Records the authority an API key was minted with, so integrity scans can
  detect later edits. Best effort: a missing evidence key never blocks
  minting.
  """
  @spec record_key_minted(String.t(), map(), String.t()) :: :ok
  def record_key_minted(tenant_id, key, minted_by) do
    _ =
      Evidence.append(tenant_id, "key.minted", %{
        subject: key.principal_id,
        detail: Map.put(Integrity.key_detail(key), "by", minted_by)
      })

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  What is actually enforced for `subject` right now: the mode, the packs and
  rules that name it, its grants in force, and the local denies that stop it.
  """
  @spec effective(String.t(), String.t(), String.t() | nil) :: map()
  def effective(tenant_id, subject, workspace_id \\ nil) do
    packs = Policy.applicable(tenant_id, workspace_id, subject)

    rules =
      for pack <- packs,
          rule <- pack.document["rules"],
          is_nil(rule["subjects"]) or Enum.any?(rule["subjects"], &Policy.glob?(&1, subject)) do
        Map.merge(rule, %{
          "policy_id" => pack.id,
          "policy_sha256" => pack.hash,
          "scope" => pack.scope_type
        })
      end

    grants =
      tenant_id
      |> Grants.list(subject: subject)
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.filter(&(Admission.in_force(tenant_id, &1.jti) == :ok))
      |> Enum.filter(&(is_nil(workspace_id) or &1.workspace_id == workspace_id))
      |> Enum.map(fn grant ->
        %{
          "jti" => grant.jti,
          "action" => grant.action,
          "resource" => grant.resource,
          "workspace_id" => grant.workspace_id,
          "data_class" => grant.data_class,
          "expires_at" => grant.expires_at,
          "remaining_uses" => grant.max_uses - grant.uses,
          "parent" => grant.parent_jti
        }
      end)

    denies =
      tenant_id
      |> LocalDeny.active()
      |> Enum.filter(fn deny ->
        Policy.glob?(deny.subject, subject) and
          (is_nil(deny.workspace_id) or is_nil(workspace_id) or deny.workspace_id == workspace_id)
      end)
      |> Enum.map(&Map.take(&1, [:id, :workspace_id, :subject, :action, :resource, :reason]))

    %{
      "subject" => subject,
      "tenant_id" => tenant_id,
      "workspace_id" => workspace_id,
      "mode" => Settings.mode(tenant_id),
      "packs" =>
        Enum.map(
          packs,
          &%{"id" => &1.id, "hash" => &1.hash, "scope" => &1.scope_type, "version" => &1.version}
        ),
      "rules" => rules,
      "grants" => grants,
      "local_denies" => denies,
      "as_of" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # ---------------------------------------------------------------------------

  defp loosening_authorized(_tenant_id, [], _resource, _by, _opts), do: :ok

  defp loosening_authorized(tenant_id, _loosening, resource, by, opts) do
    case {Settings.mode(tenant_id), opts[:grant]} do
      {"enforce", nil} ->
        {:error, :loosening_requires_grant}

      {_mode, nil} ->
        :ok

      {_mode, token} ->
        case Admission.admit(token, %{
               tenant_id: tenant_id,
               subject: by,
               action: "authority:loosen",
               resource: resource
             }) do
          {:ok, _admission} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp record_grant(tenant_id, kind, grant, by) do
    optimal = grant.claims["optimal"]

    Evidence.append(tenant_id, kind, %{
      jti: grant.jti,
      subject: grant.claims["sub"],
      action: optimal["action"],
      resource: optimal["resource"],
      workspace_id: optimal["workspace"],
      detail: %{
        "by" => by,
        "audience" => grant.claims["aud"],
        "expires_at" => grant.claims["exp"],
        "max_uses" => optimal["max_uses"],
        "parent" => optimal["parent"],
        "policy_sha256" => optimal["policy_sha256"],
        "rule" => optimal["rule"],
        "approval" => optimal["approval"],
        "token_sha256" => :crypto.hash(:sha256, grant.token) |> Base.encode16(case: :lower)
      }
    })
  end

  defp decision_detail(decision) do
    %{
      "effect" => Atom.to_string(decision.effect),
      "reason" => decision.reason,
      "rule" => decision.rule_id,
      "policy_id" => decision.policy_id,
      "policy_sha256" => decision.policy_hash,
      "local_deny" => decision.local_deny_id
    }
  end

  defp decision_kind(:deny), do: "decision.denied"
  defp decision_kind(:ask), do: "decision.ask"
  defp decision_kind(:allow), do: "decision.allowed"
end
