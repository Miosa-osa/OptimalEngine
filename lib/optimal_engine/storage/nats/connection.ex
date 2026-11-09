defmodule OptimalEngine.Storage.NATS.Connection do
  @moduledoc """
  One long-lived, supervised connection to the NATS server named by
  `OPTIMAL_NATS_URL`, shared by everything the Engine sends through JetStream
  (`OptimalEngine.Storage.NATS.JetStream` builds the JetStream API on it).

  It connects at start, answers the server's `PING`s, sends its own every
  `:ping_interval` and treats two unanswered ones as a dead connection. When
  the connection goes, every request still waiting is answered
  `{:error, :disconnected}`, and the client reconnects after an exponential
  backoff with jitter (`:backoff`, `{min_ms, max_ms}`, default
  `{500, 30_000}`), forever: a NATS outage never stops the Engine, it only
  delays what flows through NATS.

  While it is not connected, every call answers `{:error, :not_connected}` at
  once, so a caller on a write path never waits on a server that is not
  there; the callers keep their own durable record (the SQLite ledger, the
  `jobs` table) and catch up when the connection is back.

  Requests are publishes with a reply subject under the connection's own
  inbox (`_INBOX.<random>.*`, subscription 1). A pull from a JetStream
  consumer gets a subscription of its own for the duration of the pull,
  because the messages it delivers arrive under their stream subject.

  `status/1` is what the provider inventory shows: the state, how often the
  connection was lost, the last error and the server's version. It never
  holds the URL or its credential.
  """

  use GenServer

  require Logger

  alias OptimalEngine.Storage.NATS
  alias OptimalEngine.Storage.NATS.Protocol

  @default_backoff {500, 30_000}
  @default_timeout 5_000
  @default_ping_interval 30_000
  @max_pings_out 2
  @inbox_sid "1"

  @type server :: GenServer.server()

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts the connection. Options: `:name` (default this module), `:url`
  (default `OPTIMAL_NATS_URL`; an explicit `nil` is not configured),
  `:backoff`, `:connect_timeout`, `:ping_interval`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The connection's state for an operator: `state` (`connected`,
  `connecting`, `disconnected`, `not_configured`, or `down` when the process
  is not running), `reconnects` (connections lost since start),
  `last_error`, `connected_since`, `server` (`version`, `jetstream`, `max_payload`) and
  `pending` (requests waiting on an answer).
  """
  @spec status(server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 1_000)
  catch
    :exit, _ ->
      %{
        state: "down",
        reconnects: 0,
        last_error: nil,
        connected_since: nil,
        server: nil,
        pending: 0
      }
  end

  @doc "Whether the connection is up now."
  @spec connected?(server()) :: boolean()
  def connected?(server \\ __MODULE__), do: status(server).state == "connected"

  @doc """
  Publishes `payload` on `subject` with `headers` and waits for the one
  reply. Returns the reply frame (`OptimalEngine.Storage.NATS.Protocol.msg/0`):
  a reply with a status header (`503`: nobody serves the subject) is a reply
  too, the caller reads it.
  """
  @spec request(server(), String.t(), iodata(), map(), timeout()) ::
          {:ok, Protocol.msg()} | {:error, term()}
  def request(server, subject, payload, headers \\ %{}, timeout \\ @default_timeout) do
    call(server, {:request, subject, payload, headers, timeout}, timeout)
  end

  @doc "Publishes without waiting for anything but the write to the socket."
  @spec publish(server(), String.t(), iodata(), map()) :: :ok | {:error, term()}
  def publish(server, subject, payload, headers \\ %{}) do
    call(server, {:publish, subject, payload, headers}, @default_timeout)
  end

  @doc """
  Sends `body` to `subject` (a `$JS.API.CONSUMER.MSG.NEXT` pull) on a
  subscription of its own and collects what arrives: up to `batch` messages,
  ending at the first status reply (`404` nothing there, `408` the pull
  expired, `409` the consumer cannot serve it) or after `timeout`.
  """
  @spec pull(server(), String.t(), iodata(), pos_integer(), timeout()) ::
          {:ok, [Protocol.msg()]} | {:error, term()}
  def pull(server, subject, body, batch, timeout) do
    call(server, {:pull, subject, body, batch, timeout}, timeout)
  end

  # The server closes a connection that sends more than its max_payload
  # (the header block and the payload together), which would drop every
  # request on it and meet the same message after the reconnect: such a
  # message is refused here. The size is what `Protocol.pub/4` sends: a plain
  # PUB (no headers) has no header block.
  defp fits(%{server: %{max_payload: max}}, payload, headers) when is_integer(max) do
    block = if headers in [%{}, []], do: 0, else: byte_size(Protocol.header_block(headers))
    size = IO.iodata_length(payload) + block

    if size > max, do: {:error, {:payload_too_large, size, max}}, else: :ok
  end

  defp fits(_state, _payload, _headers), do: :ok

  defp call(server, message, timeout) do
    GenServer.call(server, message, timeout + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :not_connected}
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    config =
      if Keyword.has_key?(opts, :url) do
        case Keyword.get(opts, :url) do
          nil -> {:error, :not_configured}
          url -> NATS.config(url: url)
        end
      else
        NATS.config()
      end

    {min_backoff, max_backoff} = Keyword.get(opts, :backoff, @default_backoff)

    state = %{
      config: nil,
      state: :not_configured,
      socket: nil,
      buffer: "",
      attempt: 0,
      reconnects: 0,
      last_error: nil,
      connected_since: nil,
      server: nil,
      inbox: nil,
      next_sid: 2,
      requests: %{},
      pulls: %{},
      pings_out: 0,
      ping_timer: nil,
      backoff: {min_backoff, max_backoff},
      connect_timeout: Keyword.get(opts, :connect_timeout, @default_timeout),
      ping_interval: Keyword.get(opts, :ping_interval, @default_ping_interval)
    }

    case config do
      {:ok, config} ->
        {:ok, %{state | config: config, state: :connecting}, {:continue, :connect}}

      {:error, :not_configured} ->
        {:ok, state}

      {:error, reason} ->
        {:ok, %{state | last_error: describe(reason)}}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       state: Atom.to_string(state.state),
       reconnects: state.reconnects,
       last_error: state.last_error,
       connected_since: state.connected_since,
       server: state.server,
       pending: map_size(state.requests) + map_size(state.pulls)
     }, state}
  end

  def handle_call(_request, _from, %{state: s} = state) when s != :connected,
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:publish, subject, payload, headers}, _from, state) do
    with :ok <- fits(state, payload, headers),
         :ok <- write(state, Protocol.pub(subject, nil, payload, headers)) do
      {:reply, :ok, state}
    else
      {:error, {:payload_too_large, _size, _max} = reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, :not_connected}, lost(state, reason)}
    end
  rescue
    error in ArgumentError -> {:reply, {:error, {:invalid, Exception.message(error)}}, state}
  end

  def handle_call({:request, subject, payload, headers, timeout}, from, state) do
    reply = state.inbox <> "." <> random()

    with :ok <- fits(state, payload, headers),
         :ok <- write(state, Protocol.pub(subject, reply, payload, headers)) do
      timer = Process.send_after(self(), {:request_timeout, reply}, timeout)
      {:noreply, put_in(state, [:requests, reply], {from, timer})}
    else
      {:error, {:payload_too_large, _size, _max} = reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, :not_connected}, lost(state, reason)}
    end
  rescue
    error in ArgumentError -> {:reply, {:error, {:invalid, Exception.message(error)}}, state}
  end

  def handle_call({:pull, subject, body, batch, timeout}, from, state) do
    sid = Integer.to_string(state.next_sid)
    inbox = "_INBOX." <> random()

    with :ok <- fits(state, body, %{}),
         :ok <- write(state, [Protocol.sub(inbox, sid), Protocol.pub(subject, inbox, body)]) do
      timer = Process.send_after(self(), {:pull_timeout, sid}, timeout)
      pull = %{from: from, timer: timer, batch: batch, messages: []}
      {:noreply, %{state | next_sid: state.next_sid + 1, pulls: Map.put(state.pulls, sid, pull)}}
    else
      {:error, {:payload_too_large, _size, _max} = reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, :not_connected}, lost(state, reason)}
    end
  end

  @impl GenServer
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info({transport, socket, data}, %{socket: socket} = state)
      when transport in [:tcp, :ssl] do
    case Protocol.parse(state.buffer <> data) do
      {:ok, frames, rest} ->
        state = Enum.reduce(frames, %{state | buffer: rest}, &frame/2)
        if state.socket, do: activate(state)
        {:noreply, state}

      {:error, reason} ->
        {:noreply, lost(state, {:protocol, reason})}
    end
  end

  def handle_info({closed, socket}, %{socket: socket} = state)
      when closed in [:tcp_closed, :ssl_closed],
      do: {:noreply, lost(state, :closed)}

  def handle_info({error, socket, reason}, %{socket: socket} = state)
      when error in [:tcp_error, :ssl_error],
      do: {:noreply, lost(state, reason)}

  def handle_info({:request_timeout, reply}, state) do
    case Map.pop(state.requests, reply) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, requests} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | requests: requests}}
    end
  end

  def handle_info({:pull_timeout, sid}, state), do: {:noreply, finish_pull(state, sid)}

  def handle_info(:ping, %{state: :connected} = state) do
    if state.pings_out >= @max_pings_out do
      {:noreply, lost(state, :stale_connection)}
    else
      case write(state, Protocol.ping()) do
        :ok -> {:noreply, schedule_ping(%{state | pings_out: state.pings_out + 1})}
        {:error, reason} -> {:noreply, lost(state, reason)}
      end
    end
  end

  def handle_info(:ping, state), do: {:noreply, state}

  # A message for a socket this process no longer holds.
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.socket, do: close(state.socket)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Frames
  # ---------------------------------------------------------------------------

  defp frame(_frame, %{socket: nil} = state), do: state

  defp frame(:ping, state) do
    case write(state, Protocol.pong()) do
      :ok -> state
      {:error, reason} -> lost(state, reason)
    end
  end

  defp frame(:pong, state), do: %{state | pings_out: 0}

  defp frame({:err, message}, state) do
    Logger.warning("[NATS] server error: #{message}")
    %{state | last_error: "server: " <> message}
  end

  defp frame({:msg, %{sid: @inbox_sid, subject: reply} = msg}, state) do
    case Map.pop(state.requests, reply) do
      {nil, _} ->
        state

      {{from, timer}, requests} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, msg})
        %{state | requests: requests}
    end
  end

  defp frame({:msg, %{sid: sid} = msg}, state) do
    case state.pulls[sid] do
      nil ->
        state

      # Idle heartbeats and flow control are not messages.
      _pull when msg.status == "100" ->
        state

      _pull when is_binary(msg.status) ->
        finish_pull(state, sid)

      pull ->
        pull = %{pull | messages: [msg | pull.messages]}
        state = put_in(state, [:pulls, sid], pull)
        if length(pull.messages) >= pull.batch, do: finish_pull(state, sid), else: state
    end
  end

  defp frame(_other, state), do: state

  defp finish_pull(state, sid) do
    case Map.pop(state.pulls, sid) do
      {nil, _} ->
        state

      {pull, pulls} ->
        Process.cancel_timer(pull.timer)
        GenServer.reply(pull.from, {:ok, Enum.reverse(pull.messages)})
        state = %{state | pulls: pulls}

        case state.socket && write(state, Protocol.unsub(sid)) do
          {:error, reason} -> lost(state, reason)
          _ -> state
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Connecting and losing the connection
  # ---------------------------------------------------------------------------

  defp connect(%{config: config} = state) do
    timeout = state.connect_timeout

    case open(config, timeout) do
      {:ok, socket, info, buffer} ->
        state = %{
          state
          | socket: socket,
            buffer: buffer,
            state: :connected,
            attempt: 0,
            inbox: "_INBOX." <> random(),
            connected_since:
              DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
            server: %{
              version: info["version"],
              jetstream: info["jetstream"] == true,
              max_payload: info["max_payload"]
            },
            pings_out: 0
        }

        case write(state, Protocol.sub(state.inbox <> ".*", @inbox_sid)) do
          :ok ->
            if state.reconnects > 0, do: Logger.info("[NATS] reconnected")
            activate(state)
            schedule_ping(state)

          {:error, reason} ->
            lost(state, reason)
        end

      {:error, reason} ->
        retry(%{state | state: :disconnected, last_error: describe(reason)})
    end
  end

  # The handshake runs on a passive socket: INFO, the TLS upgrade for
  # `tls://`, CONNECT, then a PING whose PONG proves the server took the
  # CONNECT (it answers -ERR and closes for a refused credential).
  defp open(config, timeout) do
    with {:ok, config} <- NATS.credentials(config),
         {:ok, tcp} <-
           :gen_tcp.connect(
             String.to_charlist(config.hostname),
             config.port,
             [:binary, active: false],
             timeout
           ) do
      case handshake(tcp, config, timeout) do
        {:ok, socket, info, buffer} ->
          {:ok, socket, info, buffer}

        {:error, reason, socket} ->
          close(socket)
          {:error, reason}
      end
    end
  catch
    kind, reason -> {:error, {:connect, kind, reason}}
  end

  defp handshake(tcp, config, timeout) do
    with {:ok, {:info, info}, buffer} <- read_frame(tcp, "", timeout),
         {:ok, socket} <- upgrade(tcp, config, timeout),
         :ok <- send_data(socket, [Protocol.connect(NATS.connect_options(config)), Protocol.ping()]),
         {:ok, buffer} <- await_pong(socket, buffer, timeout) do
      {:ok, socket, info, buffer}
    else
      {:ok, other, _buffer} -> {:error, {:protocol, other}, tcp}
      {:error, reason, socket} -> {:error, reason, socket}
      {:error, reason} -> {:error, reason, tcp}
    end
  end

  defp upgrade(tcp, %{ssl: true} = config, timeout) do
    options =
      [mode: :binary, active: false, server_name_indication: String.to_charlist(config.hostname)] ++
        OptimalEngine.Connectors.HTTP.ssl_options("https://" <> config.hostname)

    case :ssl.connect(tcp, options, timeout) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:tls, reason}, tcp}
    end
  end

  defp upgrade(tcp, _config, _timeout), do: {:ok, tcp}

  defp await_pong(socket, buffer, timeout) do
    case read_frame(socket, buffer, timeout) do
      {:ok, :pong, rest} -> {:ok, rest}
      {:ok, {:err, message}, _rest} -> {:error, {:server, message}, socket}
      {:ok, _other, rest} -> await_pong(socket, rest, timeout)
      {:error, reason} -> {:error, reason, socket}
    end
  end

  # One control line (INFO, PONG, -ERR) and the bytes after it. Nothing else
  # arrives before the client subscribes, so a MSG here is a protocol error.
  defp read_frame(socket, buffer, timeout) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        case Protocol.parse(line <> "\r\n") do
          {:ok, [frame], ""} -> {:ok, frame, rest}
          _ -> {:error, {:protocol, :unexpected_frame}}
        end

      [_partial] ->
        case recv(socket, timeout) do
          {:ok, data} -> read_frame(socket, buffer <> data, timeout)
          {:error, reason} -> {:error, {:recv, reason}}
        end
    end
  end

  defp lost(%{socket: nil} = state, _reason), do: state

  defp lost(state, reason) do
    close(state.socket)
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)
    Logger.warning("[NATS] connection lost: #{describe(reason)}")

    Enum.each(state.requests, fn {_reply, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :disconnected})
    end)

    Enum.each(state.pulls, fn {_sid, pull} ->
      Process.cancel_timer(pull.timer)
      GenServer.reply(pull.from, {:error, :disconnected})
    end)

    retry(%{
      state
      | socket: nil,
        buffer: "",
        state: :disconnected,
        requests: %{},
        pulls: %{},
        ping_timer: nil,
        connected_since: nil,
        reconnects: state.reconnects + 1,
        last_error: describe(reason)
    })
  end

  defp retry(state) do
    {min_ms, max_ms} = state.backoff
    delay = min(max_ms, min_ms * Integer.pow(2, min(state.attempt, 16)))
    jitter = :rand.uniform(max(div(delay, 4), 1))
    Process.send_after(self(), :connect, delay + jitter)
    %{state | attempt: state.attempt + 1}
  end

  defp schedule_ping(state) do
    %{state | ping_timer: Process.send_after(self(), :ping, state.ping_interval)}
  end

  # A reason as an operator reads it. Built from the reason alone, which never
  # carries the URL: the credential is in the state's config and nowhere else.
  defp describe({:server, message}), do: "server: " <> message
  defp describe({:recv, reason}), do: "receive: " <> describe(reason)
  defp describe({:tls, reason}), do: "tls: " <> inspect(reason)
  defp describe({:protocol, reason}), do: "protocol: " <> inspect(reason)
  defp describe({:connect, _kind, _reason}), do: "connect failed"
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)

  # ---------------------------------------------------------------------------
  # Socket
  # ---------------------------------------------------------------------------

  defp write(%{socket: socket}, data), do: send_data(socket, data)

  defp activate(%{socket: {:sslsocket, _, _} = socket}), do: :ssl.setopts(socket, active: :once)
  defp activate(%{socket: socket}), do: :inet.setopts(socket, active: :once)

  defp send_data({:sslsocket, _, _} = socket, data), do: :ssl.send(socket, data)
  defp send_data(socket, data), do: :gen_tcp.send(socket, data)

  defp recv({:sslsocket, _, _} = socket, timeout), do: :ssl.recv(socket, 0, timeout)
  defp recv(socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  defp close(nil), do: :ok
  defp close({:sslsocket, _, _} = socket), do: :ssl.close(socket)
  defp close(socket), do: :gen_tcp.close(socket)

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
