defmodule OptimalEngine.Storage.Qdrant.Sync do
  @moduledoc """
  Brings the Qdrant projection level with the embedded stores, idempotently.

  A run walks six phases, in order, for one workspace or for every one:

    1. `contexts`, `chunks`, `memories`: every row of `vectors`,
       `chunk_embeddings` and `memory_embeddings` is upserted to its collection
       (the point id comes from the row's key, so a second run writes the same
       points again and adds none);
    2. `orphans_contexts`, `orphans_chunks`, `orphans_memories`: every point of
       the kind's collections (in the workspace, when one is named) is read
       back from SQLite, and a point whose row is gone, or is now in another
       workspace or of another dimension, is deleted.

  One run handles at most `:limit` rows and points (default 2,000) and returns
  where it stopped (`next`), so a job can continue it after a restart:
  `mix optimal.qdrant_sync` loops until `next` is nil, and the
  `maintenance.qdrant_sync` job queues its own continuation. When a pass
  completes, the workspace's count comparisons are dropped, so its next search
  compares again and reads Qdrant if they agree.
  """

  alias OptimalEngine.Storage.Qdrant.Projection
  alias OptimalEngine.Store

  @phases ~w(contexts chunks memories orphans_contexts orphans_chunks orphans_memories)
  @default_limit 2_000
  @page 256

  @type cursor :: %{optional(String.t()) => term()} | nil
  @type result :: %{
          workspace_id: String.t() | nil,
          upserted: non_neg_integer(),
          deleted: non_neg_integer(),
          skipped: non_neg_integer(),
          next: cursor()
        }

  @doc "The phases of a run, in order."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc """
  One bounded run. Options: `:workspace_id` (default: every workspace),
  `:limit` (rows and points this run handles, default 2,000), `:after` (the
  `next` of the run before), `:pause_ms` between pages (default 0).

  Returns `{:error, :not_configured}` when the projection is off and
  `{:error, {:qdrant_unavailable, reason}}` when Qdrant does not answer, so a
  job can wait for it.
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    limit = max(Keyword.get(opts, :limit, @default_limit), 1)

    cond do
      not Projection.enabled?() ->
        {:error, :not_configured}

      not reachable?() ->
        {:error, {:qdrant_unavailable, :health_check_failed}}

      # Removals Qdrant refused come first; a run fails while one remains, so
      # the job that ran it is retried.
      (pending = Projection.retry_pending()) != :ok ->
        {:error,
         {:qdrant_unavailable, {:pending_removals, Projection.error_class(elem(pending, 1))}}}

      true ->
        acc = %{workspace_id: workspace_id, upserted: 0, deleted: 0, skipped: 0, next: nil}
        state = %{ws: workspace_id, budget: limit, pause: Keyword.get(opts, :pause_ms, 0)}
        cursor = start(Keyword.get(opts, :after))

        # A pass repairs the dirty marks made before it began, and carries when
        # that was in its cursor, so a continuation (even after a restart) does
        # not clear a mark made during the pass.
        started =
          case cursor["started"] do
            stamp when is_integer(stamp) -> stamp
            _ -> Projection.stamp()
          end

        case walk(Map.delete(cursor, "started"), state, acc) do
          {:ok, %{next: nil} = result} ->
            Projection.clear_dirty(workspace_id, started)

            if workspace_id,
              do: Projection.invalidate(workspace_id),
              else: Projection.invalidate_all()

            {:ok, result}

          {:ok, %{next: next} = result} ->
            {:ok, %{result | next: Map.put(next, "started", started)}}

          other ->
            other
        end
    end
  end

  # A fresh health answer: a sync is the way out of an unhealthy spell.
  defp reachable? do
    case OptimalEngine.Storage.Qdrant.health(timeout: Projection.timeout()) do
      :healthy -> true
      _ -> false
    end
  end

  defp start(%{"phase" => phase} = cursor) when phase in @phases, do: cursor
  defp start(_), do: %{"phase" => "contexts"}

  defp walk(cursor, %{budget: budget} = _state, acc) when budget <= 0,
    do: {:ok, %{acc | next: cursor}}

  defp walk(%{"phase" => phase} = cursor, state, acc) do
    result =
      case phase do
        "orphans_" <> kind -> sweep(String.to_existing_atom(kind), cursor, state)
        kind -> upsert_page(String.to_existing_atom(kind), cursor, state)
      end

    case result do
      {:ok, handled, counts, next} ->
        acc = Map.merge(acc, counts, fn _key, a, b -> a + b end)
        state = %{state | budget: state.budget - max(handled, 1)}
        if state.pause > 0, do: Process.sleep(state.pause)

        case next do
          :phase_done -> next_phase(phase, state, acc)
          next -> walk(next, state, acc)
        end

      {:error, _} = error ->
        error
    end
  end

  defp next_phase(phase, state, acc) do
    case Enum.drop_while(@phases, &(&1 != phase)) do
      [_current, following | _] -> walk(%{"phase" => following}, state, acc)
      _ -> {:ok, %{acc | next: nil}}
    end
  end

  # ── upsert phases ───────────────────────────────────────────────────────

  defp upsert_page(kind, cursor, state) do
    size = min(@page, state.budget)

    with {:ok, rows} <- page_rows(kind, state.ws, cursor["after"], size),
         :ok <- Projection.upsert_rows(kind, rows) do
      next =
        case rows do
          rows when length(rows) < size -> :phase_done
          rows -> %{"phase" => Atom.to_string(kind), "after" => last_key(kind, List.last(rows))}
        end

      skipped = Enum.count(rows, &(Projection.point(kind, &1) == []))
      {:ok, length(rows), %{upserted: length(rows) - skipped, skipped: skipped}, next}
    end
  end

  defp last_key(:memories, [memory_id, _blob, _tenant, _ws, model]), do: [memory_id, model]
  defp last_key(_kind, [key | _]), do: key

  defp page_rows(kind, ws, after_key, size) when kind in [:contexts, :chunks],
    do:
      keyed_page(
        Projection.select_sql(kind),
        Projection.key_column(kind),
        Projection.workspace_column(kind),
        ws,
        after_key,
        size
      )

  defp page_rows(:memories, ws, after_key, size) do
    {after_clause, after_params} =
      case after_key do
        [memory_id, model] ->
          {"(me.memory_id > ?A OR (me.memory_id = ?A AND me.model > ?B))", [memory_id, model]}

        _ ->
          {nil, []}
      end

    {ws_clause, ws_params} = if ws, do: {"me.workspace_id = ?W", [ws]}, else: {nil, []}

    {where, params} = numbered([ws_clause, after_clause], ws_params ++ after_params)

    Store.raw_query(
      Projection.select_sql(:memories) <>
        where <> " ORDER BY me.memory_id, me.model LIMIT ?#{length(params) + 1}",
      params ++ [size]
    )
  end

  defp keyed_page(select, key, ws_column, ws, after_key, size) do
    {ws_clause, ws_params} = if ws, do: {"#{ws_column} = ?W", [ws]}, else: {nil, []}

    {after_clause, after_params} =
      if is_binary(after_key), do: {"#{key} > ?A", [after_key]}, else: {nil, []}

    {where, params} = numbered([ws_clause, after_clause], ws_params ++ after_params)

    Store.raw_query(
      select <> where <> " ORDER BY #{key} LIMIT ?#{length(params) + 1}",
      params ++ [size]
    )
  end

  # Joins the clauses that are present with AND and numbers their parameters
  # in order: ?W, ?A and ?B stand for the next parameter of their clause.
  defp numbered(clauses, params) do
    present = Enum.reject(clauses, &is_nil/1)

    {numbered, _n} =
      Enum.map_reduce(present, 1, fn clause, n ->
        markers = Regex.scan(~r/\?[WAB]/, clause) |> List.flatten() |> Enum.uniq()

        {text, next} =
          Enum.reduce(markers, {clause, n}, fn marker, {text, i} ->
            {String.replace(text, marker, "?#{i}"), i + 1}
          end)

        {text, next}
      end)

    where = if numbered == [], do: "", else: " WHERE " <> Enum.join(numbered, " AND ")
    {where, params}
  end

  # ── orphan phases ───────────────────────────────────────────────────────

  defp sweep(kind, cursor, state) do
    with {:ok, names} <- Projection.collections(kind) do
      names = Enum.drop_while(names, &(cursor["collection"] && &1 < cursor["collection"]))

      case names do
        [] -> {:ok, 0, %{}, :phase_done}
        [name | rest] -> sweep_page(kind, name, rest, cursor, state)
      end
    end
  end

  defp sweep_page(kind, name, rest, cursor, state) do
    offset = if cursor["collection"] == name, do: cursor["offset"], else: nil
    size = min(@page, state.budget)
    field = Projection.id_field(kind)

    body =
      %{limit: size, with_payload: [field, "workspace_id", "model"], with_vector: false}
      |> put_if(:offset, offset)
      |> Map.put(:filter, Projection.filter(if state.ws, do: %{workspace_id: state.ws}, else: %{}))

    case Projection.request(:post, "/collections/#{name}/points/scroll", body) do
      {:ok, 200, %{"result" => %{"points" => points} = result}} ->
        with {:ok, stale} <- stale_points(kind, Projection.dims(name), points),
             :ok <- Projection.delete_points(name, stale) do
          next =
            case {result["next_page_offset"], rest} do
              {nil, []} ->
                :phase_done

              {nil, [following | _]} ->
                %{"phase" => "orphans_#{kind}", "collection" => following}

              {offset, _} ->
                %{"phase" => "orphans_#{kind}", "collection" => name, "offset" => offset}
            end

          {:ok, length(points), %{deleted: length(stale)}, next}
        end

      {:ok, 404, _} ->
        next =
          case rest do
            [] -> :phase_done
            [following | _] -> %{"phase" => "orphans_#{kind}", "collection" => following}
          end

        {:ok, 0, %{}, next}

      other ->
        {:error, {:qdrant_unavailable, Projection.failure(other)}}
    end
  end

  # The point ids whose row is gone, or is in another workspace or of another
  # dimension than the collection's.
  defp stale_points(_kind, _dims, []), do: {:ok, []}

  defp stale_points(kind, dims, points) do
    field = Projection.id_field(kind)
    keys = Enum.map(points, &key_of(kind, &1, field))

    with {:ok, rows} <- Projection.rows_for_keys(kind, Enum.reject(keys, &is_nil/1)) do
      live =
        for [key, blob, _tenant, ws | extra] <- rows,
            is_binary(blob) and byte_size(blob) == dims * 4,
            into: MapSet.new(),
            do: {row_key(kind, key, extra), ws}

      stale =
        points
        |> Enum.zip(keys)
        |> Enum.reject(fn {point, key} ->
          key != nil and MapSet.member?(live, {key, get_in(point, ["payload", "workspace_id"])})
        end)
        |> Enum.map(fn {point, _key} -> point["id"] end)

      {:ok, stale}
    end
  end

  defp key_of(:memories, point, field) do
    case point["payload"] do
      %{^field => id, "model" => model} when is_binary(id) and is_binary(model) -> {id, model}
      _ -> nil
    end
  end

  defp key_of(_kind, point, field) do
    case get_in(point, ["payload", field]) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp row_key(:memories, memory_id, [model]), do: {memory_id, model}
  defp row_key(_kind, key, _extra), do: key

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
