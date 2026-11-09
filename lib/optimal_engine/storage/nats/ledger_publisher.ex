defmodule OptimalEngine.Storage.NATS.LedgerPublisher do
  @moduledoc """
  Publishes the change ledger (`sync_mutations`) to a JetStream stream, so
  anything that can read NATS can follow a workspace's changes as they happen
  without being a replication peer. On with `ledger` in `OPTIMAL_NATS_FLOWS`.

  ## What goes out

  The changes `OptimalEngine.Sync.changes/3` serves a peer that pulls: those
  of the workspaces enabled for replication (`Sync.enable/4`), only the
  tables that replicate, and never a row the data-class gate keeps home
  (`config :optimal_engine, :sync_serve_max_class`, default `confidential`).
  A workspace that is not enabled for replication has no ledger, and nothing
  of it is published.

  ## Where it goes

  Stream `<NAMESPACE>_LEDGER` (`OPTIMAL_LEDGER` by default) on subjects
  `<namespace>.ledger.<tenant>.<workspace>` (each id made a subject token by
  `OptimalEngine.Storage.NATS.Protocol.token/1`), file storage, limits
  retention, kept `OPTIMAL_NATS_LEDGER_MAX_AGE_HOURS` (default 168, `0`
  forever). A subscriber filters on one workspace's subject, or on
  `<namespace>.ledger.>` for all of them.

  Each message is one change as JSON (the shape `Sync.changes/3` serves, with
  `tenant_id` and `workspace_id`), with headers `Nats-Msg-Id` (the
  mutation's id), `Optimal-Ledger-Seq` (its ledger sequence),
  `Optimal-Entity-Type`, `Optimal-Operation` and `Optimal-Replica` (the
  Engine that published it).

  ## Ordered, once, and never in the way of a write

  Changes go out one at a time in ledger order, each waiting for the
  stream's acknowledgement before the next, so a subject holds a workspace's
  changes in the order the Engine made them. A publish whose acknowledgement
  is lost is sent again with the same message id, and the stream stores it
  once. Where to resume is read from the stream itself (the
  `Optimal-Ledger-Seq` of the last message on the workspace's subject) at
  start and after every reconnect, so a restart repeats nothing, and a stream
  that was lost is filled again from the ledger's beginning.

  No Engine write waits on this: the ledger is written in the write's
  transaction, and this process reads it afterwards. While NATS is down the
  publisher reports `buffering` with each workspace's backlog, and the
  backlog goes out when the connection is back.

  The stream is a copy for subscribers. Replication between Engines does not
  read it, and a workspace erasure does not reach it: the age limit is what
  removes a change from it.
  """

  use GenServer

  require Logger

  alias OptimalEngine.Storage.NATS
  alias OptimalEngine.Storage.NATS.{Connection, JetStream, Protocol}
  alias OptimalEngine.Store
  alias OptimalEngine.Sync

  @flow "ledger"
  @interval 1_000
  @page 200
  @pages_per_pass 10
  @max_age_env "OPTIMAL_NATS_LEDGER_MAX_AGE_HOURS"
  @default_max_age_hours 168

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts the publisher. Options (tests): `:name`, `:connection`,
  `:namespace`, `:enabled` (default: the `ledger` flow is named and the
  provider configured), `:interval_ms` (0: only `publish_now/1` publishes),
  `:workspaces` (only these workspace ids).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "One pass now. `{:ok, %{published: n}}`, or why nothing could be published."
  @spec publish_now(GenServer.server()) :: {:ok, %{published: non_neg_integer()}} | {:error, term()}
  def publish_now(server \\ __MODULE__), do: GenServer.call(server, :publish_now, 120_000)

  @doc """
  What an operator sees: `state` (`off`, `invalid_namespace`, `buffering`,
  `publishing`, `caught_up`, `error`), the stream, how many changes went out
  since start, the last error, and for each workspace the sequence published
  through and the backlog still to go.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 5_000)
  catch
    :exit, _ -> %{state: "down", workspaces: []}
  end

  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    enabled = Keyword.get_lazy(opts, :enabled, fn -> NATS.flow?(@flow) end)

    namespace =
      case Keyword.fetch(opts, :namespace) do
        {:ok, namespace} -> {:ok, namespace}
        :error -> NATS.namespace()
      end

    state = %{
      enabled: enabled,
      namespace: elem(namespace, 1),
      connection: Keyword.get(opts, :connection, Connection),
      interval: Keyword.get(opts, :interval_ms, @interval),
      only: Keyword.get(opts, :workspaces),
      state: if(enabled, do: "starting", else: "off"),
      epoch: nil,
      more: false,
      cursors: %{},
      published: 0,
      last_published_at: nil,
      last_error: nil
    }

    cond do
      not enabled ->
        {:ok, state}

      match?({:error, _}, namespace) ->
        {:ok, %{state | state: "invalid_namespace", enabled: false}}

      true ->
        schedule(state)
        {:ok, state}
    end
  end

  @impl GenServer
  def handle_call(:publish_now, _from, %{enabled: false} = state),
    do: {:reply, {:error, :off}, state}

  def handle_call(:publish_now, _from, state) do
    {reply, state} = pass(state)
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       state: state.state,
       stream: if(state.enabled, do: stream(state)),
       subjects: if(state.enabled, do: "#{state.namespace}.ledger.>"),
       published: state.published,
       last_published_at: state.last_published_at,
       last_error: state.last_error,
       workspaces: if(state.enabled, do: backlogs(state), else: [])
     }, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    {_reply, state} = pass(state)
    schedule(state)
    {:noreply, state}
  end

  defp schedule(%{interval: interval}) when interval > 0,
    do: Process.send_after(self(), :tick, interval)

  defp schedule(_state), do: :ok

  # ---------------------------------------------------------------------------
  # A pass: every workspace, a few pages each, in ledger order.
  # ---------------------------------------------------------------------------

  defp pass(state) do
    with :ok <- sqlite(),
         {:ok, state} <- provision(state) do
      {count, state} =
        Enum.reduce_while(workspaces(state), {0, state}, fn workspace, {count, state} ->
          case publish_workspace(state, workspace, @pages_per_pass, 0) do
            {:ok, n, state} -> {:cont, {count + n, state}}
            {:error, reason, n, state} -> {:halt, {count + n, failed(state, reason)}}
          end
        end)

      state = if state.state in ["error", "buffering"], do: state, else: settled(state)

      reply =
        case state.state do
          "buffering" -> {:error, :not_connected}
          "error" -> {:error, state.last_error}
          _ -> {:ok, %{published: count}}
        end

      {reply, %{state | published: state.published + count, more: false}}
    else
      {:error, :not_connected} ->
        {{:error, :not_connected}, %{state | state: "buffering"}}

      {:error, reason} ->
        {{:error, reason}, failed(state, reason)}
    end
  rescue
    error ->
      Logger.warning("[NATS] ledger pass failed: #{Exception.message(error)}")
      {{:error, :pass_failed}, failed(state, :pass_failed)}
  end

  defp sqlite do
    if Store.selected?(OptimalEngine.Store.SQLite), do: :ok, else: {:error, :unsupported_store}
  end

  # The stream is made sure of once per connection; a new connection may be to
  # a server that lost it, so where each workspace stands is read again.
  defp provision(state) do
    case Connection.status(state.connection) do
      %{state: "connected", reconnects: n, connected_since: since}
      when {n, since} == state.epoch ->
        {:ok, %{state | state: "publishing"}}

      %{state: "connected", reconnects: n, connected_since: since} ->
        config = %{
          name: stream(state),
          subjects: ["#{state.namespace}.ledger.>"],
          retention: "limits",
          storage: "file",
          max_age_ms: max_age_ms()
        }

        with {:ok, outcome, _info} <- JetStream.ensure_stream(state.connection, config) do
          if outcome == :created, do: Logger.info("[NATS] ledger stream #{config.name} created")
          {:ok, %{state | epoch: {n, since}, cursors: %{}, state: "publishing"}}
        end

      _not_connected ->
        {:error, :not_connected}
    end
  end

  # The pass's budget for one workspace is spent; the rest goes next pass.
  defp publish_workspace(state, _workspace, 0, count), do: {:ok, count, %{state | more: true}}

  defp publish_workspace(state, {tenant, ws} = workspace, pages, count) do
    with {:ok, cursor, state} <- cursor(state, workspace) do
      page = Sync.changes(tenant, ws, since: cursor, limit: @page)

      case publish_all(state, workspace, page["mutations"]) do
        {:ok, n} ->
          state = put_in(state, [:cursors, workspace], page["cursor"])
          state = if n > 0, do: %{state | last_published_at: now()}, else: state

          if page["more"],
            do: publish_workspace(state, workspace, pages - 1, count + n),
            else: {:ok, count + n, state}

        {:error, reason, n, through} ->
          state = if through, do: put_in(state, [:cursors, workspace], through), else: state
          {:error, reason, count + n, state}
      end
    else
      {:error, reason} -> {:error, reason, count, state}
    end
  end

  # One at a time, each acknowledged before the next: a subject holds the
  # workspace's changes in ledger order.
  defp publish_all(state, workspace, mutations) do
    Enum.reduce_while(mutations, {:ok, 0}, fn mutation, {:ok, n} ->
      case publish(state, workspace, mutation) do
        {:ok, _ack} ->
          {:cont, {:ok, n + 1}}

        {:error, reason} ->
          through = if n > 0, do: Enum.at(mutations, n - 1)["sequence"]
          {:halt, {:error, reason, n, through}}
      end
    end)
  end

  defp publish(state, {tenant, ws} = workspace, mutation) do
    body = mutation |> Map.put("tenant_id", tenant) |> Map.put("workspace_id", ws)

    JetStream.publish(state.connection, subject(state, workspace), Jason.encode!(body),
      msg_id: mutation["id"],
      headers: %{
        "Optimal-Ledger-Seq" => mutation["sequence"],
        "Optimal-Entity-Type" => mutation["entity_type"],
        "Optimal-Operation" => mutation["operation"],
        "Optimal-Replica" => mutation["device_id"]
      }
    )
  end

  # Where a workspace stands: in memory, or the last message on its subject.
  defp cursor(state, workspace) do
    case Map.fetch(state.cursors, workspace) do
      {:ok, cursor} ->
        {:ok, cursor, state}

      :error ->
        case JetStream.get_message(state.connection, stream(state),
               last_by_subject: subject(state, workspace)
             ) do
          {:ok, %{headers: %{"Optimal-Ledger-Seq" => seq}}} ->
            cursor = String.to_integer(seq)
            {:ok, cursor, put_in(state, [:cursors, workspace], cursor)}

          {:ok, _other} ->
            {:ok, 0, put_in(state, [:cursors, workspace], 0)}

          {:error, :not_found} ->
            {:ok, 0, put_in(state, [:cursors, workspace], 0)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp workspaces(state) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT tenant_id, workspace_id FROM sync_workspaces ORDER BY enabled_at, workspace_id",
        []
      )

    rows = Enum.map(rows, fn [tenant, ws] -> {tenant, ws} end)

    case state.only do
      nil -> rows
      only -> Enum.filter(rows, fn {_tenant, ws} -> ws in only end)
    end
  end

  # Sealed first, so a write the triggers captured counts before a pass ran.
  defp backlogs(state) do
    if sqlite() == :ok do
      {:ok, _} = OptimalEngine.Sync.Capture.seal()

      for {tenant, ws} = workspace <- workspaces(state) do
        through = Map.get(state.cursors, workspace)

        {:ok, [[backlog]]} =
          Store.raw_query(
            "SELECT COUNT(*) FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3",
            [tenant, ws, through || 0]
          )

        %{tenant_id: tenant, workspace_id: ws, published_through: through, backlog: backlog}
      end
    else
      []
    end
  end

  defp settled(%{more: true} = state), do: %{state | state: "publishing", last_error: nil}
  defp settled(state), do: %{state | state: "caught_up", last_error: nil}

  defp failed(state, reason) when reason in [:not_connected, :disconnected],
    do: %{state | state: "buffering"}

  defp failed(state, {:error, reason}), do: failed(state, reason)

  # Nobody serves the subject: the stream went while the connection stayed.
  # The next pass makes sure of it again and reads where each workspace stands.
  defp failed(state, {:no_responders, _} = reason),
    do: %{state | state: "error", last_error: inspect(reason), epoch: nil}

  defp failed(state, reason) do
    Logger.warning("[NATS] ledger publish stopped: #{inspect(reason)}")
    %{state | state: "error", last_error: inspect(reason)}
  end

  defp stream(state), do: NATS.stream_name(state.namespace, "LEDGER")

  defp subject(state, {tenant, ws}),
    do: "#{state.namespace}.ledger.#{Protocol.token(tenant)}.#{Protocol.token(ws)}"

  defp max_age_ms do
    hours =
      case Integer.parse(System.get_env(@max_age_env) || "") do
        {n, ""} when n >= 0 -> n
        _ -> @default_max_age_hours
      end

    if hours == 0, do: 0, else: hours * 3_600_000
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
