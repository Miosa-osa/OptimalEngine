defmodule OptimalEngine.Imports.FetchTest do
  @moduledoc """
  `OptimalEngine.Imports.Fetch` against real local HTTP and HTTPS servers:
  the allowlist, address checks, redirects only to allowed `https` hosts,
  certificate verification, the byte cap while streaming, and URLs that are
  never shown with their query string.
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

    assert {:error, {:download_failed, "connect: " <> _}} =
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
    assert {:error, {:download_failed, "http 404"}} =
             Fetch.download(ctx.http <> "/missing", dest(ctx), 1_000)
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
