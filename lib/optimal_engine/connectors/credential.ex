defmodule OptimalEngine.Connectors.Credential do
  @moduledoc """
  Encrypted-at-rest credential storage for connector auth material.

  Connector config rows live in the `connectors` table. When the config
  contains auth material (OAuth tokens, API keys, private keys) we
  serialize + envelope-encrypt it here before writing, and decrypt
  on read.

  ## Key management

  Phase 9 uses an `AES-256-GCM` key loaded from the `CONNECTOR_KEY`
  env var (hex-encoded 32 bytes), or from OpenBao when the variable is a
  reference (`openbao:<path>#<field>`, `OptimalEngine.Secrets`). Without a
  usable key every encrypt and decrypt is refused, never a plaintext write,
  and the reason says which way the key is unusable: `:key_missing` (not
  set), `:key_invalid` (not 64 hex characters) or `:key_unavailable` (an
  OpenBao reference OpenBao could not answer; `OptimalEngine.Secrets` logs
  why). `refusal/1` turns each into the reason a caller returns
  (`:connector_key_missing`, `:connector_key_invalid`,
  `:connector_key_unavailable`) and logs it.
  With `OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao`, connector credentials themselves are kept in
  OpenBao rather than in this envelope (`OptimalEngine.Connectors.CredentialVault`). In production the master key should
  come from a KMS / HSM — this module exposes `encrypt/1` + `decrypt/1`
  as the only code paths that touch the key, so swapping providers is
  a one-module change. See `docs/architecture/COMPLIANCE.md` for the
  Phase 11 plan.

  ## Envelope format

      <<version::8, iv::96, tag::128, ciphertext::binary>>

  stored as Base64 in the `config.credentials_ciphertext` JSON field.
  `version = 1` today; any change bumps it and triggers rotation.
  """

  require Logger

  @version 1
  @iv_size 12
  @tag_size 16

  @type plaintext :: map()
  @type envelope :: String.t()
  @type key_error :: :key_missing | :key_invalid | :key_unavailable

  @key_errors [:key_missing, :key_invalid, :key_unavailable]

  @doc """
  Encrypt a credentials map. Returns a Base64-encoded envelope, or the
  `t:key_error/0` that says why the master key cannot be used.

  `aad` is associated data the envelope is bound to: it is not stored, and the
  envelope opens only when the same data is given to `decrypt/2`. Binding it to
  the row it belongs to keeps a copy of the envelope from opening elsewhere.
  """
  @spec encrypt(plaintext(), binary()) :: {:ok, envelope()} | {:error, key_error()}
  def encrypt(creds, aad \\ "") when is_map(creds) and is_binary(aad) do
    with {:ok, key} <- master_key() do
      iv = :crypto.strong_rand_bytes(@iv_size)
      plaintext = Jason.encode!(creds)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)

      payload = <<@version::8, iv::binary, tag::binary, ciphertext::binary>>
      {:ok, Base.encode64(payload)}
    end
  end

  @doc """
  Decrypt an envelope. Returns the original credentials map or an
  error atom describing what went wrong.
  """
  @spec decrypt(envelope(), binary()) ::
          {:ok, plaintext()}
          | {:error, key_error() | :bad_envelope | :unsupported_version | :auth_failed}
  def decrypt(envelope, aad \\ "") when is_binary(envelope) and is_binary(aad) do
    with {:ok, key} <- master_key(),
         {:ok, raw} <- Base.decode64(envelope) |> wrap_bad(),
         {:ok, iv, tag, ciphertext} <- split_envelope(raw),
         {:ok, plaintext} <- aead_decrypt(key, iv, tag, ciphertext, aad),
         {:ok, map} <- Jason.decode(plaintext) do
      {:ok, map}
    end
  end

  @doc """
  Return `true` when the master key is configured. Handy for startup
  health checks so operators know the engine can read existing rows.
  """
  @spec ready?() :: boolean()
  def ready? do
    match?({:ok, _}, master_key())
  end

  @doc """
  Whether the master key can be used now: `:ok`, or the reason a caller
  returns when it cannot (`:connector_key_missing`, `:connector_key_invalid`,
  `:connector_key_unavailable`). Logs nothing beyond what
  `OptimalEngine.Secrets` logs for a reference.
  """
  @spec key_status() ::
          :ok
          | {:error, :connector_key_missing | :connector_key_invalid | :connector_key_unavailable}
  def key_status do
    case master_key() do
      {:ok, _key} -> :ok
      {:error, reason} -> {:error, connector_reason(reason)}
    end
  end

  @doc "True for the errors that mean the master key itself is unusable."
  @spec key_error?(term()) :: boolean()
  def key_error?(reason), do: reason in @key_errors

  @doc """
  The reason a caller returns when `encrypt/2` or `decrypt/2` failed with a
  `t:key_error/0`, after logging which way the key is unusable. `what` says
  what was refused ("Connector credentials refused", ...).
  """
  @spec refusal(key_error(), String.t()) ::
          :connector_key_missing | :connector_key_invalid | :connector_key_unavailable
  def refusal(reason, what) when reason in @key_errors do
    Logger.error("#{what}: #{describe(reason)}.")
    connector_reason(reason)
  end

  @doc """
  The reason a caller returns for a `t:key_error/0`, without logging: for a
  path that runs on a timer (a peer's sync cycle), whose status already
  carries the reason.
  """
  @spec reason(key_error()) ::
          :connector_key_missing | :connector_key_invalid | :connector_key_unavailable
  def reason(reason) when reason in @key_errors, do: connector_reason(reason)

  @doc "A sentence naming why the master key cannot be used. Never carries the key."
  @spec describe(key_error() | atom()) :: String.t()
  def describe(reason) when reason in [:key_missing, :connector_key_missing],
    do: "CONNECTOR_KEY is not configured"

  def describe(reason) when reason in [:key_invalid, :connector_key_invalid],
    do: "CONNECTOR_KEY is not 64 hex characters (32 bytes)"

  def describe(reason) when reason in [:key_unavailable, :connector_key_unavailable],
    do:
      "CONNECTOR_KEY is an OpenBao reference that could not be read (the log line before names why)"

  # ─── private ─────────────────────────────────────────────────────────────

  defp connector_reason(:key_missing), do: :connector_key_missing
  defp connector_reason(:key_invalid), do: :connector_key_invalid
  defp connector_reason(:key_unavailable), do: :connector_key_unavailable

  defp master_key do
    case OptimalEngine.Secrets.fetch("CONNECTOR_KEY") do
      {:ok, hex} -> decode_master_key(hex)
      {:error, :not_set} -> {:error, :key_missing}
      {:error, {:secret_unavailable, _name, _reason}} -> {:error, :key_unavailable}
    end
  end

  defp decode_master_key(hex) do
    with true <- byte_size(hex) == 64,
         {:ok, key} when byte_size(key) == 32 <- Base.decode16(hex, case: :mixed) do
      {:ok, key}
    else
      _invalid -> {:error, :key_invalid}
    end
  end

  defp wrap_bad(:error), do: {:error, :bad_envelope}
  defp wrap_bad({:ok, _} = ok), do: ok

  defp split_envelope(
         <<@version::8, iv::binary-size(@iv_size), tag::binary-size(@tag_size), rest::binary>>
       ) do
    {:ok, iv, tag, rest}
  end

  defp split_envelope(<<v::8, _::binary>>) when v != @version, do: {:error, :unsupported_version}
  defp split_envelope(_), do: {:error, :bad_envelope}

  defp aead_decrypt(key, iv, tag, ciphertext, aad) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> {:error, :auth_failed}
    end
  end
end
