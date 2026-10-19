defmodule OptimalEngine.Conformance.Transport.Plug do
  @moduledoc """
  Answers a conformance request with this node's own router, so the suite can
  be run against the Engine in process: real routes, real store, no socket and
  no second database. Test support only.
  """

  @behaviour OptimalEngine.Conformance.Transport

  @impl true
  def request(%{method: method, url: url, headers: headers, body: body}) do
    parsed = URI.parse(url)
    path = parsed.path <> if(parsed.query, do: "?" <> parsed.query, else: "")

    conn =
      method
      |> Plug.Test.conn(path, body || "")
      |> put_headers(headers)

    conn = OptimalEngine.API.Router.call(conn, OptimalEngine.API.Router.init([]))

    {:ok, %{status: conn.status, headers: conn.resp_headers, body: conn.resp_body}}
  rescue
    error -> {:error, error}
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
  end
end
