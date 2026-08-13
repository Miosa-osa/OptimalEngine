defmodule OptimalEngine.Memory.Versioned.Embeddings do
  @moduledoc """
  Rebuildable semantic projection for durable versioned memories.

  Canonical memory content remains in `memories`.
  This projection is workspace scoped and can be deleted and rebuilt safely.
  """

  alias OptimalEngine.Embed.Ollama
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Store

  @model "nomic-embed-text"

  @spec index(Versioned.t(), keyword()) :: :ok | {:error, term()}
  def index(memory, opts \\ []) do
    embedder = Keyword.get(opts, :embedder, &Ollama.embed/1)

    with {:ok, vector} when is_list(vector) and vector != [] <- embedder.(memory.content) do
      put(memory, vector, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_embedding}
    end
  end

  @spec put(Versioned.t(), [float()], keyword()) :: :ok | {:error, term()}
  def put(memory, embedding, opts \\ []) when is_list(embedding) do
    model = Keyword.get(opts, :model, @model)
    blob = encode(embedding)

    sql = """
    INSERT OR REPLACE INTO memory_embeddings
      (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    """

    case Store.raw_query(sql, [
           memory.id,
           memory.tenant_id,
           memory.workspace_id,
           model,
           length(embedding),
           {:blob, blob},
           content_hash(memory.content)
         ]) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @spec search([float()], keyword()) :: {:ok, [{Versioned.t(), float()}]} | {:error, term()}
  def search(query_embedding, opts) when is_list(query_embedding) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    model = Keyword.get(opts, :model, @model)
    limit = Keyword.get(opts, :limit, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.1)

    sql = """
    SELECT me.memory_id, me.embedding
    FROM memory_embeddings me
    JOIN memories m ON m.id = me.memory_id
    WHERE me.tenant_id = ?1 AND me.workspace_id = ?2 AND me.model = ?3
      AND m.is_latest = 1 AND m.is_forgotten = 0
    """

    with {:ok, rows} <- Store.raw_query(sql, [tenant_id, workspace_id, model]) do
      results =
        rows
        |> Enum.map(fn [id, blob] -> {id, cosine(query_embedding, decode(blob))} end)
        |> Enum.filter(fn {_id, score} -> score >= min_similarity end)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(limit)
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
    embedder = Keyword.get(opts, :embedder, &Ollama.embed/1)
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    limit = Keyword.get(opts, :limit, 100_000)
    concurrency = opts |> Keyword.get(:concurrency, 4) |> max(1) |> min(32)

    sql = """
    SELECT id FROM memories
    WHERE tenant_id = ?1 AND workspace_id = ?2
      AND is_latest = 1 AND is_forgotten = 0
    ORDER BY updated_at DESC
    LIMIT ?3
    """

    case Store.raw_query(sql, [tenant_id, workspace_id, limit]) do
      {:ok, rows} ->
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
            fn memory -> index(memory, embedder: embedder, tenant_id: tenant_id) end,
            max_concurrency: concurrency,
            ordered: false,
            timeout: 120_000
          )
          |> Enum.reduce(%{indexed: 0, failed: 0}, fn
            {:ok, :ok}, counts -> Map.update!(counts, :indexed, &(&1 + 1))
            _, counts -> Map.update!(counts, :failed, &(&1 + 1))
          end)

        {:ok, Map.merge(summary, %{workspace_id: workspace_id, total: length(memories)})}

      {:error, _} = error ->
        error
    end
  end

  defp content_hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
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
