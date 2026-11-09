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

  ## What is erased leaves the queue

  A queued Signal and a dead letter hold connector content that was taken in
  and not ingested. When its workspace is archived or moved away
  (`forget_workspace/4`) or its connector deleted (`forget_connector/3`),
  every such item goes: the queued ones of the tenant on `<NAMESPACE>_INTAKE`
  and the intake dead letters, each matched by the workspace and connector it
  was queued for. The request is written first as an `events` row (`kind =
  'nats_intake_purge_requested'`) and done at once when NATS is reachable,
  otherwise when the queue is next provisioned (`process_requests/2`), so a
  removal asked for during an outage, or across a restart, is not lost; each
  one done is a `nats_purge` event.
  """

  @behaviour OptimalEngine.Storage.NATS.WorkQueue

  require Logger

  alias OptimalEngine.Connectors.{PullScheduler, Rows}
  alias OptimalEngine.{Signal, Store}
  alias OptimalEngine.Storage.NATS
  alias OptimalEngine.Storage.NATS.{Connection, DeadLetters, Protocol, WorkQueue}

  @request_kind "nats_intake_purge_requested"

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
             "run_id" => Map.get(scope, :run_id),
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

  @doc """
  Removes what the workspace's connectors queued and did not ingest: queued
  Signals and intake dead letters queued for `workspace_id` (or by one of its
  connectors). `{:ok, %{queued_purged:, dead_letters_removed:}}` when done,
  `{:ok, %{pending: true}}` when NATS is not reachable now (done on the next
  provisioning), `{:ok, %{state: "off"}}` without the intake flow. Options:
  `:connection`, `:namespace` (tests). Never raises.
  """
  @spec forget_workspace(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()}
  def forget_workspace(tenant_id, workspace_id, reason, opts \\ []) do
    connectors =
      case Store.raw_query(
             "SELECT id FROM connectors WHERE tenant_id = ?1 AND workspace_id = ?2",
             [tenant_id, workspace_id]
           ) do
        {:ok, rows} -> List.flatten(rows)
        _ -> []
      end

    forget(
      %{
        "tenant_id" => tenant_id,
        "workspace_id" => workspace_id,
        "connector_ids" => connectors,
        "reason" => reason
      },
      "workspace:" <> workspace_id,
      opts
    )
  end

  @doc "Removes what one connector queued and did not ingest, as `forget_workspace/4` does."
  @spec forget_connector(String.t(), String.t(), keyword()) :: {:ok, map()}
  def forget_connector(tenant_id, connector_id, opts \\ []) do
    forget(
      %{
        "tenant_id" => tenant_id,
        "workspace_id" => nil,
        "connector_ids" => [connector_id],
        "reason" => "connector_deleted"
      },
      "connector:" <> connector_id,
      opts
    )
  end

  defp forget(request, target, opts) do
    with {:ok, namespace} <- namespace(opts),
         true <- Keyword.has_key?(opts, :connection) or NATS.flow?("intake") do
      conn = Keyword.get(opts, :connection, default_conn())
      id = record_request(namespace, request, target)

      if Connection.connected?(conn) do
        case purge(conn, namespace, request) do
          {:ok, counts} ->
            done(id, namespace, request, counts)
            {:ok, counts}

          {:error, reason} ->
            Logger.warning("[NATS] intake removal #{id} not done yet: #{inspect(reason)}")
            {:ok, %{pending: true}}
        end
      else
        {:ok, %{pending: true}}
      end
    else
      _off -> {:ok, %{state: "off"}}
    end
  rescue
    error ->
      Logger.warning("[NATS] intake removal failed: #{Exception.message(error)}")
      {:ok, %{pending: true}}
  catch
    :exit, _ -> {:ok, %{pending: true}}
  end

  @doc """
  Does every intake removal still pending in `namespace`; the result is the
  counts of each done, by request id. One that fails stays pending.
  """
  @spec process_requests(GenServer.server(), String.t()) :: {:ok, map()}
  def process_requests(conn, namespace) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT r.id, r.metadata FROM events r
        WHERE r.kind = ?1
          AND NOT EXISTS (
            SELECT 1 FROM events d
            WHERE d.kind = 'nats_purge' AND d.target_uri = 'nats-intake-purge-request:' || CAST(r.id AS TEXT)
          )
        ORDER BY r.id
        LIMIT 500
        """,
        [@request_kind]
      )

    done =
      for [id, meta] <- rows,
          request = Jason.decode!(meta),
          request["namespace"] == namespace,
          {:ok, counts} <- [purge(conn, namespace, request)],
          into: %{} do
        done(id, namespace, request, counts)
        {id, counts}
      end

    {:ok, done}
  end

  # The tenant's queued Signals and the intake dead letters this request names.
  defp purge(conn, namespace, request) do
    tenant = request["tenant_id"]
    connectors = request["connector_ids"] || []
    workspace = request["workspace_id"]

    match? = fn payload ->
      payload["tenant_id"] == tenant and
        ((is_binary(workspace) and payload["workspace_id"] == workspace) or
           payload["connector_id"] in connectors)
    end

    stream = NATS.stream_name(namespace, "INTAKE")
    subject = "#{namespace}.intake.#{Protocol.token(tenant || "")}.>"

    with {:ok, queued} <- DeadLetters.scan(conn, stream, subject, 1, match?, 0),
         {:ok, letters} <- DeadLetters.forget(conn, namespace, "intake", match?) do
      {:ok, %{queued_purged: queued, dead_letters_removed: letters}}
    end
  end

  defp record_request(namespace, request, target) do
    {:ok, [[id]]} =
      Store.raw_query(
        """
        INSERT INTO events (tenant_id, principal, kind, target_uri, metadata)
        VALUES (?1, 'system:nats', ?2, ?3, ?4) RETURNING id
        """,
        [
          request["tenant_id"],
          @request_kind,
          target,
          Jason.encode!(Map.merge(request, %{"flow" => "intake", "namespace" => namespace}))
        ]
      )

    id
  end

  defp done(id, namespace, request, counts) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO events (tenant_id, principal, kind, target_uri, metadata) VALUES (?1, 'system:nats', 'nats_purge', ?2, ?3)",
        [
          request["tenant_id"],
          "nats-intake-purge-request:#{id}",
          Jason.encode!(
            Map.merge(counts, %{
              flow: "intake",
              stream: NATS.stream_name(namespace, "INTAKE"),
              workspace_id: request["workspace_id"],
              connector_ids: request["connector_ids"],
              reason: request["reason"]
            })
          )
        ]
      )

    :ok
  end

  defp namespace(opts) do
    case Keyword.fetch(opts, :namespace) do
      {:ok, namespace} -> {:ok, namespace}
      :error -> NATS.namespace()
    end
  end

  defp default_conn, do: Application.get_env(:optimal_engine, :nats_connection, Connection)

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

  # Removals asked for while NATS was down are done once the queue is up.
  @impl WorkQueue
  def on_provisioned(_server, context) do
    with {:ok, namespace} <- namespace(Map.to_list(Map.take(context, [:namespace]))) do
      process_requests(Map.get(context, :connection, default_conn()), namespace)
    end

    :ok
  rescue
    error -> Logger.warning("[NATS] pending intake removals: #{Exception.message(error)}")
  end

  # Intake of one Signal can take a while (entity resolution, loops); the
  # consumer has ten minutes before an unanswered one is delivered again.
  @impl WorkQueue
  def consumer, do: %{ack_wait_ms: 600_000, max_deliver: -1}

  # Ten deliveries that fail (about seventeen minutes of backoff), then the
  # dead letters. `:dead_letter_after` overrides it (tests).
  @impl WorkQueue
  def dead_letter_after(context), do: Map.get(context, :dead_letter_after, 10)

  # The pull that queued it counts it, as it counts a refusal in process.
  @impl WorkQueue
  def on_dead_letter(message, _error, _context) do
    with {:ok, %{"run_id" => run_id}} when is_integer(run_id) <- Jason.decode(message.payload) do
      record_run(run_id, "dead_lettered")
    end

    :ok
  end

  @impl WorkQueue
  def handle_message(message, context) do
    %{"tenant_id" => tenant, "connector_id" => connector, "signal" => encoded} =
      decoded = Jason.decode!(message.payload)

    ingest = Map.get(context, :ingest, &PullScheduler.ingest_signal/2)

    case Rows.get(tenant, connector) do
      {:ok, row} ->
        scope = %{
          workspace_id: row.workspace_id,
          tenant_id: tenant,
          connector_id: connector,
          kind: row.kind,
          config: row.config || %{}
        }

        case ingest.(decode_signal(encoded), scope) do
          :ok ->
            :ack

          :refused ->
            refused(decoded["run_id"], connector, context)
        end

      {:error, :not_found} ->
        Logger.warning(
          "[NATS] queued Signal dropped: connector #{inspect(connector)} no longer exists"
        )

        :term
    end
  end

  # A refusal is counted in the run row of the pull that queued it. That row is
  # written when the pull ends, so while the pull is still running the count
  # waits: the message comes back shortly instead of the count being lost.
  defp refused(run_id, connector, context) when is_integer(run_id) do
    case record_run(run_id, "queue_refused") do
      :running ->
        {:retry, Map.get(context, :retry_ms, 2_000)}

      _recorded_or_gone ->
        Logger.warning("[NATS] intake refused a queued Signal of connector #{inspect(connector)}")
        :term
    end
  end

  defp refused(_run_id, connector, _context) do
    Logger.warning("[NATS] intake refused a queued Signal of connector #{inspect(connector)}")
    :term
  end

  # One more error on the run, and the count under `key` in its error detail.
  @doc false
  @spec record_run(integer(), String.t()) :: :recorded | :running | :no_run
  def record_run(run_id, key) do
    {:ok, outcome} =
      Store.transaction(fn txn ->
        case Store.txn_query(txn, "SELECT status, error_detail FROM connector_runs WHERE id = ?1", [
               run_id
             ]) do
          {:ok, []} ->
            {:ok, :no_run}

          {:ok, [["running", _detail]]} ->
            {:ok, :running}

          {:ok, [[_status, detail]]} ->
            detail = detail |> detail_map() |> Map.update(key, 1, &(&1 + 1))

            {:ok, _} =
              Store.txn_execute(
                txn,
                "UPDATE connector_runs SET errors_encountered = errors_encountered + 1, error_detail = ?2 WHERE id = ?1",
                [run_id, Jason.encode!(detail)]
              )

            {:ok, :recorded}
        end
      end)

    outcome
  end

  defp detail_map(nil), do: %{}

  defp detail_map(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> map
      _ -> %{"detail" => text}
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
