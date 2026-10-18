defmodule OptimalEngine.API.ReadAPI do
  @moduledoc """
  `GET /api/read`: one context by `optimal://` URI or by id, from the requested
  workspace only, at a chosen tier. Called from `OptimalEngine.API.Router`.

  Query parameters:

    * `uri` or `id` (one is required)
    * `workspace` (default `"default"`); `WorkspaceAuthPlug` has already
      authorized it, and a context in any other workspace is reported as
      not found
    * `tier`: `l0` (abstract), `l1` (overview, the default), or `full`
      (content)

  When the requested tier is empty for a context, the next fuller tier is
  served and named in `served_tier`. Reading never indexes files or changes
  the store; a URI the store does not hold is 404.
  """

  import Plug.Conn

  alias OptimalEngine.Store

  @tiers ~w(l0 l1 full)

  def read(conn) do
    conn = fetch_query_params(conn)
    q = conn.query_params
    workspace_id = q["workspace"] || "default"
    tier = q["tier"] || "l1"

    cond do
      tier not in @tiers -> error(conn, 400, "invalid_tier")
      present?(q["uri"]) -> respond(conn, lookup("uri", q["uri"], workspace_id), tier)
      present?(q["id"]) -> respond(conn, lookup("id", q["id"], workspace_id), tier)
      true -> error(conn, 400, "uri_or_id_required")
    end
  end

  defp lookup(column, value, workspace_id) when column in ["uri", "id"] do
    Store.raw_query(
      """
      SELECT id, uri, title, node, genre, signal_type, sn_ratio, modified_at,
             l0_abstract, l1_overview, content
      FROM contexts
      WHERE #{column} = ?1 AND workspace_id = ?2
      LIMIT 1
      """,
      [value, workspace_id]
    )
  end

  defp respond(conn, {:ok, [row]}, tier) do
    [id, uri, title, node, genre, type, sn_ratio, modified_at, l0, l1, content] = row
    {served, text} = at_tier(tier, %{"l0" => l0, "l1" => l1, "full" => content})

    json(conn, 200, %{
      id: id,
      uri: uri,
      title: title,
      node: node,
      genre: genre,
      type: type,
      sn_ratio: sn_ratio,
      modified_at: modified_at,
      tier: tier,
      served_tier: served,
      text: text
    })
  end

  defp respond(conn, {:ok, []}, _tier), do: error(conn, 404, "not_found")
  defp respond(conn, {:error, reason}, _tier), do: error(conn, 500, inspect(reason))

  # The requested tier, or the next fuller one when it is empty.
  defp at_tier(tier, texts) do
    @tiers
    |> Enum.drop_while(&(&1 != tier))
    |> Enum.find_value({tier, ""}, fn candidate ->
      if present?(texts[candidate]), do: {candidate, texts[candidate]}
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp error(conn, status, reason), do: json(conn, status, %{error: reason})

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
