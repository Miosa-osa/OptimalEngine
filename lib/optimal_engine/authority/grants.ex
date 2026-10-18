defmodule OptimalEngine.Authority.Grants do
  @moduledoc """
  Grants: signed, short-lived statements of exactly who may do exactly what
  to exactly which resource, issued by this Engine and enforced wherever the
  audience says.

  A grant is a compact JWS (`typ: optimal-grant+jws`, EdDSA) over canonical
  JSON claims. The registered claims follow RFC 7519 (`iss`, `aud`, `sub`,
  `iat`, `nbf`, `exp`, `jti`); everything specific to authority sits under
  one `optimal` claim:

      tenant, workspace, action, resource, data_class,
      command_sha256   - binds the grant to one exact command or query
      ceiling          - named upper bounds (for example records: 100)
      max_uses         - how many admissions it allows (default 1)
      delegable        - whether it may be narrowed to another subject
      parent           - the grant it was narrowed from
      policy_sha256, rule, approval - why it was issued

  Issuance is a decision: the policy must allow, or ask with an approved
  request; the lifetime and ceilings may not exceed what the matching rules
  permit. Every grant is registered so it can be suspended, restored,
  revoked (with all grants narrowed from it), and read back.
  """

  alias OptimalEngine.Authority.{CanonicalJSON, Decision, JWS, Keys, Requests}
  alias OptimalEngine.Store

  @typ "optimal-grant+jws"
  @default_ttl 900

  @doc "The JWS `typ` every grant carries."
  @spec typ() :: String.t()
  def typ, do: @typ

  @doc "The issuer name this Engine signs grants as."
  @spec issuer() :: String.t()
  def issuer, do: config(:authority_issuer, "optimal-engine")

  @doc "The audience name this Engine enforces as."
  @spec audience() :: String.t()
  def audience, do: config(:authority_audience, "optimal-engine")

  @doc "The longest lifetime any grant may have, in seconds."
  @spec max_ttl() :: pos_integer()
  def max_ttl, do: config(:authority_max_ttl_seconds, 3_600)

  @doc """
  Issues a grant for `attrs` in `tenant_id`, on behalf of `issued_by`.

  `attrs`: `subject`, `action`, `resource` (required); `workspace_id`,
  `data_class`, `ttl_seconds`, `not_before` (unix seconds), `audience`,
  `max_uses`, `ceiling`, `command` (any JSON value, hashed into the grant),
  `delegable`, `approval_id`.
  """
  @spec issue(String.t(), map(), String.t()) :: {:ok, map()} | {:error, atom(), map()}
  def issue(tenant_id, attrs, issued_by) do
    attrs = normalize(attrs)
    request = request(tenant_id, attrs)
    decision = Decision.decide(request)

    with :ok <- required(attrs),
         {:ok, approval} <- authorized(tenant_id, decision, attrs, request),
         {:ok, limits} <- within_policy(attrs, decision) do
      sign_and_register(tenant_id, request, attrs, limits, decision, approval, nil, issued_by)
    else
      {:error, reason} -> {:error, reason, %{decision: decision}}
    end
  end

  @doc """
  Narrows grant `parent_jti` into a new grant. The child may only shrink:
  same action and data class, a resource inside the parent's, no later
  expiry, no larger ceilings or uses, and the same command binding. A
  different subject requires a delegable parent and a policy that does not
  deny that subject. Uses given to the child are reserved from the parent.
  """
  @spec narrow(String.t(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, atom(), map()}
  def narrow(tenant_id, parent_jti, attrs, narrowed_by) do
    attrs = normalize(attrs)

    with {:ok, parent} <- fetch(tenant_id, parent_jti),
         :ok <- usable_parent(parent),
         child_attrs = inherit(parent, attrs),
         :ok <- narrower(parent, child_attrs),
         request = request(tenant_id, child_attrs),
         decision = Decision.decide(request),
         :ok <- delegate_permitted(parent, child_attrs, decision) do
      limits = %{
        ttl: child_attrs["ttl_seconds"],
        not_before: child_attrs["not_before"],
        ceiling: child_attrs["ceiling"],
        max_uses: child_attrs["max_uses"],
        delegable:
          child_attrs["delegable"] == true and parent.claims["optimal"]["delegable"] == true
      }

      Store.transaction(fn txn ->
        case Store.txn_execute(
               txn,
               """
               UPDATE authority_grants SET uses = uses + ?3
               WHERE tenant_id = ?1 AND jti = ?2 AND status = 'active' AND uses + ?3 <= max_uses
               """,
               [tenant_id, parent_jti, limits.max_uses]
             ) do
          {:ok, 1} -> {:ok, :reserved}
          _ -> {:error, :parent_uses_exhausted}
        end
      end)
      |> case do
        {:ok, :reserved} ->
          sign_and_register(
            tenant_id,
            request,
            child_attrs,
            limits,
            decision,
            parent.claims["optimal"]["approval"],
            parent_jti,
            narrowed_by
          )

        {:error, reason} ->
          {:error, reason, %{}}
      end
    else
      {:error, reason} -> {:error, reason, %{}}
      {:error, reason, detail} -> {:error, reason, detail}
    end
  end

  @doc "Suspends an active grant; admissions stop until it is restored."
  @spec suspend(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def suspend(tenant_id, jti), do: transition(tenant_id, jti, ["active"], "suspended")

  @doc "Restores a suspended grant if it has not expired. Its limits are unchanged."
  @spec restore(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def restore(tenant_id, jti) do
    with {:ok, grant} <- fetch(tenant_id, jti) do
      if expired?(grant),
        do: {:error, :expired},
        else: transition(tenant_id, jti, ["suspended"], "active")
    end
  end

  @doc """
  Revokes a grant and every grant narrowed from it. Returns the revoked
  jtis, the grant itself first.
  """
  @spec revoke(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, atom()}
  def revoke(tenant_id, jti, revoked_by, reason \\ nil) do
    with {:ok, _grant} <- fetch(tenant_id, jti) do
      {:ok, rows} =
        Store.raw_query(
          """
          WITH RECURSIVE lineage(jti) AS (
            SELECT jti FROM authority_grants WHERE tenant_id = ?1 AND jti = ?2
            UNION
            SELECT g.jti FROM authority_grants g JOIN lineage l ON g.parent_jti = l.jti
            WHERE g.tenant_id = ?1
          )
          SELECT jti FROM lineage
          """,
          [tenant_id, jti]
        )

      jtis = Enum.map(rows, &hd/1)

      Enum.each(jtis, fn id ->
        {:ok, _} =
          Store.raw_query(
            """
            UPDATE authority_grants
            SET status = 'revoked', revoked_at = datetime('now'), revoked_by = ?3, revoked_reason = ?4
            WHERE tenant_id = ?1 AND jti = ?2 AND status != 'revoked'
            """,
            [tenant_id, id, revoked_by, reason]
          )
      end)

      {:ok, [jti | List.delete(jtis, jti)]}
    end
  end

  @doc "A registered grant."
  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch(tenant_id, jti) do
    case Store.raw_query(select_sql("WHERE tenant_id = ?1 AND jti = ?2"), [tenant_id, jti]) do
      {:ok, [row]} -> {:ok, to_grant(row)}
      _ -> {:error, :not_found}
    end
  end

  @doc "Registered grants, newest first. Filters: `:subject`, `:status`, `:workspace_id`."
  @spec list(String.t(), keyword()) :: [map()]
  def list(tenant_id, opts \\ []) do
    filters =
      [subject: "subject", status: "status", workspace_id: "workspace_id"]
      |> Enum.flat_map(fn {opt, column} ->
        case opts[opt] do
          nil -> []
          value -> [{column, value}]
        end
      end)

    where =
      ["tenant_id = ?1"] ++
        (filters |> Enum.with_index(2) |> Enum.map(fn {{column, _}, i} -> "#{column} = ?#{i}" end))

    {:ok, rows} =
      Store.raw_query(
        select_sql("WHERE " <> Enum.join(where, " AND ") <> " ORDER BY issued_at DESC LIMIT 500"),
        [tenant_id | Enum.map(filters, &elem(&1, 1))]
      )

    Enum.map(rows, &to_grant/1)
  end

  @doc "The jtis from `jti` up to its root, nearest first (excluding `jti`)."
  @spec ancestors(String.t(), String.t()) :: [map()]
  def ancestors(tenant_id, jti) do
    case fetch(tenant_id, jti) do
      {:ok, %{parent_jti: nil}} -> []
      {:ok, %{parent_jti: parent}} -> collect_ancestors(tenant_id, parent, [])
      _ -> []
    end
  end

  @doc "Whether the grant's expiry has passed."
  @spec expired?(map()) :: boolean()
  def expired?(%{claims: %{"exp" => exp}}), do: exp <= now()

  @doc "SHA-256 of the canonical form of a command, as bound into grants."
  @spec command_hash(term()) :: String.t()
  def command_hash(command), do: CanonicalJSON.hash(command)

  # ---------------------------------------------------------------------------

  defp sign_and_register(tenant_id, request, attrs, limits, decision, approval, parent_jti, by) do
    with {:ok, key} <- Keys.active(tenant_id, "grant") do
      jti = "grt_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
      issued_at = now()
      not_before = limits.not_before || issued_at
      expires_at = not_before + limits.ttl

      optimal =
        %{
          "tenant" => tenant_id,
          "workspace" => request.workspace_id,
          "action" => request.action,
          "resource" => request.resource,
          "data_class" => request.data_class,
          "command_sha256" => attrs["command_sha256"],
          "ceiling" => limits.ceiling,
          "max_uses" => limits.max_uses,
          "delegable" => limits.delegable,
          "parent" => parent_jti,
          "policy_sha256" => decision.policy_hash,
          "rule" => decision.rule_id,
          "approval" => approval
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      claims = %{
        "iss" => issuer(),
        "aud" => attrs["audience"] || audience(),
        "sub" => request.subject,
        "iat" => issued_at,
        "nbf" => not_before,
        "exp" => expires_at,
        "jti" => jti,
        "optimal" => optimal
      }

      token = JWS.sign(claims, @typ, key.kid, key.private_key)

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO authority_grants
            (jti, tenant_id, workspace_id, issuer, audience, subject, action, resource, data_class,
             command_hash, parent_jti, delegable, max_uses, uses, status, not_before, expires_at,
             claims, token_hash, kid, policy_hash, rule_id, approval_id, issued_by)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, 0, 'active', ?14, ?15,
                  ?16, ?17, ?18, ?19, ?20, ?21, ?22)
          """,
          [
            jti,
            tenant_id,
            request.workspace_id,
            claims["iss"],
            claims["aud"],
            request.subject,
            request.action,
            request.resource,
            request.data_class,
            attrs["command_sha256"],
            parent_jti,
            if(limits.delegable, do: 1, else: 0),
            limits.max_uses,
            not_before,
            expires_at,
            CanonicalJSON.encode(claims),
            :crypto.hash(:sha256, token) |> Base.encode16(case: :lower),
            key.kid,
            decision.policy_hash,
            decision.rule_id,
            approval,
            by
          ]
        )

      if approval && is_nil(parent_jti), do: Requests.mark_used(tenant_id, approval, jti)

      {:ok, %{token: token, jti: jti, claims: claims, decision: decision}}
    else
      {:error, reason} -> {:error, reason, %{decision: decision}}
    end
  end

  defp authorized(_tenant_id, %{effect: :allow}, attrs, _request), do: {:ok, attrs["approval_id"]}

  defp authorized(tenant_id, %{effect: :ask}, %{"approval_id" => approval_id}, request)
       when is_binary(approval_id) do
    if Requests.approved_for?(tenant_id, approval_id, request),
      do: {:ok, approval_id},
      else: {:error, :approval_required}
  end

  defp authorized(_tenant_id, %{effect: :ask}, _attrs, _request), do: {:error, :approval_required}
  defp authorized(_tenant_id, %{effect: :deny}, _attrs, _request), do: {:error, :denied}

  defp within_policy(attrs, decision) do
    policy_ttl = min(decision.max_ttl_seconds || max_ttl(), max_ttl())
    ttl = attrs["ttl_seconds"] || min(@default_ttl, policy_ttl)
    requested_ceiling = attrs["ceiling"] || %{}

    ceiling =
      Map.merge(decision.ceiling, requested_ceiling, fn _name, policy, requested ->
        min(policy, requested)
      end)

    cond do
      not (is_integer(ttl) and ttl > 0) ->
        {:error, :invalid_ttl}

      ttl > policy_ttl ->
        {:error, :ttl_exceeds_policy}

      Enum.any?(requested_ceiling, fn {name, value} ->
        Map.has_key?(decision.ceiling, name) and value > decision.ceiling[name]
      end) ->
        {:error, :ceiling_exceeds_policy}

      attrs["delegable"] == true and not decision.delegable ->
        {:error, :delegation_not_permitted}

      true ->
        {:ok,
         %{
           ttl: ttl,
           not_before: attrs["not_before"],
           ceiling: ceiling,
           max_uses: attrs["max_uses"] || 1,
           delegable: attrs["delegable"] == true
         }}
    end
  end

  defp usable_parent(parent) do
    cond do
      parent.status != "active" -> {:error, String.to_atom("parent_" <> parent.status)}
      expired?(parent) -> {:error, :parent_expired}
      true -> :ok
    end
  end

  defp inherit(parent, attrs) do
    optimal = parent.claims["optimal"]

    %{
      "subject" => attrs["subject"] || parent.subject,
      "action" => attrs["action"] || parent.action,
      "resource" => attrs["resource"] || parent.resource,
      "workspace_id" => Map.get(attrs, "workspace_id", parent.workspace_id),
      "data_class" => attrs["data_class"] || parent.data_class,
      "command_sha256" => attrs["command_sha256"] || optimal["command_sha256"],
      "ceiling" => attrs["ceiling"] || optimal["ceiling"] || %{},
      "max_uses" => attrs["max_uses"] || 1,
      "not_before" => max(attrs["not_before"] || now(), parent.claims["nbf"]),
      "ttl_seconds" =>
        attrs["ttl_seconds"] ||
          parent.claims["exp"] - max(attrs["not_before"] || now(), parent.claims["nbf"]),
      "delegable" => attrs["delegable"] == true,
      "audience" => attrs["audience"] || parent.audience
    }
  end

  defp narrower(parent, child) do
    parent_optimal = parent.claims["optimal"]
    parent_ceiling = parent_optimal["ceiling"] || %{}
    child_exp = child["not_before"] + child["ttl_seconds"]

    cond do
      child["action"] != parent.action ->
        {:error, :action_not_narrower}

      child["data_class"] != parent.data_class ->
        {:error, :data_class_not_narrower}

      child["workspace_id"] != parent.workspace_id ->
        {:error, :workspace_not_narrower}

      child["audience"] != parent.audience ->
        {:error, :audience_not_narrower}

      not within_resource?(parent.resource, child["resource"]) ->
        {:error, :resource_not_narrower}

      not (is_integer(child["ttl_seconds"]) and child["ttl_seconds"] > 0) ->
        {:error, :invalid_ttl}

      child_exp > parent.claims["exp"] ->
        {:error, :expiry_not_narrower}

      parent_optimal["command_sha256"] &&
          child["command_sha256"] != parent_optimal["command_sha256"] ->
        {:error, :command_not_narrower}

      Enum.any?(parent_ceiling, fn {name, limit} ->
        not Map.has_key?(child["ceiling"], name) or child["ceiling"][name] > limit
      end) ->
        {:error, :ceiling_not_narrower}

      not (is_integer(child["max_uses"]) and child["max_uses"] > 0) ->
        {:error, :invalid_max_uses}

      true ->
        :ok
    end
  end

  defp delegate_permitted(parent, child, decision) do
    cond do
      decision.effect == :deny -> {:error, :denied, %{decision: decision}}
      child["subject"] == parent.subject -> :ok
      parent.claims["optimal"]["delegable"] == true -> :ok
      true -> {:error, :not_delegable}
    end
  end

  defp within_resource?(parent, child),
    do: parent == child or OptimalEngine.Authority.Policy.glob?(parent, child)

  defp transition(tenant_id, jti, from, to) do
    placeholders =
      from |> Enum.with_index(3) |> Enum.map(fn {_, i} -> "?#{i}" end) |> Enum.join(", ")

    Store.transaction(fn txn ->
      Store.txn_execute(
        txn,
        "UPDATE authority_grants SET status = '#{to}' WHERE tenant_id = ?1 AND jti = ?2 AND status IN (#{placeholders})",
        [tenant_id, jti | from]
      )
    end)
    |> case do
      {:ok, 1} ->
        fetch(tenant_id, jti)

      {:ok, 0} ->
        if match?({:ok, _}, fetch(tenant_id, jti)),
          do: {:error, :invalid_state},
          else: {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_ancestors(tenant_id, jti, acc) do
    case fetch(tenant_id, jti) do
      {:ok, grant} ->
        acc = [grant | acc]

        if grant.parent_jti,
          do: collect_ancestors(tenant_id, grant.parent_jti, acc),
          else: Enum.reverse(acc)

      _ ->
        Enum.reverse(acc)
    end
  end

  defp required(attrs) do
    if Enum.all?(~w(subject action resource), &(is_binary(attrs[&1]) and attrs[&1] != "")),
      do: :ok,
      else: {:error, :subject_action_resource_required}
  end

  defp request(tenant_id, attrs) do
    Decision.normalize(%{
      tenant_id: tenant_id,
      workspace_id: attrs["workspace_id"],
      subject: attrs["subject"],
      action: attrs["action"],
      resource: attrs["resource"],
      data_class: attrs["data_class"]
    })
  end

  @known ~w(subject action resource workspace_id data_class ttl_seconds not_before audience
            max_uses ceiling command command_sha256 delegable approval_id)

  defp normalize(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(@known)

    case Map.pop(attrs, "command") do
      {nil, attrs} -> attrs
      {command, attrs} -> Map.put(attrs, "command_sha256", command_hash(command))
    end
  end

  defp select_sql(where) do
    """
    SELECT jti, tenant_id, workspace_id, issuer, audience, subject, action, resource, data_class,
           command_hash, parent_jti, delegable, max_uses, uses, status, not_before, expires_at,
           claims, kid, policy_hash, rule_id, approval_id, issued_by, issued_at, revoked_at,
           revoked_by, revoked_reason
    FROM authority_grants #{where}
    """
  end

  defp to_grant([
         jti,
         tenant_id,
         workspace_id,
         issuer,
         audience,
         subject,
         action,
         resource,
         data_class,
         command_hash,
         parent_jti,
         delegable,
         max_uses,
         uses,
         status,
         not_before,
         expires_at,
         claims,
         kid,
         policy_hash,
         rule_id,
         approval_id,
         issued_by,
         issued_at,
         revoked_at,
         revoked_by,
         revoked_reason
       ]) do
    %{
      jti: jti,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      issuer: issuer,
      audience: audience,
      subject: subject,
      action: action,
      resource: resource,
      data_class: data_class,
      command_hash: command_hash,
      parent_jti: parent_jti,
      delegable: delegable == 1,
      max_uses: max_uses,
      uses: uses,
      status: status,
      not_before: not_before,
      expires_at: expires_at,
      claims: Jason.decode!(claims),
      kid: kid,
      policy_hash: policy_hash,
      rule_id: rule_id,
      approval_id: approval_id,
      issued_by: issued_by,
      issued_at: issued_at,
      revoked_at: revoked_at,
      revoked_by: revoked_by,
      revoked_reason: revoked_reason
    }
  end

  defp now, do: System.os_time(:second)

  defp config(key, default) do
    case Application.get_env(:optimal_engine, key) do
      nil -> default
      value -> value
    end
  end
end
