defmodule OptimalEngine.AppData.Semantic do
  @moduledoc """
  Semantic search over a collection's `search.semantic` fields.

  Embeddings are a rebuildable projection in `data_embeddings`, one vector
  per record, computed from the record's semantic field values joined by
  newlines. They are written after the record's transaction commits:
  asynchronously by default, synchronously or not at all by configuration:

      config :optimal_engine, :app_data,
        embedder: OptimalEngine.Embed.Text,     # module with embed/2
        embed_model: "nomic-embed-text",
        semantic_indexing: :async               # :async | :sync | :off

  A semantic query embeds the query text with the same embedder and ranks
  matching records by cosine similarity in-process. When no embedder is
  reachable the query fails with `semantic_unavailable`; it never falls
  back silently to another kind of search.
  """

  require Logger

  alias OptimalEngine.AppData.{Collections, Query, Records, Schema, Scope, SQL}
  alias OptimalEngine.Store

  @rebuild_batch 200

  @doc "Embedder module, model, and indexing mode from configuration."
  @spec config() :: %{embedder: module(), model: String.t(), indexing: atom()}
  def config do
    cfg = Application.get_env(:optimal_engine, :app_data, [])

    %{
      embedder: Keyword.get(cfg, :embedder, OptimalEngine.Embed.Text),
      model: Keyword.get(cfg, :embed_model, OptimalEngine.Embed.Text.model()),
      indexing: Keyword.get(cfg, :semantic_indexing, :async)
    }
  end

  @doc "Whether the configured embedder answers a probe right now."
  @spec status() :: map()
  def status do
    %{embedder: embedder, model: model, indexing: indexing} = config()

    # A probe must reach the embedder, never the cache.
    available =
      case embed(embedder, "probe", model, 2_000, cache: false) do
        {:ok, _vector} -> true
        _ -> false
      end

    %{
      "available" => available,
      "embedder" => inspect(embedder),
      "model" => model,
      "indexing" => Atom.to_string(indexing)
    }
  end

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  @doc false
  @spec query(map()) :: {:ok, map()} | {:error, term()}
  def query(%{c: c, scope: scope, spec: spec, limit: limit, mode: {:semantic, semantic}} = plan) do
    %{embedder: embedder, model: model} = config()
    min_score = semantic["min_score"] || 0.0

    with {:ok, vector} <- query_vector(embedder, semantic["text"], model),
         {where_sql, where_params} =
           Records.owner_filter(scope, c, elem(plan.where, 0), elem(plan.where, 1)),
         {:ok, rows} <-
           SQL.query(
             :store,
             ~s[SELECT t."_rowid", e.embedding FROM "#{c.table}" t JOIN data_embeddings e ON e.collection_id = ? AND e.record_id = t."id" AND e.model = ? WHERE #{where_sql}],
             [c.id, model | where_params]
           ) do
      hash =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({c.id, spec["where"], semantic}, [:deterministic])
        )
        |> binary_part(0, 8)

      scored =
        rows
        |> Enum.map(fn [rowid, blob] -> {cosine(vector, decode(blob)), rowid} end)
        |> Enum.filter(fn {score, _} -> score >= min_score end)
        |> Enum.sort_by(fn {score, rowid} -> {-score, rowid} end)

      after_cursor =
        case Query.decode_cursor(spec["cursor"], hash, 1) do
          nil -> scored
          {[score], rowid} -> Enum.drop_while(scored, fn {s, r} -> {-s, r} <= {-score, rowid} end)
        end

      {page, more} = Enum.split(after_cursor, limit)
      by_rowid = fetch_rowids(c, Enum.map(page, &elem(&1, 1)), plan.names)

      records =
        for {score, rowid} <- page,
            record = by_rowid[rowid],
            record != nil,
            do: Map.put(record, "score", Float.round(score, 6))

      next_cursor =
        case {more, List.last(page)} do
          {[_ | _], {score, rowid}} -> Query.encode_cursor(hash, [score], rowid)
          _ -> nil
        end

      result = %{
        "records" => records,
        "next_cursor" => next_cursor,
        "has_more" => next_cursor != nil,
        "model" => model
      }

      {:ok, if(spec["count"] == true, do: Map.put(result, "count", length(scored)), else: result)}
    end
  catch
    {:bad_query, message} -> {:error, {:validation, [message]}}
  end

  defp query_vector(embedder, text, model) do
    case embed(embedder, text, model, 15_000) do
      {:ok, vector} ->
        {:ok, vector}

      {:error, reason} ->
        {:error,
         {:unavailable, "semantic_unavailable",
          "no embedding provider answered (#{inspect(embedder)}, model #{model}): #{inspect(reason)}"}}
    end
  end

  defp fetch_rowids(_c, [], _names), do: %{}

  defp fetch_rowids(c, rowids, names) do
    sql =
      ~s[SELECT #{Enum.join([Records.system_columns() | Records.field_columns(c, names)], ", ")} FROM "#{c.table}" t WHERE t."_rowid" IN (#{SQL.placeholders(length(rowids))})]

    case SQL.query(:store, sql, rowids) do
      {:ok, rows} -> Map.new(rows, &Records.row_record(c, &1, names))
      _ -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Indexing
  # ---------------------------------------------------------------------------

  @doc """
  Embeds written records of collections that declare semantic fields.
  `written` is the `written` list from `Records.transact/2`.
  """
  @spec index_written([tuple()]) :: :ok
  def index_written(written) do
    work =
      for {c, :written, record} <- written, Schema.semantic_fields(c.schema) != [], do: {c, record}

    case {work, config().indexing} do
      {[], _} -> :ok
      {_, :off} -> :ok
      {work, :sync} -> index_records(work)
      {work, _async} -> start_async(work)
    end
  end

  defp start_async(work) do
    case Task.Supervisor.start_child(OptimalEngine.AppData.TaskSupervisor, fn ->
           index_records(work)
         end) do
      {:ok, _pid} -> :ok
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp index_records(work) do
    %{embedder: embedder, model: model} = config()
    Enum.each(work, fn {c, record} -> index_record(embedder, model, c, record) end)
  end

  defp index_record(embedder, model, c, record) do
    text =
      c.schema
      |> Schema.semantic_fields()
      |> Enum.map(&record["data"][&1])
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.join("\n")

    hash = :crypto.hash(:sha256, model <> "\n" <> text) |> Base.encode16(case: :lower)

    cond do
      text == "" ->
        Store.raw_execute(
          "DELETE FROM data_embeddings WHERE collection_id = ? AND record_id = ?",
          [c.id, record["id"]]
        )

        :skipped

      current_hash(c, record["id"]) == hash ->
        :unchanged

      true ->
        case embed(embedder, text, model, 15_000) do
          {:ok, vector} ->
            Store.raw_execute(
              "INSERT OR REPLACE INTO data_embeddings (collection_id, record_id, model, dimensions, embedding, content_hash, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
              [
                c.id,
                record["id"],
                model,
                length(vector),
                {:blob, encode(vector)},
                hash,
                Schema.now()
              ]
            )

            :indexed

          {:error, reason} ->
            Logger.debug("[AppData.Semantic] embedding skipped: #{inspect(reason)}")
            :failed
        end
    end
  end

  defp current_hash(c, record_id) do
    case SQL.scalar(
           :store,
           "SELECT content_hash FROM data_embeddings WHERE collection_id = ? AND record_id = ?",
           [c.id, record_id]
         ) do
      {:ok, hash} -> hash
      _ -> nil
    end
  end

  @doc """
  Re-embeds every record of a collection and removes embeddings of records
  that no longer exist. Synchronous. Returns counts.
  """
  @spec rebuild(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rebuild(%Scope{} = scope, name) do
    %{embedder: embedder, model: model} = config()

    with :ok <- Scope.allow(scope, name, "update"),
         {:ok, c} <- Collections.load(:store, scope, name),
         :ok <- has_semantic(c),
         {:ok, _probe} <- query_vector(embedder, "probe", model) do
      Store.raw_execute(
        ~s[DELETE FROM data_embeddings WHERE collection_id = ? AND (model != ? OR record_id NOT IN (SELECT "id" FROM "#{c.table}"))],
        [c.id, model]
      )

      counts =
        rebuild_from(embedder, model, c, 0, %{
          "indexed" => 0,
          "unchanged" => 0,
          "skipped" => 0,
          "failed" => 0
        })

      {:ok, Map.put(counts, "model", model)}
    end
  end

  defp has_semantic(c) do
    if Schema.semantic_fields(c.schema) == [],
      do: {:error, {:validation, ["collection #{c.name} has no semantic search fields"]}},
      else: :ok
  end

  defp rebuild_from(embedder, model, c, after_rowid, counts) do
    sql =
      ~s[SELECT #{Enum.join([Records.system_columns() | Records.field_columns(c)], ", ")} FROM "#{c.table}" t WHERE t."_rowid" > ? ORDER BY t."_rowid" LIMIT ?]

    case SQL.query(:store, sql, [after_rowid, @rebuild_batch]) do
      {:ok, []} ->
        counts

      {:ok, rows} ->
        records = Enum.map(rows, &Records.row_record(c, &1))

        counts =
          Enum.reduce(records, counts, fn {_rowid, record}, acc ->
            outcome = index_record(embedder, model, c, record) |> Atom.to_string()
            Map.update!(acc, outcome, &(&1 + 1))
          end)

        {last_rowid, _} = List.last(records)
        rebuild_from(embedder, model, c, last_rowid, counts)

      _ ->
        counts
    end
  end

  # ---------------------------------------------------------------------------

  defp embed(embedder, text, model, timeout, opts \\ []) do
    task = Task.async(fn -> embedder.embed(text, Keyword.put(opts, :model, model)) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, vector}} when is_list(vector) and vector != [] -> {:ok, vector}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:invalid_embedding, other}}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  defp encode(vector), do: for(x <- vector, into: <<>>, do: <<x / 1::little-float-32>>)

  defp decode(blob), do: for(<<x::little-float-32 <- blob>>, do: x)

  defp cosine(a, b) when length(a) == length(b) do
    {dot, na, nb} =
      Enum.zip_reduce(a, b, {0.0, 0.0, 0.0}, fn x, y, {d, p, q} ->
        {d + x * y, p + x * x, q + y * y}
      end)

    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (:math.sqrt(na) * :math.sqrt(nb))
  end

  defp cosine(_a, _b), do: 0.0
end
