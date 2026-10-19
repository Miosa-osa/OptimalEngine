defmodule OptimalEngine.Conformance.Client do
  @moduledoc """
  The HTTP client the conformance runner uses.

  Every keyed request carries the caller's key as `Authorization: Bearer <key>`.
  The key is never echoed: evidence records the request path and the response,
  never the request headers. A client built without a key is anonymous, which
  is how the suite proves that authentication is enforced.

  `transport` is injectable so the runner can be pointed at this node's own
  router instead of a socket (see `OptimalEngine.Conformance.Transport`).
  """

  @enforce_keys [:url]
  defstruct [
    :url,
    :key,
    transport: OptimalEngine.Conformance.Transport.HTTP,
    timeout: 30_000
  ]

  @type transport :: module() | (OptimalEngine.Conformance.Transport.request() -> term())

  @type t :: %__MODULE__{
          url: String.t(),
          key: String.t() | nil,
          transport: transport(),
          timeout: pos_integer()
        }

  @doc """
  Builds a client. `:url` is required; `:key` may be absent for anonymous
  requests, and `:transport` and `:timeout` have defaults. The transport is a
  module implementing `OptimalEngine.Conformance.Transport` or a one-argument
  function.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      url: opts |> Keyword.fetch!(:url) |> String.trim_trailing("/"),
      key: Keyword.get(opts, :key),
      transport: Keyword.get(opts, :transport, OptimalEngine.Conformance.Transport.HTTP),
      timeout: Keyword.get(opts, :timeout, 30_000)
    }
  end

  @doc "Sends a GET. `:query` is a keyword list or map; nil values are dropped."
  @spec get(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(client, path, opts \\ []), do: request(client, :get, path, opts)

  @doc "Sends a POST with a JSON body."
  @spec post(t(), String.t(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def post(client, path, body \\ nil, opts \\ []),
    do: request(client, :post, path, Keyword.put(opts, :body, body))

  @doc "Sends a DELETE."
  @spec delete(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(client, path, opts \\ []), do: request(client, :delete, path, opts)

  @doc """
  Sends one request and decodes a JSON response body when the server labels it
  as JSON. Returns `{:ok, %{status: status, headers: headers, body: decoded}}`
  or `{:error, reason}` when no response arrived.
  """
  @spec request(t(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(client, method, path, opts) do
    url = client.url <> path <> query_string(opts)
    body = encode_body(Keyword.get(opts, :body))

    request = %{
      method: method,
      url: url,
      headers: headers(client.key, body != nil),
      body: body,
      timeout: Keyword.get(opts, :timeout, client.timeout)
    }

    case dispatch(client.transport, request) do
      {:ok, %{status: status} = response} ->
        {:ok, %{status: status, headers: response[:headers] || [], body: decode(response[:body])}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A transport is a module implementing the behaviour, or a one-argument
  # function, which keeps a test double to a single closure.
  defp dispatch(transport, request) when is_function(transport, 1), do: transport.(request)
  defp dispatch(transport, request), do: transport.request(request)

  defp headers(nil, _body), do: []

  defp headers(key, true),
    do: [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}]

  defp headers(key, false), do: [{"authorization", "Bearer " <> key}]

  defp encode_body(nil), do: nil
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)
  defp encode_body(body) when is_binary(body), do: body

  defp query_string(opts) do
    opts
    |> Keyword.get(:query, [])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> case do
      [] -> ""
      pairs -> "?" <> URI.encode_query(pairs)
    end
  end

  defp decode(body) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body
end
