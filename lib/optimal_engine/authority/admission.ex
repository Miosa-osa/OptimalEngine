defmodule OptimalEngine.Authority.Admission do
  @moduledoc """
  The enforcement point: checks a presented grant against the exact request
  before anything happens, and again before a result is released.

  `admit/3` refuses unless every check passes, in this order, so nothing in
  a token is trusted before its signature is:

  1. Shape: three base64url parts, header `alg: EdDSA` only (no `none`, no
     HMAC), `typ: optimal-grant+jws`, a `kid`, no `crit`, canonical payload.
  2. Key: the `kid` is pinned for the claimed issuer in the enforcer's own
     tenant (local grant key, or a registered outside issuer); revoked keys
     do not verify.
  3. Signature (Ed25519).
  4. Issuer trusted, audience is this enforcer.
  5. Time: not before `nbf`, before `exp`, `iat` not in the future, and a
     lifetime no longer than the Engine allows.
  6. Binding: subject, tenant, workspace, action, resource, data class, and
     the command hash all equal the request.
  7. Ceilings: each requested amount within the grant's ceiling; a ceiling
     this enforcer cannot measure means refusal (`constraint_not_enforceable`),
     never a silent pass.
  8. Independent local deny.
  9. State: for local grants the registry row and every grant it was
     narrowed from must be neither revoked nor suspended; for outside grants
     the issuer's revocations must be known and fresh (fail closed while
     disconnected).
  10. Uses: one admission is consumed atomically, so a replay (even two at
      once) is refused.

  Every admission and refusal is recorded in the evidence chain.
  """

  alias OptimalEngine.Authority.{Evidence, Grants, Issuers, JWS, Keys, LocalDeny, WorkspaceRekeys}

  @skew 5
  @measurable_ceilings ~w(records bytes calls tokens)

  @doc """
  Admits `token` for `request`. Options: `:measurable` (ceiling names this
  enforcer can measure; defaults to records, bytes, calls, tokens) and
  `:consume` (default true).
  """
  @spec admit(String.t(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def admit(token, request, opts \\ []) do
    request = normalize(request)

    case check(token, request, opts) do
      {:ok, claims, origin} ->
        detail = %{"origin" => origin, "issuer" => claims["iss"], "amounts" => request.amounts}
        record(request, "grant.admitted", claims["jti"], detail)
        {:ok, %{jti: claims["jti"], claims: claims, origin: origin, subject: request.subject}}

      {:error, reason, jti} ->
        record(request, "grant.denied", jti, %{"reason" => Atom.to_string(reason)})

        if reason == :constraint_not_enforceable,
          do: record(request, "could_not_enforce", jti, %{"constraint" => "ceiling"})

        {:error, reason}
    end
  end

  @doc """
  Re-checks an admitted grant during execution. Returns `:ok` while it is
  still in force, otherwise `{:error, :revoked | :suspended | :expired}`.
  """
  @spec checkpoint(String.t(), String.t(), map()) :: :ok | {:error, atom()}
  def checkpoint(tenant_id, jti, context \\ %{}) do
    case in_force(tenant_id, jti) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Evidence.append(tenant_id, "grant.checkpoint", %{
          jti: jti,
          subject: context[:subject],
          detail: %{"in_force" => false, "reason" => Atom.to_string(reason)}
        })

        error
    end
  end

  @doc """
  Releases a result: re-checks the grant and records completion, or records
  that the result was withheld because the grant stopped being in force.
  `result` is hashed into the evidence, never stored.
  """
  @spec release(String.t(), String.t(), term(), map()) :: :ok | {:error, atom()}
  def release(tenant_id, jti, result, context \\ %{}) do
    result_hash = OptimalEngine.Authority.CanonicalJSON.hash(result)

    case in_force(tenant_id, jti) do
      :ok ->
        Evidence.append(tenant_id, "action.completed", %{
          jti: jti,
          subject: context[:subject],
          detail: %{"result_sha256" => result_hash}
        })

        :ok

      {:error, reason} = error ->
        Evidence.append(tenant_id, "action.withheld", %{
          jti: jti,
          subject: context[:subject],
          detail: %{"reason" => Atom.to_string(reason), "result_sha256" => result_hash}
        })

        error
    end
  end

  # ---------------------------------------------------------------------------

  defp check(token, _request, _opts) when not is_binary(token) or token == "",
    do: {:error, :missing_grant, nil}

  defp check(token, request, opts) do
    with {:ok, parsed} <- JWS.parse(token, Grants.typ()) |> tag(nil),
         claims = parsed.claims,
         jti = claims["jti"],
         {:ok, origin, public_key} <-
           verification_key(request.tenant_id, claims, parsed.header) |> tag(jti),
         :ok <- JWS.verify_signature(parsed, public_key) |> tag(jti),
         :ok <- audience(claims, request) |> tag(jti),
         :ok <- times(claims) |> tag(jti),
         :ok <- binding(claims, request) |> tag(jti),
         :ok <- ceilings(claims, request, opts) |> tag(jti),
         :ok <- local_deny(request) |> tag(jti),
         :ok <- state(origin, request.tenant_id, claims) |> tag(jti),
         :ok <- consume(origin, request.tenant_id, claims, opts) |> tag(jti) do
      {:ok, claims, origin}
    end
  end

  defp tag(:ok, _jti), do: :ok
  defp tag({:ok, value}, _jti), do: {:ok, value}
  defp tag({:ok, a, b}, _jti), do: {:ok, a, b}
  defp tag({:error, reason}, jti), do: {:error, reason, jti}

  defp verification_key(tenant_id, %{"iss" => issuer}, %{"kid" => kid}) when is_binary(issuer) do
    if issuer == Grants.issuer() do
      case Keys.verification_key(tenant_id, kid, "grant") do
        {:ok, key} -> {:ok, "local", key}
        error -> error
      end
    else
      case Issuers.key(tenant_id, issuer, kid) do
        {:ok, key} -> {:ok, "external", key}
        error -> error
      end
    end
  end

  defp verification_key(_tenant_id, _claims, _header), do: {:error, :untrusted_issuer}

  defp audience(%{"aud" => aud}, request) do
    cond do
      aud == request.audience -> :ok
      is_list(aud) and request.audience in aud -> :ok
      true -> {:error, :wrong_audience}
    end
  end

  defp audience(_claims, _request), do: {:error, :wrong_audience}

  defp times(%{"nbf" => nbf, "exp" => exp, "iat" => iat})
       when is_integer(nbf) and is_integer(exp) and is_integer(iat) do
    now = System.os_time(:second)

    cond do
      iat > now + @skew -> {:error, :issued_in_future}
      nbf > now + @skew -> {:error, :not_yet_valid}
      exp <= now -> {:error, :expired}
      exp - nbf > Grants.max_ttl() -> {:error, :lifetime_exceeds_limit}
      true -> :ok
    end
  end

  defp times(_claims), do: {:error, :invalid_time_claims}

  defp binding(%{"sub" => sub, "optimal" => %{} = optimal} = claims, request) do
    cond do
      sub != request.subject -> {:error, :wrong_subject}
      optimal["tenant"] != request.tenant_id -> {:error, :wrong_tenant}
      true -> workspace_binding(claims, optimal, request)
    end
  end

  defp binding(_claims, _request), do: {:error, :malformed}

  defp workspace_binding(claims, optimal, request) do
    {workspace, resource} = bound_workspace(claims, optimal, request)

    cond do
      workspace != request.workspace_id -> {:error, :wrong_workspace}
      optimal["action"] != request.action -> {:error, :wrong_action}
      not resource_covered?(resource, request.resource) -> {:error, :wrong_resource}
      (optimal["data_class"] || "internal") != request.data_class -> {:error, :wrong_data_class}
      command_mismatch?(optimal["command_sha256"], request) -> {:error, :command_mismatch}
      true -> :ok
    end
  end

  # A grant names its workspace by the id it had when it was issued. When
  # that is not the id asked for, the signed workspace id repairs recorded
  # after the grant was issued are followed (`WorkspaceRekeys`), so a grant
  # issued before an operator's repair still admits under the new id, and
  # only that one. A grant issued after a repair is not changed by it, and a
  # grant with no local issuance entry (an outside issuer's) is taken as
  # written.
  defp bound_workspace(claims, optimal, request) do
    as_written = {optimal["workspace"], optimal["resource"]}

    with true <- optimal["workspace"] != request.workspace_id,
         jti when is_binary(jti) <- claims["jti"],
         seq when is_integer(seq) <- issued_seq(request.tenant_id, jti),
         [_ | _] = rekeys <- WorkspaceRekeys.list(request.tenant_id) do
      {WorkspaceRekeys.current(rekeys, optimal["workspace"], seq),
       WorkspaceRekeys.current_resource(rekeys, optimal["resource"], seq)}
    else
      _ -> as_written
    end
  end

  # Where in the evidence chain the Engine recorded issuing the grant.
  defp issued_seq(tenant_id, jti) do
    tenant_id
    |> Evidence.list(jti: jti)
    |> Enum.find(fn entry ->
      entry["kind"] in ["grant.issued", "grant.narrowed"] and
        Evidence.verify_one(tenant_id, entry) == :ok
    end)
    |> case do
      nil -> nil
      entry -> entry["seq"]
    end
  end

  defp resource_covered?(granted, requested) when is_binary(granted) and is_binary(requested) do
    granted == requested or
      (String.contains?(granted, "*") and OptimalEngine.Authority.Policy.glob?(granted, requested))
  end

  defp resource_covered?(_granted, _requested), do: false

  defp command_mismatch?(nil, _request), do: false
  defp command_mismatch?(hash, %{command_sha256: hash}), do: false
  defp command_mismatch?(_hash, _request), do: true

  defp ceilings(%{"optimal" => optimal}, request, opts) do
    ceiling = optimal["ceiling"] || %{}
    measurable = Keyword.get(opts, :measurable, @measurable_ceilings)

    cond do
      Enum.any?(Map.keys(ceiling), &(&1 not in measurable)) ->
        {:error, :constraint_not_enforceable}

      Enum.any?(ceiling, fn {name, limit} -> amount(request, name) > limit end) ->
        {:error, :ceiling_exceeded}

      true ->
        :ok
    end
  end

  defp amount(request, name) do
    case Map.get(request.amounts, name) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp local_deny(request) do
    case LocalDeny.matching(request.tenant_id, request) do
      nil -> :ok
      _deny -> {:error, :local_deny}
    end
  end

  defp state("local", tenant_id, %{"jti" => jti}) do
    in_force(tenant_id, jti)
  end

  defp state("external", tenant_id, %{"iss" => issuer, "jti" => jti}) do
    cond do
      Issuers.revoked?(tenant_id, issuer, jti) -> {:error, :revoked}
      true -> Issuers.fresh(tenant_id, issuer)
    end
  end

  # Uses are consumed last, after every other check passed, so a refused
  # request never spends a use.
  defp consume(origin, tenant_id, claims, opts) do
    if Keyword.get(opts, :consume, true), do: consume_use(origin, tenant_id, claims), else: :ok
  end

  defp consume_use("local", tenant_id, %{"jti" => jti}) do
    OptimalEngine.Store.transaction(fn txn ->
      OptimalEngine.Store.txn_execute(
        txn,
        """
        UPDATE authority_grants
        SET uses = uses + 1,
            status = CASE WHEN uses + 1 >= max_uses THEN 'consumed' ELSE status END
        WHERE tenant_id = ?1 AND jti = ?2 AND status = 'active' AND uses < max_uses
        """,
        [tenant_id, jti]
      )
    end)
    |> case do
      {:ok, 1} -> :ok
      _ -> {:error, :replayed}
    end
  end

  defp consume_use("external", tenant_id, %{"iss" => issuer, "jti" => jti} = claims) do
    max_uses = get_in(claims, ["optimal", "max_uses"]) || 1
    Issuers.consume(tenant_id, issuer, jti, max_uses)
  end

  @doc false
  # A grant is in force while it and every grant it was narrowed from are
  # neither revoked nor suspended, and it has not expired.
  def in_force(tenant_id, jti) do
    with {:ok, grant} <- Grants.fetch(tenant_id, jti) |> registered() do
      chain = [grant | Grants.ancestors(tenant_id, jti)]

      cond do
        Enum.any?(chain, &(&1.status == "revoked")) -> {:error, :revoked}
        Enum.any?(chain, &(&1.status == "suspended")) -> {:error, :suspended}
        Grants.expired?(grant) -> {:error, :expired}
        true -> :ok
      end
    end
  end

  defp registered({:ok, grant}), do: {:ok, grant}
  defp registered({:error, :not_found}), do: {:error, :not_registered}

  defp record(request, kind, jti, detail) do
    Evidence.append(request.tenant_id, kind, %{
      jti: jti,
      subject: request.subject,
      action: request.action,
      resource: request.resource,
      workspace_id: request.workspace_id,
      detail: detail
    })
  end

  defp normalize(request) do
    request = Map.new(request, fn {key, value} -> {to_key(key), value} end)

    command_sha256 =
      case Map.fetch(request, :command) do
        {:ok, command} -> Grants.command_hash(command)
        :error -> request[:command_sha256]
      end

    %{
      tenant_id: request[:tenant_id] || "default",
      audience: request[:audience] || Grants.audience(),
      subject: request[:subject],
      workspace_id: request[:workspace_id],
      action: request[:action],
      resource: request[:resource],
      data_class: request[:data_class] || "internal",
      command_sha256: command_sha256,
      amounts: stringify_amounts(request[:amounts] || %{})
    }
  end

  defp stringify_amounts(amounts) when is_map(amounts),
    do: Map.new(amounts, fn {name, value} -> {to_string(name), value} end)

  defp stringify_amounts(_amounts), do: %{}

  @keys ~w(tenant_id audience subject workspace_id action resource data_class command command_sha256 amounts)
  defp to_key(key) when is_atom(key), do: key
  defp to_key(key) when key in @keys, do: String.to_existing_atom(key)
  defp to_key(key), do: key
end
