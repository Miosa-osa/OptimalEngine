defmodule OptimalEngine.Storage.OpenBao do
  @moduledoc """
  The OpenBao service provider: secrets, keys and PKI for the Engine and its
  workspaces. It is the one provider that holds truth of its own (managed
  secrets); recovery follows the secret manager's policy.

  Reached over its HTTP API through `OptimalEngine.Connectors.HTTP`, from
  `OPTIMAL_OPENBAO_ADDR` and `OPTIMAL_OPENBAO_TOKEN` (sent as `X-Vault-Token`,
  never logged, described or returned). `OPTIMAL_OPENBAO_KV_MOUNT` names the
  KV version 2 mount the proof writes under (`secret` by default).

  Health is `GET /v1/sys/health` saying initialized and unsealed, then
  `GET /v1/auth/token/lookup-self` answering 200: a sealed server or a bad
  token is `unreachable`, not healthy. The proof writes one secret under
  `<mount>/data/optimal/proof/<random>`, reads the same value back and deletes
  its metadata, so a healthy provider has stored and returned a secret.

  ## In the data path

  Beyond the probe, the Engine reads and writes through this module:

    * `kv_read/2`, `kv_write/3` and `kv_delete/2` hold secrets under the KV
      version 2 mount: the secret references `OptimalEngine.Secrets` resolves
      (`openbao:<path>#<field>`) and the connector credentials
      `OptimalEngine.Connectors.CredentialVault` keeps out of the Engine
      database. A write to a mount that does not exist enables it as KV
      version 2 once, so a freshly initialised server (as on a managed MIOSA
      Engine, which starts with no secrets engine) works without a manual step;
      a token that may not do that gets `:openbao_mount_missing`.
    * `transit_data_key/2` and `transit_decrypt/3` wrap backup data keys with
      the transit key named by `OPTIMAL_OPENBAO_TRANSIT_KEY` under
      `OPTIMAL_OPENBAO_TRANSIT_MOUNT` (`transit`), so the backup key never
      leaves OpenBao (`OptimalEngine.Backup.Envelope`).

  Every failure is a reason an operator can act on, never a silent default:
  `:openbao_not_configured`, `:openbao_invalid_config`, `:openbao_unreachable`,
  `:openbao_sealed`, `:openbao_forbidden` (the token may not do this),
  `:openbao_mount_missing`, `:openbao_transit_key_missing` or
  `{:openbao_status, status}`. A read of a path that holds nothing is
  `{:error, :not_found}`. No reason carries a secret, a token or a response
  body that could hold one.

  ## While OpenBao is down

  A data-path call that finds OpenBao sealed or not answering (a refused
  connection, a timeout, a standby that cannot serve) marks that address down
  for `OPTIMAL_OPENBAO_RETRY_AFTER_MS` (5000; `0` turns it off). Inside that
  window every data-path call to the address fails at once with the same
  reason instead of waiting out the HTTP timeout again; the first call after
  it asks OpenBao again, and any answer that is not an outage clears the mark.
  A definite answer (a refused token, a missing secret) is never kept. The
  health probe and the proof always ask.
  """

  alias OptimalEngine.Connectors.HTTP

  require Logger

  @addr_env "OPTIMAL_OPENBAO_ADDR"
  @token_env "OPTIMAL_OPENBAO_TOKEN"
  @mount_env "OPTIMAL_OPENBAO_KV_MOUNT"
  @transit_key_env "OPTIMAL_OPENBAO_TRANSIT_KEY"
  @transit_mount_env "OPTIMAL_OPENBAO_TRANSIT_MOUNT"
  @default_mount "secret"
  @default_transit_mount "transit"
  # A secret a path names is a few keys and values, never more than this.
  @max_body_bytes 1_048_576
  @default_timeout 3_000
  @retry_after_env "OPTIMAL_OPENBAO_RETRY_AFTER_MS"
  @default_retry_after_ms 5_000
  @breaker_key {__MODULE__, :down}

  @type health :: :healthy | :unreachable | :not_configured | :invalid_config

  @doc "The environment variables the provider is configured by."
  @spec env_names() :: [String.t()]
  def env_names, do: [@addr_env, @token_env]

  @doc "The optional environment variables: the KV mount, the transit key and mount, and the outage window."
  @spec optional_env_names() :: [String.t()]
  def optional_env_names, do: [@mount_env, @transit_key_env, @transit_mount_env, @retry_after_env]

  @doc "Whether the address and the token are set and the address is an http(s) URL."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config())

  @doc """
  The address, the KV mount and whether a token is set. The token itself is
  not in the result; `headers/0` carries it to the request and nowhere else.
  """
  @spec config(keyword()) :: {:ok, map()} | {:error, atom()}
  def config(opts \\ []) do
    addr = Keyword.get(opts, :addr) || System.get_env(@addr_env)
    token = System.get_env(@token_env)

    cond do
      not present?(addr) or not present?(token) ->
        {:error, :not_configured}

      not match?(
        %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h),
        URI.parse(addr)
      ) ->
        {:error, :invalid_url}

      true ->
        mount =
          System.get_env(@mount_env)
          |> then(&if(present?(&1), do: &1, else: @default_mount))
          |> String.trim()
          |> String.trim("/")

        {:ok,
         %{
           base_url: String.trim_trailing(addr, "/"),
           tls: String.starts_with?(addr, "https"),
           mount: mount,
           token: true
         }}
    end
  end

  @doc "Initialized, unsealed, and the token looks itself up."
  @spec health(keyword()) :: health()
  def health(opts \\ []) do
    case config(opts) do
      {:ok, config} ->
        # A performance or HA standby answers 429 by default; standbyok asks
        # it for 200, so a healthy standby is not reported as unreachable.
        with {:ok, 200, %{"initialized" => true, "sealed" => false}} <-
               call(config, :get, "/v1/sys/health?standbyok=true", nil, opts),
             {:ok, 200, _} <- call(config, :get, "/v1/auth/token/lookup-self", nil, opts) do
          :healthy
        else
          _ -> :unreachable
        end

      {:error, :not_configured} ->
        :not_configured

      {:error, _reason} ->
        :invalid_config
    end
  end

  @doc """
  Whether OpenBao can serve the Engine's data-path calls now: `:ok`, or the
  reason it cannot (`:openbao_sealed`, `:openbao_not_initialized`,
  `:openbao_unreachable`, `:openbao_not_configured`, ...). Never raises, so a
  readiness check or a boot path can report a sealed OpenBao and go on.
  """
  @spec availability(keyword()) :: :ok | {:error, term()}
  def availability(opts \\ []) do
    with {:ok, config} <- data_config(opts) do
      case guarded_call(config, :get, "/v1/sys/health?standbyok=true", nil, opts) do
        {:ok, 200, %{"sealed" => true}} -> {:error, :openbao_sealed}
        {:ok, 200, _body} -> :ok
        {:ok, 501, _body} -> {:error, :openbao_not_initialized}
        other -> failure(other)
      end
    end
  end

  @doc """
  What OpenBao says about the configured token: `{:ok, %{ttl: seconds,
  renewable: boolean}}`; a `ttl` of 0 never expires (a root token).
  """
  @spec token_lookup(keyword()) ::
          {:ok, %{ttl: non_neg_integer(), renewable: boolean()}} | {:error, term()}
  def token_lookup(opts \\ []) do
    with {:ok, config} <- data_config(opts) do
      case guarded_call(config, :get, "/v1/auth/token/lookup-self", nil, opts) do
        {:ok, 200, %{"data" => data}} when is_map(data) ->
          {:ok, %{ttl: non_negative(data["ttl"]), renewable: data["renewable"] == true}}

        other ->
          failure(other)
      end
    end
  end

  @doc """
  Renews the configured token (`auth/token/renew-self`): `{:ok, ttl}` with
  its new time to live in seconds.
  """
  @spec token_renew(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def token_renew(opts \\ []) do
    with {:ok, config} <- data_config(opts) do
      case guarded_call(config, :post, "/v1/auth/token/renew-self", %{}, opts) do
        {:ok, 200, %{"auth" => %{"lease_duration" => ttl}}} -> {:ok, non_negative(ttl)}
        {:ok, 400, _body} -> {:error, :openbao_token_not_renewable}
        other -> failure(other)
      end
    end
  end

  defp non_negative(value) when is_integer(value) and value > 0, do: value
  defp non_negative(_value), do: 0

  @doc "Writes a secret, reads the same value back and deletes it. Nothing is left behind."
  @spec round_trip(keyword()) :: {:ok, map()} | {:error, term()}
  def round_trip(opts \\ []) do
    with {:ok, config} <- config(opts) do
      name = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      value = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      data_path = "/v1/#{config.mount}/data/optimal/proof/#{name}"
      metadata_path = "/v1/#{config.mount}/metadata/optimal/proof/#{name}"

      # KV version 2 answers a write with 200 and the version it made, and a
      # read with that version in `metadata`. A version 1 mount answers 204 and
      # stores the payload at the literal `data/...` path, which the delete of
      # `metadata/...` would never remove, so it is not a pass.
      result =
        with {:ok, 200, %{"data" => %{"version" => version}}} when is_integer(version) <-
               call(config, :post, data_path, %{data: %{value: value}}, opts),
             {:ok, 200,
              %{"data" => %{"data" => %{"value" => ^value}, "metadata" => %{"version" => ^version}}}} <-
               call(config, :get, data_path, nil, opts) do
          {:ok, %{wrote: 1, read_back: true, version: version, mount: config.mount}}
        else
          {:ok, 204, _body} -> {:error, :not_kv_version_2}
          {:ok, status, body} -> {:error, {:round_trip_mismatch, status, summary(body)}}
          {:error, reason} -> {:error, reason}
        end

      # The secret goes whatever happened, and a proof that could not remove it
      # is not a pass: a token without delete on metadata/ would leave one
      # behind on every run.
      deleted = call(config, :delete, metadata_path, nil, opts)

      case {result, deleted} do
        {{:ok, evidence}, {:ok, status, _}} when status in [200, 204] ->
          {:ok, Map.put(evidence, :deleted, true)}

        {{:ok, _evidence}, {:ok, status, _}} ->
          {:error, {:secret_not_deleted, status}}

        {{:ok, _evidence}, {:error, reason}} ->
          {:error, {:secret_not_deleted, reason}}

        {error, _deleted} ->
          error
      end
    end
  end

  # ─── KV version 2 ────────────────────────────────────────────────────────

  @doc """
  The data map stored at `path` under the KV mount (the latest version), or
  `{:error, :not_found}` when nothing is stored there.
  """
  @spec kv_read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def kv_read(path, opts \\ []) do
    with {:ok, config} <- data_config(opts),
         {:ok, segments} <- secret_path(path) do
      case guarded_call(config, :get, "/v1/#{config.mount}/data/#{segments}", nil, opts) do
        {:ok, 200, %{"data" => %{"data" => data}}} when is_map(data) -> {:ok, data}
        # A secret whose latest version was deleted answers 404 with its metadata.
        {:ok, 404, _body} -> {:error, :not_found}
        {:ok, 200, _body} -> {:error, :openbao_not_kv_version_2}
        other -> failure(other)
      end
    end
  end

  @doc """
  Writes `data` (a map of strings) at `path` under the KV mount as a new
  version. A mount that does not exist is enabled as KV version 2 once.
  """
  @spec kv_write(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def kv_write(path, data, opts \\ []) when is_map(data) do
    with {:ok, config} <- data_config(opts),
         {:ok, segments} <- secret_path(path) do
      write = fn ->
        guarded_call(config, :post, "/v1/#{config.mount}/data/#{segments}", %{data: data}, opts)
      end

      case write.() do
        {:ok, 200, _body} ->
          :ok

        {:ok, 204, _body} ->
          {:error, :openbao_not_kv_version_2}

        {:ok, status, body} = missing when status in [400, 404] ->
          if no_route?(body), do: enable_kv_and_retry(config, write, opts), else: failure(missing)

        other ->
          failure(other)
      end
    end
  end

  @doc "Deletes every version of the secret at `path` and its metadata. A path holding nothing is `:ok`."
  @spec kv_delete(String.t(), keyword()) :: :ok | {:error, term()}
  def kv_delete(path, opts \\ []) do
    with {:ok, config} <- data_config(opts),
         {:ok, segments} <- secret_path(path) do
      case guarded_call(config, :delete, "/v1/#{config.mount}/metadata/#{segments}", nil, opts) do
        {:ok, status, _body} when status in [200, 204, 404] -> :ok
        other -> failure(other)
      end
    end
  end

  # A freshly initialised server has no secrets engine at all. Enabling the
  # mount needs a token allowed to (the in-guest root token is); a new KV
  # version 2 mount can take a moment before it routes writes.
  defp enable_kv_and_retry(config, write, opts) do
    mount_body = %{type: "kv", options: %{version: "2"}, description: "Optimal Engine secrets"}

    case guarded_call(config, :post, "/v1/sys/mounts/#{config.mount}", mount_body, opts) do
      {:ok, status, _body} when status in [200, 204] ->
        Logger.info("OpenBao: enabled the KV version 2 mount #{config.mount} for Engine secrets.")
        retry_write(write, Keyword.get(opts, :mount_retries, 10))

      {:ok, status, _body} when status in [401, 403] ->
        {:error, :openbao_mount_missing}

      other ->
        failure(other)
    end
  end

  defp retry_write(write, attempts) do
    case write.() do
      {:ok, 200, _body} ->
        :ok

      {:ok, status, body} = other when status in [400, 404] ->
        if no_route?(body) and attempts > 0 do
          Process.sleep(100)
          retry_write(write, attempts - 1)
        else
          if no_route?(body), do: {:error, :openbao_mount_missing}, else: failure(other)
        end

      other ->
        failure(other)
    end
  end

  # ─── transit ─────────────────────────────────────────────────────────────

  @doc """
  The transit key backups are sealed under: `%{mount: mount, name: name}` from
  `OPTIMAL_OPENBAO_TRANSIT_KEY` (and `OPTIMAL_OPENBAO_TRANSIT_MOUNT`), or `nil`
  when no transit key is named.
  """
  @spec transit_key() :: %{mount: String.t(), name: String.t()} | nil
  def transit_key do
    case System.get_env(@transit_key_env) do
      name when is_binary(name) ->
        if present?(name) do
          %{mount: transit_mount(), name: name |> String.trim() |> String.trim("/")}
        end

      _unset ->
        nil
    end
  end

  defp transit_mount do
    System.get_env(@transit_mount_env)
    |> then(&if(present?(&1), do: &1, else: @default_transit_mount))
    |> String.trim()
    |> String.trim("/")
  end

  @doc """
  A new 256-bit data key from the transit key: `{:ok, plaintext, ciphertext}`,
  where `ciphertext` is the key wrapped by OpenBao (`vault:v<n>:...`). The
  plaintext key is used once and never stored.
  """
  @spec transit_data_key(%{mount: String.t(), name: String.t()}, keyword()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def transit_data_key(%{mount: mount, name: name}, opts \\ []) do
    with {:ok, config} <- data_config(opts),
         {:ok, key} <- secret_path(name) do
      case guarded_call(config, :post, "/v1/#{mount}/datakey/plaintext/#{key}", %{bits: 256}, opts) do
        {:ok, 200, %{"data" => %{"plaintext" => plain, "ciphertext" => wrapped}}}
        when is_binary(plain) and is_binary(wrapped) ->
          case Base.decode64(plain) do
            {:ok, data_key} when byte_size(data_key) == 32 -> {:ok, data_key, wrapped}
            _other -> {:error, :openbao_bad_data_key}
          end

        other ->
          transit_failure(other)
      end
    end
  end

  @doc "Unwraps a data key `transit_data_key/2` made, with the same transit key."
  @spec transit_decrypt(%{mount: String.t(), name: String.t()}, String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def transit_decrypt(%{mount: mount, name: name}, ciphertext, opts \\ [])
      when is_binary(ciphertext) do
    with {:ok, config} <- data_config(opts),
         {:ok, key} <- secret_path(name) do
      case guarded_call(
             config,
             :post,
             "/v1/#{mount}/decrypt/#{key}",
             %{ciphertext: ciphertext},
             opts
           ) do
        {:ok, 200, %{"data" => %{"plaintext" => plain}}} when is_binary(plain) ->
          case Base.decode64(plain) do
            {:ok, data_key} -> {:ok, data_key}
            :error -> {:error, :openbao_bad_data_key}
          end

        # Transit answers a ciphertext it cannot open with 400.
        {:ok, 400, %{"errors" => errors}} = other when is_list(errors) ->
          if Enum.any?(errors, &(is_binary(&1) and &1 =~ "not found")),
            do: {:error, :openbao_transit_key_missing},
            else: transit_failure(other)

        other ->
          transit_failure(other)
      end
    end
  end

  defp transit_failure({:ok, 400, %{"errors" => errors}} = other) when is_list(errors) do
    cond do
      Enum.any?(errors, &(is_binary(&1) and &1 =~ "key not found")) ->
        {:error, :openbao_transit_key_missing}

      Enum.any?(errors, &(is_binary(&1) and &1 =~ "authentication failed")) ->
        {:error, :openbao_decrypt_failed}

      true ->
        failure(other)
    end
  end

  defp transit_failure({:ok, 404, _body}), do: {:error, :openbao_transit_key_missing}
  defp transit_failure(other), do: failure(other)

  # ─── shared ──────────────────────────────────────────────────────────────

  # Configuration for a data-path call, as a reason an operator can act on.
  defp data_config(opts) do
    case config(opts) do
      {:ok, config} -> {:ok, config}
      {:error, :not_configured} -> {:error, :openbao_not_configured}
      {:error, _invalid} -> {:error, :openbao_invalid_config}
    end
  end

  # Each segment is percent-encoded, and none may be empty, "." or "..": a
  # path names one secret under the mount, never a route beside it.
  defp secret_path(path) when is_binary(path) do
    segments = path |> String.trim() |> String.trim("/") |> String.split("/")

    if segments != [""] and Enum.all?(segments, &(&1 not in ["", ".", ".."])) do
      {:ok, Enum.map_join(segments, "/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))}
    else
      {:error, :invalid_secret_path}
    end
  end

  defp secret_path(_path), do: {:error, :invalid_secret_path}

  # A sealed server answers 503 to everything but sys/health; a standby that
  # cannot serve the request answers 429 or 473.
  defp failure({:ok, 503, _body}), do: {:error, :openbao_sealed}
  defp failure({:ok, status, _body}) when status in [401, 403], do: {:error, :openbao_forbidden}

  defp failure({:ok, status, _body}) when status in [429, 472, 473],
    do: {:error, :openbao_unreachable}

  defp failure({:ok, status, _body}), do: {:error, {:openbao_status, status}}
  defp failure({:error, {:openbao_down, reason}}), do: {:error, reason}
  defp failure({:error, _reason}), do: {:error, :openbao_unreachable}

  # ─── outage window ───────────────────────────────────────────────────────

  @doc "Forgets that any OpenBao address was down, so the next call asks it."
  @spec reset_outages() :: :ok
  def reset_outages do
    :persistent_term.erase(@breaker_key)
    :ok
  end

  defp guarded_call(config, method, path, body, opts) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@breaker_key, nil) do
      {base_url, until, reason} when base_url == config.base_url and until > now ->
        {:error, {:openbao_down, reason}}

      marked ->
        result = call(config, method, path, body, opts)
        note_outage(marked, config.base_url, outage(result), now)
        result
    end
  end

  # Only what says OpenBao cannot serve at all opens the window.
  defp outage({:ok, 503, _body}), do: :openbao_sealed
  defp outage({:ok, status, _body}) when status in [429, 472, 473], do: :openbao_unreachable
  defp outage({:ok, _status, _body}), do: nil
  defp outage({:error, _reason}), do: :openbao_unreachable

  # persistent_term is written only when the state changes: once when an
  # outage starts (and once per window while it lasts), once when it ends.
  defp note_outage(marked, base_url, nil, _now) do
    if match?({^base_url, _until, _reason}, marked), do: :persistent_term.erase(@breaker_key)
    :ok
  end

  defp note_outage(_marked, base_url, reason, now) do
    case retry_after_ms() do
      0 -> :ok
      window -> :persistent_term.put(@breaker_key, {base_url, now + window, reason})
    end

    :ok
  end

  defp retry_after_ms do
    case Integer.parse(System.get_env(@retry_after_env) || "") do
      {ms, ""} when ms >= 0 -> ms
      _unset_or_invalid -> @default_retry_after_ms
    end
  end

  defp no_route?(%{"errors" => errors}) when is_list(errors),
    do: Enum.any?(errors, &(is_binary(&1) and &1 =~ "no handler for route"))

  defp no_route?(_body), do: false

  defp call(config, method, path, body, opts) do
    # Sent once, and over https only to a verified certificate and host name:
    # the token is a credential to the secrets store itself.
    request_opts =
      [
        method: method,
        headers: headers(),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        single_attempt: true,
        max_body_bytes: @max_body_bytes
      ]
      |> then(fn o -> if body, do: Keyword.put(o, :body, body), else: o end)

    case HTTP.request(config.base_url <> path, request_opts) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, {:unreachable, class(reason)}}
    end
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  @doc """
  A SHA-256 of the configured token, to tell one token from another without
  keeping the token itself (`OptimalEngine.Secrets` keys its kept values by
  it). Never shown to anyone.
  """
  @spec token_fingerprint() :: binary()
  def token_fingerprint do
    :crypto.hash(:sha256, System.get_env(@token_env) |> to_string() |> String.trim())
  end

  defp headers do
    token = System.get_env(@token_env) |> to_string() |> String.trim()
    [{"X-Vault-Token", token}, {"content-type", "application/json"}]
  end

  defp class(reason) when is_atom(reason), do: reason
  defp class({class, _detail}) when is_atom(class), do: class
  defp class(_other), do: :request_failed

  defp summary(%{"errors" => errors}) when is_list(errors), do: Enum.join(errors, "; ")
  defp summary(body) when is_binary(body), do: String.slice(body, 0, 80)
  defp summary(_body), do: :unexpected_body

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
