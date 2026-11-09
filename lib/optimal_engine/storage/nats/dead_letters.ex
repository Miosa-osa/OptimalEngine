defmodule OptimalEngine.Storage.NATS.DeadLetters do
  @moduledoc """
  Where a work-queue item goes when its handling keeps failing: stream
  `<NAMESPACE>_DEAD_LETTERS` (limits retention, file storage), one subject per
  flow (`<namespace>.dead.<flow>`). A letter stays until an operator requeues
  it, or until it is older than `OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS`
  (720 hours, 30 days, by default; `0` keeps letters until requeued): that
  is the stream's `max_age`, so JetStream purges an expired letter itself, and
  an existing stream takes a changed limit when it is next provisioned.
  `forget/4` removes the letters a match names (an erased workspace's, a
  deleted connector's).

  A dead letter keeps the item's payload as it was queued and says why, in
  headers: `Optimal-Flow`, `Optimal-Subject` (where it was queued),
  `Optimal-Delivered` (how often it was delivered), `Optimal-Error` (the last
  failure, one line, at most 500 bytes) and `Optimal-Stream-Seq` (its sequence
  in the work queue). `OptimalEngine.Storage.NATS.WorkQueue` moves an item
  here once it reaches its flow's delivery cap.

  `list/3` reads them without their payload (connector content stays where it
  is), `requeue/3` puts one back on its work queue, under a new message id so
  the queue's duplicate window does not drop it, and removes it from here,
  `summary/2` counts them per flow for the provider inventory. The API
  (`GET /api/maintenance/nats/dead-letters`,
  `POST /api/maintenance/nats/dead-letters/:seq/requeue`) and
  `mix optimal.nats` call these for the Engine operator.
  """

  alias OptimalEngine.Storage.NATS
  alias OptimalEngine.Storage.NATS.{Connection, JetStream}

  @default_limit 50
  @max_age_env "OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS"
  @default_max_age_hours 720
  @max_limit 500
  @error_bytes 500

  @doc "The dead-letter stream of `namespace`."
  @spec stream(String.t()) :: String.t()
  def stream(namespace), do: NATS.stream_name(namespace, "DEAD_LETTERS")

  @doc """
  How long a dead letter is kept, in milliseconds, from
  `OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS` (default #{@default_max_age_hours});
  `0` keeps letters until they are requeued. A value that is not a whole
  number of hours is the default.
  """
  @spec max_age_ms() :: non_neg_integer()
  def max_age_ms do
    case Integer.parse(System.get_env(@max_age_env) || "") do
      {hours, ""} when hours >= 0 -> hours * 3_600_000
      _unset_or_invalid -> @default_max_age_hours * 3_600_000
    end
  end

  @doc """
  Makes sure the dead-letter stream exists, with the age limit `max_age_ms/0`
  (or `:max_age_ms`), so an expired letter is purged by JetStream.
  """
  @spec ensure(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def ensure(conn, namespace, opts \\ []) do
    config = %{
      name: stream(namespace),
      subjects: ["#{namespace}.dead.>"],
      retention: "limits",
      storage: "file",
      max_age_ms: Keyword.get_lazy(opts, :max_age_ms, &max_age_ms/0)
    }

    with {:ok, _outcome, _info} <- JetStream.ensure_stream(conn, config), do: :ok
  end

  @doc "Stores `message` of `flow` as a dead letter, with why."
  @spec put(GenServer.server(), String.t(), String.t(), JetStream.message(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def put(conn, namespace, flow, message, error) do
    JetStream.publish(conn, "#{namespace}.dead.#{flow}", message.payload,
      msg_id: "dead:#{message.stream}:#{message.stream_seq}",
      headers: %{
        "Optimal-Flow" => flow,
        "Optimal-Subject" => message.subject,
        "Optimal-Delivered" => message.delivered || 0,
        "Optimal-Error" => one_line(error),
        "Optimal-Stream-Seq" => message.stream_seq || 0
      }
    )
  end

  @doc """
  The dead letters, oldest first, without their payload. Options: `:flow`,
  `:limit` (default #{@default_limit}, at most #{@max_limit}), `:after` (a
  sequence to start after).
  """
  @spec list(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(conn \\ default_conn(), namespace \\ default_namespace(), opts \\ []) do
    subject = subject(namespace, Keyword.get(opts, :flow))
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)
    collect(conn, stream(namespace), subject, Keyword.get(opts, :after, 0) + 1, limit, [])
  end

  defp collect(_conn, _stream, _subject, _from, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp collect(conn, stream, subject, from, limit, acc) do
    case JetStream.get_message(conn, stream, next_by_subject: subject, from: from) do
      {:ok, message} ->
        collect(conn, stream, subject, message.seq + 1, limit - 1, [letter(message) | acc])

      {:error, :not_found} ->
        {:ok, Enum.reverse(acc)}

      {:error, {:jetstream, %{err_code: 10_059}}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp letter(message) do
    headers = message.headers

    %{
      seq: message.seq,
      flow: headers["Optimal-Flow"],
      subject: headers["Optimal-Subject"],
      delivered: int(headers["Optimal-Delivered"]),
      error: headers["Optimal-Error"],
      queue_seq: int(headers["Optimal-Stream-Seq"]),
      dead_at: message.time,
      bytes: byte_size(message.payload)
    }
  end

  @doc """
  Puts dead letter `seq` back on the work queue it came from and removes it
  from the dead letters. `{:error, :not_found}` when there is no such letter.
  """
  @spec requeue(GenServer.server(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def requeue(conn \\ default_conn(), namespace \\ default_namespace(), seq) do
    with {:ok, message} <- get(conn, namespace, seq),
         subject when is_binary(subject) <-
           message.headers["Optimal-Subject"] || {:error, :no_subject},
         {:ok, _ack} <-
           JetStream.publish(conn, subject, message.payload, msg_id: "requeue:#{namespace}:#{seq}"),
         :ok <- JetStream.delete_message(conn, stream(namespace), seq) do
      {:ok, %{requeued: seq, subject: subject, flow: message.headers["Optimal-Flow"]}}
    end
  end

  defp get(conn, namespace, seq) do
    prefix = namespace <> ".dead."

    case JetStream.get_message(conn, stream(namespace), seq: seq) do
      {:ok, %{subject: subject} = message} ->
        if String.starts_with?(subject, prefix), do: {:ok, message}, else: {:error, :not_found}

      {:error, {:jetstream, %{err_code: 10_059}}} ->
        {:error, :not_found}

      {:error, {:jetstream, %{code: 404}}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes every dead letter of `flow` whose queued payload (decoded JSON)
  `match?` accepts. Returns how many went; a stream that does not exist has
  none.
  """
  @spec forget(GenServer.server(), String.t(), String.t(), (map() -> boolean())) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def forget(conn, namespace, flow, match?) when is_function(match?, 1) do
    scan(conn, stream(namespace), subject(namespace, flow), 1, match?, 0)
  end

  @doc false
  # Every message of `stream` on `subject` from sequence `from`, deleted when
  # its payload matches. Shared with the work queue's removals
  # (`OptimalEngine.Storage.NATS.IntakeQueue.forget_workspace/4`).
  @spec scan(
          GenServer.server(),
          String.t(),
          String.t(),
          pos_integer(),
          (map() -> boolean()),
          non_neg_integer()
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def scan(conn, stream, subject, from, match?, removed) do
    case JetStream.get_message(conn, stream, next_by_subject: subject, from: from) do
      {:ok, message} ->
        with {:ok, removed} <- maybe_delete(conn, stream, message, match?, removed) do
          scan(conn, stream, subject, message.seq + 1, match?, removed)
        end

      {:error, :not_found} ->
        {:ok, removed}

      {:error, {:jetstream, %{err_code: 10_059}}} ->
        {:ok, removed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_delete(conn, stream, message, match?, removed) do
    payload =
      case Jason.decode(message.payload) do
        {:ok, %{} = map} -> map
        _ -> %{}
      end

    if match?.(payload) do
      case JetStream.delete_message(conn, stream, message.seq) do
        :ok -> {:ok, removed + 1}
        # Acknowledged or expired in between: gone all the same.
        {:error, :not_found} -> {:ok, removed}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, removed}
    end
  end

  @doc """
  The dead letters per flow, for the provider inventory:
  `%{total:, flows: %{flow => count}}`, or `%{state: "not_connected"}`.
  """
  @spec summary(GenServer.server(), String.t()) :: map()
  def summary(conn \\ default_conn(), namespace \\ default_namespace()) do
    if Connection.connected?(conn) do
      case JetStream.api(conn, "STREAM.INFO." <> stream(namespace), %{
             "subjects_filter" => "#{namespace}.dead.>"
           }) do
        {:ok, %{"state" => state}} ->
          flows =
            Map.new(state["subjects"] || %{}, fn {subject, n} ->
              {subject |> String.split(".") |> List.last(), n}
            end)

          %{total: state["messages"] || 0, flows: flows}

        {:error, {:jetstream, %{err_code: 10_059}}} ->
          %{total: 0, flows: %{}}

        {:error, reason} ->
          %{state: "error", error: inspect(reason)}
      end
    else
      %{state: "not_connected"}
    end
  catch
    :exit, _ -> %{state: "not_connected"}
  end

  defp subject(namespace, nil), do: "#{namespace}.dead.>"
  defp subject(namespace, flow), do: "#{namespace}.dead.#{flow}"

  defp default_conn, do: Application.get_env(:optimal_engine, :nats_connection, Connection)

  defp default_namespace do
    case NATS.namespace() do
      {:ok, namespace} -> namespace
      _ -> "optimal"
    end
  end

  defp one_line(error) do
    error
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> binary_part_safe(@error_bytes)
  end

  defp binary_part_safe(text, max) when byte_size(text) <= max, do: text

  defp binary_part_safe(text, max) do
    text
    |> binary_part(0, max)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end

  defp int(nil), do: nil

  defp int(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> nil
    end
  end
end
