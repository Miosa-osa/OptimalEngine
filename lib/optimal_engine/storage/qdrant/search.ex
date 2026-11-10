defmodule OptimalEngine.Storage.Qdrant.Search do
  @moduledoc """
  Nearest neighbours from Qdrant, read back from SQLite before they count.

  `nearest/5` answers only when the projection is enabled, Qdrant is healthy,
  the workspace is not dirty from a failed mirror, and Qdrant holds exactly as
  many of this Engine's points in the searched scope as the embedded store
  holds searchable rows (`OptimalEngine.Storage.Qdrant.Projection.in_sync?/2`).
  The search itself is filtered to this Engine's points (`engine_id`).
  Otherwise, and on any error, it answers `:fallback` and the caller searches
  the embedded vectors as before.

  Qdrant only proposes candidates. Every page of candidates goes to the
  caller's `verify` function, which reads them from SQLite with the caller's
  own scope and filters (workspace, tenant, type, node, latest and not
  forgotten) and scores them with the caller's own similarity over the stored
  vector. So a result is in the same shape, passes the same filters, and has
  the same score as the embedded search would give it; a point whose row is
  gone or moved is dropped. Pages are read until `limit` candidates are
  verified or Qdrant has no more; a search whose filters reject so much that
  five pages do not fill it falls back to the embedded search rather than
  answer short.
  """

  alias OptimalEngine.Storage.Qdrant.Projection

  @max_pages 5
  @min_page 64

  @type verify :: ([String.t()] -> {:ok, [{String.t(), float()}]} | {:error, term()})

  @doc """
  The `limit` best verified results for `query` in `scope`, best first, ties
  by id, or `:fallback`. Options: `:limit` (default 10), `:min_similarity`
  (default 0.0; also passed to Qdrant as a slightly lower score threshold, the
  verified score decides).
  """
  @spec nearest(Projection.kind(), [float()], map(), keyword(), verify()) ::
          {:ok, [{String.t(), float()}]} | :fallback
  def nearest(kind, query, scope, opts, verify) when is_list(query) and query != [] do
    limit = Keyword.get(opts, :limit, 10)

    cond do
      limit < 1 ->
        :fallback

      not Projection.enabled?() ->
        :fallback

      not Projection.healthy?() ->
        fallback()

      not Projection.in_sync?(kind, scope) ->
        fallback()

      true ->
        search(kind, query, scope, limit, Keyword.get(opts, :min_similarity, 0.0), verify)
    end
  rescue
    _ -> fallback()
  end

  def nearest(_kind, _query, _scope, _opts, _verify), do: :fallback

  defp search(kind, query, scope, limit, min_similarity, verify) do
    page = max(limit * 4, @min_page)
    collection = Projection.collection(kind, length(query))

    body =
      %{
        vector: query,
        filter: Projection.filter(scope),
        limit: page,
        with_payload: [Projection.id_field(kind)],
        with_vector: false
      }
      |> put_threshold(min_similarity)

    case pages(kind, collection, body, page, verify, 0, %{}, limit) do
      {:ok, found} ->
        Projection.count(:searches_served, 1)

        {:ok,
         found
         |> Enum.sort_by(fn {id, score} -> {0.0 - score, id} end)
         |> Enum.take(limit)}

      :fallback ->
        fallback()
    end
  end

  defp pages(_kind, _collection, _body, _page, _verify, @max_pages, _found, _limit),
    do: :fallback

  defp pages(kind, collection, body, page, verify, n, found, limit) do
    case Projection.request(
           :post,
           "/collections/#{collection}/points/search",
           Map.put(body, :offset, n * page)
         ) do
      {:ok, 200, %{"result" => hits}} when is_list(hits) ->
        field = Projection.id_field(kind)
        ids = hits |> Enum.map(&get_in(&1, ["payload", field])) |> Enum.filter(&is_binary/1)

        with {:ok, verified} <- verify_ids(verify, ids) do
          found = Enum.into(verified, found)

          if map_size(found) >= limit or length(hits) < page,
            do: {:ok, Map.to_list(found)},
            else: pages(kind, collection, body, page, verify, n + 1, found, limit)
        end

      other ->
        Projection.mark_unhealthy(Projection.failure(other))
        :fallback
    end
  end

  defp verify_ids(_verify, []), do: {:ok, []}

  defp verify_ids(verify, ids) do
    case verify.(Enum.uniq(ids)) do
      {:ok, verified} when is_list(verified) -> {:ok, verified}
      _ -> :fallback
    end
  end

  # Qdrant's cosine is computed in float32 on normalised vectors; the threshold
  # is a little lower than asked so no candidate the exact score keeps is lost.
  defp put_threshold(body, min) when is_number(min) and min > 0.0,
    do: Map.put(body, :score_threshold, max(min - 1.0e-3, 0.0))

  defp put_threshold(body, _min), do: body

  defp fallback do
    Projection.count(:searches_fallback, 1)
    :fallback
  end
end
