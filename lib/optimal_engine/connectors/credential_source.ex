defmodule OptimalEngine.Connectors.CredentialSource do
  @moduledoc """
  Where a connector's credentials come from.

  Two sources exist, chosen per connector by the `config.credential_source`
  field:

    * `"stored"` (the default) - the Engine's own encrypted store. The
      Runner decrypts `config.credentials_ciphertext` with `CONNECTOR_KEY`
      and hands the plaintext to the adapter for the length of one sync.
      This is the path a self-hosted Engine outside MIOSA uses.
    * `"broker"` - an outside broker (MIOSA Connect) holds the account. The
      connector names the broker's endpoint and a reference to the
      connection; at sync time the Engine asks the broker for a
      short-lived, scoped credential and never writes it anywhere.

  ## Broker config keys

  All of them live in the connector's `config` JSON:

      "credential_source": "broker"
      "broker_url":        "https://connect.example.com/api/credentials"
      "broker_reference":  "conn_0000000000"   (the broker's own reference to the connection)
      "broker_scopes":     ["mail.read"]        (optional)
      "broker_timeout_ms": 5000                 (optional, at most 30000)

  The reference is opaque to the Engine and may be signed by the broker, so
  it is a secret: it is sealed with `CONNECTOR_KEY` into
  `config.broker_reference_ciphertext` when the row is written
  (`seal_reference/1`), opened only for the broker call, and every read API
  shows it as `"[redacted]"`. A reference written before sealing existed is
  read as it is and sealed on the connector's next change.

  `broker_url` must be `https` and its host must be one of the hosts named in
  `config :optimal_engine, :credential_broker_hosts` (the
  `OPTIMAL_CREDENTIAL_BROKER_HOSTS` environment variable). With no hosts
  named, no broker is called.

  ## Request

  The Engine `POST`s to `broker_url` with a JSON body:

      {
        "reference":    "conn_0000000000",
        "connector":    {"id": "pull:default:gmail", "kind": "gmail"},
        "tenant_id":    "default",
        "workspace_id": "default",
        "scopes":       ["mail.read"]
      }

  `reference` is the configured `broker_reference`, sent verbatim and never
  parsed (MIOSA Connect signs it as `<connection_id>.<hmac>`, and that
  signature is what the broker authenticates the call by). The Engine sends
  no secret and no header of its own beyond `accept` and `content-type`. The
  call does not follow redirects and gives up after `broker_timeout_ms`.

  ## Response

  An OAuth connection is answered with a short-lived access token:

      {"credentials": {"access_token": "...", "expires_at": "2026-10-18T12:05:00Z"}}

  The same fields at the top level are accepted too, and `"expires_in"`
  (seconds) is read when `"expires_at"` is absent. The token becomes an
  `OptimalEngine.Connectors.AccessToken` in the adapter's `access_token`
  credential: the adapter calls its API through that module, which asks the
  broker again within 60 s of `expires_at` and once after a `401`.

  Any other connection is answered with its credential map:

      {"credentials": {"api_key": "..."}, "expires_at": "2026-10-18T12:05:00Z"}

  which is merged into the config exactly as if it had been decrypted from
  the Engine's store, so adapters never learn which source they ran under.

  ## Errors

      {:error, :broker_not_configured}       - source is "broker" but the URL or
                                              reference is missing
      {:error, :broker_url_not_allowed}      - the URL is not https, or its host
                                              is not an allowed broker host
      {:error, :broker_reference_unreadable} - the sealed reference cannot be
                                              opened with this CONNECTOR_KEY
      {:error, :broker_unauthorized}         - the broker answered 401: it did not
                                              accept the reference as proof
      {:error, :broker_refused}              - the broker answered without
                                              usable credentials (403, 404, an
                                              error body, or an empty
                                              credentials map)
      {:error, :broker_unreachable}          - no usable answer (network error,
                                              timeout, or a 5xx)
      {:error, :broker_token_rejected}       - the API refused a brokered token
                                              again after one re-fetch
                                              (`OptimalEngine.Connectors.AccessToken`)
      {:error, :invalid_credential_source}   - the source is not one of the two
                                              known names

  A fetch failure fails the sync before `init/1` runs, so a broker outage
  surfaces as a connector run error rather than as a half-configured
  adapter. Fetched credentials are never written to the connectors table,
  the run log, or an error message.
  """

  alias OptimalEngine.Connectors.{AccessToken, Credential, HTTP}

  require Logger

  @stored "stored"
  @broker "broker"
  @reference "broker_reference"
  @sealed_reference "broker_reference_ciphertext"
  @default_timeout_ms 5_000
  @max_timeout_ms 30_000
  # What the broker says about a token rather than the token itself.
  @token_terms ~w(expires_at expires_in token_type)

  @type source :: :stored | :broker
  @type scope :: %{
          optional(:id) => String.t(),
          optional(:kind) => String.t(),
          optional(:tenant_id) => String.t(),
          optional(:workspace_id) => String.t()
        }

  @doc "The credential source names."
  @spec sources() :: [String.t()]
  def sources, do: [@stored, @broker]

  @doc """
  The configured source for a connector config. An absent or empty value
  means `:stored`, so every connector written before this option existed
  keeps working unchanged.
  """
  @spec source(map()) :: {:ok, source()} | {:error, :invalid_credential_source}
  def source(config) when is_map(config) do
    case value(config, "credential_source") do
      nil -> {:ok, :stored}
      "" -> {:ok, :stored}
      @stored -> {:ok, :stored}
      @broker -> {:ok, :broker}
      _other -> {:error, :invalid_credential_source}
    end
  end

  @doc """
  Resolves the credentials for one sync cycle and merges them into the
  config the adapter's `init/1` receives.

  `:stored` returns the config untouched - the Runner has already decrypted
  the encrypted envelope. `:broker` fetches now, merges, and returns; the
  fetch result is not cached. The broker settings, the reference among them,
  are not passed on to the adapter.
  """
  @spec hydrate(map(), scope()) :: {:ok, map()} | {:error, atom()}
  def hydrate(config, scope \\ %{}) when is_map(config) do
    case source(config) do
      {:ok, :stored} -> {:ok, config}
      {:ok, :broker} -> fetch_and_merge(config, scope)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Guards the write path: a connector on the broker source must not also
  carry credentials, because storing them would defeat the point of the
  broker and leave a second copy of the account in the Engine database, and
  its broker URL must be one the Engine may call.
  """
  @spec check_persistable(map()) ::
          :ok | {:error, :broker_credentials_must_not_be_stored | :broker_url_not_allowed}
  def check_persistable(config) when is_map(config) do
    has_credentials? =
      is_map(value(config, "credentials")) or is_map(value(config, :credentials))

    case source(config) do
      {:ok, :broker} when has_credentials? ->
        {:error, :broker_credentials_must_not_be_stored}

      {:ok, :broker} ->
        url = value(config, "broker_url")
        if blank?(url), do: :ok, else: check_url(url)

      _ ->
        :ok
    end
  end

  @doc """
  Seals a plaintext `broker_reference` into `broker_reference_ciphertext`
  with `CONNECTOR_KEY`, replacing any older seal. A config without one is
  returned unchanged. Without a configured key the write is refused with
  `{:error, :connector_key_missing}`, as for credentials.
  """
  @spec seal_reference(map()) :: {:ok, map()} | {:error, :connector_key_missing | :invalid_config}
  def seal_reference(config) when is_map(config) do
    {plain, config} = pop_reference(config)

    case plain do
      nil ->
        {:ok, config}

      "" ->
        {:ok, Map.delete(config, @sealed_reference)}

      reference when is_binary(reference) ->
        case Credential.encrypt(%{@reference => reference}) do
          {:ok, envelope} ->
            {:ok, Map.put(config, @sealed_reference, envelope)}

          {:error, :key_missing} ->
            Logger.error("Broker reference refused: CONNECTOR_KEY is not configured.")
            {:error, :connector_key_missing}
        end

      _other ->
        {:error, :invalid_config}
    end
  end

  @doc "Whether the config names a broker reference, sealed or not."
  @spec reference?(map()) :: boolean()
  def reference?(config) when is_map(config) do
    not blank?(value(config, @reference)) or is_binary(Map.get(config, @sealed_reference))
  end

  @doc """
  Whether `url` is a broker the Engine may call: `https`, no credentials in
  the URL, and a host named in `:credential_broker_hosts`.
  """
  @spec check_url(term()) :: :ok | {:error, :broker_url_not_allowed}
  def check_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        if String.downcase(host) in allowed_hosts(),
          do: :ok,
          else: {:error, :broker_url_not_allowed}

      _other ->
        {:error, :broker_url_not_allowed}
    end
  end

  def check_url(_url), do: {:error, :broker_url_not_allowed}

  # ─── broker fetch ────────────────────────────────────────────────────────

  defp fetch_and_merge(config, scope) do
    with {:ok, broker} <- broker(config, scope),
         {:ok, credentials} <- fetch(broker) do
      {:ok,
       config
       |> Map.drop([@reference, @sealed_reference, :broker_reference])
       |> Map.put("credentials", credentials)}
    end
  end

  defp broker(config, scope) do
    url = value(config, "broker_url")

    with {:ok, reference} <- reference(config) do
      if blank?(url) or blank?(reference) do
        {:error, :broker_not_configured}
      else
        with :ok <- check_url(url) do
          {:ok,
           %{
             url: url,
             reference: reference,
             scopes: scope_scopes(config),
             timeout_ms: timeout_ms(config),
             scope: scope
           }}
        end
      end
    end
  end

  # The sealed reference wins; a plaintext one is a row written before sealing.
  defp reference(config) do
    case Map.get(config, @sealed_reference) do
      envelope when is_binary(envelope) ->
        case Credential.decrypt(envelope) do
          {:ok, %{@reference => reference}} when is_binary(reference) -> {:ok, reference}
          _unreadable -> {:error, :broker_reference_unreadable}
        end

      _none ->
        {:ok, value(config, @reference)}
    end
  end

  defp fetch(broker) do
    with {:ok, body} <- request(broker) do
      credentials(body, broker)
    end
  end

  defp request(broker) do
    payload = %{
      "reference" => broker.reference,
      "connector" => %{
        "id" => value(broker.scope, :id),
        "kind" => value(broker.scope, :kind)
      },
      "tenant_id" => value(broker.scope, :tenant_id),
      "workspace_id" => value(broker.scope, :workspace_id),
      "scopes" => broker.scopes
    }

    case HTTP.post_json(broker.url, payload, timeout: broker.timeout_ms, follow_redirects: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :broker_unauthorized}
      {:ok, %{status: status}} when status in [403, 404] -> {:error, :broker_refused}
      {:ok, %{status: status}} when status >= 500 -> {:error, :broker_unreachable}
      {:ok, _response} -> {:error, :broker_refused}
      {:error, _reason} -> {:error, :broker_unreachable}
    end
  end

  # The broker answers with the credential map itself or nests it under
  # "credentials". An access token in it becomes an issued `AccessToken` that
  # can ask the broker again. Anything else, including an empty map, is a
  # refusal: an adapter initialised with no credentials would report a
  # confusing `{:missing_credentials, ...}` instead of naming the broker.
  defp credentials(body, broker) when is_map(body) do
    map =
      case value(body, "credentials") || value(body, "data") do
        %{} = nested -> stringify(nested)
        _flat -> stringify(body)
      end

    expires_at = expires_at(map, body)
    rest = Map.drop(map, ["access_token" | @token_terms])

    case Map.get(map, "access_token") do
      token when is_binary(token) and token != "" ->
        issued = AccessToken.issued(token, expires_at, fn -> renew(broker) end)
        {:ok, Map.put(rest, "access_token", issued)}

      nil when map_size(rest) > 0 ->
        {:ok, rest}

      _none ->
        {:error, :broker_refused}
    end
  end

  defp credentials(_body, _broker), do: {:error, :broker_refused}

  # A renewal is an access token or nothing: a broker that answers a renewal
  # with something else has refused it.
  defp renew(broker) do
    case fetch(broker) do
      {:ok, %{"access_token" => %AccessToken{} = token}} -> {:ok, token}
      {:ok, _other} -> {:error, :broker_refused}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expires_at(map, body) do
    at = Map.get(map, "expires_at") || value(body, "expires_at")
    seconds = Map.get(map, "expires_in") || value(body, "expires_in")

    case {parse_instant(at), parse_seconds(seconds)} do
      {%DateTime{} = instant, _seconds} -> instant
      {nil, n} when is_integer(n) -> DateTime.add(DateTime.utc_now(), n, :second)
      _neither -> nil
    end
  end

  defp parse_instant(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, instant, _offset} -> instant
      _invalid -> nil
    end
  end

  defp parse_instant(_value), do: nil

  defp parse_seconds(n) when is_integer(n), do: n

  defp parse_seconds(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _invalid -> nil
    end
  end

  defp parse_seconds(_value), do: nil

  defp allowed_hosts do
    case Application.get_env(:optimal_engine, :credential_broker_hosts, []) do
      hosts when is_list(hosts) -> Enum.map(hosts, &normalize_host/1)
      hosts when is_binary(hosts) -> hosts |> String.split(",") |> Enum.map(&normalize_host/1)
      _other -> []
    end
  end

  defp normalize_host(host), do: host |> to_string() |> String.trim() |> String.downcase()

  defp scope_scopes(config) do
    case value(config, "broker_scopes") do
      scopes when is_list(scopes) -> Enum.map(scopes, &to_string/1)
      _ -> []
    end
  end

  defp timeout_ms(config) do
    case value(config, "broker_timeout_ms") do
      ms when is_integer(ms) and ms > 0 -> min(ms, @max_timeout_ms)
      _ -> @default_timeout_ms
    end
  end

  defp pop_reference(config) do
    {plain, config} = Map.pop(config, @reference)
    {atom_plain, config} = Map.pop(config, :broker_reference)
    {plain || atom_plain, config}
  end

  defp stringify(map), do: Map.new(map, fn {key, val} -> {to_string(key), val} end)

  # A connector config arrives with string keys from the `connectors` table and
  # with atom keys from a caller building one by hand, so both are read. The
  # atom form is looked up without creating atoms.
  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || Map.get(map, atom_key(key))
  end

  defp atom_key(key) when is_atom(key), do: key

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp atom_key(_key), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
