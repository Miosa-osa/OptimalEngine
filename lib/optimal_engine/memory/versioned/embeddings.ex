defmodule OptimalEngine.Memory.Versioned.Embeddings do
  @moduledoc """
  Rebuildable semantic projection for durable versioned memories.

  Canonical memory content remains in `memories`.
  This projection is workspace scoped and can be deleted and rebuilt safely.

  With the Qdrant projection enabled (`OptimalEngine.Storage.Qdrant.Projection`)
  every embedding put here is mirrored to Qdrant, and `search/2` takes its
  candidates from Qdrant, reading each back from SQLite (tenant, workspace,
  model, latest and not forgotten) and scoring it here before it counts.
  """

  alias OptimalEngine.Embed.Text, as: TextEmbedder
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.RetrievalDocument
  alias OptimalEngine.Store
  alias OptimalEngine.Storage.Qdrant.Projection
  alias OptimalEngine.Storage.Qdrant.Search, as: QdrantSearch
  alias OptimalEngine.Store.Replace

  @fallback_model "nomic-embed-text"

  @spec model() :: String.t()
  def model do
    Application.get_env(:optimal_engine, :memory_embeddings, [])
    |> Keyword.get(:model, @fallback_model)
  end

  @spec embed_query(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed_query(query, opts \\ []) do
    prefix = Keyword.get(opts, :query_prefix, "")

    TextEmbedder.embed(prefix <> query,
      model: Keyword.get(opts, :model, model()),
      tenant_id: Keyword.get(opts, :tenant_id),
      workspace_id: Keyword.get(opts, :workspace_id)
    )
  end

  @doc """
  Remove the cached embedding of the text a memory was indexed from, for a memory that
  is being deleted or forgotten while its row is still at hand. The text is the
  memory's content and its serialised retrieval document (both profiles), which is
  what `index/2` and an unconfigured `rebuild/2` embed. An entry made under a custom
  `:document_prefix`, or another provider model, cannot be rebuilt from the row and
  is left to the workspace purge or the age sweep.
  """
  @spec forget_cache(Versioned.t()) :: :ok
  def forget_cache(%Versioned{} = memory) do
    texts = [
      memory.content,
      RetrievalDocument.serialize(memory),
      RetrievalDocument.serialize(memory, RetrievalDocument.multimodal_profile())
    ]

    for text <- Enum.uniq(texts), is_binary(text), text != "" do
      TextEmbedder.forget(text,
        model: model(),
        tenant_id: memory.tenant_id,
        workspace_id: memory.workspace_id
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec index(Versioned.t(), keyword()) :: :ok | {:error, term()}
  def index(memory, opts \\ []) do
    projection_model = Keyword.get(opts, :model, model())

    provider_model = Keyword.get(opts, :provider_model, projection_model)

    embedder =
      Keyword.get(opts, :embedder, fn content ->
        TextEmbedder.embed(content,
          model: provider_model,
          tenant_id: memory.tenant_id,
          workspace_id: memory.workspace_id
        )
      end)

    with {:ok, document} <- retrieval_document(memory, opts),
         {:ok, vector} when is_list(vector) and vector != [] <-
           embedder.(document) do
      put(
        memory,
        vector,
        opts
        |> Keyword.put(:model, projection_model)
        |> Keyword.put(:projection_content, document)
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_embedding}
    end
  end

  @spec put(Versioned.t(), [float()], keyword()) :: :ok | {:error, term()}
  def put(memory, embedding, opts \\ []) when is_list(embedding) do
    model = Keyword.get(opts, :model, model())
    blob = encode(embedding)

    sql = """
    INSERT OR REPLACE INTO memory_embeddings
      (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    """

    case Replace.raw_query(sql, [
           memory.id,
           memory.tenant_id,
           memory.workspace_id,
           model,
           length(embedding),
           {:blob, blob},
           content_hash(Keyword.get(opts, :projection_content, memory.content))
         ]) do
      {:ok, _} ->
        # The projection follows the canonical write and never fails it.
        Projection.mirror(:memories, [{memory.id, model}], workspace_id: memory.workspace_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @spec search([float()], keyword()) :: {:ok, [{Versioned.t(), float()}]} | {:error, term()}
  def search(query_embedding, opts) when is_list(query_embedding) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    model = Keyword.get(opts, :model, model())
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.1)

    sql = """
    SELECT me.memory_id, me.embedding
    FROM memory_embeddings me
    JOIN memories m ON m.id = me.memory_id
    WHERE me.tenant_id = ?1 AND me.workspace_id = ?2 AND me.model = ?3
      AND m.is_latest = 1 AND m.is_forgotten = 0
    """

    params = [tenant_id, workspace_id, model]

    score = fn rows ->
      rows
      |> Enum.map(fn [id, blob] -> {id, cosine(query_embedding, decode(blob))} end)
      |> Enum.filter(fn {_id, score} -> score >= min_similarity end)
    end

    # Qdrant proposes; the rows read back here with the same scope decide.
    verify = fn ids ->
      placeholders = Enum.map_join(1..length(ids), ", ", &"?#{&1 + 3}")

      with {:ok, rows} <-
             Store.raw_query(sql <> " AND me.memory_id IN (#{placeholders})", params ++ ids),
           do: {:ok, score.(rows)}
    end

    ranked =
      case QdrantSearch.nearest(
             :memories,
             query_embedding,
             %{tenant_id: tenant_id, workspace_id: workspace_id, model: model},
             [limit: limit, min_similarity: min_similarity],
             verify
           ) do
        {:ok, ranked} ->
          {:ok, ranked}

        :fallback ->
          with {:ok, rows} <- Store.raw_query(sql, params) do
            {:ok,
             rows
             |> score.()
             |> Enum.sort_by(fn {id, score} -> {0.0 - score, id} end)
             |> Enum.take(limit)}
          end
      end

    with {:ok, ranked} <- ranked do
      results =
        ranked
        |> Enum.flat_map(fn {id, score} ->
          case Versioned.get(id) do
            {:ok, memory} -> [{memory, score}]
            _ -> []
          end
        end)

      {:ok, results}
    end
  end

  @spec rebuild(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild(workspace_id, opts \\ []) do
    projection_model = Keyword.get(opts, :model, model())

    provider_model = Keyword.get(opts, :provider_model, projection_model)
    document_prefix = Keyword.get(opts, :document_prefix, "")
    document_profile = Keyword.get(opts, :document_profile)

    tenant_id = Keyword.get(opts, :tenant_id, "default")

    embedder =
      Keyword.get(opts, :embedder, fn content ->
        TextEmbedder.embed(content,
          model: provider_model,
          tenant_id: tenant_id,
          workspace_id: workspace_id
        )
      end)

    limit = Keyword.get(opts, :limit, 100_000)
    concurrency = opts |> Keyword.get(:concurrency, 4) |> max(1) |> min(32)

    sql = """
    SELECT id FROM memories
    WHERE tenant_id = ?1 AND workspace_id = ?2
      AND is_latest = 1 AND is_forgotten = 0
    ORDER BY updated_at DESC, id DESC
    LIMIT ?3
    """

    with :ok <- validate_document_profile(document_profile),
         {:ok, rows} <- Store.raw_query(sql, [tenant_id, workspace_id, limit]) do
      memories =
        Enum.flat_map(rows, fn [id] ->
          case Versioned.get(id) do
            {:ok, memory} -> [memory]
            _ -> []
          end
        end)

      summary =
        memories
        |> Task.async_stream(
          fn memory ->
            index(memory,
              embedder: embedder,
              tenant_id: tenant_id,
              model: projection_model,
              provider_model: provider_model,
              document_prefix: document_prefix,
              document_profile: document_profile
            )
          end,
          max_concurrency: concurrency,
          ordered: false,
          timeout: 120_000
        )
        |> Enum.reduce(%{indexed: 0, failed: 0}, fn
          {:ok, :ok}, counts -> Map.update!(counts, :indexed, &(&1 + 1))
          _, counts -> Map.update!(counts, :failed, &(&1 + 1))
        end)

      {:ok,
       Map.merge(summary, %{
         workspace_id: workspace_id,
         total: length(memories),
         model: projection_model
       })}
    else
      {:error, _} = error -> error
    end
  end

  defp content_hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp retrieval_document(memory, opts) do
    case Keyword.get(opts, :document_profile) do
      nil ->
        {:ok, prefixed(memory.content, opts)}

      :contextual ->
        {:ok, prefixed(RetrievalDocument.serialize(memory), opts)}

      "retrieval-document-v1" ->
        {:ok, prefixed(RetrievalDocument.serialize(memory), opts)}

      "retrieval-document-multimodal-v1" ->
        {:ok,
         prefixed(
           RetrievalDocument.serialize(memory, RetrievalDocument.multimodal_profile()),
           opts
         )}

      profile ->
        {:error, {:unsupported_document_profile, profile}}
    end
  end

  defp validate_document_profile(nil), do: :ok
  defp validate_document_profile(:contextual), do: :ok
  defp validate_document_profile("retrieval-document-v1"), do: :ok
  defp validate_document_profile("retrieval-document-multimodal-v1"), do: :ok
  defp validate_document_profile(profile), do: {:error, {:unsupported_document_profile, profile}}
  defp prefixed(content, opts), do: Keyword.get(opts, :document_prefix, "") <> content

  defp encode(values), do: for(value <- values, into: <<>>, do: <<value::float-little-32>>)
  defp decode(blob), do: for(<<value::float-little-32 <- blob>>, do: value)

  defp cosine(left, right) do
    {dot, left_norm, right_norm} =
      Enum.zip_reduce(left, right, {0.0, 0.0, 0.0}, fn a, b, {dot, la, rb} ->
        {dot + a * b, la + a * a, rb + b * b}
      end)

    denominator = :math.sqrt(left_norm) * :math.sqrt(right_norm)
    if denominator == 0.0, do: 0.0, else: dot / denominator
  end
end
