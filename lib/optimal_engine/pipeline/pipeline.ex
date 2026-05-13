defmodule OptimalEngine.Pipeline do
  @moduledoc """
  Unified pipeline orchestrator — chains Stages 2→5 into a single call.

      file path
        │
        ▼
      [2] Parser.parse           → ParsedDoc
        │
        ▼
      [2.5] VlmEnricher.enrich  → ParsedDoc (enriched)
        │
        ▼
      [3] Decomposer.decompose  → ChunkTree
        │
        ▼
      [5] Embedder.embed_tree   → [Embedding]

  Each stage degrades gracefully. The result struct carries everything
  downstream stages need (chunks, embeddings, errors, metadata).

  ## Usage

      {:ok, result} = Pipeline.run("path/to/file.mp4")
      result.tree      # ChunkTree with all chunks
      result.embeddings # [Embedding] — 768-dim vectors
      result.parsed     # enriched ParsedDoc
  """

  alias OptimalEngine.Pipeline.{Decomposer, Embedder, Parser}
  alias OptimalEngine.Pipeline.Enricher.VlmEnricher

  require Logger

  @type result :: %{
          parsed: Parser.ParsedDoc.t(),
          tree: Decomposer.ChunkTree.t(),
          embeddings: [Embedder.Embedding.t()],
          embed_errors: [{String.t(), term()}],
          asset_paths: %{String.t() => String.t()}
        }

  @doc """
  Run the full parse → enrich → decompose → embed pipeline on a file.

  ## Options
  - `:skip_vlm` — skip VLM enrichment (default `false`)
  - `:skip_embed` — skip embedding (default `false`)
  - `:window_bytes` — chunk window size (default 2048)
  - `:overlap_bytes` — chunk overlap (default 256)
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(path, opts \\ []) when is_binary(path) do
    with {:ok, parsed} <- Parser.parse(path),
         {:ok, enriched} <- VlmEnricher.enrich(parsed, opts),
         {:ok, tree} <- Decomposer.decompose(enriched, opts) do
      asset_paths = build_asset_paths(enriched)

      if Keyword.get(opts, :skip_embed, false) do
        {:ok,
         %{
           parsed: enriched,
           tree: tree,
           embeddings: [],
           embed_errors: [],
           asset_paths: asset_paths
         }}
      else
        embed_opts = Keyword.put(opts, :asset_paths, asset_paths)
        {:ok, embeddings, %{errors: errors}} = Embedder.embed_tree(tree, embed_opts)

        {:ok,
         %{
           parsed: enriched,
           tree: tree,
           embeddings: embeddings,
           embed_errors: errors,
           asset_paths: asset_paths
         }}
      end
    end
  end

  defp build_asset_paths(%{assets: assets}) when is_list(assets) do
    assets
    |> Enum.filter(fn a -> is_binary(a.hash) and is_binary(a.path) end)
    |> Map.new(fn a -> {a.hash, a.path} end)
  end

  defp build_asset_paths(_), do: %{}
end
