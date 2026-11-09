defmodule OptimalEngine.Storage.NATS.WorkQueue do
  @moduledoc """
  A durable JetStream work queue the Engine both feeds and consumes: one
  stream with `workqueue` retention and one durable pull consumer with
  explicit acks. `OptimalEngine.Storage.NATS.IntakeQueue` (connector intake)
  and `OptimalEngine.Storage.NATS.JobQueue` (background jobs) are built on it;
  a callback module says what a message is and what to do with one.

  Feeding: `publish/4` sends a message with its `Nats-Msg-Id` and waits for
  the stream's acknowledgement, so a message the caller was told is queued is
  stored; a second publish of the same id inside the stream's duplicate
  window is stored once. While the connection is down it answers
  `{:error, :not_connected}` at once, and the caller takes its in-process
  path.

  Consuming: a loop pulls a batch and hands each message to the callback,
  which answers `:ack` (done, gone from the queue), `{:retry, delay_ms}`
  (delivered again after the delay) or `:term` (never delivered again). A
  callback that raises gets the message delivered again after a backoff
  (1 s doubling to 10 min) for as long as it keeps failing: a message is
  never dropped because its handler failed. A message nobody answered (the
  Engine stopped mid-way) is delivered again after the consumer's ack wait.

  The stream and the consumer are made sure of once per connection, so a
  server that lost them gets them back.
  """

  use GenServer

  require Logger

  alias OptimalEngine.Storage.NATS
  alias OptimalEngine.Storage.NATS.{Connection, JetStream}

  @callback flow() :: String.t()
  @callback stream_suffix() :: String.t()
  @callback subject_root() :: String.t()
  @callback consumer() :: map()
  @callback stream_options() :: map()
  @callback handle_message(JetStream.message(), map()) :: :ack | :term | {:retry, non_neg_integer()}
  @callback on_provisioned(GenServer.server(), map()) :: :ok

  @optional_callbacks on_provisioned: 2

  @batch 10
  @expires_ms 2_000
  @idle_ms 1_000
  @max_backoff_ms 600_000

  @doc false
  def child_spec({callback, opts}) do
    %{id: Keyword.get(opts, :name, callback), start: {__MODULE__, :start_link, [callback, opts]}}
  end

  @doc """
  Starts the queue for `callback`. Options: `:name`, `:connection`,
  `:namespace`, `:enabled` (default: the callback's flow is named in
  `OPTIMAL_NATS_FLOWS` and the provider configured), `:interval_ms` (0: no
  consumer loop, only `drain_now/1` consumes), and anything the callback
  reads from its context.
  """
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(callback, opts) do
    GenServer.start_link(__MODULE__, {callback, opts}, name: Keyword.get(opts, :name, callback))
  end

  @doc "Publishes a message on `<namespace>.<root>.<token>` and waits for the stream's ack."
  @spec publish(GenServer.server(), String.t(), iodata(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def publish(server, token, payload, msg_id) do
    GenServer.call(server, {:publish, token, payload, msg_id}, 30_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Publishes in the background: returns at once, never fails, and does nothing
  while the queue is off. For a caller whose own record is durable and is
  announced again on the next connection (`JobQueue`).
  """
  @spec publish_async(GenServer.server(), String.t(), iodata(), String.t()) :: :ok
  def publish_async(server, token, payload, msg_id),
    do: GenServer.cast(server, {:publish, token, payload, msg_id})

  @doc "Records `count` items the caller handled in process because the queue was not there."
  @spec note_fallback(GenServer.server(), non_neg_integer()) :: :ok
  def note_fallback(server, count), do: GenServer.cast(server, {:fallback, count})

  @doc """
  One pull now, in the caller's process, with what is already there:
  `{:ok, %{acked:, retried:, terminated:}}`.
  """
  @spec drain_now(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def drain_now(server) do
    with {:ok, setup} <- GenServer.call(server, :ensure, 30_000) do
      consume(setup, server, no_wait: true)
    end
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "What an operator sees: the state, the stream, and the counts since start."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status, 5_000)
  catch
    :exit, _ -> %{state: "down"}
  end

  # ---------------------------------------------------------------------------

  @impl GenServer
  def init({callback, opts}) do
    enabled = Keyword.get_lazy(opts, :enabled, fn -> NATS.flow?(callback.flow()) end)

    namespace =
      case Keyword.fetch(opts, :namespace) do
        {:ok, namespace} -> {:ok, namespace}
        :error -> NATS.namespace()
      end

    state = %{
      callback: callback,
      enabled: enabled and match?({:ok, _}, namespace),
      namespace: elem(namespace, 1),
      connection: Keyword.get(opts, :connection, Connection),
      interval: Keyword.get(opts, :interval_ms, @idle_ms),
      context: Map.new(opts),
      epoch: nil,
      state:
        cond do
          not enabled -> "off"
          match?({:error, _}, namespace) -> "invalid_namespace"
          true -> "starting"
        end,
      consumer_pid: nil,
      counts: %{published: 0, acked: 0, retried: 0, terminated: 0, failed: 0, fallback: 0},
      last_error: nil
    }

    {:ok, maybe_start_consumer(state)}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply,
     Map.merge(state.counts, %{
       state: state.state,
       stream: if(state.enabled, do: stream(state)),
       subjects: if(state.enabled, do: subjects(state)),
       last_error: state.last_error
     }), state}
  end

  def handle_call(_request, _from, %{enabled: false} = state), do: {:reply, {:error, :off}, state}

  def handle_call(:ensure, _from, state) do
    case provision(state) do
      {:ok, state} -> {:reply, {:ok, setup(state)}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:publish, token, payload, msg_id}, _from, state) do
    {reply, state} = handle_publish(token, payload, msg_id, state)
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:fallback, count}, state), do: {:noreply, bump(state, :fallback, count)}

  def handle_cast({:publish, _token, _payload, _msg_id}, %{enabled: false} = state),
    do: {:noreply, state}

  def handle_cast({:publish, token, payload, msg_id}, state) do
    {_reply, state} = handle_publish(token, payload, msg_id, state)
    {:noreply, state}
  end

  def handle_cast({:counted, counts}, state) do
    {:noreply, Enum.reduce(counts, state, fn {key, n}, state -> bump(state, key, n) end)}
  end

  def handle_cast({:consumer_error, reason}, state), do: {:noreply, unavailable(state, reason)}

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{consumer_pid: pid} = state) do
    Logger.warning("[NATS] #{state.callback.flow()} consumer stopped: #{inspect(reason)}")
    Process.send_after(self(), :restart_consumer, @idle_ms)
    {:noreply, %{state | consumer_pid: nil}}
  end

  def handle_info(:restart_consumer, state), do: {:noreply, maybe_start_consumer(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_publish(token, payload, msg_id, state) do
    with {:ok, state} <- provision(state),
         {:ok, ack} <-
           JetStream.publish(state.connection, "#{subjects_root(state)}.#{token}", payload,
             msg_id: msg_id
           ) do
      {{:ok, ack}, bump(state, :published, if(ack.duplicate, do: 0, else: 1))}
    else
      {:error, reason, state} -> {{:error, reason}, state}
      {:error, reason} -> {{:error, reason}, unavailable(state, reason)}
    end
  end

  # ---------------------------------------------------------------------------
  # Provisioning
  # ---------------------------------------------------------------------------

  defp provision(state) do
    case Connection.status(state.connection) do
      %{state: "connected", reconnects: n, connected_since: since} when {n, since} == state.epoch ->
        {:ok, state}

      %{state: "connected", reconnects: n, connected_since: since} ->
        stream_config =
          Map.merge(
            %{
              name: stream(state),
              subjects: [subjects(state)],
              retention: "workqueue",
              storage: "file"
            },
            state.callback.stream_options()
          )

        consumer = Map.merge(%{durable_name: consumer_name(state)}, state.callback.consumer())

        with {:ok, _outcome, _} <- JetStream.ensure_stream(state.connection, stream_config),
             {:ok, _} <- JetStream.ensure_consumer(state.connection, stream(state), consumer) do
          state = %{state | epoch: {n, since}, state: "running", last_error: nil}

          # Off this process: the callback may publish through it.
          if function_exported?(state.callback, :on_provisioned, 2) do
            {callback, name, context} = {state.callback, self_name(state), state.context}
            spawn(fn -> callback.on_provisioned(name, context) end)
          end

          {:ok, state}
        else
          {:error, reason} -> {:error, reason, unavailable(state, reason)}
        end

      _not_connected ->
        {:error, :not_connected, %{state | state: "buffering", epoch: nil}}
    end
  end

  defp setup(state) do
    %{
      callback: state.callback,
      connection: state.connection,
      stream: stream(state),
      consumer: consumer_name(state),
      context: state.context
    }
  end

  # ---------------------------------------------------------------------------
  # Consuming
  # ---------------------------------------------------------------------------

  defp maybe_start_consumer(%{enabled: true, interval: interval, consumer_pid: nil} = state)
       when interval > 0 do
    Process.flag(:trap_exit, true)
    server = self()
    pid = spawn_link(fn -> loop(server, interval) end)
    %{state | consumer_pid: pid}
  end

  defp maybe_start_consumer(state), do: state

  defp loop(server, interval) do
    case GenServer.call(server, :ensure, 30_000) do
      {:ok, setup} ->
        case consume(setup, server, expires_ms: @expires_ms) do
          {:ok, %{acked: 0, retried: 0, terminated: 0, failed: 0}} -> Process.sleep(100)
          {:ok, _counts} -> :ok
          {:error, _reason} -> Process.sleep(interval)
        end

      {:error, _reason} ->
        Process.sleep(interval)
    end

    loop(server, interval)
  end

  defp consume(setup, server, opts) do
    fetch_opts = [batch: @batch] ++ opts

    case JetStream.fetch(setup.connection, setup.stream, setup.consumer, fetch_opts) do
      {:ok, messages} ->
        counts =
          Enum.reduce(messages, %{acked: 0, retried: 0, terminated: 0, failed: 0}, fn message,
                                                                                      counts ->
            key = answer(setup, message)
            Map.update!(counts, key, &(&1 + 1))
          end)

        GenServer.cast(server, {:counted, counts})
        {:ok, counts}

      {:error, reason} ->
        GenServer.cast(server, {:consumer_error, reason})
        {:error, reason}
    end
  end

  defp answer(setup, message) do
    case handle(setup, message) do
      :ack ->
        _ = JetStream.ack(setup.connection, message)
        :acked

      :term ->
        _ = JetStream.term(setup.connection, message)
        :terminated

      {:retry, delay_ms} ->
        _ = JetStream.nak(setup.connection, message, delay_ms: max(delay_ms, 0))
        :retried

      {:failed, delay_ms} ->
        _ = JetStream.nak(setup.connection, message, delay_ms: delay_ms)
        :failed
    end
  end

  defp handle(setup, message) do
    case setup.callback.handle_message(message, setup.context) do
      result when result in [:ack, :term] -> result
      {:retry, delay_ms} when is_integer(delay_ms) -> {:retry, delay_ms}
      other -> raise "unexpected answer #{inspect(other)}"
    end
  rescue
    error ->
      delay = backoff(message.delivered || 1)

      Logger.warning(
        "[NATS] #{setup.callback.flow()} message #{message.stream_seq} failed (delivery #{message.delivered}), again in #{div(delay, 1000)} s: #{Exception.message(error)}"
      )

      {:failed, delay}
  end

  defp backoff(delivered), do: min(1_000 * Integer.pow(2, min(delivered - 1, 20)), @max_backoff_ms)

  # ---------------------------------------------------------------------------

  defp unavailable(state, reason) when reason in [:not_connected, :disconnected],
    do: %{state | state: "buffering", epoch: nil}

  defp unavailable(state, reason) do
    %{state | state: "error", last_error: inspect(reason), epoch: nil}
  end

  defp bump(state, key, n), do: %{state | counts: Map.update!(state.counts, key, &(&1 + n))}

  defp self_name(state), do: Map.get(state.context, :name, state.callback)
  defp stream(state), do: NATS.stream_name(state.namespace, state.callback.stream_suffix())
  defp subjects_root(state), do: "#{state.namespace}.#{state.callback.subject_root()}"
  defp subjects(state), do: subjects_root(state) <> ".>"
  defp consumer_name(_state), do: "engine"
end
