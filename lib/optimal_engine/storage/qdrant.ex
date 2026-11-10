defmodule OptimalEngine.Storage.Qdrant do
  @moduledoc """
  The Qdrant service provider: a high-scale vector projection next to the
  embedded vectors. Vector results are candidates, never truth; the canonical
  stores rebuild every collection.

  Reached over its REST API through `OptimalEngine.Connectors.HTTP`, from
  `OPTIMAL_QDRANT_URL` and, when the server asks for one, `OPTIMAL_QDRANT_API_KEY`
  (sent as the `api-key` header, never logged, described or returned). The key
  is read through `OptimalEngine.Secrets`, so it may be an
  `openbao:<path>#<field>` reference; one OpenBao cannot answer fails the
  request with `{:api_key_unavailable, reason}` and nothing is sent.

  Health is `GET /collections` answered `200`: it exercises the key and the
  API, where `/healthz` answers anyone. The proof creates a collection of its
  own (`optimal_proof_<random>`, four dimensions), upserts one point with a
  payload, searches for it, reads the payload back and deletes the collection,
  so a healthy provider has indexed and retrieved a vector, not merely answered.
  """

  alias OptimalEngine.Connectors.HTTP
  alias OptimalEngine.Secrets

  @env "OPTIMAL_QDRANT_URL"
  @key_env "OPTIMAL_QDRANT_API_KEY"
  @default_timeout 3_000
  @proof_prefix "optimal_proof_"

  @type health :: :healthy | :unreachable | :not_configured | :invalid_config

  @doc "The environment variable the provider is configured by."
  @spec env_name() :: String.t()
  def env_name, do: @env

  @doc "The environment variable the API key is read from."
  @spec key_env_name() :: String.t()
  def key_env_name, do: @key_env

  @doc "Whether `OPTIMAL_QDRANT_URL` is set and is an http(s) URL."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config())

  @doc "The base URL and whether a key is set. The key itself is not in the result."
  @spec config(keyword()) :: {:ok, map()} | {:error, atom()}
  def config(opts \\ []) do
    case Keyword.get(opts, :url) || System.get_env(@env) do
      value when is_binary(value) and value != "" ->
        case URI.parse(value) do
          %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
            {:ok,
             %{
               base_url: String.trim_trailing(value, "/"),
               tls: scheme == "https",
               key: present?(@key_env)
             }}

          _ ->
            {:error, :invalid_url}
        end

      _ ->
        {:error, :not_configured}
    end
  end

  @doc "`GET /collections` answered 200."
  @spec health(keyword()) :: health()
  def health(opts \\ []) do
    case config(opts) do
      {:ok, config} ->
        case call(config, :get, "/collections", nil, opts) do
          {:ok, 200, _body} -> :healthy
          _ -> :unreachable
        end

      {:error, :not_configured} ->
        :not_configured

      {:error, _reason} ->
        :invalid_config
    end
  end

  @doc """
  Creates a collection, upserts one point, searches for it, reads its payload
  back and deletes the collection. Nothing is left behind.
  """
  @spec round_trip(keyword()) :: {:ok, map()} | {:error, term()}
  def round_trip(opts \\ []) do
    with {:ok, config} <- config(opts) do
      collection = @proof_prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      value = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      vector = [0.1, 0.2, 0.3, 0.4]

      result =
        with {:ok, 200, _} <-
               call(
                 config,
                 :put,
                 "/collections/#{collection}",
                 %{vectors: %{size: 4, distance: "Cosine"}},
                 opts
               ),
             {:ok, 200, _} <-
               call(
                 config,
                 :put,
                 "/collections/#{collection}/points?wait=true",
                 %{points: [%{id: 1, vector: vector, payload: %{proof: value}}]},
                 opts
               ),
             {:ok, 200, %{"result" => [%{"id" => 1, "payload" => %{"proof" => ^value}} | _]}} <-
               call(
                 config,
                 :post,
                 "/collections/#{collection}/points/search",
                 %{vector: vector, limit: 1, with_payload: true},
                 opts
               ) do
          {:ok, %{collection_created: true, points: 1, searched: true, read_back: true}}
        else
          {:ok, status, body} -> {:error, {:round_trip_mismatch, status, summary(body)}}
          {:error, reason} -> {:error, reason}
        end

      # The collection goes whatever happened, and a proof that could not
      # remove it is not a pass: a key that may create but not delete would
      # otherwise leave one behind on every run.
      deleted = call(config, :delete, "/collections/#{collection}", nil, opts)

      case {result, deleted} do
        {{:ok, evidence}, {:ok, 200, _}} -> {:ok, Map.put(evidence, :collection_deleted, true)}
        {{:ok, _evidence}, {:ok, status, _}} -> {:error, {:collection_not_deleted, status}}
        {{:ok, _evidence}, {:error, reason}} -> {:error, {:collection_not_deleted, reason}}
        {error, _deleted} -> error
      end
    end
  end

  @doc """
  One request to the configured Qdrant, in the provider's own style: sent once,
  with the `api-key` header when a key is set. Returns `{:ok, status, body}`,
  `{:error, :not_configured}`, or `{:error, reason}` with the failure's class
  only (never the request, which may carry the key).
  """
  @spec request(atom(), String.t(), map() | nil, keyword()) ::
          {:ok, non_neg_integer(), term()} | {:error, term()}
  def request(method, path, body \\ nil, opts \\ []) do
    case config(opts) do
      {:ok, config} -> call(config, method, path, body, opts)
      {:error, _} = error -> error
    end
  end

  defp call(config, method, path, body, opts) do
    request_opts =
      [
        method: method,
        headers: headers(),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        # Sent once, and over https only to a verified certificate and host
        # name, like every other request that carries a credential.
        single_attempt: true
      ]
      |> then(fn o -> if body, do: Keyword.put(o, :body, body), else: o end)

    case HTTP.request(config.base_url <> path, request_opts) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, {:unreachable, class(reason)}}
    end
  catch
    :throw, {:api_key_unavailable, _reason} = unavailable -> {:error, unavailable}
    _kind, _reason -> {:error, :unreachable}
  end

  # The key is read through `OptimalEngine.Secrets`, so it may be an
  # `openbao:<path>#<field>` reference; trimmed, so a key read from a file with
  # its newline is sent as the key, and a blank one is not sent at all. A
  # reference OpenBao cannot answer stops the request before it is sent: it
  # never goes out without the key the operator configured.
  defp headers do
    case Secrets.fetch(@key_env) do
      {:ok, key} ->
        [{"api-key", key}, {"content-type", "application/json"}]

      {:error, :not_set} ->
        [{"content-type", "application/json"}]

      {:error, {:secret_unavailable, _name, reason}} ->
        throw({:api_key_unavailable, reason})
    end
  end

  # A failure reason may quote the request; keep the class only.
  defp class(reason) when is_atom(reason), do: reason
  defp class({class, _detail}) when is_atom(class), do: class
  defp class(_other), do: :request_failed

  defp summary(%{"status" => status}) when is_map(status), do: Map.get(status, "error", "error")
  defp summary(%{"status" => status}), do: status
  defp summary(body) when is_binary(body), do: String.slice(body, 0, 80)
  defp summary(_body), do: :unexpected_body

  defp present?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end
end
