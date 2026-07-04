defmodule OptimalEngine.LLM do
  @moduledoc """
  Cloud LLM provider for text generation (Anthropic / OpenAI).

  The bundled engine uses Ollama for local embeddings + generation. When the
  user connects a cloud Model in BusinessOS, the desktop EngineManager exports
  `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` into the engine's environment. This
  module detects that key at call time and routes text generation to the cloud
  API instead of Ollama.

  It is additive: `OptimalEngine.Embed.Ollama.generate/2` delegates here only
  when `cloud_configured?/0` is true, and falls back to the local Ollama path
  otherwise. This module never calls Ollama, so there is no cycle.

  Stateless — no GenServer. Uses Erlang `:httpc` (via `:inets`) so no extra
  dependencies are required, mirroring `OptimalEngine.Embed.Ollama`.

  ## Provider selection

  Selection reads the environment at call time (a release freezes `config.exs`
  at build, but env vars exported by the EngineManager are visible via
  `System.get_env/1` at runtime):

    1. `OPTIMAL_LLM_PROVIDER` env / `:llm, :provider` app config, if set to
       `"anthropic"` / `"openai"` and the matching key is present.
    2. Otherwise: Anthropic if `ANTHROPIC_API_KEY` is set, else OpenAI if
       `OPENAI_API_KEY` is set.
    3. Otherwise: `nil` (no cloud provider — Ollama stays the default).
  """

  require Logger

  @anthropic_version "2023-06-01"
  @default_anthropic_model "claude-opus-4-8"
  @default_openai_model "gpt-4o"
  @default_max_tokens 4_096
  @default_timeout_ms 60_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Returns `true` when a cloud LLM key is configured, `false` otherwise."
  @spec cloud_configured?() :: boolean()
  def cloud_configured?, do: provider() != nil

  @doc """
  Resolves the active cloud provider: `:anthropic`, `:openai`, or `nil`.

  `nil` means no cloud key is set and callers should use the Ollama path.
  """
  @spec provider() :: :anthropic | :openai | nil
  def provider do
    anthropic = present(anthropic_key())
    openai = present(openai_key())

    case configured_choice() do
      :anthropic when not is_nil(anthropic) -> :anthropic
      :openai when not is_nil(openai) -> :openai
      _ -> if anthropic, do: :anthropic, else: if(openai, do: :openai, else: nil)
    end
  end

  @doc """
  Generates a text completion via the configured cloud provider.

  Returns `{:ok, String.t()}` or `{:error, reason}`. Returns
  `{:error, :no_cloud_provider}` if no cloud key is set — callers should only
  reach this after checking `cloud_configured?/0`.

  ## Options
  - `:model` — override the provider's default model
  - `:system` — system prompt string
  - `:timeout_ms` — HTTP timeout (default 60s; cloud inference is slower than Ollama)
  - `:max_tokens` — cap on generated tokens (default 4096)
  """
  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom() | tuple()}
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    case provider() do
      :anthropic -> anthropic_generate(prompt, opts)
      :openai -> openai_generate(prompt, opts)
      nil -> {:error, :no_cloud_provider}
    end
  end

  # ---------------------------------------------------------------------------
  # Anthropic (Messages API)
  # ---------------------------------------------------------------------------

  defp anthropic_generate(prompt, opts) do
    cfg = config()
    model = Keyword.get(opts, :model, cfg[:anthropic_model])
    max_tokens = Keyword.get(opts, :max_tokens, cfg[:max_tokens])

    body =
      %{
        "model" => model,
        "max_tokens" => max_tokens,
        "messages" => [%{"role" => "user", "content" => prompt}]
      }
      |> maybe_put("system", Keyword.get(opts, :system))

    headers = [
      {~c"x-api-key", to_charlist(anthropic_key())},
      {~c"anthropic-version", to_charlist(@anthropic_version)}
    ]

    url = cfg[:anthropic_base_url] <> "/v1/messages"
    timeout = Keyword.get(opts, :timeout_ms, cfg[:timeout_ms])

    case post_json(url, headers, body, timeout) do
      {:ok, %{"content" => blocks}} when is_list(blocks) ->
        text = extract_anthropic_text(blocks)
        if text == "", do: {:error, :empty_response}, else: {:ok, text}

      {:ok, response} ->
        Logger.warning("LLM anthropic: unexpected response shape: #{inspect(response)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_anthropic_text(blocks) do
    blocks
    |> Enum.filter(fn b -> is_map(b) and b["type"] == "text" and is_binary(b["text"]) end)
    |> Enum.map_join("", & &1["text"])
  end

  # ---------------------------------------------------------------------------
  # OpenAI (Chat Completions API)
  # ---------------------------------------------------------------------------

  defp openai_generate(prompt, opts) do
    cfg = config()
    model = Keyword.get(opts, :model, cfg[:openai_model])
    max_tokens = Keyword.get(opts, :max_tokens, cfg[:max_tokens])

    messages =
      case Keyword.get(opts, :system) do
        nil -> [%{"role" => "user", "content" => prompt}]
        sys -> [%{"role" => "system", "content" => sys}, %{"role" => "user", "content" => prompt}]
      end

    body = %{"model" => model, "max_tokens" => max_tokens, "messages" => messages}

    headers = [{~c"authorization", to_charlist("Bearer " <> openai_key())}]

    url = cfg[:openai_base_url] <> "/v1/chat/completions"
    timeout = Keyword.get(opts, :timeout_ms, cfg[:timeout_ms])

    case post_json(url, headers, body, timeout) do
      {:ok, %{"choices" => [%{"message" => %{"content" => text}} | _]}} when is_binary(text) ->
        {:ok, text}

      {:ok, response} ->
        Logger.warning("LLM openai: unexpected response shape: #{inspect(response)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp configured_choice do
    raw =
      System.get_env("OPTIMAL_LLM_PROVIDER") ||
        (Application.get_env(:optimal_engine, :llm, [])[:provider] |> normalize_choice())

    case raw do
      "anthropic" -> :anthropic
      "openai" -> :openai
      _ -> nil
    end
  end

  defp normalize_choice(nil), do: nil
  defp normalize_choice(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_choice(v) when is_binary(v), do: v

  defp anthropic_key, do: System.get_env("ANTHROPIC_API_KEY")
  defp openai_key, do: System.get_env("OPENAI_API_KEY")

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v) when is_binary(v), do: v

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp config do
    cfg = Application.get_env(:optimal_engine, :llm, [])

    [
      anthropic_base_url:
        cfg[:anthropic_base_url] ||
          System.get_env("ANTHROPIC_BASE_URL", "https://api.anthropic.com"),
      openai_base_url:
        cfg[:openai_base_url] || System.get_env("OPENAI_BASE_URL", "https://api.openai.com"),
      anthropic_model:
        cfg[:anthropic_model] || System.get_env("OPTIMAL_ANTHROPIC_MODEL", @default_anthropic_model),
      openai_model:
        cfg[:openai_model] || System.get_env("OPTIMAL_OPENAI_MODEL", @default_openai_model),
      max_tokens: cfg[:max_tokens] || @default_max_tokens,
      timeout_ms: cfg[:timeout_ms] || @default_timeout_ms
    ]
  end

  defp post_json(url, extra_headers, body, timeout_ms) do
    :inets.start()
    :ssl.start()

    headers = [{~c"content-type", ~c"application/json"} | extra_headers]
    content_type = ~c"application/json"
    encoded_body = Jason.encode!(body)
    request_url = to_charlist(url)

    http_opts = [timeout: timeout_ms || @default_timeout_ms, connect_timeout: 10_000]

    case :httpc.request(:post, {request_url, headers, content_type, encoded_body}, http_opts, []) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        parse_response(status, resp_body)

      {:error, reason} ->
        Logger.warning("LLM HTTP POST #{url} failed: #{inspect(reason)}")
        {:error, :cloud_unavailable}
    end
  end

  defp parse_response(status, body) when status in 200..299 do
    case Jason.decode(to_string(body)) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        Logger.warning("LLM: failed to decode JSON response: #{inspect(reason)}")
        {:error, :invalid_json}
    end
  end

  defp parse_response(status, body) do
    Logger.warning("LLM: non-2xx status #{status}, body: #{to_string(body)}")
    {:error, {:http_error, status}}
  end
end
