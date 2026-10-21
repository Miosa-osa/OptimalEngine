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
    * a segment that decodes to a control byte or to text that is not UTF-8
      (`%00`, `%C0%AF`) is refused the same way;
    * otherwise `path_info` is replaced by its decoded segments, except that an
      escaped `/` (`%2F`) stays escaped: decoded, it would turn one segment into
      two wherever a plug joins the segments into a path or a resource string.
      With `%25` refused, decoding the segments again, as the router does,
      only turns `%2F` into `/` inside a segment, which cannot spell any
      route's literal, so every plug sees the route that is dispatched. An id
      that escapes a reserved character (`%3A` for `:`, as `encodeURIComponent`
      does) stays usable.

  `conn.request_path` stays as it was sent; the plugs that read it compare it
  with fixed paths, which an escape can only fail to match.
  """

  @behaviour Plug

  import Plug.Conn

  @escape ~r/%([0-9A-Fa-f]{2})/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    decoded = Enum.map(conn.path_info, &decode/1)

    if Enum.all?(conn.path_info, &acceptable?/1) and Enum.all?(decoded, &plain_text?/1) do
      %{conn | path_info: decoded}
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

  # Decodes every escape but `%2F`, which stays as `%2F`.
  defp decode(segment) do
    segment
    |> String.split(~r/%2F/i)
    |> Enum.map_join("%2F", &URI.decode/1)
  rescue
    ArgumentError -> segment
  end

  # Valid UTF-8 with no control byte.
  defp plain_text?(segment),
    do: String.valid?(segment) and not String.match?(segment, ~r/[\x00-\x1F\x7F]/)

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
