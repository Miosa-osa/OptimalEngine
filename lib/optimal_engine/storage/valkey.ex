defmodule OptimalEngine.Storage.Valkey do
  @moduledoc """
  The Valkey (Redis protocol) service provider: a distributed ephemeral store
  for cache, rate limits, locks and short-lived coordination. It never holds
  durable truth; everything in it can be rebuilt from the canonical stores.

  The engine speaks RESP2 directly over TCP, so the provider needs no client
  library and no supervision tree: every call opens one connection, runs its
  commands and closes it. `OPTIMAL_VALKEY_URL` is `redis://[user:password@]host[:port][/db]`
  (`rediss://` for TLS, `valkey://` accepted as an alias). The URL carries the
  credential, so it is never logged, described or returned by the API;
  `safe_config/1` is the shape a route may show.

  Health is a `PING` answered `PONG`; the proof is a `SET`, a `GET` that reads
  the same value back, and a `DEL`, under a key of its own
  (`optimal:proof:<random>`), so a healthy provider has been written to and
  read from, not merely connected to.
  """

  @env "OPTIMAL_VALKEY_URL"
  @default_port 6379
  @default_timeout 2_000
  @proof_prefix "optimal:proof:"

  @type health :: :healthy | :unreachable | :not_configured | :invalid_config

  @doc "The environment variable the provider is configured by."
  @spec env_name() :: String.t()
  def env_name, do: @env

  @doc "Whether `OPTIMAL_VALKEY_URL` is set and parses."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config())

  @doc """
  Parses the URL. The result carries the password because the connection needs
  it; use `safe_config/1` for anything a person or an API sees.
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
      {:ok, Map.drop(config, [:password, :username])}
    end
  end

  @doc """
  One `PING`. `:not_configured` without a URL, `:invalid_config` for a URL that
  does not parse, `:unreachable` for anything the server did not answer `PONG` to.
  """
  @spec health(keyword()) :: health()
  def health(opts \\ []) do
    case config(opts) do
      {:ok, config} ->
        case with_connection(config, timeout(opts), &command(&1, ["PING"], timeout(opts))) do
          {:ok, "PONG"} -> :healthy
          _ -> :unreachable
        end

      {:error, :not_configured} ->
        :not_configured

      {:error, _reason} ->
        :invalid_config
    end
  end

  @doc """
  Writes one key, reads it back and deletes it, on a connection of its own.
  Nothing is left behind.
  """
  @spec round_trip(keyword()) :: {:ok, map()} | {:error, term()}
  def round_trip(opts \\ []) do
    timeout = timeout(opts)

    with {:ok, config} <- config(opts) do
      with_connection(config, timeout, fn socket ->
        key = @proof_prefix <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        value = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

        with {:ok, "OK"} <- command(socket, ["SET", key, value, "PX", "60000"], timeout),
             {:ok, ^value} <- command(socket, ["GET", key], timeout),
             {:ok, deleted} when deleted in [0, 1] <- command(socket, ["DEL", key], timeout) do
          {:ok, %{wrote: 1, read_back: true, deleted: deleted == 1, database: config.database}}
        else
          {:ok, other} -> {:error, {:round_trip_mismatch, other}}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  @doc """
  Runs one command (a list of binaries) on an open connection and decodes the
  reply. Errors the server reports come back as `{:error, {:server, message}}`.
  """
  @spec command(:gen_tcp.socket() | :ssl.sslsocket(), [String.t()], timeout()) ::
          {:ok, term()} | {:error, term()}
  def command(socket, parts, timeout \\ @default_timeout) when is_list(parts) do
    with :ok <- send_data(socket, encode(parts)),
         {:ok, reply, _rest} <- read_reply(socket, "", timeout) do
      case reply do
        {:error, message} -> {:error, {:server, message}}
        value -> {:ok, value}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Connection
  # ---------------------------------------------------------------------------

  defp with_connection(config, timeout, fun) do
    case connect(config, timeout) do
      {:ok, socket} ->
        try do
          with :ok <- authenticate(socket, config, timeout),
               :ok <- select(socket, config, timeout) do
            fun.(socket)
          end
        after
          close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  defp connect(%{ssl: true} = config, timeout) do
    :ssl.connect(
      String.to_charlist(config.hostname),
      config.port,
      [:binary, active: false, verify: :verify_none],
      timeout
    )
  end

  defp connect(config, timeout) do
    :gen_tcp.connect(
      String.to_charlist(config.hostname),
      config.port,
      [:binary, active: false],
      timeout
    )
  end

  defp authenticate(_socket, %{password: nil}, _timeout), do: :ok

  defp authenticate(socket, %{password: password, username: username}, timeout) do
    parts = if username in [nil, ""], do: ["AUTH", password], else: ["AUTH", username, password]

    case command(socket, parts, timeout) do
      {:ok, "OK"} -> :ok
      {:error, reason} -> {:error, {:auth_failed, scrub(reason)}}
      other -> {:error, {:auth_failed, other}}
    end
  end

  defp select(_socket, %{database: 0}, _timeout), do: :ok

  defp select(socket, %{database: database}, timeout) do
    case command(socket, ["SELECT", Integer.to_string(database)], timeout) do
      {:ok, "OK"} -> :ok
      other -> {:error, {:select_failed, other}}
    end
  end

  # A server's error text never carries the credential, but the reason is
  # reported upward, so keep it to the error class.
  defp scrub({:server, message}), do: message |> String.split(" ") |> List.first()
  defp scrub(other), do: other

  defp send_data({:sslsocket, _, _} = socket, data), do: :ssl.send(socket, data)
  defp send_data(socket, data), do: :gen_tcp.send(socket, data)

  defp recv({:sslsocket, _, _} = socket, timeout), do: :ssl.recv(socket, 0, timeout)
  defp recv(socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  defp close({:sslsocket, _, _} = socket), do: :ssl.close(socket)
  defp close(socket), do: :gen_tcp.close(socket)

  # ---------------------------------------------------------------------------
  # RESP2
  # ---------------------------------------------------------------------------

  @doc false
  def encode(parts) when is_list(parts) do
    body =
      Enum.map(parts, fn part ->
        bin = to_string(part)
        "$#{byte_size(bin)}\r\n#{bin}\r\n"
      end)

    IO.iodata_to_binary(["*#{length(parts)}\r\n" | body])
  end

  defp read_reply(socket, buffer, timeout) do
    case decode(buffer) do
      {:ok, value, rest} ->
        {:ok, value, rest}

      :incomplete ->
        case recv(socket, timeout) do
          {:ok, data} -> read_reply(socket, buffer <> data, timeout)
          {:error, reason} -> {:error, {:recv, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def decode(buffer) do
    case String.split(buffer, "\r\n", parts: 2) do
      [line, rest] -> decode_line(line, rest)
      [_partial] -> :incomplete
    end
  end

  defp decode_line("+" <> simple, rest), do: {:ok, simple, rest}
  defp decode_line("-" <> error, rest), do: {:ok, {:error, error}, rest}

  defp decode_line(":" <> integer, rest) do
    case Integer.parse(integer) do
      {value, ""} -> {:ok, value, rest}
      _ -> {:error, {:protocol, :bad_integer}}
    end
  end

  defp decode_line("$-1", rest), do: {:ok, nil, rest}

  defp decode_line("$" <> length, rest) do
    with {size, ""} <- Integer.parse(length),
         true <- byte_size(rest) >= size + 2 do
      <<value::binary-size(size), "\r\n", tail::binary>> = rest
      {:ok, value, tail}
    else
      false -> :incomplete
      _ -> {:error, {:protocol, :bad_bulk_length}}
    end
  end

  defp decode_line("*-1", rest), do: {:ok, nil, rest}

  defp decode_line("*" <> count, rest) do
    case Integer.parse(count) do
      {size, ""} -> decode_array(size, rest, [])
      _ -> {:error, {:protocol, :bad_array_length}}
    end
  end

  defp decode_line(_line, _rest), do: {:error, {:protocol, :unknown_type}}

  defp decode_array(0, rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_array(n, rest, acc) do
    case decode(rest) do
      {:ok, value, tail} -> decode_array(n - 1, tail, [value | acc])
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # URL parsing
  # ---------------------------------------------------------------------------

  defp parse_url(value) do
    uri = URI.parse(value)

    with :ok <- check_scheme(uri),
         {:ok, host} <- check_host(uri),
         {:ok, database} <- check_database(uri) do
      {username, password} = userinfo(uri)

      {:ok,
       %{
         hostname: host,
         port: uri.port || @default_port,
         database: database,
         username: username,
         password: password,
         ssl: uri.scheme in ["rediss", "valkeys"]
       }}
    end
  end

  defp check_scheme(%URI{scheme: scheme}) when scheme in ~w(redis rediss valkey valkeys), do: :ok
  defp check_scheme(_uri), do: {:error, :invalid_scheme}

  defp check_host(%URI{host: host}) when is_binary(host) and host != "", do: {:ok, host}
  defp check_host(_uri), do: {:error, :missing_host}

  defp check_database(%URI{path: path}) when path in [nil, "", "/"], do: {:ok, 0}

  defp check_database(%URI{path: path}) do
    case path |> String.trim_leading("/") |> Integer.parse() do
      {database, ""} when database >= 0 -> {:ok, database}
      _ -> {:error, :invalid_database}
    end
  end

  defp userinfo(%URI{userinfo: nil}), do: {nil, nil}

  defp userinfo(%URI{userinfo: info}) do
    case String.split(info, ":", parts: 2) do
      [password] -> {nil, URI.decode_www_form(password)}
      ["", password] -> {nil, URI.decode_www_form(password)}
      [username, password] -> {URI.decode_www_form(username), URI.decode_www_form(password)}
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)
end
