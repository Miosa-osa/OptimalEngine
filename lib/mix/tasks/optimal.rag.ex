defmodule Mix.Tasks.Optimal.Rag do
  @shortdoc "Return LLM-ready retrieved chunks for a query"

  @moduledoc """
  Retrieves context chunks for a query and formats them for direct injection
  into an LLM prompt.

  This is the explicit RAG (retrieval-augmented generation) surface. Where
  `mix optimal.search` returns metadata for humans, `mix optimal.rag` returns
  a payload ready to be fed to a language model.

  ## Usage

      mix optimal.rag "query"
      mix optimal.rag "query" --limit 8 --tier l1
      mix optimal.rag "query" --format json
      mix optimal.rag "query" --format claude
      mix optimal.rag "query" --format openai

  ## Options

    --limit       Max chunks to return (default 6)
    --tier        Load each chunk at `l0` | `l1` | `full` (default `l1`)
    --format      Output format:
                    `text`   — plain concatenated chunks with separators (default)
                    `json`   — `{query, chunks: [...]}` machine-readable
                    `claude` — XML-wrapped chunks for Claude's recommended format
                    `openai` — JSON array of `{role: "system", content: ...}`
    --include-uri When set, includes the `optimal://` URI of each chunk
    --node        Restrict retrieval to a node
    --genre       Restrict retrieval to a signal genre
    --min-score   Drop chunks with hybrid score below threshold (default 0.0)

  ## Examples

      # Drop into a Claude Agent SDK prompt
      $ context=$(optimal rag "our pricing conversation with Ed" --format claude)
      $ claude-cli "Given this context: $context — what should our counter-offer be?"

      # Pipe to a local LLM
      $ optimal rag "bug report for duplicate ingest" --format text | ollama run qwen3:8b

      # Agent runtime integration (JSON)
      $ optimal rag "Q3 revenue forecast" --format json --limit 10 > context.json
  """

  use Mix.Task
  require Logger

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, rest, _} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          tier: :string,
          format: :string,
          include_uri: :boolean,
          node: :string,
          genre: :string,
          min_score: :float
        ],
        aliases: [l: :limit, t: :tier, f: :format, n: :node, g: :genre]
      )

    query = Enum.join(rest, " ")

    if query == "" do
      Mix.shell().error(~s(Usage: mix optimal.rag "query" [options]))
      Mix.shell().error("Run `mix optimal.rag --help` for details.")
      System.halt(1)
    end

    limit = Keyword.get(parsed, :limit, 6)
    tier = Keyword.get(parsed, :tier, "l1")
    format = Keyword.get(parsed, :format, "text")
    include_uri = Keyword.get(parsed, :include_uri, false)
    min_score = Keyword.get(parsed, :min_score, 0.0)

    search_opts =
      [limit: limit]
      |> maybe_put(:node, Keyword.get(parsed, :node))
      |> maybe_put(:genre, Keyword.get(parsed, :genre))

    chunks = retrieve(query, search_opts, tier, min_score)

    output =
      case format do
        "text" -> format_text(query, chunks, include_uri)
        "json" -> format_json(query, chunks, include_uri)
        "claude" -> format_claude(query, chunks, include_uri)
        "openai" -> format_openai(query, chunks, include_uri)
        other -> Mix.raise("Unknown --format #{inspect(other)}. Use text | json | claude | openai.")
      end

    IO.write(output)
    IO.puts("")
  end

  # ── Retrieval ────────────────────────────────────────────────────────────

  defp retrieve(query, search_opts, tier, min_score) do
    {:ok, hits} = OptimalEngine.Retrieval.Search.search(query, search_opts)

    hits
    |> Enum.filter(fn hit -> Map.get(hit, :score, 1.0) >= min_score end)
    |> Enum.map(&hydrate_chunk(&1, tier))
    |> Enum.reject(&is_nil/1)
  end

  defp hydrate_chunk(hit, tier) do
    # Phase 0.5 stub: full content only. Phase 8 will wire tiered (`l0`/`l1`/`full`)
    # materialization through ContextAssembler once scale-aware chunks exist.
    uri = Map.get(hit, :uri) || Map.get(hit, :id)

    content =
      case OptimalEngine.Store.get_context(uri) do
        {:ok, %{content: body}} when is_binary(body) -> body
        {:ok, %{"content" => body}} when is_binary(body) -> body
        _ -> nil
      end

    case content do
      nil ->
        nil

      body ->
        %{
          uri: uri,
          title: Map.get(hit, :title, ""),
          score: Map.get(hit, :score, 0.0),
          tier: tier,
          content: body
        }
    end
  end

  # ── Formatters ───────────────────────────────────────────────────────────

  defp format_text(query, chunks, include_uri) do
    header = "# Retrieved context for: #{query}\n\n"

    body =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {c, i} -> format_text_chunk(c, i, include_uri) end)
      |> Enum.join("\n\n---\n\n")

    header <> body
  end

  defp format_text_chunk(c, idx, include_uri) do
    title_line = "## Chunk #{idx}: #{c.title}"

    uri_line =
      if include_uri do
        "_#{c.uri} (score #{:erlang.float_to_binary(c.score, decimals: 3)})_\n\n"
      else
        ""
      end

    title_line <> "\n" <> uri_line <> c.content
  end

  defp format_json(query, chunks, include_uri) do
    payload = %{
      query: query,
      count: length(chunks),
      chunks:
        Enum.map(chunks, fn c ->
          base = %{title: c.title, content: c.content}
          if include_uri, do: Map.merge(base, %{uri: c.uri, score: c.score}), else: base
        end)
    }

    Jason.encode!(payload, pretty: true)
  end

  defp format_claude(query, chunks, include_uri) do
    inner =
      chunks
      |> Enum.with_index(1)
      |> Enum.map(fn {c, i} ->
        attrs =
          if include_uri do
            ~s( index="#{i}" source="#{c.uri}" title="#{escape(c.title)}")
          else
            ~s( index="#{i}" title="#{escape(c.title)}")
          end

        "<document#{attrs}>\n#{c.content}\n</document>"
      end)
      |> Enum.join("\n\n")

    """
    <context query="#{escape(query)}">
    #{inner}
    </context>
    """
  end

  defp format_openai(query, chunks, include_uri) do
    messages = [
      %{role: "system", content: "The following context was retrieved for the query: #{query}"}
      | Enum.map(chunks, fn c ->
          body =
            if include_uri do
              "[#{c.title}] (#{c.uri})\n#{c.content}"
            else
              "[#{c.title}]\n#{c.content}"
            end

          %{role: "system", content: body}
        end)
    ]

    Jason.encode!(messages, pretty: true)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp escape(nil), do: ""

  defp escape(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
