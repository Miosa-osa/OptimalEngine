defmodule OptimalEngine.Secrets do
  @moduledoc """
  Where the Engine's own secrets come from: the environment, or OpenBao.

  A secret the Engine reads by name (`OPTIMAL_BACKUP_KEY`,
  `OPTIMAL_AUTHORITY_KEY`, `CONNECTOR_KEY`, `OPTIMAL_S3_ACCESS_KEY_ID`,
  `OPTIMAL_S3_SECRET_ACCESS_KEY`, `OPTIMAL_QDRANT_API_KEY`,
  `OPTIMAL_VALKEY_PASSWORD`, `OPTIMAL_NATS_TOKEN`, `OPTIMAL_NATS_PASSWORD`) is
  resolved by `fetch/1`:

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

  The field read from OpenBao (only that field) is kept in an ETS table for
  `@ttl_ms` (a minute), so a
  multipart upload or a burst of connector runs does not ask OpenBao for the
  same secret on every call. A sealed or unreachable OpenBao is not asked again
  for a few seconds (`OPTIMAL_OPENBAO_RETRY_AFTER_MS`, see
  `OptimalEngine.Storage.OpenBao`), so a burst of calls during an outage fails
  at once rather than each waiting out the timeout; any other failure is never
  kept. `flush_cache/0` drops every kept value and that outage mark, and a
  rotated secret is read within the minute.

  Nothing here logs, inspects or returns a secret anywhere but to the caller
  that asked for it: errors and log lines name the variable and the reason.
  The OpenBao token itself cannot be a reference.
  """

  require Logger

  alias OptimalEngine.Storage.OpenBao

  @prefix "openbao:"
  @ttl_ms 60_000
  @cache_table :optimal_engine_secrets_cache
  @not_references ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN)
  @engine_secrets ~w(OPTIMAL_BACKUP_KEY OPTIMAL_AUTHORITY_KEY CONNECTOR_KEY
                     OPTIMAL_S3_ACCESS_KEY_ID OPTIMAL_S3_SECRET_ACCESS_KEY
                     OPTIMAL_QDRANT_API_KEY
                     OPTIMAL_VALKEY_PASSWORD OPTIMAL_NATS_TOKEN OPTIMAL_NATS_PASSWORD
                     OPTIMAL_METRICS_TOKEN)

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

  Only the operator's own settings are resolved: `name` must be one of
  `engine_secrets/0` (`{:error, :not_an_engine_secret}` otherwise), and there
  is no entry point that resolves a value handed to it. A value that arrives
  through the API or is stored in the database (a sync or federation peer's
  api_key) is never a reference: resolving one would let whoever set it have
  the Engine read any secret its OpenBao token can and send it where they
  chose.
  """
  @spec fetch(String.t()) ::
          {:ok, String.t()}
          | {:error, :not_set | :not_an_engine_secret | {:secret_unavailable, String.t(), reason()}}
  def fetch(name) when is_binary(name) and name not in @engine_secrets,
    do: {:error, :not_an_engine_secret}

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

  @doc """
  Drops every value read from OpenBao, and forgets that OpenBao was down
  (`OptimalEngine.Storage.OpenBao.reset_outages/0`), so the next fetch asks it.
  """
  @spec flush_cache() :: :ok
  def flush_cache do
    if :ets.whereis(@cache_table) != :undefined, do: :ets.delete_all_objects(@cache_table)
    OpenBao.reset_outages()
  end

  @doc """
  Creates the table values read from OpenBao are kept in, owned by the
  calling process (the application, at start). A fetch before it exists, or
  after its owner went, reads OpenBao and keeps nothing.
  """
  @spec init_cache() :: :ok
  def init_cache do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  rescue
    # Created by another process in between.
    ArgumentError -> :ok
  end

  @doc false
  # What the cache holds, for tests: `{{scope, path, field}, expires, value}`.
  def cache_entries do
    if :ets.whereis(@cache_table) == :undefined, do: [], else: :ets.tab2list(@cache_table)
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
      key = {scope, path, field}

      # Only the field asked for is kept, never the rest of the secret.
      case cached(key) do
        {:ok, value} ->
          {:ok, value}

        :miss ->
          with {:ok, data} <- read(path),
               {:ok, value} <- field(data, field) do
            remember(key, value)
            {:ok, value}
          end
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

  # One read per field per minute.
  defp read(path) do
    case OpenBao.kv_read(path) do
      {:ok, data} ->
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

  # ETS, not persistent_term: a write there is a global garbage collection.
  defp cached(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, key) do
      [{^key, expires, value}] when expires > now -> {:ok, value}
      _missing_or_stale -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp remember(key, value) do
    :ets.insert(@cache_table, {key, System.monotonic_time(:millisecond) + @ttl_ms, value})
    :ok
  rescue
    ArgumentError -> :ok
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
