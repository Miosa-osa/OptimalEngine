defmodule OptimalEngine.Imports.FetchTest do
  @moduledoc """
  `OptimalEngine.Imports.Fetch` against real local HTTP and HTTPS servers
  and raw sockets that misbehave on purpose: the allowlist, address checks
  (one resolution, every answer public), redirects only to allowed `https`
  hosts, certificate verification, the byte cap while streaming, the deadline
  and throughput floor, the fixed error vocabulary, and URLs that are never
  shown with their query string.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Imports.Fetch

  @moduletag :tmp_dir

  defmodule Server do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      conn = fetch_query_params(conn)

      case conn.request_path do
        "/export.zip" ->
          send_resp(conn, 200, opts[:body])

        "/chunked.zip" ->
          conn = send_chunked(conn, 200)

          opts[:body]
          |> :binary.bin_to_list()
          |> Enum.chunk_every(700)
          |> Enum.reduce(conn, fn piece, conn ->
            {:ok, conn} = chunk(conn, :binary.list_to_bin(piece))
            conn
          end)

        "/redirect" ->
          conn |> put_resp_header("location", conn.query_params["to"]) |> send_resp(302, "")

        "/loop" ->
          conn |> put_resp_header("location", "/loop") |> send_resp(302, "")

        _ ->
          send_resp(conn, 404, String.duplicate("not here ", 100))
      end
    end
  end

  setup do
    body = :crypto.strong_rand_bytes(5_000)
    n = System.unique_integer([:positive])

    http = :"fetch_http_#{n}"
    {:ok, _} = Plug.Cowboy.http(Server, [body: body], port: 0, ref: http)

    %{server_config: server, client_config: client} = tls_material()
    https = :"fetch_https_#{n}"

    {:ok, _} =
      Plug.Cowboy.https(Server, [body: body],
        port: 0,
        ref: https,
        cert: server[:cert],
        key: server[:key]
      )

    on_exit(fn ->
      Plug.Cowboy.shutdown(http)
      Plug.Cowboy.shutdown(https)
    end)

    put_env(:import_url_hosts, ["127.0.0.1", "localhost"])
    put_env(:import_url_cacerts, client[:cacerts])

    %{
      body: body,
      http: "http://127.0.0.1:#{:ranch.get_port(http)}",
      https: "https://localhost:#{:ranch.get_port(https)}"
    }
  end

  # A server certificate for "localhost", signed by a throwaway root the
  # client trusts through :import_url_cacerts.
  defp tls_material do
    extensions = [
      {:Extension, {2, 5, 29, 15}, false, [:digitalSignature, :keyEncipherment]},
      {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    ]

    rsa = [key: {:rsa, 2048, 65_537}, digest: :sha256]

    :public_key.pkix_test_data(%{
      server_chain: %{root: rsa, peer: [{:extensions, extensions} | rsa]},
      client_chain: %{root: rsa, peer: rsa}
    })
  end

  defp put_env(key, value) do
    previous = Application.get_env(:optimal_engine, key)
    Application.put_env(:optimal_engine, key, value)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:optimal_engine, key),
        else: Application.put_env(:optimal_engine, key, previous)
    end)
  end

  defp dest(ctx), do: Path.join(ctx.tmp_dir, "source-#{System.unique_integer([:positive])}.zip")

  # A plain TCP server on 127.0.0.1 that reads each request head and hands the
  # socket to `script`, for answers no well-behaved server gives.
  defp raw_server(script) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    spawn(fn -> serve(listen, script) end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    "http://127.0.0.1:#{port}"
  end

  defp serve(listen, script) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        read_head(socket, "")
        script.(socket)
        :gen_tcp.close(socket)
        serve(listen, script)

      {:error, _} ->
        :ok
    end
  end

  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_head(socket, buffer <> data)
        {:error, _} -> buffer
      end
    end
  end

  defp closed_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  test "downloads a sized and a chunked body to the file", ctx do
    for path <- ["/export.zip", "/chunked.zip"] do
      dest = dest(ctx)
      assert {:ok, 5_000} = Fetch.download(ctx.http <> path <> "?X-Signature=abc", dest, 1_000_000)
      assert File.read!(dest) == ctx.body
    end
  end

  test "verifies the server certificate over https", ctx do
    dest = dest(ctx)
    assert {:ok, 5_000} = Fetch.download(ctx.https <> "/export.zip", dest, 1_000_000)
    assert File.read!(dest) == ctx.body

    put_env(:import_url_cacerts, [])
    dest = dest(ctx)

    assert {:error, {:download_failed, "tls_failed"}} =
             Fetch.download(ctx.https <> "/export.zip", dest, 1_000_000)

    refute File.exists?(dest)
  end

  test "follows a redirect only to an allowed https host", ctx do
    to = fn target -> ctx.http <> "/redirect?" <> URI.encode_query(%{to: target}) end

    dest = dest(ctx)
    assert {:ok, 5_000} = Fetch.download(to.(ctx.https <> "/export.zip?sig=1"), dest, 1_000_000)
    assert File.read!(dest) == ctx.body

    assert {:error, :redirect_refused} =
             Fetch.download(to.(ctx.http <> "/export.zip"), dest(ctx), 1_000_000)

    assert {:error, :redirect_refused} =
             Fetch.download(to.("https://example.com/export.zip"), dest(ctx), 1_000_000)

    assert {:error, :redirect_refused} =
             Fetch.download(to.("ftp://localhost/x"), dest(ctx), 1_000_000)

    assert {:error, :too_many_redirects} =
             Fetch.download(ctx.https <> "/loop", dest(ctx), 1_000_000)
  end

  test "the cap holds while streaming, whatever the length header says", ctx do
    for path <- ["/export.zip", "/chunked.zip"] do
      dest = dest(ctx)
      assert {:error, :download_too_large} = Fetch.download(ctx.http <> path, dest, 1_000)
      refute File.exists?(dest)
    end
  end

  test "another status fails without reading its body", ctx do
    assert {:error, {:download_failed, "http_404"}} =
             Fetch.download(ctx.http <> "/missing", dest(ctx), 1_000)
  end

  test "a body with no length is capped while it streams, and read to the close", ctx do
    url =
      raw_server(fn socket ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
        Enum.each(1..5, fn _ -> :gen_tcp.send(socket, :binary.copy("z", 1_000)) end)
      end)

    dest = dest(ctx)
    assert {:error, :download_too_large} = Fetch.download(url <> "/export.zip", dest, 1_000)
    refute File.exists?(dest)

    dest = dest(ctx)
    assert {:ok, 5_000} = Fetch.download(url <> "/export.zip", dest, 1_000_000)
    assert File.read!(dest) == :binary.copy("z", 5_000)
    assert Bitwise.band(File.stat!(dest).mode, 0o777) == 0o600
  end

  test "every failure is a code from the fixed list, never a term from the request", ctx do
    secret = "X-Signature=s3cr3t#{System.unique_integer([:positive])}"

    garbage = raw_server(fn socket -> :gen_tcp.send(socket, "HELLO THERE\r\n\r\n") end)
    hangup = raw_server(fn _socket -> :ok end)

    short =
      raw_server(fn socket ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 5000\r\n\r\n")
        :gen_tcp.send(socket, :binary.copy("z", 100))
      end)

    nowhere = raw_server(fn socket -> :gen_tcp.send(socket, "HTTP/1.1 302 Found\r\n\r\n") end)

    for {url, code} <- [
          {"http://127.0.0.1:#{closed_port()}/export.zip", "connect_failed"},
          {garbage <> "/export.zip", "malformed_response"},
          {hangup <> "/export.zip", "connection_closed"},
          {short <> "/export.zip", "body_incomplete"},
          {nowhere <> "/export.zip", "redirect_without_location"},
          {ctx.http <> "/missing", "http_404"}
        ] do
      dest = dest(ctx)
      result = Fetch.download(url <> "?" <> secret, dest, 1_000_000)
      assert result == {:error, {:download_failed, code}}, url
      refute inspect(result) =~ "s3cr3t"
      refute File.exists?(dest)
    end
  end

  test "a download past its deadline or under the throughput floor is cut off", ctx do
    trickle =
      raw_server(fn socket ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n")

        Enum.reduce_while(1..1_000, :ok, fn _, :ok ->
          Process.sleep(50)
          if :gen_tcp.send(socket, "z") == :ok, do: {:cont, :ok}, else: {:halt, :ok}
        end)
      end)

    put_env(:import_min_bytes_per_second, 1_000)
    put_env(:import_min_rate_after_ms, 200)

    assert {:error, {:download_failed, "too_slow"}} =
             Fetch.download(trickle <> "/export.zip", dest(ctx), 1_000_000)

    stall =
      raw_server(fn socket ->
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n")
        Process.sleep(2_000)
      end)

    put_env(:import_min_bytes_per_second, 0)
    put_env(:import_fetch_deadline_ms, 300)
    started = System.monotonic_time(:millisecond)

    assert {:error, {:download_failed, "timeout"}} =
             Fetch.download(stall <> "/export.zip", dest(ctx), 1_000_000)

    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  test "the progress callback reports the bytes written while the body arrives", ctx do
    put_env(:import_fetch_progress_ms, 0)
    me = self()

    assert {:ok, 5_000} =
             Fetch.download(ctx.http <> "/chunked.zip", dest(ctx), 1_000_000,
               progress: fn bytes -> send(me, {:progress, bytes}) end
             )

    assert_received {:progress, bytes} when bytes > 0
  end

  test "public?/1 refuses every address that is not public unicast" do
    refused = [
      {0, 0, 0, 0},
      {10, 0, 0, 1},
      {100, 64, 0, 1},
      {100, 127, 255, 255},
      {127, 0, 0, 1},
      {169, 254, 169, 254},
      {172, 16, 0, 1},
      {172, 31, 255, 255},
      {192, 0, 0, 1},
      {192, 0, 2, 1},
      {192, 168, 1, 1},
      {198, 18, 0, 1},
      {198, 51, 100, 1},
      {203, 0, 113, 1},
      {224, 0, 0, 1},
      {255, 255, 255, 255},
      # ::, ::1 and ::10.0.0.1 (::/96)
      {0, 0, 0, 0, 0, 0, 0, 0},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0x0A00, 0x0001},
      # ::ffff:127.0.0.1 and ::ffff:169.254.169.254 (IPv4-mapped)
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE},
      # ::ffff:0:10.0.0.1 (IPv4-translated)
      {0, 0, 0, 0, 0xFFFF, 0, 0x0A00, 0x0001},
      # 64:ff9b::10.0.0.1 and 64:ff9b:1::1 (NAT64)
      {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001},
      {0x64, 0xFF9B, 1, 0, 0, 0, 0, 1},
      # 100::1 (discard), 2001::1 (Teredo), 2001:db8::1 (documentation)
      {0x100, 0, 0, 0, 0, 0, 0, 1},
      {0x2001, 0, 0, 0, 0, 0, 0, 1},
      {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
      # 2002:7f00:1:: (6to4 of 127.0.0.1)
      {0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0},
      # fd00::1 and fc00::1 (unique local), fe80::1, fec0::1, ff02::1
      {0xFD00, 0, 0, 0, 0, 0, 0, 1},
      {0xFC00, 0, 0, 0, 0, 0, 0, 1},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
      {0xFF02, 0, 0, 0, 0, 0, 0, 1}
    ]

    public = [
      {8, 8, 8, 8},
      {93, 184, 216, 34},
      {100, 63, 255, 255},
      {100, 128, 0, 1},
      {172, 32, 0, 1},
      {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111},
      {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808}
    ]

    for ip <- refused, do: refute(Fetch.public?(ip), "public: #{:inet.ntoa(ip)}")
    for ip <- public, do: assert(Fetch.public?(ip), "refused: #{:inet.ntoa(ip)}")
  end

  test "a host is resolved once and every address it resolves to must be public" do
    put_env(:import_url_hosts, [])

    put_env(:import_url_resolver, fn
      "files.example.test" -> [{93, 184, 216, 34}, {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}]
      "mixed.example.test" -> [{93, 184, 216, 34}, {10, 0, 0, 5}]
      "inside.example.test" -> [{10, 0, 0, 5}]
      "mapped.example.test" -> [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}]
      _ -> []
    end)

    assert :ok = Fetch.check("https://files.example.test/export.zip")
    assert {:error, :source_url_refused} = Fetch.check("https://mixed.example.test/export.zip")
    assert {:error, :source_url_refused} = Fetch.check("https://inside.example.test/export.zip")
    assert {:error, :source_url_refused} = Fetch.check("https://mapped.example.test/export.zip")
    assert {:error, :source_url_refused} = Fetch.check("https://unknown.example.test/export.zip")

    # localhost resolves to loopback through the real resolver.
    Application.delete_env(:optimal_engine, :import_url_resolver)
    assert {:error, :source_url_refused} = Fetch.check("https://localhost/export.zip")
  end

  test "a redirect to an internal address is refused", ctx do
    to = fn target -> ctx.http <> "/redirect?" <> URI.encode_query(%{to: target}) end

    for target <- [
          "https://10.0.0.5/export.zip",
          "https://169.254.169.254/latest/meta-data",
          "https://[::1]/export.zip",
          "http://127.0.0.1:1/export.zip"
        ] do
      assert {:error, :redirect_refused} = Fetch.download(to.(target), dest(ctx), 1_000_000), target
    end
  end

  test "allowed hosts are the only hosts when set; others must be public https" do
    put_env(:import_url_hosts, [])

    assert :ok = Fetch.check("https://93.184.216.34/export.zip")
    assert {:error, :source_url_refused} = Fetch.check("https://127.0.0.1/export.zip")
    assert {:error, :source_url_refused} = Fetch.check("https://10.0.0.8/export.zip")
    assert {:error, :source_url_refused} = Fetch.check("https://[::1]/export.zip")
    assert {:error, :source_url_refused} = Fetch.check("https://169.254.169.254/latest/meta-data")
    assert {:error, :invalid_source_url} = Fetch.check("http://93.184.216.34/export.zip")

    assert {:error, :invalid_source_url} =
             Fetch.check("https://user:secret@93.184.216.34/export.zip")

    assert {:error, :invalid_source_url} = Fetch.check("file:///etc/passwd")
    assert {:error, :invalid_source_url} = Fetch.check("/relative/export.zip")

    put_env(:import_url_hosts, ["storage.internal", "*.objects.example.net"])
    assert {:error, :source_url_refused} = Fetch.check("https://93.184.216.34/export.zip")
    assert Fetch.allowed_host?("bucket.objects.example.net")
    assert Fetch.allowed_host?("STORAGE.internal")
    refute Fetch.allowed_host?("objects.example.net")
    refute Fetch.allowed_host?("storage.internal.evil.example")
  end

  test "a URL is shown only as scheme, host and path" do
    url =
      "https://bucket.s3.example.com:8443/exports/notion.zip?X-Amz-Signature=deadbeef&X-Amz-Credential=key"

    assert Fetch.redact(url) == "https://bucket.s3.example.com:8443/exports/notion.zip"

    assert Fetch.redact("https://user:pw@example.com/a.zip?sig=1#frag") ==
             "https://example.com/a.zip"

    assert Fetch.redact("not a url") == "[url]"

    text = "failed to fetch #{url} after 3 tries"

    assert Fetch.scrub(text) ==
             "failed to fetch https://bucket.s3.example.com:8443/exports/notion.zip after 3 tries"
  end
end
