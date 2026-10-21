defmodule OptimalEngine.API.PathPlug do
  @moduledoc """
  Gives every plug after it the path segments the router matches.

  `Plug.Router` matches the percent-decoded segments of a path, while a plug
  that reads `conn.path_info` sees them as they were sent. A path that spells
  a route with escapes (`/%61pi/auth/%6Beys` for `/api/auth/keys`) would then
  reach that route without the workspace, connector, permission and authority
  plugs recognising it. This plug runs first:

    * a path that escapes an unreserved character (a letter, a digit, `-`,
      `.`, `_` or `~`), escapes `%` itself (`%25`), or holds a `%` that does
      not start a two-digit hex escape is refused with `400 invalid_path`. No
      client needs one: an encoder escapes only reserved characters, and the
      first two are how a route's literal can be hidden from a plug;
    * otherwise `path_info` is replaced by its decoded segments. Decoding them
      again, as the router does, changes nothing, so every plug and the route
      see the same segments. An id that escapes a reserved character (`%3A`
      for `:`, `%2F` for `/`) stays usable.
  """

  @behaviour Plug

  import Plug.Conn

  @escape ~r/%([0-9A-Fa-f]{2})/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Enum.all?(conn.path_info, &acceptable?/1) do
      %{conn | path_info: Enum.map(conn.path_info, &URI.decode/1)}
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "invalid_path"}))
      |> halt()
    end
  end

  @doc "True when a raw path segment holds only escapes of reserved characters."
  @spec acceptable?(String.t()) :: boolean()
  def acceptable?(segment) do
    well_formed?(segment) and
      @escape
      |> Regex.scan(segment, capture: :all_but_first)
      |> Enum.all?(fn [hex] -> reserved?(String.to_integer(hex, 16)) end)
  end

  # Every `%` starts a two-digit hex escape.
  defp well_formed?(segment) do
    escapes = length(Regex.scan(@escape, segment))
    percents = segment |> :binary.matches("%") |> length()
    escapes == percents
  end

  defp reserved?(byte) when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9, do: false
  defp reserved?(byte) when byte in [?-, ?., ?_, ?~, ?%], do: false
  defp reserved?(_byte), do: true
end
