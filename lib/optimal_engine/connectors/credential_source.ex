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
      "broker_url":        "https://api.miosa.ai/api/v1/connect/broker/credentials"
      "broker_reference":  "conn_0000000000.<hmac>"   (the broker's own reference to the connection)
      "broker_scopes":     ["mail.read"]        (optional)
      "broker_timeout_ms": 5000                 (optional, at most 30000)

  The reference is opaque to the Engine and may be signed by the broker, so
  it is a secret: it is sealed with `CONNECTOR_KEY`, bound to the connector's
  id and workspace, into `config.broker_reference_ciphertext` when the row is
  written (`seal_reference/2`), opened only for the broker call, and every
  read API shows it as `"[redacted]"`. A reference written before sealing
  existed, or sealed before it was bound, is read as it is and sealed (bound)
  on the connector's next change.

  `broker_url` is checked as written (`check_url/1`): `https` on port 443, a
  host named in `config :optimal_engine, :credential_broker_hosts` (the
  `OPTIMAL_CREDENTIAL_BROKER_HOSTS` environment variable), and a path under
  `:credential_broker_paths` (`OPTIMAL_CREDENTIAL_BROKER_PATHS`, default
  `/api/v1/connect/broker/`). With no hosts named, no broker is called.

  ## Request

  The Engine `POST`s to `broker_url` with a JSON body:

      {
        "reference":    "conn_0000000000.<hmac>",
        "connector":    {"id": "miosa:conn_0000000000:gmail", "kind": "gmail"},
        "tenant_id":    "default",
        "workspace_id": "default:ops",
        "scopes":       ["mail.read"]
      }

  `connector.id` is the connector's own id and `workspace_id` is the
  connector's own workspace, whatever workspaces its signals are routed to:
  a broker that signs the workspace into the reference answers a different
  one with a `401`.

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

  `expires_at` may also sit beside `credentials`. A stored API key is
  answered the same way:

      {"credentials": {"api_key": "..."}, "expires_at": "2026-10-18T12:05:00Z"}

  and the credential map is merged into the config exactly as if it had been
  decrypted from the Engine's store, so adapters never learn which source
  they ran under.

  ## Where the broker's secret lands

  Each adapter names the key its single secret lives under (`token_key:` in
  `OptimalEngine.Connectors.Adapters.Base`, read from the adapter the
  `:adapter` of the scope names), and the broker's secret is put there:

    * an access token, for an adapter that calls through `AccessToken` (Gmail,
      Drive, Notion, Slack, Dropbox, HubSpot, OneDrive, Salesforce, Teams,
      Zoom), stays under `access_token` as an issued token that can be renewed
    * an access token, for an adapter that does not (Stripe, Fathom, Linear,
      JotForm, beehiiv: `api_key`; GitHub: `pat`; GoHighLevel, Jira,
      Confluence: `api_token`), becomes that key, as a plain string
    * an API key becomes the adapter's key when it is not `api_key` (Notion:
      `integration_token`, Slack: `bot_token`, GitHub: `pat`, ...)

  A key the broker names itself is passed on as it is, and wins.

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
  # The broker's answer is a few credentials; anything longer is not one.
  @max_body_bytes 262_144
  # An expiry further away than this is read as this far away, so no value the
  # broker names can overflow a date.
  @max_expires_in_s 315_360_000
  @default_paths ["/api/v1/connect/broker/"]
  @url ~r|\Ahttps://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(/[A-Za-z0-9._~!$&'()*+,;=:@/-]*)\z|
  # What the broker says about a token rather than the token itself.
  @token_terms ~w(expires_at expires_in token_type)

  defmodule Broker do
    @moduledoc false
    # Everything one fetch needs. The reference is the broker's proof of who is
    # asking, so `inspect/1` leaves it out.
    @derive {Inspect, except: [:reference]}
    defstruct [:url, :reference, :scopes, :timeout_ms, :scope, :adapter]
  end

  @type source :: :stored | :broker
  @type scope :: %{
          optional(:id) => String.t(),
          optional(:kind) => String.t(),
          optional(:tenant_id) => String.t(),
          optional(:workspace_id) => String.t(),
          optional(:adapter) => module()
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
  with `CONNECTOR_KEY`, replacing any older seal. Without a configured key the
  write is refused with `{:error, :connector_key_missing}`, as for credentials.

  The seal is bound to the connector it belongs to: `binding` is
  `%{id: connector_id, workspace_id: workspace_id}` and the seal opens only
  for that connector in that workspace, so a copy of it placed on another row
  is not read. A config with no plaintext reference but a seal is rebound when
  the seal was made without a binding (the older form) or for the workspace
  the connector has moved from (`:previous_workspace_id`); a seal that cannot
  be opened is left as it is and reported when a run needs it, so the
  connector can still be changed. Without a `binding` the seal is the older,
  unbound form.
  """
  @spec seal_reference(map(), map() | nil) ::
          {:ok, map()} | {:error, :connector_key_missing | :invalid_config}
  def seal_reference(config, binding \\ nil) when is_map(config) do
    {plain, config} = pop_reference(config)

    case plain do
      nil ->
        {:ok, rebind(config, binding)}

      "" ->
        {:ok, Map.delete(config, @sealed_reference)}

      reference when is_binary(reference) ->
        case Credential.encrypt(%{@reference => reference}, aad(binding)) do
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

  # The associated data a seal is bound to; none for the older, unbound form.
  defp aad(%{id: id, workspace_id: workspace_id}) when is_binary(id) and is_binary(workspace_id),
    do: "optimal.connector.broker_reference\0" <> id <> "\0" <> workspace_id

  defp aad(_binding), do: ""

  defp rebind(config, nil), do: config

  defp rebind(config, binding) do
    with envelope when is_binary(envelope) <- Map.get(config, @sealed_reference),
         wanted = aad(binding),
         {:error, _reason} <- Credential.decrypt(envelope, wanted),
         {:ok, %{@reference => reference}} <- open_earlier(envelope, binding),
         {:ok, rebound} <- Credential.encrypt(%{@reference => reference}, wanted) do
      Map.put(config, @sealed_reference, rebound)
    else
      _unchanged -> config
    end
  end

  # The forms a seal had before it was bound to this connector in this
  # workspace: unbound, or bound to the workspace the connector came from.
  defp open_earlier(envelope, binding) do
    earlier =
      case Map.get(binding, :previous_workspace_id) do
        previous when is_binary(previous) and previous != binding.workspace_id ->
          [aad(%{binding | workspace_id: previous}), ""]

        _none ->
          [""]
      end

    Enum.find_value(earlier, {:error, :unreadable}, fn aad ->
      case Credential.decrypt(envelope, aad) do
        {:ok, _reference} = opened -> opened
        {:error, _reason} -> nil
      end
    end)
  end

  @doc "Whether the config names a broker reference, sealed or not."
  @spec reference?(map()) :: boolean()
  def reference?(config) when is_map(config) do
    not blank?(value(config, @reference)) or is_binary(Map.get(config, @sealed_reference))
  end

  @doc """
  Whether `url` is a broker the Engine may call: exactly `https` on port 443 (or
  none), a host named in `:credential_broker_hosts` (ASCII, compared without
  case, no trailing dot), no user info, no query, no fragment, and a path under
  one of `:credential_broker_paths` (default `/api/v1/connect/broker/`) with no
  `.`, `..`, empty or encoded segment. Anything else is refused as written, not
  as some parser might read it.
  """
  @spec check_url(term()) :: :ok | {:error, :broker_url_not_allowed}
  def check_url(url) when is_binary(url) do
    with [_all, host, port, path] <- Regex.run(@url, url),
         true <- port in ["", "443"],
         true <- String.downcase(host, :ascii) in allowed_hosts(),
         true <- clean_path?(path),
         true <- Enum.any?(allowed_paths(), &under?(path, &1)) do
      :ok
    else
      _refused -> {:error, :broker_url_not_allowed}
    end
  end

  def check_url(_url), do: {:error, :broker_url_not_allowed}

  defp clean_path?(path) do
    [_leading | segments] = String.split(path, "/")
    {last, inner} = List.pop_at(segments, -1)
    Enum.all?(inner, &(&1 not in ["", ".", ".."])) and last not in [".", ".."]
  end

  defp under?(path, prefix),
    do: path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")

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

    with {:ok, reference} <- reference(config, scope) do
      if blank?(url) or blank?(reference) do
        {:error, :broker_not_configured}
      else
        with :ok <- check_url(url) do
          {:ok,
           %Broker{
             url: url,
             reference: reference,
             scopes: scope_scopes(config),
             timeout_ms: timeout_ms(config),
             scope: scope,
             adapter: adapter_traits(scope)
           }}
        end
      end
    end
  end

  # The sealed reference wins; a plaintext one is a row written before sealing.
  # A seal opens for the connector and workspace it was bound to, or, if it was
  # sealed before it was bound, without them.
  defp reference(config, scope) do
    case Map.get(config, @sealed_reference) do
      envelope when is_binary(envelope) ->
        bound = aad(%{id: value(scope, :id), workspace_id: value(scope, :workspace_id)})

        case Enum.find_value(Enum.uniq([bound, ""]), &open(envelope, &1)) do
          nil -> {:error, :broker_reference_unreadable}
          reference -> {:ok, reference}
        end

      _none ->
        {:ok, value(config, @reference)}
    end
  end

  defp open(envelope, aad) do
    case Credential.decrypt(envelope, aad) do
      {:ok, %{@reference => reference}} when is_binary(reference) -> reference
      _unreadable -> nil
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

    opts = [
      timeout: broker.timeout_ms,
      follow_redirects: false,
      single_attempt: true,
      verify_tls: true,
      max_body_bytes: @max_body_bytes
    ]

    case HTTP.post_json(broker.url, payload, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :broker_unauthorized}
      {:ok, %{status: status}} when status in [403, 404] -> {:error, :broker_refused}
      {:ok, %{status: status}} when status >= 500 -> {:error, :broker_unreachable}
      {:ok, _response} -> {:error, :broker_refused}
      {:error, _reason} -> {:error, :broker_unreachable}
    end
  end

  # The broker answers with the credential map itself or nests it under
  # "credentials". Anything else, including an empty map, is a refusal: an
  # adapter initialised with no credentials would report a confusing
  # `{:missing_credentials, ...}` instead of naming the broker.
  #
  # What the adapter gets depends on how it authenticates (`adapter_traits/1`):
  #
  #   * an access token, for an adapter that calls through `AccessToken`, is
  #     issued as an `AccessToken` under `access_token`, which can ask the
  #     broker again
  #   * an access token, for any other adapter, goes under the key its single
  #     secret lives under (`pat`, `api_key`, ...), as a plain string
  #   * an API key goes under that same key when the adapter's is not `api_key`
  defp credentials(body, broker) when is_map(body) do
    top = stringify(body)

    map =
      case value(body, "credentials") || value(body, "data") do
        %{} = nested -> stringify(nested)
        _flat -> top
      end

    expires_at = expires_at(map, body)

    rest =
      map
      |> Map.drop(["access_token" | @token_terms])
      |> native_api_key(broker.adapter)
      |> wrap_secrets(broker.adapter)

    cond do
      # A 200 that carries an error is the broker saying no.
      Map.get(top, "error") not in [nil, false] ->
        {:error, :broker_refused}

      is_binary(Map.get(map, "access_token")) and Map.get(map, "access_token") != "" ->
        {:ok, with_access_token(rest, Map.get(map, "access_token"), expires_at, broker)}

      Map.get(map, "access_token") == nil and map_size(rest) > 0 ->
        {:ok, rest}

      true ->
        {:error, :broker_refused}
    end
  end

  defp credentials(_body, _broker), do: {:error, :broker_refused}

  defp with_access_token(rest, token, expires_at, %{adapter: %{access_token?: true}} = broker) do
    issued = AccessToken.issued(token, expires_at, fn -> renew(broker) end)
    Map.put(rest, "access_token", issued)
  end

  defp with_access_token(rest, token, _expires_at, %{adapter: %{token_key: key}})
       when is_binary(key),
       do: Map.put_new(rest, key, AccessToken.secret(token))

  defp with_access_token(rest, token, _expires_at, _broker),
    do: Map.put(rest, "access_token", AccessToken.secret(token))

  # The secrets a broker issues are held opaque in the adapter's state, so a
  # crash that prints the state prints none of them.
  defp wrap_secrets(credentials, adapter) do
    keys = Enum.reject(["api_key", adapter.token_key], &is_nil/1)

    Enum.reduce(keys, credentials, fn key, acc ->
      case Map.get(acc, key) do
        secret when is_binary(secret) and secret != "" ->
          Map.put(acc, key, AccessToken.secret(secret))

        _other ->
          acc
      end
    end)
  end

  defp native_api_key(credentials, %{token_key: key}) when is_binary(key) and key != "api_key" do
    case Map.pop(credentials, "api_key") do
      {api_key, rest} when is_binary(api_key) and api_key != "" -> Map.put_new(rest, key, api_key)
      _none -> credentials
    end
  end

  defp native_api_key(credentials, _adapter), do: credentials

  # What the Engine knows of the adapter a connector runs: the key its single
  # secret lives under, and whether it calls through `AccessToken`. Without an
  # adapter in the scope, every broker is taken to be answering an OAuth one.
  defp adapter_traits(scope) do
    mod = value(scope, :adapter)

    if is_atom(mod) and mod != nil and Code.ensure_loaded?(mod) and
         function_exported?(mod, :broker_token_key, 0) and
         function_exported?(mod, :broker_access_token?, 0) do
      %{token_key: key_name(mod.broker_token_key()), access_token?: mod.broker_access_token?()}
    else
      %{token_key: nil, access_token?: true}
    end
  end

  defp key_name(nil), do: nil
  defp key_name(key), do: to_string(key)

  # A renewal is an access token or nothing: a broker that answers a renewal
  # with something else has refused it.
  defp renew(broker) do
    with :ok <- check_url(broker.url),
         {:ok, credentials} <- fetch(broker) do
      case credentials do
        %{"access_token" => %AccessToken{} = token} -> {:ok, token}
        _other -> {:error, :broker_refused}
      end
    end
  end

  defp expires_at(map, body) do
    at = Map.get(map, "expires_at") || value(body, "expires_at")
    seconds = Map.get(map, "expires_in") || value(body, "expires_in")

    case {parse_instant(at), parse_seconds(seconds)} do
      {%DateTime{} = instant, _seconds} ->
        instant

      {nil, n} when is_integer(n) ->
        DateTime.add(DateTime.utc_now(), n |> max(0) |> min(@max_expires_in_s), :second)

      _neither ->
        nil
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

  defp normalize_host(host), do: host |> to_string() |> String.trim() |> String.downcase(:ascii)

  defp allowed_paths do
    case Application.get_env(:optimal_engine, :credential_broker_paths, @default_paths) do
      paths when is_list(paths) -> Enum.map(paths, &(&1 |> to_string() |> String.trim()))
      paths when is_binary(paths) -> paths |> String.split(",") |> Enum.map(&String.trim/1)
      _other -> @default_paths
    end
  end

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
