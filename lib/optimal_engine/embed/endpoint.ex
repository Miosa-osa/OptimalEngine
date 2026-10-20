defmodule OptimalEngine.Embed.Endpoint do
  @moduledoc """
  One text-embedding request to the endpoint named by `OPTIMAL_EMBED_URL`.

  Callers go through `OptimalEngine.Embed.Text`, which caps the input and
  caches the result. Two dialects:

    * `:openai` - `POST {"model", "input"}`, answered with
      `{"data": [{"embedding": [...]}]}`: MIOSA's shared gateway
      (`/v1/embeddings`), vLLM, or Ollama's OpenAI-compatible route;
    * `:ollama` - Ollama's native `/api/embed`, answered with
      `{"embeddings": [[...]]}`.

  The key comes from `OPTIMAL_EMBED_API_KEY`, else the file named by
  `OPTIMAL_EMBED_API_KEY_FILE`, read on every request so a rotated key takes
  effect without a restart. It is sent as `Authorization: Bearer <key>` and is
  never logged, stored or returned: log lines name the endpoint without
  credentials or query, the status and the endpoint's error code.

  Errors:

    * `{:embed_unauthorized, 401 | 403}` - the endpoint refused the key; logged
      as an error, because every embedding fails until the key is fixed;
    * `{:embed_api_key, reason}` - the key file cannot be read, or the key is
      not a single line;
    * `{:embed_unavailable, status}` - an answer every following request would
      get too: 402 out of credit, 404 no such model, 429 rate limited, 5xx the
      backend down or misconfigured (MIOSA's gateway answers 502
      `embedding_backend_unavailable` when its upstream is down);
    * `{:http_error, status}` - any other answer than 200, about this request;
    * `{:embed_dimension_mismatch, got, want}` - vectors of another width than
      the model's (768 for nomic-embed-text, or `OPTIMAL_EMBED_DIMENSIONS`);
      they would never be scored against the index, so none is returned;
    * `:embed_endpoint_unavailable` - no answer within the timeout;
    * `:unexpected_response` or `:invalid_json` - a 200 without a vector;
    * `:invalid_input` - the input cannot be encoded as JSON.

  A key sent over plain http to a host other than this machine is warned about
  once per endpoint, without the key.
  """

  require Logger

  @key_env "OPTIMAL_EMBED_API_KEY"
  # Widths of the models whose index this Engine already holds.
  @model_dimensions %{"nomic-embed-text" => 768}

  @doc "Embed `input` with `model` at `endpoint` (see `OptimalEngine.Embed.Text.endpoint/0`)."
  @spec request(OptimalEngine.Embed.Text.endpoint(), String.t(), String.t()) ::
          {:ok, [number()]} | {:error, term()}
  def request(endpoint, model, input) when is_binary(input) do
    with {:ok, [vector]} <- post(endpoint, model, input, 1), do: {:ok, vector}
  end

  @doc """
  Embed every input in one request; the vectors come back in input order.

  The caller keeps a batch within the endpoint's limits (MIOSA's gateway takes
  256 inputs and a 1 MB body).
  """
  @spec request_many(OptimalEngine.Embed.Text.endpoint(), String.t(), [String.t()]) ::
          {:ok, [[number()]]} | {:error, term()}
  def request_many(_endpoint, _model, []), do: {:ok, []}

  def request_many(endpoint, model, inputs) when is_list(inputs),
    do: post(endpoint, model, inputs, length(inputs))

  @doc "The vector width `model` must have at `endpoint`, or `nil` when unchecked."
  @spec dimensions(OptimalEngine.Embed.Text.endpoint(), String.t()) :: pos_integer() | nil
  def dimensions(endpoint, model), do: Map.get(endpoint, :dimensions) || @model_dimensions[model]

  defp post(endpoint, model, input, count) do
    with {:ok, key} <- api_key(endpoint),
         {:ok, body} <- encode(model, input) do
      ensure_http_started()
      warn_plain_http(endpoint.url, key != nil)
      timeout = endpoint.timeout_ms

      http_request =
        {String.to_charlist(endpoint.url), headers(key), ~c"application/json", body}

      http_opts = [
        timeout: timeout,
        connect_timeout: min(timeout, 5_000),
        ssl: ssl_opts(endpoint.url)
      ]

      case :httpc.request(:post, http_request, http_opts, body_format: :binary) do
        {:ok, {{_version, 200, _reason}, _headers, response}} ->
          parse(endpoint, response, count, dimensions(endpoint, model))

        {:ok, {{_version, status, _reason}, _headers, response}} when status in [401, 403] ->
          log_refused(endpoint.url, status, response, key != nil)
          {:error, {:embed_unauthorized, status}}

        {:ok, {{_version, status, _reason}, _headers, response}} ->
          Logger.warning(
            "[Embed] #{safe_url(endpoint.url)} answered HTTP #{status}#{code(response)}"
          )

          {:error, status_error(status)}

        {:error, reason} ->
          Logger.warning(
            "[Embed] #{safe_url(endpoint.url)} is unreachable: #{inspect(transport_reason(reason))}"
          )

          {:error, :embed_endpoint_unavailable}
      end
    end
  end

  # An answer that every following request would get too (out of credit, rate
  # limited, no such model, the backend down or misconfigured) makes embedding
  # unavailable for now; anything else is about this request.
  defp status_error(status) when status in [402, 404, 429] or status >= 500,
    do: {:embed_unavailable, status}

  defp status_error(status), do: {:http_error, status}

  # Every embedding fails until the key is fixed, so this is an error, and it
  # says which settings to look at.
  defp log_refused(url, status, response, key_configured?) do
    hint = if key_configured?, do: "", else: " No key is configured."

    Logger.error(
      "[Embed] #{safe_url(url)} refused the API key (HTTP #{status}#{code(response)}). " <>
        "Text embeddings fail until #{@key_env} or #{@key_env}_FILE holds a key it accepts." <>
        hint
    )
  end

  # ---------------------------------------------------------------------------
  # Key
  # ---------------------------------------------------------------------------

  defp api_key(endpoint) do
    case String.trim(System.get_env(@key_env) || "") do
      "" -> key_from_file(endpoint.api_key_file)
      key -> checked(key)
    end
  end

  defp key_from_file(nil), do: {:ok, nil}

  defp key_from_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> {:ok, nil}
          key -> checked(key)
        end

      {:error, reason} ->
        Logger.error("[Embed] cannot read #{@key_env}_FILE #{path}: #{inspect(reason)}")
        {:error, {:embed_api_key, reason}}
    end
  end

  # A key is one printable line; anything else would end up as a broken or
  # injected header.
  defp checked(key) do
    if String.printable?(key) and not String.contains?(key, ["\r", "\n"]) do
      {:ok, key}
    else
      Logger.error("[Embed] the embedding API key is not a single printable line")
      {:error, {:embed_api_key, :invalid}}
    end
  end

  # The encoder's error would quote the input, so only its kind is returned.
  defp encode(model, input) do
    case Jason.encode(%{"model" => model, "input" => input}) do
      {:ok, body} -> {:ok, body}
      {:error, _reason} -> {:error, :invalid_input}
    end
  end

  @doc false
  # True for a plain http URL whose host is not this machine.
  @spec plain_http_remote?(String.t()) :: boolean()
  def plain_http_remote?(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host} when is_binary(host) ->
        not (host in ["localhost", "::1", "[::1]"] or String.starts_with?(host, "127."))

      _ ->
        false
    end
  end

  @doc false
  # Warns once per endpoint when a key is about to cross the network unencrypted.
  @spec warn_plain_http(String.t(), boolean()) :: :ok
  def warn_plain_http(_url, false), do: :ok

  def warn_plain_http(url, true) do
    flag = {__MODULE__, :plain_http_warned, url}

    if plain_http_remote?(url) and :persistent_term.get(flag, false) == false do
      :persistent_term.put(flag, true)

      Logger.warning(
        "[Embed] the embedding API key goes to #{safe_url(url)} over plain http; use https"
      )
    end

    :ok
  end

  defp headers(nil), do: [{~c"accept", ~c"application/json"}]

  defp headers(key) do
    [{~c"accept", ~c"application/json"}, {~c"authorization", ~c"Bearer " ++ to_charlist(key)}]
  end

  # ---------------------------------------------------------------------------
  # Response
  # ---------------------------------------------------------------------------

  defp parse(endpoint, response, count, want) do
    case Jason.decode(response) do
      {:ok, decoded} ->
        case vectors(endpoint.dialect, decoded) do
          {:ok, vectors} when length(vectors) == count ->
            check_width(endpoint, vectors, want)

          _ ->
            Logger.warning(
              "[Embed] #{safe_url(endpoint.url)} answered 200 without #{count} embedding vector(s)"
            )

            {:error, :unexpected_response}
        end

      {:error, _reason} ->
        Logger.warning("[Embed] #{safe_url(endpoint.url)} answered 200 with invalid JSON")
        {:error, :invalid_json}
    end
  end

  defp check_width(_endpoint, vectors, nil), do: {:ok, vectors}

  defp check_width(endpoint, vectors, want) do
    case Enum.find(vectors, &(length(&1) != want)) do
      nil ->
        {:ok, vectors}

      wrong ->
        got = length(wrong)

        Logger.error(
          "[Embed] #{safe_url(endpoint.url)} answered #{got}-dimension vectors; " <>
            "the model needs #{want}"
        )

        {:error, {:embed_dimension_mismatch, got, want}}
    end
  end

  # OpenAI-style items carry their input's index; Ollama answers in input order.
  defp vectors(:openai, %{"data" => [_ | _] = data}) do
    data
    |> Enum.sort_by(fn item -> (is_map(item) && item["index"]) || 0 end)
    |> Enum.map(fn item -> is_map(item) && item["embedding"] end)
    |> numbers()
  end

  defp vectors(:ollama, %{"embeddings" => [_ | _] = embeddings}), do: numbers(embeddings)
  defp vectors(_dialect, _decoded), do: :error

  defp numbers(vectors) do
    if Enum.all?(vectors, &vector?/1), do: {:ok, vectors}, else: :error
  end

  defp vector?([_ | _] = vector), do: Enum.all?(vector, &is_number/1)
  defp vector?(_other), do: false

  # The endpoint's error code or type (OpenAI-style `error.code`/`error.type`,
  # or Ollama's `error` string), never the body: a body may echo input text.
  defp code(response) do
    case Jason.decode(response) do
      {:ok, %{"error" => %{} = error}} ->
        case error["code"] || error["type"] do
          code when is_binary(code) and code != "" -> ": " <> String.slice(code, 0, 80)
          _ -> ""
        end

      _ ->
        ""
    end
  end

  # ---------------------------------------------------------------------------
  # Transport
  # ---------------------------------------------------------------------------

  defp ensure_http_started do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp ssl_opts(url) do
    case URI.parse(url) do
      %URI{scheme: "https"} ->
        [
          verify: :verify_peer,
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ cacerts()

      _ ->
        []
    end
  end

  defp cacerts do
    [cacerts: :public_key.cacerts_get()]
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp transport_reason({:failed_connect, [{:to_address, _address}, {_family, _addr, reason}]}),
    do: reason

  defp transport_reason({:failed_connect, _details}), do: :failed_connect
  defp transport_reason(reason) when is_atom(reason), do: reason
  defp transport_reason(_reason), do: :error

  @doc false
  # The URL as it may appear in a log line: no user info, no query.
  @spec safe_url(String.t()) :: String.t()
  def safe_url(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
  end
end
