defmodule OptimalEngine.Storage.NATS.IntakeQueue do
  @moduledoc """
  Connector intake through a JetStream work queue. On with `intake` in
  `OPTIMAL_NATS_FLOWS`.

  A connector pull (`OptimalEngine.Connectors.PullScheduler`) hands its
  Signals to `offer/3`, which publishes each one to stream
  `<NAMESPACE>_INTAKE` on `<namespace>.intake.<tenant>.<connector>` and waits
  for the stream's acknowledgement. The pull then moves its cursor: a Signal
  is either stored in the stream or ingested in process, never neither.
  What `offer/3` could not queue (NATS down, or it went down mid-way) comes
  back to the pull, which ingests it in process as it always has.

  The queue's durable consumer ingests each Signal through the same intake
  as the in-process path (`PullScheduler.ingest_signal/2`, then
  `Connectors.Routing`), with the connector's current routing config read
  from its row. A stored Signal is acknowledged and leaves the queue; one
  intake refuses is terminated and logged, as the in-process path logs and
  counts it; one whose connector was deleted since is terminated. One whose
  intake raised is delivered again after a backoff. A Signal queued and not
  yet ingested when the Engine stops is still in the stream when it starts.

  The message id is `<connector>:<signal id>`, so a pull that runs again
  over items it already queued (its cursor did not move) queues each once
  inside the stream's duplicate window, and intake stores a source item
  once whatever arrives.

  Refusals at consumption are not in the pull's `connector_runs` row (the
  pull has finished by then); they are in this queue's `terminated` count
  and the log.
  """

  @behaviour OptimalEngine.Storage.NATS.WorkQueue

  require Logger

  alias OptimalEngine.Connectors.{PullScheduler, Rows}
  alias OptimalEngine.Signal
  alias OptimalEngine.Storage.NATS.{Protocol, WorkQueue}

  @doc false
  def child_spec(opts), do: WorkQueue.child_spec({__MODULE__, opts})

  @doc "Starts the queue (see `OptimalEngine.Storage.NATS.WorkQueue.start_link/2`)."
  def start_link(opts \\ []), do: WorkQueue.start_link(__MODULE__, opts)

  @doc """
  Queues `signals` for the connector `scope` names. Returns
  `{queued, rest}`: the Signals the stream acknowledged, and the ones the
  caller must ingest itself, in their order.
  """
  @spec offer(GenServer.server(), [Signal.t()], map()) :: {[Signal.t()], [Signal.t()]}
  def offer(server \\ __MODULE__, signals, scope) do
    case do_offer(server, signals, scope, []) do
      {queued, [], _reason} ->
        {queued, []}

      # Off: the in-process path is the only one, and nothing fell back.
      {queued, rest, :off} ->
        {queued, rest}

      {queued, rest, _reason} ->
        WorkQueue.note_fallback(server, length(rest))
        {queued, rest}
    end
  end

  defp do_offer(_server, [], _scope, queued), do: {Enum.reverse(queued), [], nil}

  defp do_offer(server, [signal | more] = signals, scope, queued) do
    tenant = Map.get(scope, :tenant_id)
    connector = Map.get(scope, :connector_id)

    token = "#{Protocol.token(tenant || "")}.#{Protocol.token(connector || "")}"

    # A Signal that cannot be put on the wire (content that is not UTF-8) is
    # left to the in-process path with the rest, in order.
    with {:ok, payload} <-
           Jason.encode(%{
             "tenant_id" => tenant,
             "connector_id" => connector,
             "workspace_id" => Map.get(scope, :workspace_id),
             "signal" => encode_signal(signal)
           }),
         {:ok, _ack} <- WorkQueue.publish(server, token, payload, msg_id(connector, signal)) do
      do_offer(server, more, scope, [signal | queued])
    else
      {:error, reason} -> {Enum.reverse(queued), signals, reason}
    end
  end

  defp msg_id(connector, %Signal{id: id}) when is_binary(id) and id != "", do: "#{connector}:#{id}"

  defp msg_id(connector, signal) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(encode_signal(signal)))
    "#{connector}:sha256:" <> Base.encode16(hash, case: :lower)
  end

  @doc "One pull now (tests, operators)."
  @spec drain_now(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def drain_now(server \\ __MODULE__), do: WorkQueue.drain_now(server)

  @doc "The queue's state and counts: `published`, `acked`, `terminated`, `retried`, `failed`, `fallback`."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: WorkQueue.status(server)

  # ---------------------------------------------------------------------------
  # WorkQueue callbacks
  # ---------------------------------------------------------------------------

  @impl WorkQueue
  def flow, do: "intake"

  @impl WorkQueue
  def stream_suffix, do: "INTAKE"

  @impl WorkQueue
  def subject_root, do: "intake"

  @impl WorkQueue
  def stream_options, do: %{}

  # Intake of one Signal can take a while (entity resolution, loops); the
  # consumer has ten minutes before an unanswered one is delivered again.
  @impl WorkQueue
  def consumer, do: %{ack_wait_ms: 600_000, max_deliver: -1}

  @impl WorkQueue
  def handle_message(message, _context) do
    %{"tenant_id" => tenant, "connector_id" => connector, "signal" => encoded} =
      Jason.decode!(message.payload)

    case Rows.get(tenant, connector) do
      {:ok, row} ->
        scope = %{
          workspace_id: row.workspace_id,
          tenant_id: tenant,
          connector_id: connector,
          kind: row.kind,
          config: row.config || %{}
        }

        case PullScheduler.ingest_signal(decode_signal(encoded), scope) do
          :ok ->
            :ack

          :refused ->
            Logger.warning(
              "[NATS] intake refused a queued Signal of connector #{inspect(connector)}"
            )

            :term
        end

      {:error, :not_found} ->
        Logger.warning(
          "[NATS] queued Signal dropped: connector #{inspect(connector)} no longer exists"
        )

        :term
    end
  end

  # ---------------------------------------------------------------------------
  # Signals on the wire
  # ---------------------------------------------------------------------------

  @datetimes ~w(created_at modified_at valid_from valid_until)a

  @doc false
  @spec encode_signal(Signal.t()) :: map()
  def encode_signal(%Signal{} = signal) do
    signal
    |> Map.from_struct()
    |> Map.new(fn
      {key, %DateTime{} = value} ->
        {Atom.to_string(key), DateTime.to_iso8601(value)}

      {key, value} when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
        {Atom.to_string(key), Atom.to_string(value)}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end

  # Only the fields a Signal has, atoms only from the closed lists Signal
  # declares: a message from the stream never creates an atom.
  @doc false
  @spec decode_signal(map()) :: Signal.t()
  def decode_signal(map) do
    fields =
      for key <- Map.keys(%Signal{}) -- [:__struct__], into: %{} do
        value = Map.get(map, Atom.to_string(key))

        value =
          cond do
            key in @datetimes -> datetime(value)
            key == :mode -> one_of(value, Signal.valid_modes())
            key == :type -> one_of(value, Signal.valid_types())
            key == :format -> one_of(value, Signal.valid_formats())
            true -> value
          end

        {key, value}
      end

    struct(Signal, fields)
  end

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp datetime(_value), do: nil

  defp one_of(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  defp one_of(_value, _allowed), do: nil
end
