defmodule OptimalEngine.Connectors.CredentialSource do
  @moduledoc """
  Where a connector's credentials come from.

  Two sources exist, chosen per connector by the `config.credential_source`
  field:

    * `"stored"` (the default) — the Engine's own encrypted store. The
      Runner decrypts `config.credentials_ciphertext` with `CONNECTOR_KEY`
      and hands the plaintext to the adapter for the length of one sync.
      This is the path a self-hosted Engine outside MIOSA uses.
    * `"broker"` — an outside broker (MIOSA Connect) holds the account. The
      connector names the broker's endpoint and a reference to the
      connection; at sync time the Engine asks the broker for a
      short-lived, scoped credential and never writes it anywhere.

  ## Broker config keys

  All five live in the connector's `config` JSON:

      "credential_source": "broker"
      "broker_url":        "https://connect.example.com/api/credentials"
      "broker_reference":  "conn_0000000000"   (the broker's own connection id)
      "broker_scopes":     ["mail.read"]        (optional)
      "broker_timeout_ms": 5000                 (optional)

  ## Request

  The Engine `POST`s to `broker_url` with a JSON body:

      {
        "reference":    "conn_0000000000",
        "connector":    {"id": "pull:default:gmail", "kind": "gmail"},
        "tenant_id":    "default",
        "workspace_id": "default",
        "scopes":       ["mail.read"]
      }

  The Engine presents no Engine-side secret: the broker authenticates the
  Engine out of band (a broker-issued Engine token, mTLS, or a private
  network). No token value travels outbound in this call.

  ## Response

      {
        "credentials": {"oauth_refresh_token": "...", "client_id": "..."},
        "expires_at":  "2026-10-18T12:05:00Z"
      }

  `credentials` is merged into the config exactly as if it had been
  decrypted from the Engine's store, so adapters never learn which source
  they ran under. `expires_at` is informational: the Engine fetches just in
  time on every sync and holds the result in memory for one cycle only.

  ## Errors

      {:error, :broker_not_configured} — source is "broker" but the URL or
                                        reference is missing, or the source
                                        name is not one of the two known
                                        values
      {:error, :broker_refused}        — the broker answered without usable
                                        credentials (401, 403, 404, an error
                                        body, or an empty credentials map)
      {:error, :broker_unreachable}    — no usable answer (network error,
                                        timeout, or a 5xx)

  A fetch failure fails the sync before `init/1` runs, so a broker outage
  surfaces as a connector run error rather than as a half-configured
  adapter. Fetched credentials are never written to the connectors table,
  the run log, or an error message.
  """

  alias OptimalEngine.Connectors.HTTP

  @stored "stored"
  @broker "broker"
  @default_timeout_ms 5_000

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

  `:stored` returns the config untouched — the Runner has already decrypted
  the encrypted envelope. `:broker` fetches now, merges, and returns; the
  fetch result is not cached.
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
  broker and leave a second copy of the account in the Engine database.
  """
  @spec check_persistable(map()) :: :ok | {:error, :broker_credentials_must_not_be_stored}
  def check_persistable(config) when is_map(config) do
    has_credentials? =
      is_map(value(config, "credentials")) or is_map(value(config, :credentials))

    case source(config) do
      {:ok, :broker} when has_credentials? -> {:error, :broker_credentials_must_not_be_stored}
      _ -> :ok
    end
  end

  # ─── broker fetch ────────────────────────────────────────────────────────

  defp fetch_and_merge(config, scope) do
    url = value(config, "broker_url")
    reference = value(config, "broker_reference")

    if blank?(url) or blank?(reference) do
      {:error, :broker_not_configured}
    else
      with {:ok, body} <- request(url, reference, config, scope),
           {:ok, credentials} <- credentials(body) do
        {:ok, Map.put(config, "credentials", credentials)}
      end
    end
  end

  defp request(url, reference, config, scope) do
    payload = %{
      "reference" => reference,
      "connector" => %{
        "id" => value(scope, :id),
        "kind" => value(scope, :kind)
      },
      "tenant_id" => value(scope, :tenant_id),
      "workspace_id" => value(scope, :workspace_id),
      "scopes" => scope_scopes(config)
    }

    opts = [timeout: timeout_ms(config)]

    case HTTP.post_json(url, payload, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} when status in [401, 403, 404] -> {:error, :broker_refused}
      {:ok, %{status: status}} when status >= 500 -> {:error, :broker_unreachable}
      {:ok, _response} -> {:error, :broker_refused}
      {:error, _reason} -> {:error, :broker_unreachable}
    end
  end

  # The broker answers with the credential map itself or nests it under
  # "credentials". Anything else, including an empty map, is a refusal: an
  # adapter initialised with no credentials would report a confusing
  # `{:missing_credentials, ...}` instead of naming the broker.
  defp credentials(body) when is_map(body) do
    map = value(body, "credentials") || value(body, "data") || body

    case map do
      %{} = credentials when map_size(credentials) > 0 -> {:ok, stringify(credentials)}
      _ -> {:error, :broker_refused}
    end
  end

  defp credentials(_body), do: {:error, :broker_refused}

  defp scope_scopes(config) do
    case value(config, "broker_scopes") do
      scopes when is_list(scopes) -> Enum.map(scopes, &to_string/1)
      _ -> []
    end
  end

  defp timeout_ms(config) do
    case value(config, "broker_timeout_ms") do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_timeout_ms
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, val} -> {to_string(key), val} end)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
