defmodule OptimalEngine.TestSupport.NATSStub do
  @moduledoc """
  A local NATS server for tests: the slice of the text protocol and the
  JetStream API the provider uses. It sends `INFO`, accepts `CONNECT`, `PING`,
  `SUB` and `PUB`, and answers requests to `$JS.API.INFO`,
  `$JS.API.STREAM.CREATE.<name>`, `$JS.API.STREAM.MSG.GET.<name>` and
  `$JS.API.STREAM.DELETE.<name>` from an in-memory stream table; a publish on a
  stream's subject is stored and acknowledged. Written independently of
  `OptimalEngine.Storage.NATS`, parsing requests as they arrive on the wire.

  Options: `:jetstream` (false makes every `$JS.API` request a 503 "no
  responders", as a core server without JetStream does), `:token` (the stub
  refuses a `CONNECT` whose `auth_token` differs).
  """

  @doc "Starts a listener on a free port. Returns `{:ok, %{port:, agent:, listener:}}`."
  @spec start(keyword()) :: {:ok, map()}
  def start(opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> %{streams: %{}, commands: []} end)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    settings = %{jetstream: Keyword.get(opts, :jetstream, true), token: Keyword.get(opts, :token)}
    spawn_link(fn -> accept(listener, agent, settings) end)
    {:ok, %{port: port, agent: agent, listener: listener}}
  end

  @doc "Stops the listener."
  @spec stop(map()) :: :ok
  def stop(%{listener: listener}), do: :gen_tcp.close(listener)

  @doc "Every control line served, oldest first."
  @spec commands(map()) :: [String.t()]
  def commands(%{agent: agent}), do: agent |> Agent.get(& &1.commands) |> Enum.reverse()

  @doc "The streams the stub holds now, by name."
  @spec streams(map()) :: map()
  def streams(%{agent: agent}), do: Agent.get(agent, & &1.streams)

  defp accept(listener, agent, settings) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn_link(fn ->
          :ok =
            :gen_tcp.send(
              socket,
              "INFO #{Jason.encode!(%{server_id: "stub", version: "2.10.0", jetstream: settings.jetstream, max_payload: 1_048_576})}\r\n"
            )

          serve(socket, agent, settings, %{subs: %{}, buffer: ""})
        end)

        accept(listener, agent, settings)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, agent, settings, state) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        case handle_all(socket, agent, settings, %{state | buffer: state.buffer <> data}) do
          {:ok, state} -> serve(socket, agent, settings, state)
          :close -> :gen_tcp.close(socket)
        end

      {:error, _closed} ->
        :gen_tcp.close(socket)
    end
  end

  defp handle_all(socket, agent, settings, state) do
    case String.split(state.buffer, "\r\n", parts: 2) do
      [line, rest] ->
        Agent.update(agent, &%{&1 | commands: [line | &1.commands]})

        case handle(line, rest, socket, agent, settings, state) do
          {:ok, state} -> handle_all(socket, agent, settings, state)
          :incomplete -> {:ok, state}
          :close -> :close
        end

      [_partial] ->
        {:ok, state}
    end
  end

  defp handle("CONNECT " <> json, rest, socket, _agent, settings, state) do
    options = Jason.decode!(json)

    if is_nil(settings.token) or options["auth_token"] == settings.token do
      {:ok, %{state | buffer: rest}}
    else
      :ok = :gen_tcp.send(socket, "-ERR 'Authorization Violation'\r\n")
      :close
    end
  end

  defp handle("PING", rest, socket, _agent, _settings, state) do
    :ok = :gen_tcp.send(socket, "PONG\r\n")
    {:ok, %{state | buffer: rest}}
  end

  defp handle("PONG", rest, _socket, _agent, _settings, state), do: {:ok, %{state | buffer: rest}}

  defp handle("SUB " <> args, rest, _socket, _agent, _settings, state) do
    [subject, sid] = args |> String.split(" ") |> Enum.take(2)
    {:ok, %{state | buffer: rest, subs: Map.put(state.subs, subject, sid)}}
  end

  defp handle("PUB " <> args, rest, socket, agent, settings, state) do
    {subject, reply, size} =
      case String.split(args, " ") do
        [subject, reply, size] -> {subject, reply, String.to_integer(size)}
        [subject, size] -> {subject, nil, String.to_integer(size)}
      end

    if byte_size(rest) >= size + 2 do
      <<payload::binary-size(size), "\r\n", remaining::binary>> = rest
      if reply, do: respond(socket, agent, settings, state, subject, reply, payload)
      {:ok, %{state | buffer: remaining}}
    else
      :incomplete
    end
  end

  defp handle(_other, rest, socket, _agent, _settings, state) do
    :ok = :gen_tcp.send(socket, "-ERR 'Unknown Protocol Operation'\r\n")
    {:ok, %{state | buffer: rest}}
  end

  # Replies go to the reply subject through the subscription that covers it.
  defp respond(socket, agent, settings, state, subject, reply, payload) do
    sid = sid_for(state.subs, reply)

    case answer(subject, payload, agent, settings) do
      {:json, map} ->
        body = Jason.encode!(map)
        :ok = :gen_tcp.send(socket, "MSG #{reply} #{sid} #{byte_size(body)}\r\n#{body}\r\n")

      :no_responders ->
        headers = "NATS/1.0 503\r\n\r\n"

        :ok =
          :gen_tcp.send(
            socket,
            "HMSG #{reply} #{sid} #{byte_size(headers)} #{byte_size(headers)}\r\n#{headers}\r\n"
          )
    end
  end

  defp sid_for(subs, reply) do
    Enum.find_value(subs, "1", fn {pattern, sid} ->
      prefix = String.trim_trailing(pattern, "*")
      if String.starts_with?(reply, prefix), do: sid
    end)
  end

  defp answer("$JS.API." <> _api, _payload, _agent, %{jetstream: false}), do: :no_responders

  defp answer("$JS.API.INFO", _payload, agent, _settings) do
    {:json,
     %{
       type: "io.nats.jetstream.api.v1.account_info_response",
       memory: 0,
       storage: 0,
       streams: map_size(streams(%{agent: agent})),
       consumers: 0
     }}
  end

  defp answer("$JS.API.STREAM.CREATE." <> name, payload, agent, _settings) do
    config = Jason.decode!(payload)
    Agent.update(agent, &put_in(&1, [:streams, name], %{config: config, messages: []}))

    {:json,
     %{
       type: "io.nats.jetstream.api.v1.stream_create_response",
       config: config,
       state: %{messages: 0}
     }}
  end

  defp answer("$JS.API.STREAM.MSG.GET." <> name, payload, agent, _settings) do
    %{"seq" => seq} = Jason.decode!(payload)

    case Agent.get(agent, &get_in(&1, [:streams, name])) do
      %{messages: messages} ->
        case Enum.find(messages, &(&1.seq == seq)) do
          nil ->
            {:json, %{error: %{code: 404, description: "no message found"}}}

          message ->
            {:json,
             %{
               message: %{
                 subject: message.subject,
                 seq: seq,
                 data: Base.encode64(message.data),
                 time: "2026-11-02T00:00:00Z"
               }
             }}
        end

      nil ->
        {:json, %{error: %{code: 404, description: "stream not found"}}}
    end
  end

  defp answer("$JS.API.STREAM.DELETE." <> name, _payload, agent, _settings) do
    Agent.update(agent, &%{&1 | streams: Map.delete(&1.streams, name)})
    {:json, %{success: true}}
  end

  defp answer("$JS.API." <> _other, _payload, _agent, _settings),
    do: {:json, %{error: %{code: 404, description: "unknown api"}}}

  # A publish on a subject some stream covers is stored and acknowledged.
  defp answer(subject, payload, agent, _settings) do
    Agent.get_and_update(agent, fn state ->
      case Enum.find(state.streams, fn {_name, s} -> subject in (s.config["subjects"] || []) end) do
        {name, stream} ->
          seq = length(stream.messages) + 1
          message = %{seq: seq, subject: subject, data: payload}
          updated = put_in(state, [:streams, name, :messages], stream.messages ++ [message])
          {{:json, %{stream: name, seq: seq}}, updated}

        nil ->
          {:no_responders, state}
      end
    end)
  end
end
