defmodule OptimalEngine.Connectors.HTTP.SingleAttemptTest do
  @moduledoc """
  The client that sends a request once and never again, against loopback
  servers. Nothing outside the machine is called.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Connectors.HTTP.SingleAttempt

  describe "the request" do
    test "is written once, with the headers the client owns and the caller's" do
      origin = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"))

      assert {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, _headers, "ok"}} =
               SingleAttempt.request(
                 :post,
                 origin.url <> "/a/b?x=1",
                 [{"accept", "application/json"}],
                 "application/json",
                 ~s({"a":1})
               )

      assert_received {:request, raw}
      [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
      lines = String.split(head, "\r\n")

      assert hd(lines) == "POST /a/b?x=1 HTTP/1.1"
      assert "host: 127.0.0.1:#{origin.port}" in lines
      assert "connection: close" in lines
      assert "content-length: 7" in lines
      assert "content-type: application/json" in lines
      assert "accept: application/json" in lines
      assert body == ~s({"a":1})
      assert_received :connection
      refute_received :connection
    end

    test "a GET carries no body headers" do
      origin = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"))

      assert {:ok, {{_v, 200, _r}, _h, ""}} =
               SingleAttempt.request(:get, origin.url, [], "application/json", "")

      assert_received {:request, raw}
      assert String.starts_with?(raw, "GET / HTTP/1.1\r\n")
      refute raw =~ "content-length"
      refute raw =~ "content-type"
    end

    test "a header that could split the request is refused before anything is sent" do
      origin = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"))
      url = origin.url

      for headers <- [
            [{"x-a", "1\r\nx-evil: 1"}],
            [{"x-a", "1\nx-evil: 1"}],
            [{"x-a", <<"1", 0, "2">>}],
            [{"x a", "1"}],
            [{"x-a:", "1"}],
            [{"", "1"}],
            [{"Host", "evil.example"}],
            [{"Content-Length", "0"}],
            [{"connection", "keep-alive"}],
            [{"Transfer-Encoding", "chunked"}]
          ] do
        assert {:error, :invalid_header} = SingleAttempt.request(:get, url, headers, nil, ""),
               "accepted #{inspect(headers)}"
      end

      assert {:error, :invalid_header} =
               SingleAttempt.request(:post, url, [], "text/plain\r\nx-evil: 1", "")

      refute_receive :connection, 100
    end

    test "a URL that is not a plain http or https one is refused" do
      for url <- [
            "ftp://127.0.0.1/",
            "http://user:secret@127.0.0.1/",
            "http:///path",
            "127.0.0.1/path",
            "http://127.0.0.1/a b",
            "http://127.0.0.1/\r\nx: 1"
          ] do
        assert {:error, :invalid_url} = SingleAttempt.request(:get, url, [], nil, ""),
               "accepted #{inspect(url)}"
      end
    end

    test "a refused connection is an error, not a retry" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      :gen_tcp.close(listener)

      assert {:error, {:failed_connect, :econnrefused}} =
               SingleAttempt.request(:get, "http://127.0.0.1:#{port}/", [], nil, "")
    end
  end

  describe "an answer that asks to be sent again" do
    test "a 503 with a Retry-After is handed back and the POST is not repeated" do
      origin =
        serve(
          respond("HTTP/1.1 503 Service Unavailable\r\nretry-after: 1\r\ncontent-length: 0\r\n\r\n")
        )

      assert {:ok, {{_v, 503, ~c"Service Unavailable"}, headers, ""}} =
               SingleAttempt.request(:post, origin.url, [], "text/plain", "x", timeout: 3_000)

      assert {"retry-after", "1"} in headers
      assert_received {:request, _raw}
      refute_receive {:request, _}, 1_800
      assert_received :connection
      refute_received :connection
    end

    test "a redirect is handed back and not followed" do
      origin =
        serve(
          respond(
            "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:9/elsewhere\r\ncontent-length: 0\r\n\r\n"
          )
        )

      assert {:ok, {{_v, 302, _r}, headers, ""}} =
               SingleAttempt.request(:get, origin.url, [], nil, "")

      assert {"location", "http://127.0.0.1:9/elsewhere"} in headers
      assert_received {:request, _raw}
      refute_receive {:request, _}, 200
    end

    test "a 100 Continue before the answer is set aside" do
      origin =
        serve(
          respond("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\ncontent-length: 1\r\n\r\nx")
        )

      assert {:ok, {{_v, 201, _r}, _h, "x"}} =
               SingleAttempt.request(:post, origin.url, [], "text/plain", "y")
    end
  end

  describe "the answer" do
    test "is read to its content-length" do
      origin = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello trailing"))

      assert {:ok, {{_v, 200, _r}, _h, "hello"}} =
               SingleAttempt.request(:get, origin.url, [], nil, "")
    end

    test "is read when it arrives in pieces" do
      origin =
        serve(fn socket ->
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-le")
          Process.sleep(20)
          :gen_tcp.send(socket, "ngth: 6\r\n\r\nabc")
          Process.sleep(20)
          :gen_tcp.send(socket, "def")
        end)

      assert {:ok, {{_v, 200, _r}, _h, "abcdef"}} =
               SingleAttempt.request(:get, origin.url, [], nil, "")
    end

    test "is read chunked, with extensions and trailers" do
      origin =
        serve(
          respond(
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n" <>
              "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nx-trailer: 1\r\n\r\n"
          )
        )

      assert {:ok, {{_v, 200, _r}, _h, "hello world"}} =
               SingleAttempt.request(:get, origin.url, [], nil, "")
    end

    test "is read to the close when it names no length" do
      origin = serve(respond("HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nuntil the end"))

      assert {:ok, {{_v, 200, _r}, _h, "until the end"}} =
               SingleAttempt.request(:get, origin.url, [], nil, "")
    end

    test "has no body for a HEAD, a 204 or a 304" do
      head = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 50\r\n\r\n"))
      no_content = serve(respond("HTTP/1.1 204 No Content\r\n\r\n"))
      not_modified = serve(respond("HTTP/1.1 304 Not Modified\r\ncontent-length: 9\r\n\r\n"))

      assert {:ok, {{_v, 200, _r}, _h, ""}} = SingleAttempt.request(:head, head.url, [], nil, "")

      assert {:ok, {{_v, 204, _r}, _h, ""}} =
               SingleAttempt.request(:get, no_content.url, [], nil, "")

      assert {:ok, {{_v, 304, _r}, _h, ""}} =
               SingleAttempt.request(:get, not_modified.url, [], nil, "")
    end

    test "a body shorter than its content-length is an error, never a short success" do
      origin = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nabc"))

      assert {:error, :closed} = SingleAttempt.request(:get, origin.url, [], nil, "")
    end

    test "a chunked body that stops early is an error" do
      origin =
        serve(respond("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n"))

      assert {:error, :closed} = SingleAttempt.request(:get, origin.url, [], nil, "")
    end

    test "a chunk with the wrong framing is refused" do
      origin =
        serve(respond("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhelloXX0\r\n\r\n"))

      assert {:error, :invalid_response} = SingleAttempt.request(:get, origin.url, [], nil, "")
    end

    test "an answer that is not HTTP is refused" do
      for garbage <- [
            "SMTP ready\r\n\r\n",
            "HTTP/2 200\r\n\r\n",
            "HTTP/1.1 20 OK\r\n\r\n",
            "HTTP/1.1 200 OK\r\nbad header\r\n\r\n",
            "HTTP/1.1 101 Switching Protocols\r\n\r\n"
          ] do
        origin = serve(respond(garbage))

        assert {:error, :invalid_response} =
                 SingleAttempt.request(:get, origin.url, [], nil, ""),
               "accepted #{inspect(garbage)}"
      end
    end

    test "framing the client cannot trust is refused" do
      for framing <- [
            "content-length: 3\r\ncontent-length: 4\r\n",
            "content-length: -1\r\n",
            "content-length: 3x\r\n",
            "transfer-encoding: gzip, chunked\r\n",
            "transfer-encoding: identity\r\n"
          ] do
        origin = serve(respond("HTTP/1.1 200 OK\r\n" <> framing <> "\r\nabc"))

        assert {:error, :invalid_response} =
                 SingleAttempt.request(:get, origin.url, [], nil, ""),
               "accepted #{inspect(framing)}"
      end
    end

    test "agreeing content-lengths are accepted" do
      origin = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 3, 3\r\n\r\nabc"))

      assert {:ok, {{_v, 200, _r}, _h, "abc"}} =
               SingleAttempt.request(:get, origin.url, [], nil, "")
    end
  end

  describe "the size cap" do
    test "a content-length over it fails before the body is read" do
      origin = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 2000\r\n\r\n"))

      assert {:error, :response_too_large} =
               SingleAttempt.request(:get, origin.url, [], nil, "", max_body_bytes: 1_000)
    end

    test "a chunked body over it fails" do
      origin =
        serve(
          respond(
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n#{chunk(600)}#{chunk(600)}0\r\n\r\n"
          )
        )

      assert {:error, :response_too_large} =
               SingleAttempt.request(:get, origin.url, [], nil, "", max_body_bytes: 1_000)
    end

    test "a body without a length that runs over it fails" do
      origin =
        serve(
          respond("HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n" <> String.duplicate("a", 2_000))
        )

      assert {:error, :response_too_large} =
               SingleAttempt.request(:get, origin.url, [], nil, "", max_body_bytes: 1_000)
    end

    test "a body at the cap is read" do
      body = String.duplicate("a", 1_000)
      origin = serve(respond("HTTP/1.1 200 OK\r\ncontent-length: 1000\r\n\r\n" <> body))

      assert {:ok, {{_v, 200, _r}, _h, ^body}} =
               SingleAttempt.request(:get, origin.url, [], nil, "", max_body_bytes: 1_000)
    end

    test "an answer headed by more than the head limit is refused" do
      origin = serve(respond("HTTP/1.1 200 OK\r\nx-a: " <> String.duplicate("a", 70_000)))

      assert {:error, :invalid_response} = SingleAttempt.request(:get, origin.url, [], nil, "")
    end
  end

  describe "the deadline" do
    test "bounds the whole call when the server stalls" do
      origin = serve(fn _socket -> Process.sleep(2_000) end)
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               SingleAttempt.request(:get, origin.url, [], nil, "", timeout: 200)

      assert System.monotonic_time(:millisecond) - started < 1_500
    end

    test "bounds a server that trickles its answer" do
      origin =
        serve(fn socket ->
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n")

          for _ <- 1..50 do
            :gen_tcp.send(socket, "a")
            Process.sleep(40)
          end
        end)

      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               SingleAttempt.request(:get, origin.url, [], nil, "", timeout: 300)

      assert System.monotonic_time(:millisecond) - started < 1_500
    end
  end

  describe "TLS" do
    test "a certificate the system's roots do not vouch for is refused before any request" do
      %{server_config: server_config} =
        :public_key.pkix_test_data(%{
          server_chain: %{root: [], peer: []},
          client_chain: %{root: [], peer: []}
        })

      parent = self()

      {:ok, listener} =
        :ssl.listen(0, server_config ++ [mode: :binary, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, {_ip, port}} = :ssl.sockname(listener)

      pid =
        spawn_link(fn ->
          with {:ok, socket} <- :ssl.transport_accept(listener, 5_000),
               {:ok, socket} <- :ssl.handshake(socket, 5_000),
               {:ok, data} <- :ssl.recv(socket, 0, 1_000) do
            send(parent, {:tls_request, data})
          end
        end)

      on_exit(fn ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        :ssl.close(listener)
      end)

      assert {:error, {:failed_connect, _reason}} =
               SingleAttempt.request(:get, "https://127.0.0.1:#{port}/", [], nil, "",
                 timeout: 3_000
               )

      refute_receive {:tls_request, _}, 300
    end
  end

  # ─── loopback server ──────────────────────────────────────────────────────

  defp chunk(size),
    do: Integer.to_string(size, 16) <> "\r\n" <> String.duplicate("a", size) <> "\r\n"

  defp respond(data), do: fn socket -> :gen_tcp.send(socket, data) end

  # Accepts one connection at a time, reads the whole request, tells the test
  # about the connection and the request, and lets `script` answer on the socket.
  defp serve(script) do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    pid = spawn_link(fn -> accept(listener, parent, script) end)

    on_exit(fn ->
      Process.unlink(pid)
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    %{port: port, url: "http://127.0.0.1:#{port}"}
  end

  defp accept(listener, parent, script) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        send(parent, :connection)

        with {:ok, raw} <- read_request(socket, "") do
          send(parent, {:request, raw})
          script.(socket)
        end

        :gen_tcp.close(socket)
        accept(listener, parent, script)

      {:error, _closed} ->
        :ok
    end
  end

  defp read_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_whole, digits] -> String.to_integer(digits)
            nil -> 0
          end

        read_body(socket, head, rest, length)

      [_incomplete] ->
        with {:ok, data} <- :gen_tcp.recv(socket, 0, 2_000),
             do: read_request(socket, buffer <> data)
    end
  end

  defp read_body(socket, head, rest, length) do
    if byte_size(rest) >= length do
      {:ok, head <> "\r\n\r\n" <> rest}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 2_000),
           do: read_body(socket, head, rest <> data, length)
    end
  end
end
