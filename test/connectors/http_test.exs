defmodule OptimalEngine.Connectors.HTTPTest do
  @moduledoc """
  What `OptimalEngine.Connectors.HTTP` puts on the wire and what it keeps off
  it, against loopback servers. Nothing outside the machine is called.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.HTTP

  setup do
    original = Application.get_env(:optimal_engine, :http_mock)
    Application.delete_env(:optimal_engine, :http_mock)

    on_exit(fn ->
      if original, do: Application.put_env(:optimal_engine, :http_mock, original)
    end)

    :ok
  end

  describe "a redirect" do
    test "is followed by default" do
      origin =
        serve(fn
          "/", port -> redirect(302, "http://127.0.0.1:#{port}/elsewhere")
          _other, _port -> json("{\"ok\":true}")
        end)

      assert {:ok, %{status: 200}} = HTTP.get_json(origin.base <> "/")

      assert_received {:requested, _, "GET", "/", _}
      assert_received {:requested, _, "GET", "/elsewhere", _}
    end

    test "is handed back as the answer when told not to follow it" do
      origin =
        serve(fn
          "/", port -> redirect(302, "http://127.0.0.1:#{port}/elsewhere")
          _other, _port -> json("{\"ok\":true}")
        end)

      assert {:ok, %{status: 302, headers: headers}} =
               HTTP.get_json(origin.base <> "/", follow_redirects: false)

      assert {_, location} = Enum.find(headers, fn {name, _} -> name == "location" end)
      assert location == origin.base <> "/elsewhere"

      assert_received {:requested, _, "GET", "/", _}
      refute_received {:requested, _, _, "/elsewhere", _}
    end

    test "to another origin is not followed, so the request's headers reach no one else" do
      other = serve(fn _path, _port -> json("{\"ok\":true}") end)
      origin = serve(fn _path, _port -> redirect(302, other.base <> "/landed") end)

      assert {:ok, %{status: 302}} =
               HTTP.get_json(origin.base <> "/",
                 follow_redirects: false,
                 headers: [{"authorization", "Bearer example-token"}]
               )

      assert_received {:requested, _, "GET", "/", headers}
      assert {"authorization", "Bearer example-token"} in headers
      refute_received {:requested, _, _, "/landed", _}
    end

    test "a POST answered with a 303 is handed back, not replayed as a GET" do
      other = serve(fn _path, _port -> json("{\"ok\":true}") end)
      origin = serve(fn _path, _port -> redirect(303, other.base <> "/landed") end)

      assert {:ok, %{status: 303}} =
               HTTP.post_json(origin.base <> "/", %{"reference" => "example"},
                 follow_redirects: false
               )

      refute_received {:requested, _, _, "/landed", _}
    end
  end

  describe "a request body" do
    test "keeps the content type the caller named for a binary body" do
      origin = serve(fn _path, _port -> json("{\"ok\":true}") end)

      assert {:ok, %{status: 200}} =
               HTTP.request(origin.base <> "/token",
                 method: :post,
                 body: "grant_type=refresh_token&client_id=example",
                 headers: [{"content-type", "application/x-www-form-urlencoded"}]
               )

      assert_received {:requested, _, "POST", "/token", headers}
      assert {"content-type", "application/x-www-form-urlencoded"} in headers
      assert [_one] = Enum.filter(headers, fn {name, _} -> name == "content-type" end)
    end

    test "is octet-stream for a binary body with no type, and JSON for a map" do
      origin = serve(fn _path, _port -> json("{\"ok\":true}") end)

      HTTP.request(origin.base <> "/raw", method: :post, body: "raw")
      HTTP.post_json(origin.base <> "/json", %{"a" => 1})

      assert_received {:requested, _, "POST", "/raw", raw}
      assert {"content-type", "application/octet-stream"} in raw
      assert_received {:requested, _, "POST", "/json", json}
      assert {"content-type", "application/json"} in json
    end
  end

  describe "the answer" do
    test "is cut off at the size the caller allows" do
      origin = serve(fn _path, _port -> json(String.duplicate("a", 10_000)) end)

      assert {:error, :response_too_large} =
               HTTP.get_json(origin.base <> "/", max_body_bytes: 1_000, parse_json: false)

      assert {:ok, %{status: 200, body: body}} =
               HTTP.get_json(origin.base <> "/", max_body_bytes: 20_000, parse_json: false)

      assert byte_size(body) == 10_000
    end

    test "is read in full when the caller sets no limit" do
      origin = serve(fn _path, _port -> json(String.duplicate("a", 10_000)) end)

      assert {:ok, %{status: 200, body: body}} =
               HTTP.get_json(origin.base <> "/", parse_json: false)

      assert byte_size(body) == 10_000
    end
  end

  describe "a single attempt" do
    test "asks the server to close the connection, so there is no session to retry on" do
      origin = serve(fn _path, _port -> json("{\"ok\":true}") end)

      assert {:ok, %{status: 200}} = HTTP.get_json(origin.base <> "/", single_attempt: true)

      assert_received {:requested, _, "GET", "/", headers}
      assert {"connection", "close"} in headers
    end
  end

  describe "TLS" do
    test "is verified against the system's roots and the host name for https" do
      opts = HTTP.ssl_options("https://api.miosa.ai/x")

      assert opts[:verify] == :verify_peer
      assert Keyword.has_key?(opts, :customize_hostname_check)
      assert Keyword.has_key?(opts, :cacerts)
    end

    test "has no options for a plain URL" do
      assert HTTP.ssl_options("http://127.0.0.1/x") == []
    end
  end

  # ─── loopback servers ─────────────────────────────────────────────────────

  defp serve(handler) do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    pid = spawn_link(fn -> accept(listener, parent, port, handler) end)

    on_exit(fn ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    %{port: port, base: "http://127.0.0.1:#{port}"}
  end

  defp accept(listener, parent, port, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        answer(socket, parent, port, handler)
        :gen_tcp.close(socket)
        accept(listener, parent, port, handler)

      {:error, _closed} ->
        :ok
    end
  end

  defp answer(socket, parent, port, handler) do
    with {:ok, request} <- :gen_tcp.recv(socket, 0, 2_000),
         [head | _body] <- String.split(request, "\r\n\r\n", parts: 2),
         [line | header_lines] <- String.split(head, "\r\n"),
         [method, path | _rest] <- String.split(line, " ") do
      headers =
        Enum.flat_map(header_lines, fn header_line ->
          case String.split(header_line, ":", parts: 2) do
            [name, value] -> [{String.downcase(name), String.trim(value)}]
            _other -> []
          end
        end)

      send(parent, {:requested, port, method, path, headers})
      :gen_tcp.send(socket, handler.(path, port))
    end
  end

  defp redirect(status, location) do
    "HTTP/1.1 #{status} Redirect\r\nlocation: #{location}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  end

  defp json(body) do
    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <> body
  end
end
