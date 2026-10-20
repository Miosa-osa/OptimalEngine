defmodule OptimalEngine.Embed.Text do
  @moduledoc """
  The Engine's text embedder.

  Every text embedding goes through `embed/2`: the semantic pipeline at
  intake, chunk embeddings, search queries, durable memory projections,
  app data and the backfill.

  Where the vectors come from:

    * `OPTIMAL_EMBED_URL` unset: Ollama at `OLLAMA_HOST`, unchanged
      (`OptimalEngine.Embed.Ollama`).
    * `OPTIMAL_EMBED_URL` set: that endpoint (`OptimalEngine.Embed.Endpoint`),
      in the OpenAI-compatible dialect or Ollama's native one, with the key
      from `OPTIMAL_EMBED_API_KEY` or `OPTIMAL_EMBED_API_KEY_FILE` as a bearer
      token. A shared, metered gateway keeps a small Engine from running a
      model of its own.

  Either way an empty input is refused without a call, the input is capped at
  6,000 characters, and an identical model and input is served from the
  filesystem cache. The cache key is the model and the input, not the
  endpoint: a shared endpoint serves the same model, so its vectors stay
  comparable with the ones indexed locally. Stored vectors of another
  dimension are never scored (`OptimalEngine.Store.Vectors.search/2`).

  Configuration (`config :optimal_engine, :text_embedding`), set from the
  environment in `config/runtime.exs`:

    * `:url` - the endpoint, or `nil` for Ollama at `OLLAMA_HOST`;
    * `:dialect` - `:openai` or `:ollama`; inferred from the URL when `nil`;
    * `:api_key_file` - a file holding the key, read on every request;
    * `:timeout_ms` - per request (default 10,000);
    * `:probe_timeout_ms` - budget of the health probe on the search path
      (default 2,000 for an endpoint).

  The model is the Engine's embed model (`OPTIMAL_EMBED_MODEL`, default
  `nomic-embed-text`) whichever endpoint serves it.
  """

  alias OptimalEngine.Embed.{Endpoint, Ollama}
  alias OptimalEngine.Store.FileCache

  # Embedding models have a bounded context window; nomic-embed-text rejects
  # oversized input with HTTP 400 ("input length exceeds the context length").
  # Cap input so large chunks embed (truncated) instead of being skipped.
  # nomic-embed-text's effective window is ~2048 tokens; ~4 chars/token, kept
  # conservative so even token-dense text stays under the limit.
  @max_chars 6_000
  @default_model "nomic-embed-text"
  @timeout_ms 10_000
  @probe_timeout_ms 2_000
  @health_ttl_ms 60_000
  @batch_inputs 64
  @batch_bytes 512_000

  @type dialect :: :openai | :ollama
  @type endpoint :: %{
          url: String.t(),
          dialect: dialect(),
          api_key_file: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @doc """
  Embed `text` with the configured model and endpoint.

  Returns `{:ok, vector}` or `{:error, reason}`; `{:error, :empty_input}` for
  blank text. See `OptimalEngine.Embed.Endpoint` for the endpoint's errors.

  ## Options

    * `:model` - override the embed model
    * `:cache` - `false` bypasses the filesystem cache (default `true`)
  """
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text), do: embed_with(endpoint(), text, opts)

  @doc false
  # Ollama at OLLAMA_HOST, whatever OPTIMAL_EMBED_URL says. Used by
  # `Ollama.embed_text/2`, which keeps its meaning for direct callers.
  @spec embed_via_ollama(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed_via_ollama(text, opts), do: embed_with(nil, text, opts)

  defp embed_with(target, text, opts) do
    if String.trim(text) == "" do
      {:error, :empty_input}
    else
      model = Keyword.get(opts, :model, model())
      capped = cap(text)

      if Keyword.get(opts, :cache, true) do
        FileCache.fetch("embeddings", cache_key(model, capped), fn ->
          request(target, model, capped)
        end)
      else
        request(target, model, capped)
      end
    end
  end

  defp request(nil, model, input), do: Ollama.request_embedding(model, input)
  defp request(endpoint, model, input), do: Endpoint.request(endpoint, model, input)

  @doc """
  Embed many texts; the results come back in input order, one
  `{:ok, vector}` or `{:error, reason}` per text.

  With an endpoint configured, the inputs the cache does not hold go out in
  batches of at most #{@batch_inputs} inputs and #{@batch_bytes} bytes, so a
  bulk job makes a few requests instead of one per text (a shared gateway
  meters and rate-limits requests). A batch the endpoint refuses gives every
  text in it that error. Without an endpoint each text is embedded by Ollama
  one at a time, as `embed/2` does (see `embed_each/2`). Takes the options of
  `embed/2`.
  """
  @spec embed_many([String.t()], keyword()) :: [{:ok, [float()]} | {:error, term()}]
  def embed_many(texts, opts \\ []) when is_list(texts) do
    case endpoint() do
      nil -> embed_each(texts, &embed(&1, opts))
      endpoint -> embed_batched(endpoint, texts, opts)
    end
  end

  @doc """
  Embed texts one at a time with `embed`, a function returning
  `{:ok, vector}` or `{:error, reason}`, in input order. Once a result is
  `unavailable?/1`, the remaining texts get that error without a call.
  """
  @spec embed_each([String.t()], (String.t() -> {:ok, [float()]} | {:error, term()})) ::
          [{:ok, [float()]} | {:error, term()}]
  def embed_each(texts, embed) when is_list(texts) and is_function(embed, 1) do
    texts
    |> Enum.map_reduce(nil, fn
      _text, {:error, _reason} = down ->
        {down, down}

      text, nil ->
        result = embed.(text)
        {result, if(unavailable_result?(result), do: result)}
    end)
    |> elem(0)
  end

  defp unavailable_result?({:error, reason}), do: unavailable?(reason)
  defp unavailable_result?(_result), do: false

  defp embed_batched(endpoint, texts, opts) do
    model = Keyword.get(opts, :model, model())
    cache? = Keyword.get(opts, :cache, true)

    looked_up =
      Enum.map(texts, fn text ->
        cond do
          String.trim(text) == "" -> {:error, :empty_input}
          cache? -> cached(model, cap(text))
          true -> {:pending, cap(text)}
        end
      end)

    fetched =
      looked_up
      |> Enum.flat_map(fn
        {:pending, input} -> [input]
        _done -> []
      end)
      |> Enum.uniq()
      |> batches()
      |> Enum.reduce(%{}, fn batch, acc ->
        results =
          case Endpoint.request_many(endpoint, model, batch) do
            {:ok, vectors} -> Enum.zip(batch, Enum.map(vectors, &{:ok, &1}))
            {:error, _} = error -> Enum.map(batch, &{&1, error})
          end

        Map.merge(acc, Map.new(results))
      end)

    Enum.map(looked_up, fn
      {:pending, input} ->
        result = Map.fetch!(fetched, input)
        if cache?, do: cache(model, input, result)
        result

      done ->
        done
    end)
  end

  defp cached(model, input) do
    case FileCache.get("embeddings", cache_key(model, input)) do
      {:ok, vector} -> {:ok, vector}
      _miss -> {:pending, input}
    end
  end

  defp cache(model, input, {:ok, vector}),
    do: FileCache.put("embeddings", cache_key(model, input), vector)

  defp cache(_model, _input, _error), do: :ok

  defp cache_key(model, input), do: "#{model}\0#{input}"

  # Batches in input order, each within the input and byte limits.
  defp batches(inputs) do
    inputs
    |> Enum.chunk_while(
      {[], 0},
      fn input, {batch, bytes} ->
        size = byte_size(input)

        if batch != [] and (length(batch) >= @batch_inputs or bytes + size > @batch_bytes) do
          {:cont, Enum.reverse(batch), {[input], size}}
        else
          {:cont, {[input | batch], bytes + size}}
        end
      end,
      fn
        {[], _bytes} -> {:cont, {[], 0}}
        {batch, _bytes} -> {:cont, Enum.reverse(batch), {[], 0}}
      end
    )
  end

  @doc "The embed model: `OPTIMAL_EMBED_MODEL`, default `nomic-embed-text`."
  @spec model() :: String.t()
  def model do
    Application.get_env(:optimal_engine, :ollama, [])[:embed_model] || @default_model
  end

  @doc "The longest input sent to the model, in characters; longer text is truncated."
  @spec max_chars() :: pos_integer()
  def max_chars, do: @max_chars

  defp cap(text) do
    if String.length(text) > @max_chars, do: String.slice(text, 0, @max_chars), else: text
  end

  @doc """
  The configured embedding endpoint, or `nil` when text is embedded by Ollama
  at `OLLAMA_HOST`.
  """
  @spec endpoint() :: endpoint() | nil
  def endpoint do
    cfg = Application.get_env(:optimal_engine, :text_embedding, [])

    case cfg[:url] do
      url when is_binary(url) and url != "" ->
        {dialect, endpoint_url} = resolve(url, cfg[:dialect])

        %{
          url: endpoint_url,
          dialect: dialect,
          api_key_file: blank_to_nil(cfg[:api_key_file]),
          timeout_ms: cfg[:timeout_ms] || @timeout_ms
        }

      _ ->
        nil
    end
  end

  @doc "True when `OPTIMAL_EMBED_URL` names an endpoint other than Ollama at `OLLAMA_HOST`."
  @spec endpoint_configured?() :: boolean()
  def endpoint_configured?, do: endpoint() != nil

  @doc """
  The dialect and request URL for a configured `OPTIMAL_EMBED_URL`.

  A URL whose path ends in `/api/embed` speaks Ollama's native API; any other
  speaks the OpenAI-compatible API. An explicit dialect wins. The request path
  is completed when the URL stops short of it: `/v1/embeddings` (or
  `/embeddings` after `/v1`) for OpenAI, `/api/embed` for Ollama.
  """
  @spec resolve(String.t(), dialect() | String.t() | nil) :: {dialect(), String.t()}
  def resolve(url, dialect) when is_binary(url) do
    uri = URI.parse(String.trim(url))
    path = String.trim_trailing(uri.path || "", "/")
    dialect = dialect(dialect, path)
    {dialect, URI.to_string(%{uri | path: request_path(dialect, path)})}
  end

  defp dialect(dialect, _path) when dialect in [:openai, "openai"], do: :openai
  defp dialect(dialect, _path) when dialect in [:ollama, "ollama"], do: :ollama

  defp dialect(_none, path) do
    if String.ends_with?(path, "/api/embed"), do: :ollama, else: :openai
  end

  defp request_path(:ollama, path) do
    if String.ends_with?(path, "/api/embed"), do: path, else: path <> "/api/embed"
  end

  defp request_path(:openai, path) do
    cond do
      String.ends_with?(path, "/embeddings") -> path
      String.ends_with?(path, "/v1") -> path <> "/embeddings"
      true -> path <> "/v1/embeddings"
    end
  end

  @doc """
  True when the embedder answers a probe with a non-empty vector right now.

  The search path asks before spending time on a vector hop. The answer is
  cached in the calling process for 60 seconds, and the probe is bounded so a
  hung endpoint cannot stall the caller. Without an endpoint this is
  `Ollama.embed_healthy?/0`.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case endpoint() do
      nil -> Ollama.embed_healthy?()
      endpoint -> cached_probe(endpoint)
    end
  end

  defp cached_probe(endpoint) do
    now = System.monotonic_time(:millisecond)
    key = {:oe_text_embed_health, endpoint.url}

    case Process.get(key) do
      {result, cached_at} when now - cached_at < @health_ttl_ms ->
        result

      _ ->
        result = probe(endpoint)
        Process.put(key, {result, now})
        result
    end
  end

  defp probe(endpoint) do
    budget =
      Application.get_env(:optimal_engine, :text_embedding, [])[:probe_timeout_ms] ||
        @probe_timeout_ms

    # A health probe must reach the embedder, never the cache.
    task =
      Task.async(fn ->
        match?({:ok, [_ | _]}, Endpoint.request(endpoint, model(), "probe"))
      end)

    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> false
    end
  end

  @doc """
  True when `reason` means every following embedding would fail the same way:
  the embedder is unreachable, refuses the key, or answers that it cannot
  serve (out of credit, rate limited, its backend down). A batch stops on
  these instead of counting each item as failed. For Ollama at `OLLAMA_HOST`
  only `:ollama_unavailable` counts, as before.
  """
  @spec unavailable?(term()) :: boolean()
  def unavailable?(:ollama_unavailable), do: true
  def unavailable?(:embed_endpoint_unavailable), do: true
  def unavailable?({:embed_unavailable, _status}), do: true
  def unavailable?({:embed_unauthorized, _status}), do: true
  def unavailable?({:embed_api_key, _reason}), do: true
  def unavailable?(_reason), do: false

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
