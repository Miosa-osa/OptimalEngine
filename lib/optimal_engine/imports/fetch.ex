defmodule OptimalEngine.Imports.Fetch do
  @moduledoc """
  Downloads an import source named by URL to a file, under a byte cap,
  without trusting the URL or the server.

  The Engine fetches the URL itself, so every URL is checked before it is
  requested:

    * `https`, with the server's certificate and host name verified; plain
      `http` only to an allowed host
    * when allowed hosts are configured, only those hosts; an entry is a host
      name or `*.` and a domain (`*.storage.example.com`)
    * the host must resolve only to public addresses (loopback, private,
      link-local, shared, multicast and reserved ranges are refused) unless
      it is an allowed host
    * the connection goes to the address that was checked, so a second DNS
      answer cannot move it
    * a redirect is followed only to an allowed `https` host, checked the same
      way, at most five times

  Allowed hosts come from `config :optimal_engine, :import_url_hosts` and the
  `OPTIMAL_IMPORT_URL_HOSTS` environment variable (comma-separated). Extra
  trusted certificate authorities (a private CA in front of internal object
  storage) come from `config :optimal_engine, :import_url_cacerts` (DER
  certificates) or `OPTIMAL_IMPORT_CA_FILE` (a PEM file).

  The body of a `200` answer is written to an owner-only file as it arrives,
  never held whole in memory, and the transfer stops the moment it passes the
  cap: `Content-Length` only lets an oversized answer fail early, it is not
  trusted. The body of any other answer is never read. A download that runs
  past 30 minutes, or averages under 16 KiB/s after its first minute, is cut
  off (`config :optimal_engine, :import_fetch_deadline_ms`,
  `:import_min_bytes_per_second`, `:import_min_rate_after_ms`).

  A URL is never logged, stored or returned by this module, and neither is any
  term derived from the request: a failure is `{:download_failed, code}` with
  a code from a fixed list (`connect_failed`, `tls_failed`, `timeout`,
  `too_slow`, `send_failed`, `receive_failed`, `connection_closed`,
  `malformed_response`, `body_incomplete`, `redirect_without_location`,
  `unresolvable`, `http_<status>`). `redact/1` gives the `scheme://host/path`
  form that may be shown; a presigned URL's signature lives in its query
  string, which it drops.
  """

  import Bitwise

  @max_redirects 5
  @connect_timeout_ms 15_000
  @recv_timeout_ms 60_000
  @default_deadline_ms 1_800_000
  @default_min_bytes_per_second 16_384
  @default_min_rate_after_ms 60_000
  @progress_ms 5_000
  @max_head_bytes 65_536
  @max_headers 100
  @max_chunk_line 1_024

  @type reason ::
          :invalid_source_url
          | :source_url_refused
          | :redirect_refused
          | :too_many_redirects
          | :download_too_large
          | {:download_failed, String.t()}

  @doc """
  Checks a source URL without fetching it: `:ok`, `{:error,
  :invalid_source_url}` for a URL that is not absolute `https` (or `http` to
  an allowed host) or carries credentials, or `{:error, :source_url_refused}`
  for a host that is not allowed, does not resolve, or resolves to a
  non-public address.
  """
  @spec check(String.t()) :: :ok | {:error, :invalid_source_url | :source_url_refused}
  def check(url) when is_binary(url) do
    case target(url, :initial) do
      {:ok, _target} -> :ok
      {:error, :unresolvable} -> {:error, :source_url_refused}
      {:error, reason} -> {:error, reason}
    end
  end

  def check(_url), do: {:error, :invalid_source_url}

  @doc """
  Downloads `url` to `dest`, refusing more than `max_bytes`. Returns
  `{:ok, bytes}` or `{:error, reason}` (see `t:reason/0`); on an error the
  file is removed.

  Options: `:progress`, a function called with the bytes written so far, at
  most every five seconds while the body arrives (a job extends its lease
  with it; `config :optimal_engine, :import_fetch_progress_ms`).
  """
  @spec download(String.t(), Path.t(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def download(url, dest, max_bytes, opts \\ []) do
    now = System.monotonic_time(:millisecond)

    clock = %{
      started: now,
      deadline: now + setting(:import_fetch_deadline_ms, @default_deadline_ms),
      min_rate: setting(:import_min_bytes_per_second, @default_min_bytes_per_second),
      grace_ms: setting(:import_min_rate_after_ms, @default_min_rate_after_ms),
      progress: Keyword.get(opts, :progress, fn _bytes -> :ok end),
      progress_ms: setting(:import_fetch_progress_ms, @progress_ms)
    }

    result =
      with {:ok, _} <- Application.ensure_all_started(:ssl),
           {:ok, target} <- target(url, :initial) do
        follow(target, dest, max_bytes, clock, @max_redirects)
      end

    case result do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, :unresolvable} ->
        File.rm(dest)
        {:error, {:download_failed, "unresolvable"}}

      {:error, reason} ->
        File.rm(dest)
        {:error, reason}
    end
  end

  @doc """
  The form of a URL that may be logged, stored or shown:
  `scheme://host[:port]/path`, without user info, query or fragment.
  """
  @spec redact(String.t()) :: String.t()
  def redact(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        port = if uri.port && uri.port != URI.default_port(scheme), do: ":#{uri.port}", else: ""
        "#{scheme}://#{host}#{port}#{uri.path}"

      _ ->
        "[url]"
    end
  end

  def redact(_url), do: "[url]"

  @doc "Drops the query string and user info of every URL inside `text`."
  @spec scrub(String.t()) :: String.t()
  def scrub(text) when is_binary(text) do
    Regex.replace(~r{[a-z][a-z0-9+.-]*://[^\s"'<>]+}i, text, &redact/1)
  end

  @doc "True when `host` is an allowed host (`:import_url_hosts`, `OPTIMAL_IMPORT_URL_HOSTS`)."
  @spec allowed_host?(String.t()) :: boolean()
  def allowed_host?(host) when is_binary(host) do
    host = String.downcase(host)

    Enum.any?(allowed_hosts(), fn
      "*." <> domain -> String.ends_with?(host, "." <> domain)
      entry -> entry == host
    end)
  end

  @doc "True for a public unicast address."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({a, b, c, _d}) do
    not (a == 0 or a == 10 or a == 127 or a >= 224 or
           (a == 100 and b >= 64 and b <= 127) or
           (a == 169 and b == 254) or
           (a == 172 and b >= 16 and b <= 31) or
           (a == 192 and b == 168) or
           (a == 192 and b == 0 and c in [0, 2]) or
           (a == 198 and (b == 18 or b == 19)) or
           (a == 198 and b == 51 and c == 100) or
           (a == 203 and b == 0 and c == 113))
  end

  def public?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: public?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})

  # IPv6: unspecified, loopback and IPv4-compatible (::/96), IPv4-translated
  # (::ffff:0:0:0/96), NAT64 (64:ff9b::/96, 64:ff9b:1::/48), discard
  # (100::/64), Teredo (2001::/32),
  # documentation (2001:db8::/32), 6to4 (2002::/16), unique local (fc00::/7),
  # link-local (fe80::/10), site-local (fec0::/10) and multicast (ff00::/8)
  # embed or reach addresses that are not public.
  def public?({first, second, third, fourth, _, _, _, _} = ip) do
    not (match?({0, 0, 0, 0, 0, 0, _, _}, ip) or
           match?({0, 0, 0, 0, 0xFFFF, 0, _, _}, ip) or
           (first == 0x64 and second == 0xFF9B and (third == 0 or third == 1)) or
           (first == 0x100 and second == 0 and third == 0 and fourth == 0) or
           (first == 0x2001 and (second == 0 or second == 0x0DB8)) or
           first == 0x2002 or
           (first &&& 0xFE00) == 0xFC00 or
           (first &&& 0xFFC0) == 0xFE80 or
           (first &&& 0xFFC0) == 0xFEC0 or
           (first &&& 0xFF00) == 0xFF00)
  end

  # ── checking a URL ─────────────────────────────────────────────────────

  defp target(url, kind) do
    uri = URI.parse(url)
    host = if is_binary(uri.host), do: String.downcase(uri.host), else: ""
    allowed = host != "" and allowed_host?(host)

    cond do
      uri.scheme not in ["https", "http"] or host == "" or uri.userinfo != nil ->
        if kind == :redirect, do: {:error, :redirect_refused}, else: {:error, :invalid_source_url}

      kind == :redirect and not (uri.scheme == "https" and allowed) ->
        {:error, :redirect_refused}

      uri.scheme == "http" and not allowed ->
        {:error, :invalid_source_url}

      allowed_hosts() != [] and not allowed ->
        {:error, :source_url_refused}

      true ->
        resolve(uri, host, allowed)
    end
  rescue
    _ in [URI.Error, ArgumentError] ->
      if kind == :redirect, do: {:error, :redirect_refused}, else: {:error, :invalid_source_url}
  end

  defp resolve(uri, host, allowed) do
    case addresses(host) do
      [] ->
        {:error, :unresolvable}

      ips ->
        if allowed or Enum.all?(ips, &public?/1) do
          {:ok,
           %{
             uri: uri,
             host: host,
             scheme: uri.scheme,
             port: uri.port || URI.default_port(uri.scheme),
             ips: ips
           }}
        else
          {:error, :source_url_refused}
        end
    end
  end

  # A test can stand in for DNS with `config :optimal_engine,
  # :import_url_resolver, fn host -> [ip] end`.
  defp addresses(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        [ip]

      {:error, _} ->
        case Application.get_env(:optimal_engine, :import_url_resolver) do
          resolve when is_function(resolve, 1) ->
            resolve.(host)

          _ ->
            for family <- [:inet, :inet6],
                {:ok, ips} <- [:inet.getaddrs(charlist, family)],
                ip <- ips,
                do: ip
        end
    end
  end

  defp setting(key, default) do
    case Application.get_env(:optimal_engine, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  end

  defp allowed_hosts do
    configured = Application.get_env(:optimal_engine, :import_url_hosts, [])

    from_env =
      "OPTIMAL_IMPORT_URL_HOSTS"
      |> System.get_env("")
      |> String.split(",", trim: true)

    (List.wrap(configured) ++ from_env)
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  # ── fetching ───────────────────────────────────────────────────────────

  defp follow(target, dest, max_bytes, clock, hops) do
    case get(target, dest, max_bytes, clock) do
      {:redirect, _location} when hops == 0 ->
        {:error, :too_many_redirects}

      {:redirect, location} ->
        next =
          try do
            target.uri |> URI.merge(location) |> URI.to_string()
          rescue
            _ -> nil
          end

        with next when is_binary(next) <- next || {:error, :redirect_refused},
             {:ok, next_target} <- target(next, :redirect) do
          follow(next_target, dest, max_bytes, clock, hops - 1)
        end

      other ->
        other
    end
  end

  defp get(target, dest, max_bytes, clock) do
    with {:ok, socket} <- connect(target) do
      conn = Map.merge(clock, %{socket: socket, scheme: target.scheme})

      try do
        with :ok <- send_data(conn, request(target)),
             {:ok, status, headers, rest} <- read_head(conn) do
          respond(conn, status, headers, rest, dest, max_bytes)
        end
      after
        close(conn)
      end
    end
  end

  defp respond(conn, 200, headers, rest, dest, max_bytes) do
    {:ok, out} = File.open(dest, [:write, :binary, :raw])
    :ok = File.chmod(dest, 0o600)
    Process.put(:import_fetch_progress_at, System.monotonic_time(:millisecond))

    try do
      body(conn, headers, rest, out, max_bytes)
    after
      File.close(out)
    end
  end

  defp respond(_conn, status, headers, _rest, _dest, _max)
       when status in [301, 302, 303, 307, 308] do
    case header(headers, "location") do
      nil -> {:error, {:download_failed, "redirect_without_location"}}
      location -> {:redirect, location}
    end
  end

  defp respond(_conn, status, _headers, _rest, _dest, _max),
    do: {:error, {:download_failed, "http_#{status}"}}

  defp request(target) do
    path = if target.uri.path in [nil, ""], do: "/", else: target.uri.path
    path = if target.uri.query, do: path <> "?" <> target.uri.query, else: path

    host =
      if target.port == URI.default_port(target.scheme),
        do: host_header(target.host),
        else: "#{host_header(target.host)}:#{target.port}"

    "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nUser-Agent: OptimalEngine-Import\r\n" <>
      "Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
  end

  defp host_header(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  # ── the connection ─────────────────────────────────────────────────────

  # The next address is tried only when this one could not be reached; a
  # server that answered and failed the TLS handshake fails the download.
  defp connect(target) do
    Enum.reduce_while(target.ips, {:error, {:download_failed, "connect_failed"}}, fn ip, _acc ->
      case open(target, ip) do
        {:ok, socket} ->
          {:halt, {:ok, socket}}

        {:error, reason} ->
          error = {:error, {:download_failed, connect_code(reason)}}
          if unreachable?(reason), do: {:cont, error}, else: {:halt, error}
      end
    end)
  end

  defp connect_code(reason) when reason in [:timeout, :etimedout], do: "timeout"
  defp connect_code({:tls_alert, _}), do: "tls_failed"
  defp connect_code({:options, _}), do: "tls_failed"
  defp connect_code(_reason), do: "connect_failed"

  defp unreachable?(reason),
    do: reason in [:econnrefused, :ehostunreach, :enetunreach, :etimedout, :timeout, :eaddrnotavail]

  defp open(%{scheme: "https"} = target, ip) do
    :ssl.connect(ip, target.port, ssl_opts(target), @connect_timeout_ms)
  end

  defp open(target, ip) do
    :gen_tcp.connect(ip, target.port, [:binary, active: false, packet: :raw], @connect_timeout_ms)
  end

  defp ssl_opts(target) do
    sni =
      case :inet.parse_address(String.to_charlist(target.host)) do
        {:ok, _ip} -> []
        {:error, _} -> [server_name_indication: String.to_charlist(target.host)]
      end

    [
      :binary,
      active: false,
      packet: :raw,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get() ++ extra_cacerts(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ sni
  end

  defp extra_cacerts do
    configured = Application.get_env(:optimal_engine, :import_url_cacerts, [])

    from_file =
      case System.get_env("OPTIMAL_IMPORT_CA_FILE") do
        path when is_binary(path) and path != "" ->
          case File.read(path) do
            {:ok, pem} -> for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
            {:error, _} -> []
          end

        _ ->
          []
      end

    List.wrap(configured) ++ from_file
  end

  defp send_data(%{scheme: "https", socket: socket}, data) do
    case :ssl.send(socket, data) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:download_failed, "send_failed"}}
    end
  end

  defp send_data(%{socket: socket}, data) do
    case :gen_tcp.send(socket, data) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:download_failed, "send_failed"}}
    end
  end

  defp recv(conn) do
    timeout = min(@recv_timeout_ms, conn.deadline - System.monotonic_time(:millisecond))

    if timeout <= 0 do
      {:error, {:download_failed, "timeout"}}
    else
      result =
        case conn.scheme do
          "https" -> :ssl.recv(conn.socket, 0, timeout)
          _ -> :gen_tcp.recv(conn.socket, 0, timeout)
        end

      case result do
        {:ok, data} -> {:ok, data}
        {:error, :closed} -> :closed
        {:error, :timeout} -> {:error, {:download_failed, "timeout"}}
        {:error, _reason} -> {:error, {:download_failed, "receive_failed"}}
      end
    end
  end

  defp close(%{scheme: "https", socket: socket}), do: :ssl.close(socket)
  defp close(%{socket: socket}), do: :gen_tcp.close(socket)

  # ── the response head ──────────────────────────────────────────────────

  defp read_head(conn, buffer \\ <<>>) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:ok, {:http_response, _version, status, _reason}, rest} ->
        read_headers(conn, rest, status, [], byte_size(buffer) - byte_size(rest))

      {:more, _} ->
        more(conn, buffer, byte_size(buffer), &read_head(conn, &1))

      _ ->
        {:error, {:download_failed, "malformed_response"}}
    end
  end

  defp read_headers(_conn, _buffer, _status, headers, _used) when length(headers) > @max_headers,
    do: {:error, {:download_failed, "malformed_response"}}

  defp read_headers(conn, buffer, status, headers, used) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:ok, {:http_header, _, name, _, value}, rest} ->
        used = used + byte_size(buffer) - byte_size(rest)
        name = name |> to_string() |> String.downcase()
        read_headers(conn, rest, status, [{name, value} | headers], used)

      {:ok, :http_eoh, rest} ->
        {:ok, status, Enum.reverse(headers), rest}

      {:more, _} ->
        more(conn, buffer, used + byte_size(buffer), &read_headers(conn, &1, status, headers, used))

      _ ->
        {:error, {:download_failed, "malformed_response"}}
    end
  end

  defp more(conn, buffer, size, continue) do
    if size > @max_head_bytes do
      {:error, {:download_failed, "malformed_response"}}
    else
      case recv(conn) do
        {:ok, data} -> continue.(buffer <> data)
        :closed -> {:error, {:download_failed, "connection_closed"}}
        error -> error
      end
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  # ── the body ───────────────────────────────────────────────────────────

  defp body(conn, headers, rest, out, max_bytes) do
    encoding = headers |> header("transfer-encoding") |> to_string() |> String.downcase()
    length = header(headers, "content-length")

    cond do
      String.contains?(encoding, "chunked") ->
        chunked(conn, rest, out, 0, max_bytes)

      length != nil ->
        case Integer.parse(String.trim(length)) do
          {n, ""} when n > max_bytes -> {:error, :download_too_large}
          {n, ""} when n >= 0 -> sized(conn, rest, out, n, 0)
          _ -> {:error, {:download_failed, "malformed_response"}}
        end

      true ->
        until_close(conn, rest, out, 0, max_bytes)
    end
  end

  # Exactly the declared length; anything after it is ignored.
  defp sized(conn, data, out, length, written) do
    take = min(byte_size(data), length - written)
    :ok = IO.binwrite(out, binary_part(data, 0, take))
    written = written + take

    with :ok <- track(conn, written) do
      if written == length do
        {:ok, written}
      else
        case recv(conn) do
          {:ok, data} -> sized(conn, data, out, length, written)
          :closed -> {:error, {:download_failed, "body_incomplete"}}
          error -> error
        end
      end
    end
  end

  defp until_close(conn, data, out, written, max_bytes) do
    written = written + byte_size(data)

    if written > max_bytes do
      {:error, :download_too_large}
    else
      :ok = IO.binwrite(out, data)

      with :ok <- track(conn, written) do
        case recv(conn) do
          {:ok, data} -> until_close(conn, data, out, written, max_bytes)
          :closed -> {:ok, written}
          error -> error
        end
      end
    end
  end

  # Transfer-Encoding: chunked. Each chunk is `<hex size>[;ext]\r\n<data>\r\n`;
  # a zero size ends the body (trailers are not read).
  defp chunked(conn, buffer, out, written, max_bytes) do
    case :binary.match(buffer, "\r\n") do
      :nomatch when byte_size(buffer) > @max_chunk_line ->
        {:error, {:download_failed, "malformed_response"}}

      :nomatch ->
        with {:ok, data} <- recv_or_fail(conn) do
          chunked(conn, buffer <> data, out, written, max_bytes)
        end

      {pos, 2} ->
        size = buffer |> binary_part(0, pos) |> String.split(";") |> hd() |> String.trim()
        rest = binary_part(buffer, pos + 2, byte_size(buffer) - pos - 2)

        case Integer.parse(size, 16) do
          {0, ""} -> {:ok, written}
          {n, ""} when written + n > max_bytes -> {:error, :download_too_large}
          {n, ""} when n > 0 -> chunk_data(conn, rest, out, n, written, max_bytes)
          _ -> {:error, {:download_failed, "malformed_response"}}
        end
    end
  end

  defp chunk_data(conn, buffer, out, left, written, max_bytes) do
    cond do
      byte_size(buffer) >= left + 2 ->
        :ok = IO.binwrite(out, binary_part(buffer, 0, left))

        with :ok <- track(conn, written + left) do
          case binary_part(buffer, left, byte_size(buffer) - left) do
            "\r\n" <> rest -> chunked(conn, rest, out, written + left, max_bytes)
            _ -> {:error, {:download_failed, "malformed_response"}}
          end
        end

      byte_size(buffer) > left ->
        with {:ok, data} <- recv_or_fail(conn) do
          chunk_data(conn, buffer <> data, out, left, written, max_bytes)
        end

      true ->
        :ok = IO.binwrite(out, buffer)

        with :ok <- track(conn, written + byte_size(buffer)),
             {:ok, data} <- recv_or_fail(conn) do
          chunk_data(
            conn,
            data,
            out,
            left - byte_size(buffer),
            written + byte_size(buffer),
            max_bytes
          )
        end
    end
  end

  defp recv_or_fail(conn) do
    case recv(conn) do
      {:ok, data} -> {:ok, data}
      :closed -> {:error, {:download_failed, "body_incomplete"}}
      error -> error
    end
  end

  # After every write: the throughput floor (once the grace period is over)
  # and the progress callback (at most every five seconds).
  defp track(conn, written) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - conn.started

    if conn.min_rate > 0 and elapsed > conn.grace_ms and written * 1000 < conn.min_rate * elapsed do
      {:error, {:download_failed, "too_slow"}}
    else
      if now - (Process.get(:import_fetch_progress_at) || 0) >= conn.progress_ms do
        Process.put(:import_fetch_progress_at, now)
        conn.progress.(written)
      end

      :ok
    end
  end
end
