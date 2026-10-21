defmodule OptimalEngine.API.UnparsedBodyTest do
  @moduledoc """
  A gzip or zip body is passed on unread (an import reads it itself), so Plug
  leaves `body_params` unfetched. A handler that reads a field of the body for
  a request like that finds none: it answers as it does for an empty body and
  never raises.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router

  @opts Router.init([])

  @routes [
    "/api/memory-core/active-pools",
    "/api/render/context",
    "/api/principals",
    "/api/entities/missing/merge",
    "/api/entity-mentions/missing/decision",
    "/api/review/routing/missing"
  ]

  for path <- @routes, type <- ["application/gzip", "application/zip"] do
    test "POST #{path} with a #{type} body answers, it does not fail" do
      conn =
        conn(:post, unquote(path), :zlib.gzip("{}"))
        |> put_req_header("content-type", unquote(type))
        |> Router.call(@opts)

      assert conn.status < 500, "answered #{conn.status}: #{conn.resp_body}"
    end
  end
end
