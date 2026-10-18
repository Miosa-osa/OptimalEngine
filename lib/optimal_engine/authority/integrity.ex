defmodule OptimalEngine.Authority.Integrity do
  @moduledoc """
  Detects authority changes made outside authority.

  Packs, grants, local denies, and API keys are only supposed to change
  through the authority and key APIs, each of which leaves evidence. An
  administrator with database access can still loosen something directly.
  `scan/1` compares the live rows with what the evidence chain says and
  reports every difference:

  * `evidence_chain_broken` - the chain itself fails verification;
  * `policy_changed_outside_authority` - an active pack whose content no
    longer matches its hash, or that was never published with evidence;
  * `grant_changed_outside_authority` - a grant missing from the evidence,
    a registry row whose lifetime, subject, action or resource no longer
    match its signed claims, or a grant active again after its revocation or
    suspension was recorded;
  * `local_deny_removed_outside_authority` - a deny recorded as added that
    is gone or lifted without evidence;
  * `key_scope_changed_outside_authority` - an API key whose scopes,
    workspaces or grants differ from what was recorded when it was minted.

  Findings are returned and, with `record: true`, appended to the evidence
  chain so they cannot be quietly dropped.
  """

  alias OptimalEngine.Authority.{CanonicalJSON, Evidence, Policy}
  alias OptimalEngine.Store

  @doc "Scans the tenant. Options: `record: true` appends each finding as evidence."
  @spec scan(String.t(), keyword()) :: %{findings: [map()], checked: map()}
  def scan(tenant_id, opts \\ []) do
    evidence = Evidence.list(tenant_id, limit: 10_000)

    chain =
      case Evidence.verify(tenant_id) do
        {:ok, _} ->
          []

        {:error, failure} ->
          [finding("evidence_chain_broken", nil, "entry #{failure[:seq]}: #{failure[:reason]}")]
      end

    policies = policy_findings(tenant_id, evidence)
    grants = grant_findings(tenant_id, evidence)
    denies = deny_findings(tenant_id, evidence)
    keys = key_findings(tenant_id, evidence)
    findings = chain ++ policies ++ grants ++ denies ++ keys

    if Keyword.get(opts, :record, false) do
      Enum.each(findings, fn finding ->
        Evidence.append(tenant_id, "integrity.finding", %{detail: finding})
      end)
    end

    %{
      findings: findings,
      checked: %{
        evidence_entries: length(evidence),
        policies: length(Policy.list(tenant_id, active_only: true)),
        grants: count(tenant_id, "authority_grants"),
        local_denies: count(tenant_id, "authority_local_denies"),
        api_keys: count(tenant_id, "api_keys")
      }
    }
  end

  @doc "Detail recorded with `policy.published` so scans can match it later."
  @spec policy_detail(map()) :: map()
  def policy_detail(policy) do
    %{
      "policy_id" => policy.id,
      "policy_sha256" => policy.hash,
      "scope" => policy.scope_type,
      "scope_id" => policy.scope_id
    }
  end

  @doc "Detail recorded when a key is minted so scans can detect later edits."
  @spec key_detail(map()) :: map()
  def key_detail(%{id: id, scopes: scopes, workspace_scope: workspaces, metadata: metadata}) do
    %{"key_id" => id, "key_sha256" => key_fingerprint(scopes, workspaces, metadata)}
  end

  @doc "Fingerprint of what a key is allowed to do."
  @spec key_fingerprint([String.t()], [String.t()], map()) :: String.t()
  def key_fingerprint(scopes, workspaces, metadata) do
    grants = Map.take(metadata || %{}, OptimalEngine.Auth.KeyIssuance.grant_fields())

    CanonicalJSON.hash(%{
      "scopes" => Enum.sort(scopes),
      "workspace_scope" => Enum.sort(workspaces),
      "grants" => grants
    })
  end

  # ---------------------------------------------------------------------------

  defp policy_findings(tenant_id, evidence) do
    published =
      for %{"kind" => "policy.published", "detail" => %{"policy_id" => id, "policy_sha256" => hash}} <-
            evidence,
          into: %{},
          do: {id, hash}

    tenant_id
    |> Policy.list(active_only: true)
    |> Enum.flat_map(fn policy ->
      case policy_problem(policy, published) do
        nil -> []
        problem -> [finding("policy_changed_outside_authority", policy.id, problem)]
      end
    end)
  end

  defp policy_problem(policy, published) do
    cond do
      Policy.hash(policy.document) != policy.hash -> "content does not match its hash"
      published[policy.id] == nil -> "no publication evidence"
      published[policy.id] != policy.hash -> "hash differs from the published hash"
      true -> nil
    end
  end

  defp grant_findings(tenant_id, evidence) do
    issued =
      for %{"kind" => kind, "jti" => jti} <- evidence,
          kind in ["grant.issued", "grant.narrowed"],
          into: MapSet.new(),
          do: jti

    last_state =
      Enum.reduce(evidence, %{}, fn
        %{"kind" => "grant.revoked", "jti" => jti}, acc -> Map.put(acc, jti, "revoked")
        %{"kind" => "grant.suspended", "jti" => jti}, acc -> Map.put(acc, jti, "suspended")
        %{"kind" => "grant.restored", "jti" => jti}, acc -> Map.put(acc, jti, "active")
        _entry, acc -> acc
      end)

    {:ok, rows} =
      Store.raw_query(
        "SELECT jti, status, subject, action, resource, expires_at, not_before, claims FROM authority_grants WHERE tenant_id = ?1",
        [tenant_id]
      )

    Enum.flat_map(rows, fn [
                             jti,
                             status,
                             subject,
                             action,
                             resource,
                             expires_at,
                             not_before,
                             claims_json
                           ] ->
      claims = Jason.decode!(claims_json)
      optimal = claims["optimal"] || %{}

      [
        {not MapSet.member?(issued, jti), "no issuance evidence"},
        {claims["exp"] != expires_at or claims["nbf"] != not_before,
         "lifetime differs from the signed claims"},
        {claims["sub"] != subject or optimal["action"] != action or optimal["resource"] != resource,
         "binding differs from the signed claims"},
        {last_state[jti] == "revoked" and status != "revoked",
         "active again after recorded revocation"},
        {last_state[jti] == "suspended" and status == "active",
         "active again without recorded restore"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
      |> Enum.map(&finding("grant_changed_outside_authority", jti, &1))
    end)
  end

  defp deny_findings(tenant_id, evidence) do
    added =
      for %{"kind" => "local_deny.added", "detail" => %{"deny_id" => id}} <- evidence, do: id

    lifted =
      for %{"kind" => "local_deny.lifted", "detail" => %{"deny_id" => id}} <- evidence,
          into: MapSet.new(),
          do: id

    Enum.flat_map(added, fn id ->
      case Store.raw_query(
             "SELECT lifted_at FROM authority_local_denies WHERE tenant_id = ?1 AND id = ?2",
             [tenant_id, id]
           ) do
        {:ok, []} ->
          [finding("local_deny_removed_outside_authority", id, "deny row is gone")]

        {:ok, [[lifted_at]]} when not is_nil(lifted_at) ->
          if MapSet.member?(lifted, id),
            do: [],
            else: [finding("local_deny_removed_outside_authority", id, "lifted without evidence")]

        _ ->
          []
      end
    end)
  end

  defp key_findings(tenant_id, evidence) do
    minted =
      for %{"kind" => "key.minted", "detail" => %{"key_id" => id, "key_sha256" => hash}} <- evidence,
          into: %{},
          do: {id, hash}

    {:ok, rows} =
      Store.raw_query(
        "SELECT id, scopes, workspace_scope, metadata FROM api_keys WHERE tenant_id = ?1 AND revoked_at IS NULL",
        [tenant_id]
      )

    Enum.flat_map(rows, fn [id, scopes, workspaces, metadata] ->
      case minted[id] do
        nil ->
          []

        recorded ->
          current =
            key_fingerprint(
              decode_list(scopes),
              decode_list(workspaces),
              Jason.decode!(metadata || "{}")
            )

          if current == recorded,
            do: [],
            else: [
              finding(
                "key_scope_changed_outside_authority",
                id,
                "scopes, workspaces or grants changed"
              )
            ]
      end
    end)
  end

  defp decode_list(nil), do: []
  defp decode_list(json), do: Jason.decode!(json)

  defp count(tenant_id, table) do
    case Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE tenant_id = ?1", [tenant_id]) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  defp finding(kind, subject_id, detail),
    do: %{"finding" => kind, "id" => subject_id, "detail" => detail}
end
