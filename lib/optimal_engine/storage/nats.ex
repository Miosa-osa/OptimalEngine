defmodule OptimalEngine.Storage.NATS do
  @moduledoc """
  The NATS JetStream service provider: a replayable transport for events,
  jobs, connector ingestion and replication between Engines. It is transport,
  never canonical state; what flows through it is rebuilt from the governed
  ledgers.

  The engine speaks the NATS text protocol directly over TCP, so the provider
  needs no client library: every call opens one connection, reads the server's
  `INFO`, sends `CONNECT` and runs its requests on an inbox of its own, then
  closes. `OPTIMAL_NATS_URL` is `nats://[user:password@|token@]host[:port]`
  (`tls://` for TLS). The URL carries the credential, so it is never logged,
  described or returned by the API; `safe_config/1` is the shape a route may show.

  Health is a `PING` the server answered `PONG` and a `$JS.API.INFO` request
  JetStream answered, so a core NATS server without JetStream reports
  `unreachable`: the engine's use of it is JetStream. The proof creates a
  memory stream of its own (`OPTIMAL_PROOF_<random>`), publishes one message,
  reads it back by sequence through the stream API and deletes the stream, so
  a healthy provider has stored and replayed a message, not merely connected.
  """

  @env "OPTIMAL_NATS_URL"
  @default_port 4222
  @default_timeout 2_000
  @js_api "$JS.API"
  @proof_prefix "OPTIMAL_PROOF_"

  @type health :: :healthy | :unreachable | :not_configured | :invalid_config

  @doc "The environment variable the provider is configured by."
  @spec env_name() :: String.t()
  def env_name, do: @env

  @doc "Whether `OPTIMAL_NATS_URL` is set and parses."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config())

  @doc """
  Parses the URL. The result carries the credential because the connection
  needs it; use `safe_config/1` for anything a person or an API sees.
  """
  @spec config(keyword()) :: {:ok, map()} | {:error, atom()}
  def config(opts \\ []) do
    case Keyword.get(opts, :url) || System.get_env(@env) do
      value when is_binary(value) and value != "" -> parse_url(value)
      _ -> {:error, :not_configured}
    end
  end

  @doc "The connection options without the credential."
  @spec safe_config(keyword()) :: {:ok, map()} | {:error, atom()}
  def safe_config(opts \\ []) do
    with {:ok, config} <- config(opts) do
      {:ok, Map.drop(config, [:username, :password, :token])}
    end
  end

  @doc """
  `PING` and `$JS.API.INFO`. `:not_configured` without a URL, `:invalid_config`
  for one that does not parse, `:unreachable` when the server did not answer
  both.
  """
  @spec health(keyword()) :: health()
  def health(opts \\ []) do
    case config(opts) do
      {:ok, config} ->
        timeout = timeout(opts)

        result =
          with_connection(config, timeout, fn conn ->
            with {:ok, "PONG"} <- ping(conn, timeout),
                 {:ok, %{"memory" => _}} <- js_request(conn, "INFO", "", timeout) do
              :healthy
            else
              _ -> :unreachable
            end
          end)

        if result == :healthy, do: :healthy, else: :unreachable

      {:error, :not_configured} ->
        :not_configured

      {:error, _reason} ->
        :invalid_config
    end
  end

  @doc """
  Creates a memory stream of its own, publishes one message, reads it back by
  sequence and deletes the stream, on a connection of its own. Nothing is left
  behind.
  """
  @spec round_trip(keyword()) :: {:ok, map()} | {:error, term()}
  def round_trip(opts \\ []) do
    timeout = timeout(opts)

    with {:ok, config} <- config(opts) do
      with_connection(config, timeout, fn conn ->
        suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
        stream = @proof_prefix <> String.upcase(suffix)
        subject = "optimal.proof.#{suffix}"
        payload = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

        create =
          Jason.encode!(%{
            name: stream,
            subjects: [subject],
            retention: "limits",
            storage: "memory",
            max_msgs: 10,
            max_age: 60_000_000_000,
            num_replicas: 1
          })

        result =
          with {:ok, %{"config" => %{"name" => ^stream}}} <-
                 js_request(conn, "STREAM.CREATE.#{stream}", create, timeout),
               {:ok, %{"stream" => ^stream, "seq" => seq}} <-
                 request(conn, subject, payload, timeout),
               {:ok, %{"message" => %{"data" => data}}} <-
                 js_request(conn, "STREAM.MSG.GET.#{stream}", Jason.encode!(%{seq: seq}), timeout),
               {:ok, ^payload} <- Base.decode64(data) do
            {:ok, %{stream_created: true, published: 1, sequence: seq, read_back: true}}
          else
            {:ok, other} -> {:error, {:round_trip_mismatch, other}}
            :error -> {:error, {:round_trip_mismatch, :undecodable_payload}}
            {:error, reason} -> {:error, reason}
          end

        # The stream goes whatever happened; a proof that cannot remove it is
        # not a pass, because it left a stream behind with no expiry of its own.
        deleted = js_request(conn, "STREAM.DELETE.#{stream}", "", timeout)

        case {result, deleted} do
          {{:ok, evidence}, {:ok, %{"success" => true}}} ->
            {:ok, Map.put(evidence, :stream_deleted, true)}

          {{:ok, _evidence}, other} ->
            {:error, {:stream_not_deleted, other}}

          {error, _deleted} ->
            error
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Connection
  # ---------------------------------------------------------------------------

  # The socket is closed on every path, a refused or failed handshake
  # included: a server that answers -ERR, or is not NATS, used to keep it open.
  defp with_connection(config, timeout, fun) do
    with {:ok, socket} <- connect(config, timeout) do
      conn = %{socket: socket, buffer: "", inbox: "_INBOX.#{random()}", sid: 1}

      case safe_handshake(conn, config, timeout) do
        {:ok, conn} ->
          try do
            fun.(conn)
          after
            close(conn.socket)
          end

        {:error, reason, conn} ->
          close(conn.socket)
          {:error, reason}
      end
    end
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  defp safe_handshake(conn, config, timeout) do
    handshake(conn, config, timeout)
  catch
    kind, reason -> {:error, {:handshake, kind, reason}, conn}
  end

  # Always plain TCP first: a NATS server sends INFO in the clear and the
  # client upgrades the same connection to TLS before CONNECT (`upgrade/3`).
  defp connect(config, timeout) do
    :gen_tcp.connect(
      String.to_charlist(config.hostname),
      config.port,
      [:binary, active: false],
      timeout
    )
  end

  # The server speaks first with INFO; the client answers CONNECT and subscribes
  # its inbox, on which every reply of this connection arrives.
  defp handshake(conn, config, timeout) do
    case read_line(conn, timeout) do
      {:ok, {"INFO", _json}, conn} ->
        with {:ok, conn} <- upgrade(conn, config, timeout), do: introduce(conn, config)

      {:ok, other, conn} ->
        {:error, {:protocol, other}, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  # `tls://`: the credential goes over this connection, so the server's
  # certificate and host name are verified against the system's roots, as for
  # every other credential the Engine sends (Connectors.HTTP).
  defp upgrade(conn, %{ssl: true} = config, timeout) do
    options =
      [mode: :binary, active: false, server_name_indication: String.to_charlist(config.hostname)] ++
        OptimalEngine.Connectors.HTTP.ssl_options("https://" <> config.hostname)

    case :ssl.connect(conn.socket, options, timeout) do
      {:ok, socket} -> {:ok, %{conn | socket: socket}}
      {:error, reason} -> {:error, {:tls, reason}, conn}
    end
  end

  defp upgrade(conn, _config, _timeout), do: {:ok, conn}

  defp introduce(conn, config) do
    with :ok <- send_data(conn.socket, "CONNECT #{Jason.encode!(connect_options(config))}\r\n"),
         :ok <- send_data(conn.socket, "SUB #{conn.inbox}.* 1\r\n") do
      {:ok, conn}
    else
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp connect_options(config) do
    base = %{
      verbose: false,
      pedantic: false,
      lang: "elixir",
      name: "optimal-engine",
      headers: true,
      no_responders: true,
      protocol: 1
    }

    cond do
      is_binary(config.token) -> Map.put(base, :auth_token, config.token)
      is_binary(config.password) -> Map.merge(base, %{user: config.username, pass: config.password})
      true -> base
    end
  end

  defp ping(conn, timeout) do
    with :ok <- send_data(conn.socket, "PING\r\n"),
         {:ok, {"PONG", _}, _conn} <- read_until(conn, timeout, fn {op, _} -> op == "PONG" end) do
      {:ok, "PONG"}
    else
      {:ok, other, _} -> {:error, {:protocol, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp js_request(conn, api, payload, timeout),
    do: request(conn, "#{@js_api}.#{api}", payload, timeout)

  # A request is a publish with a reply subject under the connection's inbox;
  # the answer is the next MSG on it. JetStream answers errors as JSON with an
  # `error` object, and a subject nobody serves as a 503 status header.
  defp request(conn, subject, payload, timeout) do
    reply = "#{conn.inbox}.#{random()}"

    with :ok <-
           send_data(conn.socket, "PUB #{subject} #{reply} #{byte_size(payload)}\r\n#{payload}\r\n"),
         {:ok, {:msg, ^reply, body}, _conn} <-
           read_until(conn, timeout, fn
             {:msg, ^reply, _body} -> true
             _ -> false
           end) do
      decode_reply(body)
    else
      {:ok, other, _} -> {:error, {:protocol, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_reply({:status, status, _body}), do: {:error, {:no_responders, status}}

  defp decode_reply(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code, "description" => description}}} ->
        {:error, {:jetstream, code, description}}

      {:ok, %{} = map} ->
        {:ok, map}

      {:ok, other} ->
        {:error, {:protocol, other}}

      {:error, _} ->
        {:error, {:protocol, :not_json}}
    end
  end

  # ---------------------------------------------------------------------------
  # Protocol reading
  # ---------------------------------------------------------------------------

  defp read_until(conn, timeout, matches?) do
    case read_line(conn, timeout) do
      {:ok, {"PING", _}, conn} ->
        :ok = send_data(conn.socket, "PONG\r\n")
        read_until(conn, timeout, matches?)

      {:ok, frame, conn} ->
        if matches?.(frame), do: {:ok, frame, conn}, else: read_until(conn, timeout, matches?)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One protocol frame: a control line, or a MSG/HMSG with its payload.
  defp read_line(conn, timeout) do
    case String.split(conn.buffer, "\r\n", parts: 2) do
      [line, rest] -> frame(line, %{conn | buffer: rest}, timeout)
      [_partial] -> fill(conn, timeout, &read_line/2)
    end
  end

  defp fill(conn, timeout, continue) do
    case recv(conn.socket, timeout) do
      {:ok, data} -> continue.(%{conn | buffer: conn.buffer <> data}, timeout)
      {:error, reason} -> {:error, {:recv, reason}}
    end
  end

  defp frame("MSG " <> rest, conn, timeout) do
    case String.split(rest, " ") do
      [subject, _sid, reply, size] -> payload(subject, reply, size, nil, conn, timeout)
      [subject, _sid, size] -> payload(subject, nil, size, nil, conn, timeout)
      _ -> {:error, {:protocol, :bad_msg}}
    end
  end

  defp frame("HMSG " <> rest, conn, timeout) do
    case String.split(rest, " ") do
      [subject, _sid, reply, header_size, size] ->
        payload(subject, reply, size, header_size, conn, timeout)

      [subject, _sid, header_size, size] ->
        payload(subject, nil, size, header_size, conn, timeout)

      _ ->
        {:error, {:protocol, :bad_hmsg}}
    end
  end

  defp frame("INFO " <> json, conn, _timeout), do: {:ok, {"INFO", json}, conn}
  defp frame("-ERR " <> message, _conn, _timeout), do: {:error, {:server, message}}
  defp frame(op, conn, _timeout), do: {:ok, {String.trim(op), nil}, conn}

  # The payload follows the control line and ends with CRLF; wait for all of it.
  defp payload(subject, reply, size, header_size, conn, timeout) do
    with {total, ""} <- Integer.parse(size) do
      if byte_size(conn.buffer) >= total + 2 do
        <<data::binary-size(total), "\r\n", rest::binary>> = conn.buffer

        {:ok, {:msg, subject_for(reply, subject), split_headers(data, header_size)},
         %{conn | buffer: rest}}
      else
        fill(conn, timeout, fn conn, timeout ->
          payload(subject, reply, size, header_size, conn, timeout)
        end)
      end
    else
      _ -> {:error, {:protocol, :bad_size}}
    end
  end

  # Replies arrive on the inbox subject the request named; the frame's own
  # subject is that reply subject.
  defp subject_for(_reply, subject), do: subject

  defp split_headers(data, nil), do: data

  defp split_headers(data, header_size) do
    with {size, ""} <- Integer.parse(header_size),
         <<headers::binary-size(size), body::binary>> <- data,
         "NATS/1.0 " <> status_line <- headers do
      {:status, status_line |> String.split(["\r\n", " "], parts: 2) |> List.first(), body}
    else
      _ -> data
    end
  end

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp send_data({:sslsocket, _, _} = socket, data), do: :ssl.send(socket, data)
  defp send_data(socket, data), do: :gen_tcp.send(socket, data)

  defp recv({:sslsocket, _, _} = socket, timeout), do: :ssl.recv(socket, 0, timeout)
  defp recv(socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  defp close({:sslsocket, _, _} = socket), do: :ssl.close(socket)
  defp close(socket), do: :gen_tcp.close(socket)

  # ---------------------------------------------------------------------------
  # URL parsing
  # ---------------------------------------------------------------------------

  defp parse_url(value) do
    uri = URI.parse(value)

    with :ok <- check_scheme(uri),
         {:ok, host} <- check_host(uri),
         {:ok, {username, password, token}} <- userinfo(uri) do
      {:ok,
       %{
         hostname: host,
         port: uri.port || @default_port,
         username: username,
         password: password,
         token: token,
         ssl: uri.scheme == "tls"
       }}
    end
  end

  defp check_scheme(%URI{scheme: scheme}) when scheme in ~w(nats tls), do: :ok
  defp check_scheme(_uri), do: {:error, :invalid_scheme}

  defp check_host(%URI{host: host}) when is_binary(host) and host != "", do: {:ok, host}
  defp check_host(_uri), do: {:error, :missing_host}

  # Percent-decoding only (a `+` stays a plus); a malformed escape is a
  # configuration error, never a raise out of the provider inventory.
  defp userinfo(%URI{userinfo: nil}), do: {:ok, {nil, nil, nil}}

  defp userinfo(%URI{userinfo: info}) do
    case String.split(info, ":", parts: 2) do
      [token] -> {:ok, {nil, nil, decode_credential(token)}}
      [username, password] -> {:ok, {decode_credential(username), decode_credential(password), nil}}
    end
  rescue
    ArgumentError -> {:error, :invalid_credentials}
  end

  # URI.decode/1 passes a malformed escape such as "%zz" through unchanged, so a
  # credential carrying one would be sent as typed instead of refused.
  defp decode_credential(value) do
    if Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value),
      do: raise(ArgumentError, "malformed percent escape"),
      else: URI.decode(value)
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)
end
