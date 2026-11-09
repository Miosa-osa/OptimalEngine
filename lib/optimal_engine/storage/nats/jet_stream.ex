defmodule OptimalEngine.Storage.NATS.JetStream do
  @moduledoc """
  The JetStream API on the long-lived connection
  (`OptimalEngine.Storage.NATS.Connection`): streams and durable pull
  consumers provisioned idempotently, publishes acknowledged by the stream,
  and pulls whose messages are acknowledged, refused for redelivery or
  terminated one at a time.

    * `ensure_stream/3`: created when missing, left alone when it already
      holds every setting asked for, updated when one differs (`:created`,
      `:exists`, `:updated`). A setting JetStream cannot change in place (the
      retention or the storage) comes back as the server's error.
    * `ensure_consumer/4`: a durable consumer with explicit acks, created or
      updated (JetStream does both on one call).
    * `publish/4`: a publish the stream acknowledges with its sequence. With
      `:msg_id` it carries `Nats-Msg-Id`, and a second publish of the same id
      within the stream's duplicate window is stored once and acknowledged
      `duplicate: true`, so a publisher that retries after a lost ack never
      writes twice.
    * `fetch/4`: a pull of up to `:batch` messages, each with the number of
      times it was delivered and its stream sequence; `ack/2`, `nak/3`
      (`:delay_ms`), `term/2` and `in_progress/2` answer one.
    * `get_message/3`: a stored message by sequence or the last one on a
      subject, with its headers: how a publisher finds where it left off.

  Every function answers `{:error, :not_connected}` at once while the
  connection is down. Errors JetStream returns are
  `{:error, {:jetstream, %{code:, err_code:, description:}}}`.
  """

  alias OptimalEngine.Storage.NATS.{Connection, Protocol}

  @api "$JS.API."
  @timeout 5_000
  @stream_not_found 10_059
  @no_message 10_037

  @type conn :: GenServer.server()
  @type message :: %{
          subject: String.t(),
          payload: binary(),
          headers: map(),
          reply: String.t() | nil,
          stream: String.t() | nil,
          consumer: String.t() | nil,
          delivered: pos_integer() | nil,
          stream_seq: pos_integer() | nil,
          consumer_seq: pos_integer() | nil,
          pending: non_neg_integer() | nil
        }

  @doc "A JetStream API request (`$JS.API.<api>`) with a JSON body, decoded."
  @spec api(conn(), String.t(), map() | binary(), timeout()) :: {:ok, map()} | {:error, term()}
  def api(conn, api, body \\ "", timeout \\ @timeout) do
    payload = if is_map(body), do: Jason.encode!(body), else: body

    with {:ok, reply} <- Connection.request(conn, @api <> api, payload, %{}, timeout) do
      decode(reply)
    end
  end

  # ---------------------------------------------------------------------------
  # Streams and consumers
  # ---------------------------------------------------------------------------

  @doc """
  Makes sure stream `config.name` exists with `config`. Keys: `:name`,
  `:subjects`, `:retention` (`limits`, `workqueue`, `interest`; default
  `limits`), `:storage` (`file`, `memory`; default `file`), `:max_age_ms`,
  `:max_msgs`, `:max_bytes`, `:duplicate_window_ms`, `:replicas`, `:discard`.
  A setting left out is left as the stream has it (an operator may scale the
  replicas), and the server's default on create.
  """
  @spec ensure_stream(conn(), map(), timeout()) ::
          {:ok, :created | :exists | :updated, map()} | {:error, term()}
  def ensure_stream(conn, %{name: name} = config, timeout \\ @timeout) do
    wanted = stream_config(config)

    case api(conn, "STREAM.INFO." <> name, "", timeout) do
      {:ok, %{"config" => current} = info} ->
        if holds?(current, wanted) do
          {:ok, :exists, info}
        else
          with {:ok, info} <-
                 api(conn, "STREAM.UPDATE." <> name, Map.merge(current, wanted), timeout),
               do: {:ok, :updated, info}
        end

      {:error, {:jetstream, %{err_code: @stream_not_found}}} ->
        with {:ok, info} <- api(conn, "STREAM.CREATE." <> name, wanted, timeout),
             do: {:ok, :created, info}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_config(config) do
    %{
      "name" => config.name,
      "subjects" => config.subjects,
      "retention" => Map.get(config, :retention, "limits"),
      "storage" => Map.get(config, :storage, "file")
    }
    |> put_present("num_replicas", Map.get(config, :replicas))
    |> put_ns("max_age", Map.get(config, :max_age_ms))
    |> put_ns("duplicate_window", Map.get(config, :duplicate_window_ms))
    |> put_present("max_msgs", Map.get(config, :max_msgs))
    |> put_present("max_bytes", Map.get(config, :max_bytes))
    |> put_present("discard", Map.get(config, :discard))
  end

  defp holds?(current, wanted), do: Enum.all?(wanted, fn {key, value} -> current[key] == value end)

  @doc """
  Makes sure durable consumer `config.durable_name` on `stream` exists with
  explicit acks. Keys: `:durable_name`, `:filter_subject`, `:ack_wait_ms`
  (default 30 s), `:max_deliver` (default unlimited), `:max_ack_pending`,
  `:deliver_policy` (default `all`).
  """
  @spec ensure_consumer(conn(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def ensure_consumer(conn, stream, %{durable_name: durable} = config, timeout \\ @timeout) do
    consumer =
      %{
        "durable_name" => durable,
        "ack_policy" => "explicit",
        "deliver_policy" => Map.get(config, :deliver_policy, "all"),
        "max_deliver" => Map.get(config, :max_deliver, -1)
      }
      |> put_ns("ack_wait", Map.get(config, :ack_wait_ms, 30_000))
      |> put_present("filter_subject", Map.get(config, :filter_subject))
      |> put_present("max_ack_pending", Map.get(config, :max_ack_pending))

    api(
      conn,
      "CONSUMER.CREATE.#{stream}.#{durable}",
      %{"stream_name" => stream, "config" => consumer},
      timeout
    )
  end

  # ---------------------------------------------------------------------------
  # Publishing and reading back
  # ---------------------------------------------------------------------------

  @doc """
  Publishes `payload` on `subject` and waits for the stream's
  acknowledgement. Options: `:msg_id`, `:headers`, `:timeout`. A subject no
  stream covers is `{:error, {:no_responders, "503"}}`.
  """
  @spec publish(conn(), String.t(), iodata(), keyword()) ::
          {:ok, %{stream: String.t(), seq: pos_integer(), duplicate: boolean()}} | {:error, term()}
  def publish(conn, subject, payload, opts \\ []) do
    headers =
      opts
      |> Keyword.get(:headers, %{})
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> put_present("Nats-Msg-Id", Keyword.get(opts, :msg_id))

    with {:ok, reply} <-
           Connection.request(
             conn,
             subject,
             payload,
             headers,
             Keyword.get(opts, :timeout, @timeout)
           ),
         {:ok, %{"stream" => stream, "seq" => seq} = ack} <- decode(reply) do
      {:ok, %{stream: stream, seq: seq, duplicate: Map.get(ack, "duplicate", false) == true}}
    else
      {:ok, other} -> {:error, {:unexpected_ack, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  A stored message: `seq: n`, or `last_by_subject: subject` for the newest
  one on that subject. `{:error, :not_found}` when there is none.
  """
  @spec get_message(conn(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_message(conn, stream, opts) do
    body =
      case opts do
        [seq: seq] -> %{"seq" => seq}
        [last_by_subject: subject] -> %{"last_by_subj" => subject}
      end

    case api(conn, "STREAM.MSG.GET." <> stream, body) do
      {:ok, %{"message" => message}} ->
        {_status, _description, headers} =
          case message["hdrs"] do
            nil -> {nil, nil, %{}}
            hdrs -> hdrs |> Base.decode64!() |> Protocol.headers()
          end

        {:ok,
         %{
           subject: message["subject"],
           seq: message["seq"],
           payload: Base.decode64!(message["data"] || ""),
           headers: headers,
           time: message["time"]
         }}

      {:error, {:jetstream, %{err_code: @no_message}}} ->
        {:error, :not_found}

      {:error, {:jetstream, %{code: 404, err_code: nil}}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Pulling and acknowledging
  # ---------------------------------------------------------------------------

  @doc """
  Pulls up to `:batch` (default 10) messages from durable `consumer`.
  `:expires_ms` (default 5 s) is how long the server holds the pull open for
  messages to arrive; `no_wait: true` answers at once with what is there.
  Every message must be answered: `ack/2`, `nak/3` or `term/2`; one left
  unanswered is redelivered after the consumer's ack wait.
  """
  @spec fetch(conn(), String.t(), String.t(), keyword()) :: {:ok, [message()]} | {:error, term()}
  def fetch(conn, stream, consumer, opts \\ []) do
    batch = Keyword.get(opts, :batch, 10)
    expires_ms = Keyword.get(opts, :expires_ms, 5_000)

    body =
      if Keyword.get(opts, :no_wait, false),
        do: %{"batch" => batch, "no_wait" => true},
        else: %{"batch" => batch, "expires" => expires_ms * 1_000_000}

    subject = "#{@api}CONSUMER.MSG.NEXT.#{stream}.#{consumer}"

    with {:ok, frames} <-
           Connection.pull(conn, subject, Jason.encode!(body), batch, expires_ms + 500) do
      {:ok, Enum.map(frames, &message/1)}
    end
  end

  @doc "Acknowledges a message: done, never delivered again."
  @spec ack(conn(), message()) :: :ok | {:error, term()}
  def ack(conn, %{reply: reply}), do: answer(conn, reply, "+ACK")

  @doc "Refuses a message for now: redelivered at once, or after `:delay_ms`."
  @spec nak(conn(), message(), keyword()) :: :ok | {:error, term()}
  def nak(conn, %{reply: reply}, opts \\ []) do
    case Keyword.get(opts, :delay_ms) do
      nil -> answer(conn, reply, "-NAK")
      ms -> answer(conn, reply, "-NAK " <> Jason.encode!(%{"delay" => ms * 1_000_000}))
    end
  end

  @doc "Terminates a message: never delivered again, and not processed."
  @spec term(conn(), message()) :: :ok | {:error, term()}
  def term(conn, %{reply: reply}), do: answer(conn, reply, "+TERM")

  @doc "Still working on it: the ack wait starts over."
  @spec in_progress(conn(), message()) :: :ok | {:error, term()}
  def in_progress(conn, %{reply: reply}), do: answer(conn, reply, "+WPI")

  defp answer(_conn, nil, _body), do: {:error, :no_reply_subject}
  defp answer(conn, reply, body), do: Connection.publish(conn, reply, body)

  # The ack subject carries the delivery's metadata:
  # `$JS.ACK.<stream>.<consumer>.<delivered>.<stream seq>.<consumer seq>.<time>.<pending>`,
  # with a domain and an account hash after `ACK` on newer servers.
  defp message(frame) do
    meta =
      case frame.reply && String.split(frame.reply, ".") do
        ["$JS", "ACK", stream, consumer, delivered, sseq, cseq, _time, pending] ->
          {stream, consumer, delivered, sseq, cseq, pending}

        [
          "$JS",
          "ACK",
          _domain,
          _account,
          stream,
          consumer,
          delivered,
          sseq,
          cseq,
          _time,
          pending | _
        ] ->
          {stream, consumer, delivered, sseq, cseq, pending}

        _ ->
          nil
      end

    base = %{
      subject: frame.subject,
      payload: frame.payload,
      headers: frame.headers,
      reply: frame.reply,
      stream: nil,
      consumer: nil,
      delivered: nil,
      stream_seq: nil,
      consumer_seq: nil,
      pending: nil
    }

    case meta do
      {stream, consumer, delivered, sseq, cseq, pending} ->
        %{
          base
          | stream: stream,
            consumer: consumer,
            delivered: int(delivered),
            stream_seq: int(sseq),
            consumer_seq: int(cseq),
            pending: int(pending)
        }

      nil ->
        base
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp decode(%{status: "503"}), do: {:error, {:no_responders, "503"}}

  defp decode(%{status: status, payload: ""}) when is_binary(status),
    do: {:error, {:status, status}}

  defp decode(%{payload: payload}) do
    case Jason.decode(payload) do
      {:ok, %{"error" => %{} = error}} ->
        {:error,
         {:jetstream,
          %{code: error["code"], err_code: error["err_code"], description: error["description"]}}}

      {:ok, %{} = map} ->
        {:ok, map}

      _ ->
        {:error, {:protocol, :not_json}}
    end
  end

  defp put_ns(map, _key, nil), do: map
  defp put_ns(map, key, ms), do: Map.put(map, key, ms * 1_000_000)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp int(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
