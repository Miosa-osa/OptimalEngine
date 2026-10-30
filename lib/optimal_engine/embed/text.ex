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

  Either way an empty input is refused without a call, invalid UTF-8 is
  replaced, the input is capped at 6,000 characters, and an identical input is
  served from the filesystem cache. Ollama's entries are keyed by the model and
  the input; an endpoint's are keyed by the endpoint (without user info or
  query), the model and the input, so vectors from one never answer for the
  other. An entry is stored under its tenant and workspace, by the digest of
  that key, so the cache never holds the text and deleting or erasing a
  workspace removes everything it cached (`OptimalEngine.Store.FileCache`).
  An embedding is cached only when the caller names its workspace
  (`:workspace_id`, with `:tenant_id`); without one it is computed every time.
  An endpoint's vectors must have the model's width (768 for
  nomic-embed-text, or `OPTIMAL_EMBED_DIMENSIONS`), checked on every answer and
  on every cache hit, and stored vectors of another dimension are never scored
  (`OptimalEngine.Store.Vectors.search/2`).

  Configuration (`config :optimal_engine, :text_embedding`), set from the
  environment in `config/runtime.exs`:

    * `:url` - the endpoint, or `nil` for Ollama at `OLLAMA_HOST`;
    * `:dialect` - `:openai` or `:ollama`; inferred from the URL when `nil`;
    * `:api_key_file` - a file holding the key, read on every request;
    * `:dimensions` - the vector width the endpoint must return (default 768
      for nomic-embed-text, unchecked for other models);
    * `:timeout_ms` - per request (default 5,000);
    * `:probe_timeout_ms` - budget of the health probe on the search path
      (default 2,000 for an endpoint);
    * `:health_ttl_ms` - how long a process keeps an endpoint's health answer
      (default 60,000);
    * `:cache_max_age_days` - how long a cached embedding is kept (default 30;
      `0` keeps it until its workspace is purged); see
      `OptimalEngine.Store.FileCache.Maintenance`.

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
  @timeout_ms 5_000
  @probe_timeout_ms 2_000
  @health_ttl_ms 60_000
  @outcome_key :embed_outcome
  @outcome_rewrite_ms 5_000
  @status_ttl_ms 60_000
  @status_probe_ms 1_500
  @batch_inputs 64
  @batch_bytes 512_000
  # A batch answered 429 is retried once when the endpoint asks for at most this wait.
  @retry_after_max_ms 60_000

  @type dialect :: :openai | :ollama
  @type endpoint :: %{
          url: String.t(),
          dialect: dialect(),
          api_key_file: String.t() | nil,
          dimensions: pos_integer() | nil,
          timeout_ms: pos_integer()
        }

  @doc """
  Embed `text` with the configured model and endpoint.

  Returns `{:ok, vector}` or `{:error, reason}`; `{:error, :empty_input}` for
  blank text. See `OptimalEngine.Embed.Endpoint` for the endpoint's errors.

  ## Options

    * `:model` - override the embed model
    * `:workspace_id` and `:tenant_id` - the workspace the text belongs to (a
      search query: the workspace being searched) and its tenant (default
      tenant when omitted). The embedding is cached under them. Without a
      `:workspace_id` nothing is read from or written to the cache.
    * `:cache` - `false` bypasses the filesystem cache even with a workspace
      (default `true`)
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

      case cache_scope(opts) do
        nil ->
          request(target, model, capped)

        scope ->
          case cached(scope, target, model, capped) do
            {:ok, vector} ->
              {:ok, vector}

            {:pending, input} ->
              result = request(target, model, input)
              cache(scope, target, model, input, result)
              result
          end
      end
    end
  end

  # The tenant and workspace an embedding is cached under, or nil when it is not
  # cached: the caller turned the cache off, or named no workspace to keep it in.
  defp cache_scope(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)

    if Keyword.get(opts, :cache, true) && is_binary(workspace_id) && workspace_id != "" do
      {tenant(Keyword.get(opts, :tenant_id)), workspace_id}
    end
  end

  defp tenant(tenant_id) when is_binary(tenant_id) and tenant_id != "", do: tenant_id
  defp tenant(_none), do: OptimalEngine.Tenancy.Tenant.default_id()

  defp request(nil, model, input) do
    result = Ollama.request_embedding(model, input)
    note_outcome(result)
    result
  end

  defp request(endpoint, model, input) do
    result = Endpoint.request(endpoint, model, input)
    note_health(endpoint, result)
    note_outcome(result)
    result
  end

  # The answer of a real request, never a cache hit, is the endpoint's health
  # for the rest of this process's probe window: after a failure the search path
  # skips the vector hop instead of waiting again, and a success clears that.
  defp note_health(endpoint, {:ok, _vectors}),
    do: Process.put(health_key(endpoint), {true, System.monotonic_time(:millisecond)})

  defp note_health(endpoint, {:error, reason}) do
    if unavailable?(reason),
      do: Process.put(health_key(endpoint), {false, System.monotonic_time(:millisecond)})

    :ok
  end

  @doc """
  Embed many texts; the results come back in input order, one
  `{:ok, vector}` or `{:error, reason}` per text.

  With an endpoint configured, the inputs the cache does not hold go out in
  batches of at most #{@batch_inputs} inputs and #{@batch_bytes} bytes, so a
  bulk job makes a few requests instead of one per text (a shared gateway
  meters and rate-limits requests). A batch answered 429 with a `Retry-After`
  of at most a minute is retried once after that wait. A batch the endpoint
  refuses gives every text in it that error; once a batch is `unavailable?/1`,
  the remaining batches get that error without a request. Without an endpoint
  each text is embedded by Ollama one at a time, as `embed/2` does, stopping
  the same way (see `embed_each/2`). Takes the options of `embed/2`.
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
    scope = cache_scope(opts)

    looked_up =
      Enum.map(texts, fn text ->
        cond do
          String.trim(text) == "" -> {:error, :empty_input}
          scope -> cached(scope, endpoint, model, cap(text))
          true -> {:pending, cap(text)}
        end
      end)

    {fetched, _down} =
      looked_up
      |> Enum.flat_map(fn
        {:pending, input} -> [input]
        _done -> []
      end)
      |> Enum.uniq()
      |> batches()
      |> Enum.reduce({%{}, nil}, fn
        batch, {acc, {:error, _} = down} ->
          {Map.merge(acc, Map.new(batch, &{&1, down})), down}

        batch, {acc, nil} ->
          result =
            Endpoint.request_many(endpoint, model, batch, retry_after_max_ms: @retry_after_max_ms)

          note_health(endpoint, result)
          note_outcome(result)

          case result do
            {:ok, vectors} ->
              {Map.merge(acc, Map.new(Enum.zip(batch, Enum.map(vectors, &{:ok, &1})))), nil}

            {:error, reason} = error ->
              {Map.merge(acc, Map.new(batch, &{&1, error})), if(unavailable?(reason), do: error)}
          end
      end)

    Enum.map(looked_up, fn
      {:pending, input} ->
        result = Map.fetch!(fetched, input)
        if scope, do: cache(scope, endpoint, model, input, result)
        result

      done ->
        done
    end)
  end

  @doc """
  Remove the cache entry `embed/2` keeps for `text`. Takes the options that
  placed it there (`:workspace_id`, `:tenant_id`, `:model`); without a workspace
  nothing was cached and there is nothing to remove. The entry of the
  configured endpoint and the entry of Ollama are both removed, since a text
  may have been embedded by either.

  This is for a record deleted or forgotten while its text is still at hand. An
  entry whose text is no longer known (the record is gone, or it was embedded
  with a prefix or document profile that cannot be rebuilt from the record) is
  removed by the workspace purge or the age sweep.
  """
  @spec forget(String.t(), keyword()) :: :ok | {:error, term()}
  def forget(text, opts) when is_binary(text) and is_list(opts) do
    case cache_scope(Keyword.delete(opts, :cache)) do
      nil ->
        :ok

      scope ->
        model = Keyword.get(opts, :model, model())
        input = cap(text)

        Enum.reduce_while(Enum.uniq([nil, endpoint()]), :ok, fn target, :ok ->
          case FileCache.delete(scope, "embeddings", cache_key(target, model, input)) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  # A cached vector of another width than an endpoint's model now needs (the
  # width setting changed since it was stored) is a miss, so it is fetched again.
  defp cached(scope, target, model, input) do
    case FileCache.get(scope, "embeddings", cache_key(target, model, input)) do
      {:ok, vector} -> if fits?(target, model, vector), do: {:ok, vector}, else: {:pending, input}
      _miss -> {:pending, input}
    end
  end

  defp fits?(nil, _model, _vector), do: true

  defp fits?(endpoint, model, vector) do
    case Endpoint.dimensions(endpoint, model) do
      nil -> true
      want -> is_list(vector) and length(vector) == want
    end
  end

  defp cache(scope, target, model, input, {:ok, vector}),
    do: FileCache.put(scope, "embeddings", cache_key(target, model, input), vector)

  defp cache(_scope, _endpoint, _model, _input, _error), do: :ok

  # Ollama at OLLAMA_HOST keeps today's key; an endpoint's entries carry the
  # endpoint, so neither answers for the other. Only the key's digest is stored.
  defp cache_key(nil, model, input), do: "#{model}\0#{input}"

  defp cache_key(endpoint, model, input),
    do: "#{Endpoint.safe_url(endpoint.url)}\0#{model}\0#{input}"

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

  # Invalid UTF-8 cannot be encoded as JSON, and an encoder error would carry
  # the text; it is replaced before anything else.
  defp cap(text) do
    text = String.replace_invalid(text)
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
          dimensions: cfg[:dimensions],
          timeout_ms: cfg[:timeout_ms] || @timeout_ms
        }

      _ ->
        nil
    end
  end

  @doc "True when `OPTIMAL_EMBED_URL` names an endpoint other than Ollama at `OLLAMA_HOST`."
  @spec endpoint_configured?() :: boolean()
  def endpoint_configured?, do: endpoint() != nil

  @doc "Who serves text embeddings, for governance provenance: `ollama` or `embedding_endpoint`."
  @spec provider() :: String.t()
  def provider, do: if(endpoint_configured?(), do: "embedding_endpoint", else: "ollama")

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

  The search path asks before spending time on a vector hop. The answer, and
  the outcome of this process's latest request to the endpoint, is kept in the
  calling process for `:health_ttl_ms` (60 seconds), and the probe is bounded
  so a hung endpoint cannot stall the caller. Without an endpoint this is
  `Ollama.embed_healthy?/0`.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    case endpoint() do
      nil -> Ollama.embed_healthy?()
      endpoint -> cached_probe(endpoint)
    end
  end

  defp health_key(endpoint), do: {:oe_text_embed_health, endpoint.url}

  defp cached_probe(endpoint) do
    now = System.monotonic_time(:millisecond)
    key = health_key(endpoint)

    cfg = Application.get_env(:optimal_engine, :text_embedding, [])
    ttl = cfg[:health_ttl_ms] || @health_ttl_ms

    case Process.get(key) do
      {result, cached_at} when now - cached_at < ttl ->
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
  The embedder's state as the Engine last saw it: `:ok`, or `{:error, reason}`
  when it is down, refuses the key, is out of credit or answers the wrong width.

  This is what the health report shows for the embedder, so a broken embedder
  is degraded health without probing it on every health call. The state is the
  outcome of the latest real embedding request in any process (a request the
  cache answered does not count), kept for `:status_ttl_ms` (default 60
  seconds). Past that, or before any request, one probe bounded to
  `:status_probe_ms` (default 1,500) asks again and records its answer. An
  error that is the input's fault (empty or too long) says nothing about the
  embedder and is not recorded.
  """
  @spec status() :: :ok | {:error, term()}
  def status do
    case recent_outcome() do
      {:ok, outcome} -> outcome
      :none -> probe_status()
    end
  end

  @doc false
  # The latest recorded outcome, unless it is older than the status TTL.
  @spec recent_outcome() :: {:ok, :ok | {:error, term()}} | :none
  def recent_outcome do
    now = System.monotonic_time(:millisecond)

    case Application.get_env(:optimal_engine, @outcome_key) do
      {outcome, at} when now - at < status_cfg(:status_ttl_ms, @status_ttl_ms) ->
        {:ok, outcome}

      _ ->
        :none
    end
  end

  @doc false
  # Forget the recorded outcome (tests; a changed embedder configuration).
  @spec reset_outcome() :: :ok
  def reset_outcome, do: Application.delete_env(:optimal_engine, @outcome_key)

  # The recorded outcome is a node-wide fact, so it lives in the application
  # environment (an ETS read, no process to call) rather than the process
  # dictionary the search path's own memo uses. An unchanged outcome is
  # rewritten at most every few seconds.
  defp note_outcome({:ok, _vectors}), do: store_outcome(:ok)

  defp note_outcome({:error, reason}) do
    if unavailable?(reason), do: store_outcome({:error, reason}), else: :ok
  end

  defp store_outcome(outcome) do
    now = System.monotonic_time(:millisecond)

    case Application.get_env(:optimal_engine, @outcome_key) do
      {^outcome, at} when now - at < @outcome_rewrite_ms -> :ok
      _ -> Application.put_env(:optimal_engine, @outcome_key, {outcome, now})
    end
  end

  defp probe_status do
    budget = status_cfg(:status_probe_ms, @status_probe_ms)
    task = Task.async(fn -> embed("health", cache: false) end)

    outcome =
      case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, _vector}} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        _ -> {:error, :timeout}
      end

    # A probe that timed out or failed in a way that is no sign of a down
    # embedder has no recorded answer, and would otherwise be probed again.
    store_outcome(outcome)
    outcome
  end

  defp status_cfg(key, default) do
    Application.get_env(:optimal_engine, :text_embedding, [])[key] || default
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
  def unavailable?({:embed_dimension_mismatch, _got, _want}), do: true
  def unavailable?(_reason), do: false

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
