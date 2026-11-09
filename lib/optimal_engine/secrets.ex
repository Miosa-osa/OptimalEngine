defmodule OptimalEngine.Secrets do
  @moduledoc """
  Where the Engine's own secrets come from: the environment, or OpenBao.

  A secret the Engine reads by name (`OPTIMAL_BACKUP_KEY`,
  `OPTIMAL_AUTHORITY_KEY`, `CONNECTOR_KEY`, `OPTIMAL_S3_ACCESS_KEY_ID`,
  `OPTIMAL_S3_SECRET_ACCESS_KEY`) is resolved by `fetch/1`:

    * a plain value in the environment is the secret, exactly as before;
    * a value of the form `openbao:<path>#<field>` is a reference: the secret
      is the `<field>` of the KV version 2 secret at `<path>` under
      `OPTIMAL_OPENBAO_KV_MOUNT` (`secret`), read with `OPTIMAL_OPENBAO_ADDR`
      and `OPTIMAL_OPENBAO_TOKEN`;
    * an unset or blank variable is `{:error, :not_set}`.

  For example `OPTIMAL_BACKUP_KEY=openbao:optimal/engine#backup_key` reads the
  `backup_key` field of `secret/optimal/engine`, which an operator writes with
  `bao kv put secret/optimal/engine backup_key=$(openssl rand -hex 32)`.

  A reference never falls back to anything: OpenBao not configured, sealed,
  unreachable, refusing the token, or holding no such secret or field is
  `{:error, {:secret_unavailable, name, reason}}`, and the caller fails with
  it rather than running without the secret. Without OpenBao, plain values
  work as they always have.

  A value read from OpenBao is kept in memory for `@ttl_ms` (a minute), so a
  multipart upload or a burst of connector runs does not ask OpenBao for the
  same secret on every call; a failure is never kept. `flush_cache/0` drops
  every kept value, and a rotated secret is read within the minute.

  Nothing here logs, inspects or returns a secret anywhere but to the caller
  that asked for it: errors and log lines name the variable and the reason.
  The OpenBao token itself cannot be a reference.
  """

  require Logger

  alias OptimalEngine.Storage.OpenBao

  @prefix "openbao:"
  @ttl_ms 60_000
  @cache_key {__MODULE__, :cache}
  @not_references ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN)
  @engine_secrets ~w(OPTIMAL_BACKUP_KEY OPTIMAL_AUTHORITY_KEY CONNECTOR_KEY
                     OPTIMAL_S3_ACCESS_KEY_ID OPTIMAL_S3_SECRET_ACCESS_KEY)

  @type reason ::
          :openbao_not_configured
          | :openbao_invalid_config
          | :openbao_unreachable
          | :openbao_sealed
          | :openbao_forbidden
          | :secret_not_found
          | :field_not_found
          | :invalid_reference
          | term()

  @doc """
  The secret named by the environment variable `name`.

  `{:ok, value}` (trimmed), `{:error, :not_set}` when the variable is unset or
  blank, or `{:error, {:secret_unavailable, name, reason}}` when it is an
  OpenBao reference that could not be read.
  """
  @spec fetch(String.t()) ::
          {:ok, String.t()} | {:error, :not_set | {:secret_unavailable, String.t(), reason()}}
  def fetch(name) when is_binary(name) do
    case env(name) do
      nil ->
        {:error, :not_set}

      @prefix <> reference when name not in @not_references ->
        case resolve(reference) do
          {:ok, value} ->
            {:ok, value}

          {:error, reason} ->
            Logger.error("Secret #{name} could not be read from OpenBao: #{describe(reason)}.")
            {:error, {:secret_unavailable, name, reason}}
        end

      value ->
        {:ok, value}
    end
  end

  @doc """
  Where `name` is read from, without reading it: `"env"`, `"openbao"` (a
  reference) or `"unset"`. Safe to show an operator.
  """
  @spec source(String.t()) :: String.t()
  def source(name) when is_binary(name) do
    case env(name) do
      nil -> "unset"
      @prefix <> _reference when name not in @not_references -> "openbao"
      _value -> "env"
    end
  end

  @doc """
  The Engine secrets (the variables `fetch/1` is asked for by name) that are
  OpenBao references now. Reads nothing from OpenBao.
  """
  @spec references() :: [String.t()]
  def references, do: Enum.filter(@engine_secrets, &(source(&1) == "openbao"))

  @doc "The environment variables the Engine reads as secrets, each of which may be a reference."
  @spec engine_secrets() :: [String.t()]
  def engine_secrets, do: @engine_secrets

  @doc "True when `value` is an OpenBao secret reference."
  @spec reference?(term()) :: boolean()
  def reference?(@prefix <> _rest), do: true
  def reference?(_value), do: false

  @doc """
  Parses a reference (without the `openbao:` prefix) into the path and field
  it names. The path is relative to the KV mount.
  """
  @spec parse_reference(String.t()) :: {:ok, String.t(), String.t()} | {:error, :invalid_reference}
  def parse_reference(reference) when is_binary(reference) do
    with [path, field] <- String.split(reference, "#", parts: 2),
         path = path |> String.trim() |> String.trim("/"),
         field = String.trim(field),
         true <- path != "" and field != "" and not String.contains?(field, "#") do
      {:ok, path, field}
    else
      _invalid -> {:error, :invalid_reference}
    end
  end

  @doc "Drops every value read from OpenBao, so the next fetch reads it again."
  @spec flush_cache() :: :ok
  def flush_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc "A sentence naming what went wrong, for a log line or an operator. Never carries a secret."
  @spec describe(term()) :: String.t()
  def describe({:secret_unavailable, name, reason}),
    do: "#{name} names an OpenBao secret that could not be read: #{describe(reason)}"

  def describe(:openbao_not_configured),
    do: "OpenBao is not configured (set OPTIMAL_OPENBAO_ADDR and OPTIMAL_OPENBAO_TOKEN)"

  def describe(:openbao_invalid_config), do: "OPTIMAL_OPENBAO_ADDR is not an http(s) URL"
  def describe(:openbao_unreachable), do: "OpenBao did not answer"
  def describe(:openbao_sealed), do: "OpenBao is sealed; unseal it and retry"

  def describe(:openbao_not_initialized),
    do: "OpenBao is not initialized (bao operator init)"

  def describe(:openbao_forbidden),
    do: "OpenBao refused the token (OPTIMAL_OPENBAO_TOKEN) for this path"

  def describe(:openbao_mount_missing),
    do:
      "the KV mount does not exist and the token may not enable it (bao secrets enable -path=secret -version=2 kv)"

  def describe(:openbao_not_kv_version_2), do: "the KV mount is not KV version 2"

  def describe(:openbao_transit_key_missing),
    do:
      "the transit key named by OPTIMAL_OPENBAO_TRANSIT_KEY does not exist (bao secrets enable transit; bao write -f transit/keys/<name>)"

  def describe(:openbao_decrypt_failed), do: "OpenBao transit could not decrypt the wrapped key"
  def describe(:secret_not_found), do: "no secret is stored at that path"
  def describe(:field_not_found), do: "the secret has no such field"
  def describe(:invalid_reference), do: "the reference is not openbao:<path>#<field>"
  def describe(:invalid_secret_path), do: "the reference names an invalid path"
  def describe({:openbao_status, status}), do: "OpenBao answered HTTP #{status}"
  def describe(reason), do: inspect(reason)

  # ─── resolution ──────────────────────────────────────────────────────────

  defp resolve(reference) do
    with {:ok, path, field} <- parse_reference(reference),
         {:ok, scope} <- cache_scope() do
      key = {scope, path}

      # A kept copy that lacks the field is read again: the operator may have
      # just added it.
      with {:ok, data} <- cached(key),
           {:ok, value} <- field(data, field) do
        {:ok, value}
      else
        _miss_or_absent ->
          with {:ok, data} <- read(key, path), do: field(data, field)
      end
    end
  end

  defp field(data, field) do
    case Map.get(data, field) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, :field_not_found},
          else: {:ok, String.trim(value)}

      _absent_or_not_a_string ->
        {:error, :field_not_found}
    end
  end

  # One read per secret path per minute, whichever fields of it are asked for.
  defp read(key, path) do
    case OpenBao.kv_read(path) do
      {:ok, data} ->
        remember(key, data)
        {:ok, data}

      {:error, :not_found} ->
        {:error, :secret_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Kept values belong to the server, the mount and the token they were read
  # with (by a hash of it), so pointing the Engine at another OpenBao or
  # changing its token never serves what the old one could read.
  defp cache_scope do
    case OpenBao.config() do
      {:ok, config} -> {:ok, {config.base_url, config.mount, OpenBao.token_fingerprint()}}
      {:error, :not_configured} -> {:error, :openbao_not_configured}
      {:error, _invalid} -> {:error, :openbao_invalid_config}
    end
  end

  defp cached(key) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, %{}) do
      %{^key => {expires, data}} when expires > now -> {:ok, data}
      _missing_or_stale -> :miss
    end
  end

  defp remember(key, data) do
    now = System.monotonic_time(:millisecond)

    cache =
      @cache_key
      |> :persistent_term.get(%{})
      |> Map.reject(fn {_key, {expires, _data}} -> expires <= now end)
      |> Map.put(key, {now + @ttl_ms, data})

    :persistent_term.put(@cache_key, cache)
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _unset ->
        nil
    end
  end
end
