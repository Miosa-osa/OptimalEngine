defmodule OptimalEngine.API.Pagination do
  @moduledoc """
  Shared pagination helpers for the API router.

  All list endpoints parse `?offset=0&limit=50` from query params and wrap
  their responses in a standard pagination envelope.

  Limits:
    - `offset` is clamped to >= 0 (negative values treated as 0)
    - `limit`  is clamped to 1..200 (0 or negative → 1; >200 → 200)
    - a value outside the signed 64-bit range is refused with `400`
      (`OptimalEngine.API.IntParam`), not clamped
  """

  alias OptimalEngine.API.IntParam

  @max_limit 200
  @default_limit 50

  @doc """
  Parses offset and limit from a Plug.Conn's query params.

  Returns `{offset, limit}` with sensible bounds applied.
  """
  @spec parse(Plug.Conn.t()) :: {non_neg_integer(), pos_integer()}
  def parse(conn) do
    offset = get_param(conn, "offset", "0") |> parse_int(0) |> max(0)

    limit =
      get_param(conn, "limit", to_string(@default_limit))
      |> parse_int(@default_limit)
      |> clamp_limit()

    {offset, limit}
  end

  @doc """
  Parses offset and limit, using a custom default limit.
  """
  @spec parse(Plug.Conn.t(), pos_integer()) :: {non_neg_integer(), pos_integer()}
  def parse(conn, default_limit) do
    offset = get_param(conn, "offset", "0") |> parse_int(0) |> max(0)

    limit =
      get_param(conn, "limit", to_string(default_limit))
      |> parse_int(default_limit)
      |> clamp_limit()

    {offset, limit}
  end

  @doc """
  Wraps a list of items with a standard pagination envelope.

  The `:data` key holds the page of items. The `:pagination` map contains:
    - `offset`   — position of the first item in this page
    - `limit`    — maximum page size requested
    - `total`    — total number of matching records (from COUNT query)
    - `has_more` — true when items beyond this page exist

  `has_more` is `offset + length(items) < total` unless `:has_more` is given: a
  list read around what its reader may not see knows whether another item
  follows, whatever the total says.
  """
  @spec wrap([term()], non_neg_integer(), non_neg_integer(), pos_integer(), keyword()) :: map()
  def wrap(items, total, offset, limit, opts \\ []) do
    %{
      data: items,
      pagination: %{
        offset: offset,
        limit: limit,
        total: total,
        has_more: Keyword.get(opts, :has_more, offset + length(items) < total)
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_param(conn, key, default) do
    conn = Plug.Conn.fetch_query_params(conn)
    Map.get(conn.query_params, key, default)
  end

  defp parse_int(value, default), do: IntParam.parse(value, default, partial: true)

  defp clamp_limit(n) when n < 1, do: 1
  defp clamp_limit(n) when n > @max_limit, do: @max_limit
  defp clamp_limit(n), do: n
end
