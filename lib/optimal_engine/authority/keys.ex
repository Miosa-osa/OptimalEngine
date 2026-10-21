defmodule OptimalEngine.Authority.Keys do
  @moduledoc """
  Ed25519 signing keys for authority, one active key per tenant and purpose.

  Two purposes are kept apart on purpose: `"grant"` keys sign grants and
  `"evidence"` keys sign the evidence chain, so a party that can verify
  grants can never forge evidence, and rotating one never touches the other.

  A key's id (`kid`) is its RFC 7638 JWK thumbprint. Public keys are
  published as an RFC 8037 JWK set. Private keys are wrapped with AES-256-GCM
  under `OPTIMAL_AUTHORITY_KEY` (64 hex characters). Without that variable an
  engine that requires authentication refuses to create keys; an open local
  development engine stores them unwrapped and logs a warning.

  Lifecycle: `active` keys sign; `rotate/2` retires the active key, which
  keeps verifying what it signed; `revoke/2` marks a key compromised and
  everything it signed stops verifying.
  """

  require Logger

  alias OptimalEngine.Authority.{CanonicalJSON, JWS}
  alias OptimalEngine.Store

  @purposes ~w(grant evidence)
  @aad "optimal-authority-key-v1"

  @type key :: %{
          kid: String.t(),
          tenant_id: String.t(),
          purpose: String.t(),
          public_key: binary(),
          private_key: binary() | nil,
          status: String.t(),
          created_at: String.t() | nil,
          retired_at: String.t() | nil
        }

  @doc "The active key for `tenant_id` and `purpose`, created on first use."
  @spec active(String.t(), String.t()) :: {:ok, key()} | {:error, term()}
  def active(tenant_id, purpose) when purpose in @purposes do
    case load_active(tenant_id, purpose) do
      {:ok, key} -> {:ok, key}
      {:error, :not_found} -> create(tenant_id, purpose)
      error -> error
    end
  end

  @doc "Retires the active key and creates a new one."
  @spec rotate(String.t(), String.t()) :: {:ok, key()} | {:error, term()}
  def rotate(tenant_id, purpose) when purpose in @purposes do
    with :ok <- wrapping_available() do
      {:ok, _} =
        Store.raw_query(
          """
          UPDATE authority_keys SET status = 'retired', retired_at = datetime('now')
          WHERE tenant_id = ?1 AND purpose = ?2 AND status = 'active'
          """,
          [tenant_id, purpose]
        )

      create(tenant_id, purpose)
    end
  end

  @doc "Marks a key compromised; what it signed no longer verifies."
  @spec revoke(String.t(), String.t()) :: :ok | {:error, :not_found}
  def revoke(tenant_id, kid) do
    case lookup(tenant_id, kid) do
      {:ok, _key} ->
        {:ok, _} =
          Store.raw_query(
            """
            UPDATE authority_keys SET status = 'revoked', revoked_at = datetime('now')
            WHERE tenant_id = ?1 AND kid = ?2
            """,
            [tenant_id, kid]
          )

        :ok

      error ->
        error
    end
  end

  @doc """
  The verification key for `kid` in `tenant_id` with the given purpose.
  Revoked keys return `{:error, :key_revoked}`; unknown keys
  `{:error, :unknown_key}`.
  """
  @spec verification_key(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :unknown_key | :key_revoked}
  def verification_key(tenant_id, kid, purpose) do
    case lookup(tenant_id, kid) do
      {:ok, %{purpose: ^purpose, status: "revoked"}} -> {:error, :key_revoked}
      {:ok, %{purpose: ^purpose, public_key: public_key}} -> {:ok, public_key}
      _ -> {:error, :unknown_key}
    end
  end

  @doc "Signs `data` with the private half of `key`."
  @spec sign(key(), binary()) :: binary()
  def sign(%{private_key: private_key}, data) when is_binary(private_key),
    do: :crypto.sign(:eddsa, :none, data, [private_key, :ed25519])

  @doc "The tenant's public keys (active and retired) as a JWK set."
  @spec jwks(String.t()) :: map()
  def jwks(tenant_id) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT kid, purpose, public_key, status FROM authority_keys
        WHERE tenant_id = ?1 AND status IN ('active', 'retired')
        ORDER BY created_at
        """,
        [tenant_id]
      )

    %{
      "keys" =>
        Enum.map(rows, fn [kid, purpose, public_key, status] ->
          public_key
          |> decode_public()
          |> jwk()
          |> Map.merge(%{"kid" => kid, "use" => "sig", "alg" => "EdDSA"})
          |> Map.put("optimal_purpose", purpose)
          |> Map.put("optimal_status", status)
        end)
    }
  end

  @doc """
  One of the tenant's evidence keys as a public JWK, by `kid`: `"kty"`, `"crv"`, `"kid"`,
  `"x"`, `"alg"` (`"EdDSA"`) and `"optimal_purpose"` (`"evidence"`), with `"retired_at"`
  (ISO 8601, UTC) when the key is retired. `{:error, :not_found}` for an unknown kid, a
  key of another purpose or tenant, or a revoked key: what a revoked key signed no
  longer verifies, so it is never served.
  """
  @spec evidence_jwk(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def evidence_jwk(tenant_id, kid) do
    case Store.raw_query(
           """
           SELECT public_key, status, retired_at FROM authority_keys
           WHERE tenant_id = ?1 AND kid = ?2 AND purpose = 'evidence'
             AND status IN ('active', 'retired')
           """,
           [tenant_id, kid]
         ) do
      {:ok, [[public_key, status, retired_at]]} ->
        jwk =
          public_key
          |> decode_public()
          |> jwk()
          |> Map.merge(%{"kid" => kid, "alg" => "EdDSA", "optimal_purpose" => "evidence"})

        if status == "retired",
          do: {:ok, Map.put(jwk, "retired_at", utc_iso8601(retired_at))},
          else: {:ok, jwk}

      {:ok, _rows} ->
        {:error, :not_found}
    end
  end

  # SQLite's datetime('now') is UTC without a zone ("2026-10-21 07:00:00").
  defp utc_iso8601(text) do
    case NaiveDateTime.from_iso8601(text || "") do
      {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
      {:error, _reason} -> text
    end
  end

  @doc "RFC 8037 public JWK for a raw Ed25519 public key."
  @spec jwk(binary()) :: map()
  def jwk(public_key), do: %{"crv" => "Ed25519", "kty" => "OKP", "x" => JWS.encode64(public_key)}

  @doc "RFC 7638 thumbprint of a raw Ed25519 public key."
  @spec thumbprint(binary()) :: String.t()
  def thumbprint(public_key) do
    :crypto.hash(:sha256, CanonicalJSON.encode(jwk(public_key))) |> JWS.encode64()
  end

  @doc "Raw public key from an RFC 8037 JWK map."
  @spec from_jwk(map()) :: {:ok, binary()} | {:error, :invalid_jwk}
  def from_jwk(%{"kty" => "OKP", "crv" => "Ed25519", "x" => x}) do
    case JWS.decode64(x) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :invalid_jwk}
    end
  end

  def from_jwk(_jwk), do: {:error, :invalid_jwk}

  # ---------------------------------------------------------------------------

  defp create(tenant_id, purpose) do
    with :ok <- wrapping_available() do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      kid = thumbprint(public_key)
      {wrapped, stored_private} = wrap(private_key)

      case Store.raw_query(
             """
             INSERT INTO authority_keys
               (kid, tenant_id, purpose, public_key, private_key, wrapped, status)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active')
             """,
             [kid, tenant_id, purpose, JWS.encode64(public_key), stored_private, wrapped]
           ) do
        {:ok, _} -> load_active(tenant_id, purpose)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp load_active(tenant_id, purpose) do
    case Store.raw_query(
           """
           SELECT kid, tenant_id, purpose, public_key, private_key, wrapped, status, created_at, retired_at
           FROM authority_keys
           WHERE tenant_id = ?1 AND purpose = ?2 AND status = 'active'
           ORDER BY created_at DESC LIMIT 1
           """,
           [tenant_id, purpose]
         ) do
      {:ok, [row]} -> to_key(row, true)
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  defp lookup(tenant_id, kid) do
    case Store.raw_query(
           """
           SELECT kid, tenant_id, purpose, public_key, private_key, wrapped, status, created_at, retired_at
           FROM authority_keys WHERE tenant_id = ?1 AND kid = ?2
           """,
           [tenant_id, kid]
         ) do
      {:ok, [row]} -> to_key(row, false)
      _ -> {:error, :not_found}
    end
  end

  defp to_key(
         [
           kid,
           tenant_id,
           purpose,
           public_key,
           private_key,
           wrapped,
           status,
           created_at,
           retired_at
         ],
         with_private?
       ) do
    private =
      if with_private? do
        case unwrap(private_key, wrapped == 1) do
          {:ok, key} -> key
          {:error, reason} -> throw({:unwrap_failed, reason})
        end
      end

    {:ok,
     %{
       kid: kid,
       tenant_id: tenant_id,
       purpose: purpose,
       public_key: decode_public(public_key),
       private_key: private,
       status: status,
       created_at: created_at,
       retired_at: retired_at
     }}
  catch
    {:unwrap_failed, reason} -> {:error, reason}
  end

  defp decode_public(encoded) do
    {:ok, key} = JWS.decode64(encoded)
    key
  end

  defp wrapping_available do
    cond do
      match?({:ok, _}, wrapping_key()) -> :ok
      auth_required?() -> {:error, :authority_key_missing}
      true -> :ok
    end
  end

  defp wrap(private_key) do
    case wrapping_key() do
      {:ok, key} ->
        iv = :crypto.strong_rand_bytes(12)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, private_key, @aad, true)

        {1, Base.encode64(iv <> tag <> ciphertext)}

      {:error, _} ->
        Logger.warning(
          "Authority private key stored unwrapped - set OPTIMAL_AUTHORITY_KEY to wrap it."
        )

        {0, Base.encode64(private_key)}
    end
  end

  defp unwrap(stored, false), do: Base.decode64(stored) |> ok_or(:invalid_private_key)

  defp unwrap(stored, true) do
    with {:ok, key} <- wrapping_key(),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.decode64(stored) |> ok_or(:invalid_private_key) do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
        :error -> {:error, :unwrap_failed}
        private_key -> {:ok, private_key}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_private_key}
    end
  end

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}

  defp wrapping_key do
    with hex when is_binary(hex) <- System.get_env("OPTIMAL_AUTHORITY_KEY"),
         {:ok, key} when byte_size(key) == 32 <- Base.decode16(hex, case: :mixed) do
      {:ok, key}
    else
      _ -> {:error, :authority_key_missing}
    end
  end

  defp auth_required? do
    :optimal_engine |> Application.get_env(:auth, []) |> Keyword.get(:auth_required, false)
  end
end
