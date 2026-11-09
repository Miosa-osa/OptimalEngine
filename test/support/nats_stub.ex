defmodule OptimalEngine.TestSupport.NATSStub do
  @moduledoc """
  A local NATS server for tests: the slice of the text protocol and the
  JetStream API the provider uses. It sends `INFO`, accepts `CONNECT`, `PING`,
  `SUB`, `UNSUB`, `PUB` and `HPUB`, and answers requests to `$JS.API.INFO`,
  `$JS.API.STREAM.CREATE|UPDATE|INFO|DELETE.<name>`,
  `$JS.API.STREAM.MSG.GET.<name>` (by `seq` or `last_by_subj`),
  `$JS.API.CONSUMER.CREATE.<stream>.<name>` and
  `$JS.API.CONSUMER.MSG.NEXT.<stream>.<name>` from an in-memory stream table.
  A publish on a stream's subject is stored and acknowledged, once per
  `Nats-Msg-Id`; a pull delivers what the consumer has not had acknowledged,
  each message with a `$JS.ACK` reply the client answers with `+ACK`, `-NAK`
  (redelivered at once, or after its `delay`), `+TERM` or `+WPI`. A
  `workqueue` stream forgets a message once it is acknowledged. Written
  independently of `OptimalEngine.Storage.NATS`, parsing requests as they
  arrive on the wire.

  Options: `:jetstream` (false makes every `$JS.API` request a 503 "no
  responders", as a core server without JetStream does), `:token` (the stub
  refuses a `CONNECT` whose `auth_token` differs), `:delete` (`:refused`
  answers a stream delete with a permissions error), `:port` (listen on this
  port, to stand a server back up where a client is reconnecting).
  """

  @doc "Starts a listener on a free port. Returns `{:ok, %{port:, agent:, listener:}}`."
  @spec start(keyword()) :: {:ok, map()}
  def start(opts \\ []) do
    {:ok, agent} =
      Agent.start(fn -> %{streams: %{}, consumers: %{}, commands: [], sockets: []} end)

    {:ok, listener} =
      :gen_tcp.listen(Keyword.get(opts, :port, 0), [:binary, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    settings = %{
      jetstream: Keyword.get(opts, :jetstream, true),
      token: Keyword.get(opts, :token),
      delete: Keyword.get(opts, :delete, :ok)
    }

    spawn(fn -> accept(listener, agent, settings) end)
    {:ok, %{port: port, agent: agent, listener: listener}}
  end

  @doc "Stops the listener and closes every connection it accepted."
  @spec stop(map()) :: :ok
  def stop(%{listener: listener, agent: agent} = stub) do
    :gen_tcp.close(listener)
    drop(stub)
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Closes every connection the stub holds, as a server restart does; keeps listening."
  @spec drop(map()) :: :ok
  def drop(%{agent: agent}) do
    if Process.alive?(agent) do
      agent
      |> Agent.get_and_update(&{&1.sockets, %{&1 | sockets: []}})
      |> Enum.each(&:gen_tcp.close/1)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Every control line served, oldest first."
  @spec commands(map()) :: [String.t()]
  def commands(%{agent: agent}), do: agent |> Agent.get(& &1.commands) |> Enum.reverse()

  @doc "The streams the stub holds now, by name."
  @spec streams(map()) :: map()
  def streams(%{agent: agent}), do: Agent.get(agent, & &1.streams)

  @doc "The messages a stream holds now, oldest first."
  @spec messages(map(), String.t()) :: [map()]
  def messages(stub, stream), do: get_in(streams(stub), [stream, :messages]) || []

  @doc "The consumers the stub holds now, by `{stream, name}`."
  @spec consumers(map()) :: map()
  def consumers(%{agent: agent}), do: Agent.get(agent, & &1.consumers)

  defp accept(listener, agent, settings) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        Agent.update(agent, &%{&1 | sockets: [socket | &1.sockets]})

        pid =
          spawn(fn ->
            receive do
              :go -> :ok
            end

            :ok =
              :gen_tcp.send(
                socket,
                "INFO #{Jason.encode!(%{server_id: "stub", version: "2.10.0", jetstream: settings.jetstream, headers: true, max_payload: 1_048_576})}\r\n"
              )

            serve(socket, agent, settings, %{subs: %{}, buffer: ""})
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listener, agent, settings)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, agent, settings, state) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        case handle_all(socket, agent, settings, %{state | buffer: state.buffer <> data}) do
          {:ok, state} -> serve(socket, agent, settings, state)
          :close -> :gen_tcp.close(socket)
        end

      {:error, _closed} ->
        :gen_tcp.close(socket)
    end
  catch
    :exit, _ -> :gen_tcp.close(socket)
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
      _ = :gen_tcp.send(socket, "-ERR 'Authorization Violation'\r\n")
      :close
    end
  end

  defp handle("PING", rest, socket, _agent, _settings, state) do
    _ = :gen_tcp.send(socket, "PONG\r\n")
    {:ok, %{state | buffer: rest}}
  end

  defp handle("PONG", rest, _socket, _agent, _settings, state), do: {:ok, %{state | buffer: rest}}

  defp handle("SUB " <> args, rest, _socket, _agent, _settings, state) do
    [subject, sid] = args |> String.split(" ") |> Enum.take(2)
    {:ok, %{state | buffer: rest, subs: Map.put(state.subs, subject, sid)}}
  end

  defp handle("UNSUB " <> args, rest, _socket, _agent, _settings, state) do
    sid = args |> String.split(" ") |> hd()
    subs = state.subs |> Enum.reject(fn {_subject, s} -> s == sid end) |> Map.new()
    {:ok, %{state | buffer: rest, subs: subs}}
  end

  defp handle("PUB " <> args, rest, socket, agent, settings, state) do
    {subject, reply, size} =
      case String.split(args, " ") do
        [subject, reply, size] -> {subject, reply, String.to_integer(size)}
        [subject, size] -> {subject, nil, String.to_integer(size)}
      end

    if byte_size(rest) >= size + 2 do
      <<payload::binary-size(size), "\r\n", remaining::binary>> = rest
      published(socket, agent, settings, state, subject, reply, %{}, payload)
      {:ok, %{state | buffer: remaining}}
    else
      :incomplete
    end
  end

  defp handle("HPUB " <> args, rest, socket, agent, settings, state) do
    {subject, reply, header_size, size} =
      case String.split(args, " ") do
        [subject, reply, hsize, size] ->
          {subject, reply, String.to_integer(hsize), String.to_integer(size)}

        [subject, hsize, size] ->
          {subject, nil, String.to_integer(hsize), String.to_integer(size)}
      end

    if byte_size(rest) >= size + 2 do
      <<data::binary-size(size), "\r\n", remaining::binary>> = rest
      <<block::binary-size(header_size), payload::binary>> = data
      published(socket, agent, settings, state, subject, reply, parse_headers(block), payload)
      {:ok, %{state | buffer: remaining}}
    else
      :incomplete
    end
  end

  defp handle(_other, rest, socket, _agent, _settings, state) do
    _ = :gen_tcp.send(socket, "-ERR 'Unknown Protocol Operation'\r\n")
    {:ok, %{state | buffer: rest}}
  end

  defp parse_headers(block) do
    block
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> [{String.trim(name), String.trim(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  # An acknowledgement changes the consumer; anything else with a reply subject
  # is a request the stub answers.
  defp published(_socket, agent, _settings, _state, "$JS.ACK." <> _ = subject, _reply, _h, payload),
    do: acknowledge(agent, subject, payload)

  defp published(
         socket,
         agent,
         settings,
         state,
         "$JS.API.CONSUMER.MSG.NEXT." <> names,
         reply,
         _h,
         payload
       )
       when is_binary(reply) do
    if settings.jetstream,
      do: next(socket, agent, state, names, reply, payload),
      else: send_status(socket, reply, sid_for(state.subs, reply), "503")
  end

  defp published(socket, agent, settings, state, subject, reply, headers, payload) do
    case answer(subject, headers, payload, agent, settings) do
      _ when is_nil(reply) -> :ok
      {:json, map} -> send_msg(socket, reply, sid_for(state.subs, reply), Jason.encode!(map))
      :no_responders -> send_status(socket, reply, sid_for(state.subs, reply), "503")
    end
  end

  defp send_msg(socket, subject, sid, body, reply \\ nil, headers \\ nil)

  defp send_msg(socket, subject, sid, body, reply, nil) do
    reply_part = if reply, do: " #{reply}", else: ""

    _ =
      :gen_tcp.send(socket, "MSG #{subject} #{sid}#{reply_part} #{byte_size(body)}\r\n#{body}\r\n")

    :ok
  end

  defp send_msg(socket, subject, sid, body, reply, headers) do
    block =
      "NATS/1.0\r\n" <> Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <> "\r\n"

    reply_part = if reply, do: " #{reply}", else: ""

    _ =
      :gen_tcp.send(
        socket,
        "HMSG #{subject} #{sid}#{reply_part} #{byte_size(block)} #{byte_size(block) + byte_size(body)}\r\n#{block}#{body}\r\n"
      )

    :ok
  end

  defp send_status(socket, subject, sid, status, description \\ nil) do
    line = if description, do: "NATS/1.0 #{status} #{description}", else: "NATS/1.0 #{status}"
    headers = line <> "\r\n\r\n"

    _ =
      :gen_tcp.send(
        socket,
        "HMSG #{subject} #{sid} #{byte_size(headers)} #{byte_size(headers)}\r\n#{headers}\r\n"
      )

    :ok
  end

  defp sid_for(subs, reply) do
    Enum.find_value(subs, "1", fn {pattern, sid} ->
      cond do
        pattern == reply ->
          sid

        String.ends_with?(pattern, "*") and
            String.starts_with?(reply, String.trim_trailing(pattern, "*")) ->
          sid

        true ->
          nil
      end
    end)
  end

  defp answer("$JS.API." <> _api, _headers, _payload, _agent, %{jetstream: false}),
    do: :no_responders

  defp answer("$JS.API.INFO", _headers, _payload, agent, _settings) do
    {:json,
     %{
       type: "io.nats.jetstream.api.v1.account_info_response",
       memory: 0,
       storage: 0,
       streams: map_size(streams(%{agent: agent})),
       consumers: 0
     }}
  end

  defp answer("$JS.API.STREAM.CREATE." <> name, _headers, payload, agent, _settings) do
    config = Jason.decode!(payload)

    Agent.get_and_update(agent, fn state ->
      case state.streams[name] do
        nil ->
          stream = %{config: config, messages: [], last_seq: 0, ids: %{}}
          {{:json, stream_info(stream)}, put_in(state, [:streams, name], stream)}

        %{config: ^config} = stream ->
          {{:json, stream_info(stream)}, state}

        _different ->
          {{:json,
            js_error(400, 10_058, "stream name already in use with a different configuration")},
           state}
      end
    end)
  end

  defp answer("$JS.API.STREAM.UPDATE." <> name, _headers, payload, agent, _settings) do
    config = Jason.decode!(payload)

    Agent.get_and_update(agent, fn state ->
      case state.streams[name] do
        nil ->
          {{:json, js_error(404, 10_059, "stream not found")}, state}

        stream ->
          stream = %{stream | config: config}
          {{:json, stream_info(stream)}, put_in(state, [:streams, name], stream)}
      end
    end)
  end

  defp answer("$JS.API.STREAM.INFO." <> name, _headers, _payload, agent, _settings) do
    case Agent.get(agent, &get_in(&1, [:streams, name])) do
      nil -> {:json, js_error(404, 10_059, "stream not found")}
      stream -> {:json, stream_info(stream)}
    end
  end

  defp answer("$JS.API.STREAM.MSG.GET." <> name, _headers, payload, agent, _settings) do
    request = Jason.decode!(payload)

    case Agent.get(agent, &get_in(&1, [:streams, name])) do
      %{messages: messages} ->
        found =
          case request do
            %{"seq" => seq} ->
              Enum.find(messages, &(&1.seq == seq))

            %{"last_by_subj" => subject} ->
              messages |> Enum.filter(&(&1.subject == subject)) |> List.last()
          end

        case found do
          nil ->
            {:json, js_error(404, 10_037, "no message found")}

          message ->
            {:json,
             %{
               message:
                 %{
                   subject: message.subject,
                   seq: message.seq,
                   data: Base.encode64(message.data),
                   time: "2026-11-02T00:00:00Z"
                 }
                 |> put_hdrs(message.headers)
             }}
        end

      nil ->
        {:json, js_error(404, 10_059, "stream not found")}
    end
  end

  # `delete: :refused` answers as a server whose permissions do not allow it.
  defp answer("$JS.API.STREAM.DELETE." <> _name, _headers, _payload, _agent, %{delete: :refused}),
    do: {:json, %{error: %{code: 403, description: "permissions violation"}}}

  defp answer("$JS.API.STREAM.DELETE." <> name, _headers, _payload, agent, _settings) do
    Agent.update(agent, &%{&1 | streams: Map.delete(&1.streams, name)})
    {:json, %{success: true}}
  end

  defp answer("$JS.API.CONSUMER.CREATE." <> names, _headers, payload, agent, _settings) do
    [stream, name | _filter] = String.split(names, ".")
    %{"config" => config} = Jason.decode!(payload)

    Agent.get_and_update(agent, fn state ->
      cond do
        is_nil(state.streams[stream]) ->
          {{:json, js_error(404, 10_059, "stream not found")}, state}

        consumer = state.consumers[{stream, name}] ->
          consumer = %{consumer | config: config}

          {{:json, consumer_info(stream, name, consumer)},
           put_in(state, [:consumers, {stream, name}], consumer)}

        true ->
          consumer = %{config: config, acked: MapSet.new(), pending: %{}, deliveries: %{}, cseq: 0}

          {{:json, consumer_info(stream, name, consumer)},
           put_in(state, [:consumers, {stream, name}], consumer)}
      end
    end)
  end

  defp answer("$JS.API." <> _other, _headers, _payload, _agent, _settings),
    do: {:json, %{error: %{code: 404, description: "unknown api"}}}

  # A publish on a subject some stream covers is stored and acknowledged, once
  # per Nats-Msg-Id.
  defp answer(subject, headers, payload, agent, _settings) do
    Agent.get_and_update(agent, fn state ->
      case Enum.find(state.streams, fn {_name, s} ->
             covers?(s.config["subjects"] || [], subject)
           end) do
        {name, stream} ->
          msg_id = headers["Nats-Msg-Id"]

          case msg_id && stream.ids[msg_id] do
            seq when is_integer(seq) ->
              {{:json, %{stream: name, seq: seq, duplicate: true}}, state}

            _ ->
              seq = stream.last_seq + 1
              message = %{seq: seq, subject: subject, data: payload, headers: headers}

              stream = %{
                stream
                | messages: stream.messages ++ [message],
                  last_seq: seq,
                  ids: if(msg_id, do: Map.put(stream.ids, msg_id, seq), else: stream.ids)
              }

              {{:json, %{stream: name, seq: seq}}, put_in(state, [:streams, name], stream)}
          end

        nil ->
          {:no_responders, state}
      end
    end)
  end

  defp covers?(patterns, subject) do
    Enum.any?(patterns, fn pattern ->
      if String.ends_with?(pattern, ".>"),
        do: String.starts_with?(subject, String.trim_trailing(pattern, ">")),
        else: pattern == subject
    end)
  end

  defp put_hdrs(message, headers) when map_size(headers) == 0, do: message

  defp put_hdrs(message, headers) do
    block =
      "NATS/1.0\r\n" <> Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <> "\r\n"

    Map.put(message, :hdrs, Base.encode64(block))
  end

  defp js_error(code, err_code, description),
    do: %{error: %{code: code, err_code: err_code, description: description}}

  defp stream_info(stream) do
    %{
      type: "io.nats.jetstream.api.v1.stream_info_response",
      config: stream.config,
      state: %{messages: length(stream.messages), last_seq: stream.last_seq}
    }
  end

  defp consumer_info(stream, name, consumer) do
    %{
      type: "io.nats.jetstream.api.v1.consumer_create_response",
      stream_name: stream,
      name: name,
      config: consumer.config,
      num_ack_pending: map_size(consumer.pending)
    }
  end

  # A pull: up to `batch` messages the consumer has not had acknowledged and
  # that are not waiting on an acknowledgement (or whose wait ran out), oldest
  # first. Nothing to deliver: `404` at once for `no_wait`, else `408` when the
  # request expires (a short wait in the stub, so a client loop does not spin).
  defp next(socket, agent, state, names, reply, payload) do
    [stream, name] = String.split(names, ".", parts: 2)
    request = if payload == "", do: %{}, else: Jason.decode!(payload)
    batch = Map.get(request, "batch", 1)
    sid = sid_for(state.subs, reply)
    now = System.monotonic_time(:millisecond)

    delivered =
      Agent.get_and_update(agent, fn st ->
        with %{messages: messages} = s <- st.streams[stream],
             %{} = consumer <- st.consumers[{stream, name}] do
          filter = consumer.config["filter_subject"]
          ack_wait = div(consumer.config["ack_wait"] || 30_000_000_000, 1_000_000)
          max_deliver = consumer.config["max_deliver"] || -1

          due =
            messages
            |> Enum.filter(fn m ->
              (is_nil(filter) or covers?([filter], m.subject)) and
                not MapSet.member?(consumer.acked, m.seq) and
                (max_deliver < 0 or Map.get(consumer.deliveries, m.seq, 0) < max_deliver) and
                case consumer.pending[m.seq] do
                  nil -> true
                  until -> until <= now
                end
            end)
            |> Enum.take(batch)

          {consumer, out} =
            Enum.reduce(due, {consumer, []}, fn m, {c, out} ->
              count = Map.get(c.deliveries, m.seq, 0) + 1
              cseq = c.cseq + 1
              ack = "$JS.ACK.#{stream}.#{name}.#{count}.#{m.seq}.#{cseq}.0.0"

              c = %{
                c
                | deliveries: Map.put(c.deliveries, m.seq, count),
                  pending: Map.put(c.pending, m.seq, now + ack_wait),
                  cseq: cseq
              }

              {c, [{m, ack} | out]}
            end)

          _ = s
          {Enum.reverse(out), put_in(st, [:consumers, {stream, name}], consumer)}
        else
          _ -> {:no_consumer, st}
        end
      end)

    case delivered do
      :no_consumer ->
        send_status(socket, reply, sid, "404", "No Messages")

      [] ->
        if request["no_wait"],
          do: send_status(socket, reply, sid, "404", "No Messages"),
          else: expire_later(socket, reply, sid, request)

      messages ->
        Enum.each(messages, fn {m, ack} ->
          if map_size(m.headers) == 0,
            do: send_msg(socket, m.subject, sid, m.data, ack),
            else: send_msg(socket, m.subject, sid, m.data, ack, m.headers)
        end)

        # A pull the stub could not fill ends as a server ends it: at once for
        # no_wait, when it expires otherwise.
        cond do
          length(messages) >= batch -> :ok
          request["no_wait"] -> send_status(socket, reply, sid, "404", "No Messages")
          true -> expire_later(socket, reply, sid, request)
        end
    end
  end

  defp expire_later(socket, reply, sid, request) do
    wait = min(div(Map.get(request, "expires", 200_000_000), 1_000_000), 200)

    spawn(fn ->
      Process.sleep(wait)
      send_status(socket, reply, sid, "408", "Request Timeout")
    end)

    :ok
  end

  defp acknowledge(agent, "$JS.ACK." <> rest, payload) do
    [stream, name, _count, seq | _] = String.split(rest, ".")
    seq = String.to_integer(seq)
    now = System.monotonic_time(:millisecond)

    Agent.update(agent, fn st ->
      case st.consumers[{stream, name}] do
        nil ->
          st

        consumer ->
          {consumer, remove?} =
            case payload do
              "+ACK" <> _ ->
                {%{
                   consumer
                   | acked: MapSet.put(consumer.acked, seq),
                     pending: Map.delete(consumer.pending, seq)
                 }, true}

              "+TERM" <> _ ->
                {%{
                   consumer
                   | acked: MapSet.put(consumer.acked, seq),
                     pending: Map.delete(consumer.pending, seq)
                 }, true}

              "-NAK" <> delay ->
                until =
                  case Jason.decode(String.trim(delay)) do
                    {:ok, %{"delay" => ns}} -> now + div(ns, 1_000_000)
                    _ -> now
                  end

                {%{consumer | pending: Map.put(consumer.pending, seq, until)}, false}

              "+WPI" <> _ ->
                ack_wait = div(consumer.config["ack_wait"] || 30_000_000_000, 1_000_000)
                {%{consumer | pending: Map.put(consumer.pending, seq, now + ack_wait)}, false}

              _ ->
                {consumer, false}
            end

          st = put_in(st, [:consumers, {stream, name}], consumer)

          if remove? and get_in(st, [:streams, stream, :config, "retention"]) == "workqueue",
            do:
              update_in(
                st,
                [:streams, stream, :messages],
                &Enum.reject(&1, fn m -> m.seq == seq end)
              ),
            else: st
      end
    end)
  end
end
