defmodule OptimalEngine.Authority.Issuers do
  @moduledoc """
  Outside authorities this Engine trusts to issue grants it enforces.

  An issuer is registered per tenant with its pinned public keys (an RFC 8037
  JWK set) and a revocation feed freshness limit. Grants from an issuer are
  verified only against those pinned keys. Revocations arrive by push
  (`record_revocations/3`); the Engine keeps honoring every revocation and
  expiry it knows, and when the feed is older than the limit it refuses the
  issuer's grants instead of trusting authority it can no longer check
  (fail closed while disconnected). Reconnecting is simply the next push.

  Grants issued by this Engine itself never go through this module; they are
  checked against the local registry.
  """

  alias OptimalEngine.Authority.Keys
  alias OptimalEngine.Store

  @default_staleness 300

  @doc "Registers or replaces an issuer's pinned keys."
  @spec register(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def register(tenant_id, issuer, jwks, opts \\ [])

  def register(tenant_id, issuer, %{"keys" => [_ | _] = keys} = jwks, opts) do
    if Enum.all?(keys, &(is_binary(&1["kid"]) and match?({:ok, _}, Keys.from_jwk(&1)))) do
      staleness = Keyword.get(opts, :max_staleness_seconds, @default_staleness)

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO authority_issuers (tenant_id, issuer, jwks, max_staleness_seconds, status, revocations_synced_at)
          VALUES (?1, ?2, ?3, ?4, 'active', datetime('now'))
          ON CONFLICT(tenant_id, issuer) DO UPDATE SET
            jwks = excluded.jwks, max_staleness_seconds = excluded.max_staleness_seconds, status = 'active'
          """,
          [tenant_id, issuer, Jason.encode!(jwks), staleness]
        )

      get(tenant_id, issuer)
    else
      {:error, :invalid_jwks}
    end
  end

  def register(_tenant_id, _issuer, _jwks, _opts), do: {:error, :invalid_jwks}

  @doc "A registered issuer."
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(tenant_id, issuer) do
    case Store.raw_query(
           """
           SELECT issuer, jwks, max_staleness_seconds, status, revocations_synced_at, created_at
           FROM authority_issuers WHERE tenant_id = ?1 AND issuer = ?2
           """,
           [tenant_id, issuer]
         ) do
      {:ok, [[issuer, jwks, staleness, status, synced_at, created_at]]} ->
        {:ok,
         %{
           issuer: issuer,
           jwks: Jason.decode!(jwks),
           max_staleness_seconds: staleness,
           status: status,
           revocations_synced_at: synced_at,
           created_at: created_at
         }}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "The pinned public key `kid` of `issuer`."
  @spec key(String.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, atom()}
  def key(tenant_id, issuer, kid) do
    with {:ok, %{status: "active", jwks: %{"keys" => keys}}} <- get(tenant_id, issuer),
         %{} = jwk <- Enum.find(keys, &(&1["kid"] == kid)) do
      Keys.from_jwk(jwk)
    else
      {:ok, _inactive} -> {:error, :untrusted_issuer}
      {:error, :not_found} -> {:error, :untrusted_issuer}
      nil -> {:error, :unknown_key}
    end
  end

  @doc """
  Whether the issuer's revocation feed is fresh enough to rely on. Returns
  `:ok` or `{:error, :authority_unavailable}`.
  """
  @spec fresh(String.t(), String.t()) :: :ok | {:error, :authority_unavailable | :untrusted_issuer}
  def fresh(tenant_id, issuer) do
    case Store.raw_query(
           """
           SELECT (julianday('now') - julianday(revocations_synced_at)) * 86400.0, max_staleness_seconds
           FROM authority_issuers WHERE tenant_id = ?1 AND issuer = ?2 AND status = 'active'
           """,
           [tenant_id, issuer]
         ) do
      {:ok, [[age, limit]]} when is_number(age) and age <= limit -> :ok
      {:ok, [[_age, _limit]]} -> {:error, :authority_unavailable}
      _ -> {:error, :untrusted_issuer}
    end
  end

  @doc """
  Records revocations pushed by `issuer` and marks its feed as synced now.
  Each revocation is `%{"jti" => id, "reason" => text}`.
  """
  @spec record_revocations(String.t(), String.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def record_revocations(tenant_id, issuer, revocations) when is_list(revocations) do
    with {:ok, _issuer} <- get(tenant_id, issuer),
         :ok <- valid_revocations(revocations) do
      Enum.each(revocations, fn %{"jti" => jti} = revocation ->
        {:ok, _} =
          Store.raw_query(
            """
            INSERT OR IGNORE INTO authority_revocations (tenant_id, issuer, jti, reason)
            VALUES (?1, ?2, ?3, ?4)
            """,
            [tenant_id, issuer, jti, revocation["reason"]]
          )
      end)

      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_issuers SET revocations_synced_at = datetime('now') WHERE tenant_id = ?1 AND issuer = ?2",
          [tenant_id, issuer]
        )

      {:ok, length(revocations)}
    end
  end

  def record_revocations(_tenant_id, _issuer, _revocations), do: {:error, :invalid_revocations}

  defp valid_revocations(revocations) do
    if Enum.all?(revocations, &match?(%{"jti" => jti} when is_binary(jti) and jti != "", &1)),
      do: :ok,
      else: {:error, :invalid_revocations}
  end

  @doc "Whether `issuer` has revoked `jti`."
  @spec revoked?(String.t(), String.t(), String.t()) :: boolean()
  def revoked?(tenant_id, issuer, jti) do
    match?(
      {:ok, [_ | _]},
      Store.raw_query(
        "SELECT 1 FROM authority_revocations WHERE tenant_id = ?1 AND issuer = ?2 AND jti = ?3",
        [tenant_id, issuer, jti]
      )
    )
  end

  @doc """
  Consumes one use of an outside grant. Returns `:ok` the first time and
  `{:error, :replayed}` after `max_uses` admissions.
  """
  @spec consume(String.t(), String.t(), String.t(), pos_integer()) :: :ok | {:error, :replayed}
  def consume(tenant_id, issuer, jti, max_uses) do
    Store.transaction(fn txn ->
      {:ok, _} =
        Store.txn_execute(
          txn,
          "INSERT OR IGNORE INTO authority_consumed (tenant_id, issuer, jti, uses) VALUES (?1, ?2, ?3, 0)",
          [tenant_id, issuer, jti]
        )

      Store.txn_execute(
        txn,
        "UPDATE authority_consumed SET uses = uses + 1 WHERE tenant_id = ?1 AND issuer = ?2 AND jti = ?3 AND uses < ?4",
        [tenant_id, issuer, jti, max_uses]
      )
    end)
    |> case do
      {:ok, 1} -> :ok
      _ -> {:error, :replayed}
    end
  end

  @doc "Every revocation this Engine has issued itself, for outside enforcers to pull."
  @spec local_revocations(String.t(), String.t() | nil) :: [map()]
  def local_revocations(tenant_id, since \\ nil) do
    {sql, params} =
      if since,
        do:
          {"SELECT jti, revoked_at, revoked_reason FROM authority_grants WHERE tenant_id = ?1 AND status = 'revoked' AND revoked_at > ?2 ORDER BY revoked_at",
           [tenant_id, since]},
        else:
          {"SELECT jti, revoked_at, revoked_reason FROM authority_grants WHERE tenant_id = ?1 AND status = 'revoked' ORDER BY revoked_at",
           [tenant_id]}

    {:ok, rows} = Store.raw_query(sql, params)

    Enum.map(rows, fn [jti, at, reason] ->
      %{"jti" => jti, "revoked_at" => at, "reason" => reason}
    end)
  end
end
