defmodule OptimalEngine.Connectors.HTTP.SingleAttempt do
  @moduledoc """
  An HTTP/1.1 request that is sent once and never again.

  `:httpc` sends a request a second time on its own in two cases: on a kept-alive
  session the server closed, and (before OTP 28.4, which added the `autoretry`
  option to turn it off) after an answer that names a `Retry-After`, until the
  call's timeout. A broker call or a token exchange must not be repeated that
  way: the broker's answer is issued once per reference, and a second exchange
  spends a refresh token a provider may rotate. This client makes the guarantee
  itself, on every OTP release:

    * one connection per request, `connection: close`, no pooling, no proxy
    * no redirect and no retry: a 3xx or a 503 is handed back as the answer
    * https verifies the server's certificate against the system's roots and
      the host name (`OptimalEngine.Connectors.HTTP.ssl_options/1`); there is
      no way to turn it off
    * the whole call, connect included, is bound by one deadline
    * the answer is read in full or the call fails: a body shorter than its
      `content-length`, or a chunked body that stops early, is an error, never
      a truncated success
    * a header name or value that could split the request is refused, and the
      headers the client writes itself (`host`, `content-length`, `connection`,
      `transfer-encoding`, `expect`, `te`, `upgrade`) cannot be set by the caller

  It returns what `:httpc.request/4` returns for a binary body, so
  `OptimalEngine.Connectors.HTTP` handles both alike.
  """

  @default_timeout 10_000
  @default_max_body_bytes 1_048_576
  @max_head_bytes 65_536
  @max_line_bytes 4_096
  @max_trailer_bytes 8_192
  @max_interim 5

  @reserved ~w(host content-length connection transfer-encoding expect te upgrade)
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @target ~r/\A[\x21-\x7E]+\z/
  @status_line ~r/\AHTTP\/1\.[01] ([0-9]{3})(?: (.*))?\z/

  @type headers :: [{String.t(), String.t()}]
  @type raw ::
          {{charlist(), pos_integer(), charlist()}, [{String.t(), String.t()}], binary()}

  @doc """
  Sends `body` (ignored for `:get`, `:delete` and `:head`) to `url` and reads
  the answer. Options: `:timeout` (ms for the whole call, default 10_000) and
  `:max_body_bytes` (default 1 MiB; a longer answer is
  `{:error, :response_too_large}`).
  """
  @spec request(atom(), String.t(), headers(), String.t() | nil, binary(), keyword()) ::
          {:ok, raw()} | {:error, term()}
  def request(method, url, headers, content_type, body, opts \\ [])
      when is_atom(method) and is_binary(url) and is_binary(body) do
    deadline = now() + Keyword.get(opts, :timeout, @default_timeout)
    cap = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)

    with {:ok, target} <- target(url),
         {:ok, head} <- head(method, target, headers, content_type, body),
         {:ok, conn} <- connect(target, deadline) do
      try do
        with :ok <- send_all(conn, [head, payload(method, body)]) do
          read_response(conn, method, cap, deadline)
        end
      after
        close(conn)
      end
    end
  end

  # ─── request ─────────────────────────────────────────────────────────────

  defp target(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil, port: port} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) ->
        path = if(uri.path in [nil, ""], do: "/", else: uri.path)
        path = path <> if(uri.query, do: "?" <> uri.query, else: "")

        if Regex.match?(@target, path) and String.starts_with?(path, "/"),
          do: {:ok, %{scheme: scheme, host: host, port: port, path: path, url: url}},
          else: {:error, :invalid_url}

      _other ->
        {:error, :invalid_url}
    end
  end

  defp head(method, target, headers, content_type, body) do
    with :ok <- check_headers(headers),
         :ok <- check_content_type(content_type) do
      lines =
        [
          "#{method |> Atom.to_string() |> String.upcase()} #{target.path} HTTP/1.1",
          "host: #{host_header(target)}",
          "connection: close"
        ] ++
          Enum.map(headers, fn {name, value} -> "#{name}: #{value}" end) ++
          body_headers(method, content_type, body)

      {:ok, Enum.join(lines, "\r\n") <> "\r\n\r\n"}
    end
  end

  defp host_header(%{scheme: scheme, host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    default = if scheme == "https", do: 443, else: 80
    if port == default, do: host, else: "#{host}:#{port}"
  end

  defp body_headers(method, content_type, body) do
    if has_body?(method) do
      ["content-length: #{byte_size(body)}"] ++
        if(content_type, do: ["content-type: #{content_type}"], else: [])
    else
      []
    end
  end

  defp payload(method, body), do: if(has_body?(method), do: body, else: "")

  defp has_body?(method), do: method not in [:get, :delete, :head]

  defp check_headers(headers) do
    if Enum.all?(headers, &valid_header?/1), do: :ok, else: {:error, :invalid_header}
  end

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value) do
    Regex.match?(@token, name) and String.downcase(name) not in @reserved and
      clean?(value)
  end

  defp valid_header?(_other), do: false

  defp check_content_type(nil), do: :ok

  defp check_content_type(type) when is_binary(type),
    do: if(clean?(type), do: :ok, else: {:error, :invalid_header})

  defp clean?(value), do: not String.contains?(value, ["\r", "\n", <<0>>])

  # ─── connection ──────────────────────────────────────────────────────────

  defp connect(%{scheme: "http"} = target, deadline) do
    base = [:binary, active: false, packet: :raw, nodelay: true] ++ family(target.host)

    case :gen_tcp.connect(String.to_charlist(target.host), target.port, base, remaining(deadline)) do
      {:ok, socket} -> {:ok, %{transport: :gen_tcp, socket: socket}}
      {:error, reason} -> {:error, {:failed_connect, reason}}
    end
  end

  defp connect(%{scheme: "https"} = target, deadline) do
    _ = Application.ensure_all_started(:ssl)
    base = [:binary, active: false, packet: :raw] ++ family(target.host)
    tls = OptimalEngine.Connectors.HTTP.ssl_options(target.url)

    case :ssl.connect(
           String.to_charlist(target.host),
           target.port,
           base ++ tls,
           remaining(deadline)
         ) do
      {:ok, socket} -> {:ok, %{transport: :ssl, socket: socket}}
      {:error, reason} -> {:error, {:failed_connect, reason}}
    end
  end

  defp family(host), do: if(String.contains?(host, ":"), do: [:inet6], else: [])

  defp send_all(%{transport: transport, socket: socket}, data) do
    case transport.send(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  defp close(%{transport: transport, socket: socket}) do
    _ = transport.close(socket)
    :ok
  end

  defp recv(%{transport: transport, socket: socket}, deadline) do
    case remaining(deadline) do
      0 -> {:error, :timeout}
      ms -> transport.recv(socket, 0, ms)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)

  # ─── response ────────────────────────────────────────────────────────────

  defp read_response(conn, method, cap, deadline) do
    with {:ok, {status, reason, headers}, rest} <- read_head(conn, "", deadline, @max_interim),
         {:ok, body} <- read_body(conn, method, status, headers, rest, cap, deadline) do
      {:ok, {{~c"HTTP/1.1", status, String.to_charlist(reason)}, headers, body}}
    end
  end

  # Reads up to the blank line that ends the head, setting aside any
  # `1xx` interim answers (`100 Continue`) before it.
  defp read_head(conn, buffer, deadline, interim) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        case parse_head(head) do
          {:ok, {status, _reason, _headers}} when status in 100..199 and status != 101 ->
            if interim > 0,
              do: read_head(conn, rest, deadline, interim - 1),
              else: {:error, :invalid_response}

          {:ok, parsed} when elem(parsed, 0) == 101 ->
            {:error, :invalid_response}

          {:ok, parsed} ->
            {:ok, parsed, rest}

          {:error, _reason} = error ->
            error
        end

      [_incomplete] when byte_size(buffer) > @max_head_bytes ->
        {:error, :invalid_response}

      [_incomplete] ->
        with {:ok, data} <- recv(conn, deadline),
             do: read_head(conn, buffer <> data, deadline, interim)
    end
  end

  defp parse_head(head) do
    [status_line | header_lines] = String.split(head, "\r\n")

    with [_whole, status, reason] <- status_parts(status_line),
         {:ok, headers} <- parse_headers(header_lines) do
      {:ok, {String.to_integer(status), reason, headers}}
    else
      _bad -> {:error, :invalid_response}
    end
  end

  defp status_parts(line) do
    case Regex.run(@status_line, line) do
      [whole, status] -> [whole, status, ""]
      [_whole, _status, _reason] = parts -> parts
      nil -> nil
    end
  end

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if Regex.match?(@token, name),
            do: {:cont, {:ok, [{name, String.trim(value)} | acc]}},
            else: {:halt, {:error, :invalid_response}}

        _no_colon ->
          {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp read_body(conn, method, status, headers, rest, cap, deadline) do
    cond do
      method == :head or status in [204, 304] ->
        {:ok, ""}

      transfer_encoding(headers) == :chunked ->
        read_chunked(conn, rest, [], 0, cap, deadline)

      transfer_encoding(headers) == :other ->
        {:error, :invalid_response}

      true ->
        case content_length(headers) do
          {:ok, length} -> read_fixed(conn, rest, length, cap, deadline)
          :none -> read_to_close(conn, rest, cap, deadline)
          :invalid -> {:error, :invalid_response}
        end
    end
  end

  defp transfer_encoding(headers) do
    case values(headers, "transfer-encoding") do
      [] -> :none
      values -> if Enum.map(values, &String.downcase/1) == ["chunked"], do: :chunked, else: :other
    end
  end

  # One `content-length`, or several that agree; anything else is a framing the
  # client cannot trust.
  defp content_length(headers) do
    lengths =
      headers
      |> values("content-length")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)

    cond do
      lengths == [] -> :none
      not Enum.all?(lengths, &Regex.match?(~r/\A[0-9]{1,15}\z/, &1)) -> :invalid
      length(Enum.uniq(lengths)) > 1 -> :invalid
      true -> {:ok, lengths |> hd() |> String.to_integer()}
    end
  end

  defp values(headers, name) do
    for {key, value} <- headers, String.downcase(key) == name, do: value
  end

  defp read_fixed(_conn, _buffer, length, cap, _deadline) when length > cap,
    do: {:error, :response_too_large}

  defp read_fixed(conn, buffer, length, cap, deadline) do
    if byte_size(buffer) >= length do
      {:ok, binary_part(buffer, 0, length)}
    else
      with {:ok, data} <- recv(conn, deadline),
           do: read_fixed(conn, buffer <> data, length, cap, deadline)
    end
  end

  defp read_to_close(conn, buffer, cap, deadline) do
    cond do
      byte_size(buffer) > cap ->
        {:error, :response_too_large}

      true ->
        case recv(conn, deadline) do
          {:ok, data} -> read_to_close(conn, buffer <> data, cap, deadline)
          {:error, :closed} -> {:ok, buffer}
          {:error, _reason} = error -> error
        end
    end
  end

  defp read_chunked(conn, buffer, chunks, size, cap, deadline) do
    with {:ok, line, rest} <- read_line(conn, buffer, deadline, @max_line_bytes),
         {:ok, length} <- chunk_size(line) do
      cond do
        length == 0 ->
          with :ok <- skip_trailers(conn, rest, deadline, @max_trailer_bytes) do
            {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
          end

        size + length > cap ->
          {:error, :response_too_large}

        true ->
          with {:ok, chunk, rest} <- read_exactly(conn, rest, length + 2, deadline),
               <<data::binary-size(length), "\r\n">> <- chunk do
            read_chunked(conn, rest, [data | chunks], size + length, cap, deadline)
          else
            {:error, _reason} = error -> error
            _bad_framing -> {:error, :invalid_response}
          end
      end
    end
  end

  defp chunk_size(line) do
    [hex | _extensions] = String.split(line, ";", parts: 2)
    hex = String.trim(hex)

    if Regex.match?(~r/\A[0-9A-Fa-f]{1,8}\z/, hex),
      do: {:ok, String.to_integer(hex, 16)},
      else: {:error, :invalid_response}
  end

  defp skip_trailers(conn, buffer, deadline, budget) do
    case read_line(conn, buffer, deadline, min(budget, @max_line_bytes)) do
      {:ok, "", _rest} -> :ok
      {:ok, line, rest} -> skip_trailers(conn, rest, deadline, budget - byte_size(line) - 2)
      {:error, _reason} = error -> error
    end
  end

  defp read_line(conn, buffer, deadline, limit) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        {:ok, line, rest}

      [_incomplete] when byte_size(buffer) > limit ->
        {:error, :invalid_response}

      [_incomplete] ->
        with {:ok, data} <- recv(conn, deadline),
             do: read_line(conn, buffer <> data, deadline, limit)
    end
  end

  defp read_exactly(conn, buffer, count, deadline) do
    if byte_size(buffer) >= count do
      {:ok, binary_part(buffer, 0, count), binary_part(buffer, count, byte_size(buffer) - count)}
    else
      with {:ok, data} <- recv(conn, deadline),
           do: read_exactly(conn, buffer <> data, count, deadline)
    end
  end
end
