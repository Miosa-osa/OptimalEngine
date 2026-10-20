defmodule OptimalEngine.Pipeline.Embedder do
  @moduledoc """
  Stage 5 of the ingestion pipeline — produces a vector per chunk.

  Dispatches on `chunk.modality`:

    * `:text` / `:code` / `:data` / `:mixed` → text embedder (nomic-embed-text)
    * `:image`                                → vision embedder (nomic-embed-vision)
    * `:audio`                                → whisper-transcript → text embedder
    * `:video`                                → (Phase 10+; falls back to chunk text if present)

  All three modalities land in the same 768-dim aligned space. That's the
  single architectural win of this stage: `SearchEngine` can answer a text
  query with an image or audio chunk because their embeddings live in the
  same coordinate system — no separate indexes, no model-switching logic
  at query time.

  ## Graceful degradation

  If Ollama or whisper.cpp is unreachable, `embed/2` returns
  `{:error, :unavailable}`. `embed_tree/2` collects successes and drops
  failures — the ChunkTree itself is unchanged; chunks without embeddings
  simply aren't retrievable via vector search until the providers come back.

  ## Asset-aware embedding

  For chunks that carry an `asset_ref` (images, audio), this module reads
  the original binary from disk via `OptimalEngine.Assets` (Phase 6+ will
  formalize asset storage; today we read the path on `chunk.asset_ref`).
  When no asset is available, text-based fallback: embed `chunk.text` with
  the text model.
  """

  alias OptimalEngine.Embed.{Ollama, Whisper}
  alias OptimalEngine.Embed.Text, as: TextEmbedder
  alias OptimalEngine.MemoryCore.GovernedModel
  alias OptimalEngine.Pipeline.Decomposer.{Chunk, ChunkTree}
  alias OptimalEngine.Pipeline.Embedder.Embedding

  require Logger

  @text_model "nomic-embed-text"
  @vision_model "nomic-embed-vision"
  @dim 768

  @doc "Embed a single chunk. Returns `{:ok, %Embedding{}}` or `{:error, reason}`."
  @spec embed(Chunk.t(), keyword()) :: {:ok, Embedding.t()} | {:error, term()}
  def embed(%Chunk{} = chunk, opts \\ []) do
    case dispatch(chunk, opts) do
      {:ok, vector, model, effective_modality} ->
        {:ok,
         Embedding.new(
           chunk_id: chunk.id,
           tenant_id: chunk.tenant_id,
           model: model,
           modality: effective_modality,
           dim: length(vector),
           vector: vector
         )}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Embed every chunk in the tree. Returns `{:ok, [%Embedding{}], %{errors: [{chunk_id, reason}]}}`
  so callers can see which chunks were skipped and why.
  """
  @spec embed_tree(ChunkTree.t(), keyword()) ::
          {:ok, [Embedding.t()], %{errors: [{String.t(), term()}]}}
  def embed_tree(%ChunkTree{chunks: chunks}, opts \\ []) do
    opts = with_text_vectors(chunks, opts)

    {embeddings, errors} =
      Enum.reduce(chunks, {[], []}, fn chunk, {acc_emb, acc_err} ->
        case embed(chunk, opts) do
          {:ok, emb} -> {[emb | acc_emb], acc_err}
          {:error, reason} -> {acc_emb, [{chunk.id, reason} | acc_err]}
        end
      end)

    {:ok, Enum.reverse(embeddings), %{errors: Enum.reverse(errors)}}
  end

  # With an embedding endpoint, every chunk of a tree that is embedded by its text
  # goes out together (see batch_text/2): a few batched requests (a shared gateway
  # meters requests), governed as one model call, and an unavailable endpoint is
  # asked once, not once per chunk. Ollama at OLLAMA_HOST embeds chunk by chunk as
  # before, so a slow first model load costs only the chunk it hits.
  defp with_text_vectors(chunks, opts) do
    if TextEmbedder.endpoint_configured?() do
      texts =
        chunks
        |> Enum.map(&batch_text(&1, opts))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      vectors = texts |> Enum.zip(governed_embed_batch(texts, opts)) |> Map.new()
      Keyword.put(opts, :text_vectors, vectors)
    else
      opts
    end
  end

  # The text a chunk is embedded by, when dispatch/2 knows it before any other model
  # runs: the text of text, code, data and mixed chunks, an audio chunk's transcript,
  # and the text (OCR, captions) of an image or video with no asset that vision
  # embeds first. A transcript whisper makes, or a video's text used after vision
  # fails, is embedded on its own.
  defp batch_text(%Chunk{modality: m, text: text}, _opts)
       when m in [:text, :code, :data, :mixed, :audio],
       do: present(text)

  defp batch_text(%Chunk{modality: :image} = chunk, opts) do
    if asset_file(chunk, opts), do: nil, else: present(chunk.text)
  end

  defp batch_text(%Chunk{modality: :video} = chunk, opts) do
    path = asset_file(chunk, opts)
    if path && image_asset?(path), do: nil, else: present(chunk.text)
  end

  defp batch_text(_chunk, _opts), do: nil

  defp present(text) when is_binary(text) and text != "", do: text
  defp present(_text), do: nil

  # The chunk's asset on disk, when the caller passed a path for its `asset_ref`.
  defp asset_file(%Chunk{asset_ref: ref}, opts) when is_binary(ref) do
    path = get_in(opts, [:asset_paths, ref])
    if is_binary(path) and File.exists?(path), do: path
  end

  defp asset_file(_chunk, _opts), do: nil

  @doc """
  Embed every chunk in a tree and persist the vectors to `chunk_embeddings`.

  This is the connecting tissue between the in-memory Phase 5 embedder and the
  store: `embed_tree/2` produces `%Embedding{}` structs but never persists them;
  this function maps each embedding back onto its originating chunk (to inherit
  `workspace_id`/`tenant_id` — keeping the embedding row in the **current**
  chunk-keyed scope scheme, joinable to contexts via `chunks.signal_id`) and
  writes the batch via `OptimalEngine.Store.insert_embeddings/1`.

  Returns `{:ok, %{embedded: n, errors: [...]}}` or `{:error, reason}` if the
  store write fails. Embeddings whose providers were unreachable are reported in
  `:errors` and simply not persisted (graceful degradation).

  Gated by `config :optimal_engine, :embed, on_ingest: true` — see
  `embed_on_ingest?/0`. Callers in the ingest path should check that flag.
  """
  @spec embed_and_store(ChunkTree.t(), keyword()) ::
          {:ok, %{embedded: non_neg_integer(), errors: [{String.t(), term()}]}}
          | {:error, term()}
  def embed_and_store(%ChunkTree{chunks: chunks} = tree, opts \\ []) do
    {:ok, embeddings, %{errors: errors}} = embed_tree(tree, opts)

    chunk_by_id = Map.new(chunks, fn c -> {c.id, c} end)
    rows = Enum.map(embeddings, &embedding_row(&1, chunk_by_id))

    case OptimalEngine.Store.insert_embeddings(rows) do
      :ok -> {:ok, %{embedded: length(rows), errors: errors}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Build a persistable embedding row from an `%Embedding{}`, inheriting
  `workspace_id`/`tenant_id` from the originating chunk when available.
  """
  @spec embedding_row(Embedding.t(), %{String.t() => Chunk.t()}) :: map()
  def embedding_row(%Embedding{} = emb, chunk_by_id) do
    chunk = Map.get(chunk_by_id, emb.chunk_id)

    %{
      chunk_id: emb.chunk_id,
      tenant_id: emb.tenant_id,
      model: emb.model,
      modality: emb.modality,
      dim: emb.dim,
      vector: emb.vector,
      workspace_id: (chunk && Map.get(chunk, :workspace_id)) || "default"
    }
  end

  @doc """
  Whether embedding should run automatically on the ingest path.

  Config: `config :optimal_engine, :embed, on_ingest: true` (default `true`).
  """
  @spec embed_on_ingest?() :: boolean()
  def embed_on_ingest? do
    :optimal_engine
    |> Application.get_env(:embed, [])
    |> Keyword.get(:on_ingest, true)
  end

  # ─── dispatch ────────────────────────────────────────────────────────────

  # Text-ish modalities: plain text embedding
  defp dispatch(%Chunk{modality: m, text: text}, opts)
       when m in [:text, :code, :data, :mixed] and is_binary(text) and text != "" do
    with {:ok, vector} <- governed_embed_text(text, opts) do
      {:ok, vector, model_name(opts, :text), m}
    end
  end

  # Image: prefer asset bytes (embed the picture); fall back to OCR text if
  # the chunk has text but no readable asset path.
  defp dispatch(%Chunk{modality: :image, asset_ref: ref} = chunk, opts) when is_binary(ref) do
    # The chunk carries `asset_ref` = content hash. Pipeline.run/2 can preserve
    # parser assets through MemoryCore.AssetStore before building this lookup.
    asset_path = asset_file(chunk, opts)

    cond do
      asset_path != nil ->
        case governed_embed_image(asset_path, opts) do
          {:ok, vector} -> {:ok, vector, model_name(opts, :image), :image}
          {:error, _} = err -> err
        end

      chunk.text != "" ->
        # Vision unavailable or asset missing — fall back to OCR text embedding.
        fallback_text(chunk, opts, :image)

      true ->
        {:error, :no_embeddable_content}
    end
  end

  # Image with no asset ref — OCR text only.
  defp dispatch(%Chunk{modality: :image} = chunk, opts) do
    fallback_text(chunk, opts, :image)
  end

  # Audio: if a transcript is already on the chunk (Phase 2 whisper path),
  # embed that. Otherwise attempt whisper transcription of the asset.
  defp dispatch(%Chunk{modality: :audio, text: transcript}, opts)
       when is_binary(transcript) and transcript != "" do
    # Existing transcript → text embed.
    with {:ok, vector} <- governed_embed_text(transcript, opts) do
      {:ok, vector, "whisper+" <> model_name(opts, :text), :audio}
    end
  end

  defp dispatch(%Chunk{modality: :audio, asset_ref: ref} = chunk, opts) when is_binary(ref) do
    # No transcript yet — ask whisper.
    case asset_file(chunk, opts) do
      nil ->
        {:error, :asset_unavailable}

      asset_path ->
        case Whisper.transcribe(asset_path, opts) do
          {:ok, %{text: text}} when text != "" ->
            with {:ok, vector} <- governed_embed_text(text, opts) do
              {:ok, vector, "whisper+" <> model_name(opts, :text), :audio}
            end

          _ ->
            {:error, :transcript_unavailable}
        end
    end
  end

  defp dispatch(%Chunk{modality: :audio}, _opts), do: {:error, :no_embeddable_content}

  # Video: prefer vision embedding on keyframe assets, fall back to text.
  defp dispatch(%Chunk{modality: :video, asset_ref: ref} = chunk, opts) when is_binary(ref) do
    asset_path = asset_file(chunk, opts)

    cond do
      asset_path != nil and image_asset?(asset_path) ->
        case governed_embed_image(asset_path, opts) do
          {:ok, vector} -> {:ok, vector, "vision+" <> model_name(opts, :image), :video}
          {:error, _} -> fallback_text(chunk, opts, :video)
        end

      chunk.text != "" ->
        fallback_text(chunk, opts, :video)

      true ->
        {:error, :no_embeddable_content}
    end
  end

  defp dispatch(%Chunk{modality: :video} = chunk, opts) do
    fallback_text(chunk, opts, :video)
  end

  # Empty text on a text-modality chunk
  defp dispatch(_chunk, _opts), do: {:error, :empty_content}

  defp fallback_text(%Chunk{text: text}, opts, effective_modality)
       when is_binary(text) and text != "" do
    with {:ok, vector} <- governed_embed_text(text, opts) do
      {:ok, vector, model_name(opts, :text), effective_modality}
    end
  end

  defp fallback_text(_chunk, _opts, _modality), do: {:error, :no_embeddable_content}

  defp model_name(opts, :text), do: Keyword.get(opts, :text_model, @text_model)
  defp model_name(opts, :image), do: Keyword.get(opts, :vision_model, @vision_model)

  # ─── governance-wrapped provider calls ─────────────────────────────────────
  # Every external model call from this stage is routed through GovernedModel so
  # it lands a model_call_run with provenance (model id) + latency + status.
  # Fail-open: governance never alters or blocks the embedding result.

  # A text embedded in the tree's batch was governed with the batch.
  defp governed_embed_text(text, opts) do
    case Map.fetch(Keyword.get(opts, :text_vectors, %{}), text) do
      {:ok, result} ->
        result

      :error ->
        GovernedModel.call_model(
          "embedder.embed_text",
          %{"chars" => String.length(text)},
          fn -> TextEmbedder.embed(text, Keyword.delete(opts, :text_vectors)) end,
          model_id: model_name(opts, :text),
          model_task_type: "embedding",
          provider: TextEmbedder.provider(),
          workspace_id: Keyword.get(opts, :workspace_id, "default")
        )
    end
  end

  # One governed call for the whole batch, recorded with the input count and
  # size only, never the text, and with how many inputs got a vector.
  defp governed_embed_batch([], _opts), do: []

  defp governed_embed_batch(texts, opts) do
    GovernedModel.call_model(
      "embedder.embed_text_batch",
      %{"inputs" => length(texts), "chars" => texts |> Enum.map(&String.length/1) |> Enum.sum()},
      fn -> TextEmbedder.embed_many(texts, opts) end,
      model_id: model_name(opts, :text),
      model_task_type: "embedding",
      provider: TextEmbedder.provider(),
      workspace_id: Keyword.get(opts, :workspace_id, "default"),
      classify: &classify_batch/1
    )
  end

  defp classify_batch(results) do
    embedded = Enum.count(results, &match?({:ok, _vector}, &1))

    payload = %{
      "ok" => embedded > 0,
      "result_kind" => "vectors",
      "embedded" => embedded,
      "failed" => length(results) - embedded
    }

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {"completed", payload}
      {:error, reason} when embedded == 0 -> {"failed", Map.put(payload, "error", inspect(reason))}
      {:error, reason} -> {"completed", Map.put(payload, "error", inspect(reason))}
    end
  end

  defp governed_embed_image(asset_path, opts) do
    model = model_name(opts, :image)

    GovernedModel.call_model(
      "embedder.embed_image",
      %{"asset_path" => asset_path},
      fn -> Ollama.embed_image(asset_path, opts) end,
      model_id: model,
      model_task_type: "embedding",
      workspace_id: Keyword.get(opts, :workspace_id, "default")
    )
  end

  @image_extensions ~w(.jpg .jpeg .png .gif .webp .bmp .tiff)
  defp image_asset?(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @image_extensions
  end

  @doc "The canonical vector dimension for Phase 5 providers (768)."
  @spec dim() :: non_neg_integer()
  def dim, do: @dim
end
