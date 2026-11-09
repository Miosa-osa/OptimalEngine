defmodule OptimalEngine.Storage.NATS.LedgerPublisher do
  @moduledoc """
  Publishes the change ledger (`sync_mutations`) to a JetStream stream, so
  anything that can read NATS can follow a workspace's changes as they happen
  without being a replication peer. On with `ledger` in `OPTIMAL_NATS_FLOWS`.

  ## What goes out

  The changes `OptimalEngine.Sync.changes/3` serves a peer that pulls: those
  of the workspaces enabled for replication (`Sync.enable/4`) and active, only
  the tables that replicate, and never a row the data-class gate keeps home
  (`config :optimal_engine, :sync_serve_max_class`, default `confidential`).
  A workspace that is not enabled for replication has no ledger, and nothing
  of it is published. The ledger is the one the Engine's store keeps, SQLite
  or PostgreSQL (`OptimalEngine.Sync.Postgres` captures the same changes), so
  both publish the same stream.

  ## Where it goes

  Stream `<NAMESPACE>_LEDGER` (`OPTIMAL_LEDGER` by default) on subjects
  `<namespace>.ledger.<tenant>.<workspace>.<table>.<row>`, one per row (each
  id made a subject token by `OptimalEngine.Storage.NATS.Protocol.token/1`),
  file storage, limits retention, kept `OPTIMAL_NATS_LEDGER_MAX_AGE_HOURS`
  (default 168, `0` forever). A subscriber filters on one workspace's
  `<namespace>.ledger.<tenant>.<workspace>.>`, or on `<namespace>.ledger.>`
  for all of them.

  Each message is one change as JSON (the shape `Sync.changes/3` serves, with
  `tenant_id` and `workspace_id`), with headers `Nats-Msg-Id` (the
  mutation's id), `Optimal-Ledger-Seq` (its ledger sequence),
  `Optimal-Entity-Type`, `Optimal-Operation` and `Optimal-Replica` (the
  Engine that published it).

  ## Ordered, once, and never in the way of a write

  Changes go out one at a time in ledger order, each waiting for the
  stream's acknowledgement before the next, so a workspace's subjects hold
  its changes in the order the Engine made them. A publish whose
  acknowledgement is lost is sent again with the same message id, and the
  stream stores it once. Where to resume is read from the stream itself (the
  `Optimal-Ledger-Seq` of the last message under the workspace's subjects) at
  start and after every reconnect, so a restart repeats nothing, and a stream
  that was lost is filled again from the ledger's beginning.

  The stream stores a message id once only inside its duplicate window (the
  server's default, two minutes). A resume point the stream gives that is
  older than what was published goes out again past that window: the
  workspace's newest messages were purged by a forget whose tombstone did not
  go out (see below), they aged out (`OPTIMAL_NATS_LEDGER_MAX_AGE_HOURS`, a
  workspace idle that long), or the stream was lost. A consumer is therefore
  idempotent on the workspace and `Optimal-Ledger-Seq`: it keeps the highest
  sequence it applied per workspace and skips a message at or below it (or
  keys on `Nats-Msg-Id`, the change's id, which never changes). No epoch is
  needed: a sequence is the ledger's, never reused, and on PostgreSQL commits
  in order (`OptimalEngine.Sync.Postgres`), so a workspace's sequences only
  grow.

  No Engine write waits on this: the ledger is written in the write's
  transaction, and this process reads it afterwards. While NATS is down the
  publisher reports `buffering` with each workspace's backlog, and the
  backlog goes out when the connection is back.

  ## What the Engine forgets leaves the stream

  A row the ledger deletes (an erasure, a retention delete, a derived-data
  removal, any delete) or a memory it forgets (`is_forgotten`) is a forget:
  before its tombstone goes out, every earlier message on the row's subject is
  purged, and the tombstone carries the row's key only. A create or update a
  later forget in the ledger covers is never published, so a stream filled
  again from the ledger holds nothing forgotten either. Each pass that forgets
  rows records an `events` row (`kind = 'nats_purge'`,
  `target_uri = "workspace:<id>"`) with the rows forgotten and the messages
  purged. `flush/1` runs a pass at once for an erasure, which records its
  result in the erasure's report and audit event.

  The purge and the tombstone are two calls. A publisher stopped between them
  leaves the row's earlier messages gone and no tombstone yet; the next pass
  resumes from the stream's last message, which is before the forget, and
  sends the forget again: the purge again (nothing left to purge), then the
  tombstone. The create or update the forget covers is withheld on that pass
  too, so nothing erased goes back. This is the same on either store.

  A workspace archived or removed (`forget_workspace/4`) has its whole subject
  tree purged. The request is an `events` row (`nats_purge_requested`) written
  first and done when NATS is reachable (now, or on a later pass); its
  completion is an `events` row (`nats_purge`,
  `target_uri = "nats-purge-request:<id>"`) with the messages purged.

  The stream is a copy for subscribers; replication between Engines does not
  read it.
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
  @empty %{published: 0, purged: 0, forgotten: 0}

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts the publisher. Options (tests): `:name`, `:connection`,
  `:namespace`, `:enabled` (default: the `ledger` flow is named and the
  provider configured), `:interval_ms` (0: only `publish_now/2` publishes),
  `:workspaces` (only these workspace ids).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  One pass now: `{:ok, %{published:, purged:, forgotten:, state:}}`, or why
  nothing could be published. `workspaces:` limits it to those workspace ids.
  """
  @spec publish_now(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish_now(server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:publish_now, opts}, 120_000)

  @doc """
  For an erasure: a pass now over `workspace_ids`, so what the erasure
  deleted leaves NATS before it reports. Returns what the erasure's evidence
  records: `%{state: "off"}` without the flow; `%{state:, messages_purged:,
  rows_forgotten:}` after the pass; `%{state: "buffering", pending: true}`
  while NATS is down (the purge happens when the deletes go out). Never
  raises.
  """
  @spec flush([String.t()]) :: map()
  def flush(workspace_ids) do
    server = Application.get_env(:optimal_engine, :nats_ledger_publisher, __MODULE__)

    case GenServer.call(server, {:publish_now, workspaces: workspace_ids}, 120_000) do
      {:ok, %{purged: purged, forgotten: forgotten, state: state}} ->
        %{state: state, messages_purged: purged, rows_forgotten: forgotten}

      {:error, :off} ->
        %{state: "off"}

      {:error, :not_connected} ->
        %{state: "buffering", pending: true}

      {:error, reason} ->
        %{state: "error", pending: true, error: inspect(reason)}
    end
  catch
    :exit, _ -> %{state: "off"}
  end

  @doc """
  Purges every message of a workspace
  (`<namespace>.ledger.<tenant>.<workspace>.>`), for a workspace archived or
  removed. The request is recorded first and done now when NATS is reachable
  (`{:ok, %{messages_purged: n}}`), else on a later pass
  (`{:ok, %{pending: true}}`). `{:ok, %{state: "off"}}` without the flow.
  Never raises and never fails the caller.
  """
  @spec forget_workspace(GenServer.server(), String.t(), String.t(), String.t()) :: {:ok, map()}
  def forget_workspace(server \\ __MODULE__, tenant_id, workspace_id, reason) do
    GenServer.call(server, {:forget_workspace, tenant_id, workspace_id, reason}, 15_000)
  catch
    # Busy or gone: the request is recorded here, and done on a later pass.
    :exit, _ ->
      with true <- NATS.flow?(@flow),
           {:ok, namespace} <- NATS.namespace() do
        request_purge(namespace, tenant_id, workspace_id, reason)
        {:ok, %{pending: true}}
      else
        _ -> {:ok, %{state: "off"}}
      end
  end

  @doc """
  What an operator sees: `state` (`off`, `invalid_namespace`, `buffering`,
  `publishing`, `caught_up`, `error`), the stream, the changes published and
  the messages purged since start, the workspace purges still waiting on
  NATS, the last error, and for each workspace the sequence published through
  and the backlog still to go.
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
      purged: 0,
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
  def handle_call({:publish_now, _opts}, _from, %{enabled: false} = state),
    do: {:reply, {:error, :off}, state}

  def handle_call({:publish_now, opts}, _from, state) do
    {reply, state} = pass(state, Keyword.get(opts, :workspaces))
    {:reply, reply, state}
  end

  def handle_call({:forget_workspace, _tenant, _ws, _reason}, _from, %{enabled: false} = state),
    do: {:reply, {:ok, %{state: "off"}}, state}

  def handle_call({:forget_workspace, tenant, ws, reason}, _from, state) do
    id = request_purge(state.namespace, tenant, ws, reason)

    with {:ok, state} <- provision(state) do
      {done, state} = process_requests(state)

      case Map.fetch(done, id) do
        {:ok, purged} ->
          {:reply, {:ok, %{messages_purged: purged}}, %{state | purged: state.purged + purged}}

        :error ->
          {:reply, {:ok, %{pending: true}}, state}
      end
    else
      {:error, :not_connected} -> {:reply, {:ok, %{pending: true}}, %{state | state: "buffering"}}
      {:error, _reason} -> {:reply, {:ok, %{pending: true}}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       state: state.state,
       stream: if(state.enabled, do: stream(state)),
       subjects: if(state.enabled, do: "#{state.namespace}.ledger.>"),
       published: state.published,
       messages_purged: state.purged,
       purges_pending: if(state.enabled, do: length(pending_requests(state)), else: 0),
       last_published_at: state.last_published_at,
       last_error: state.last_error,
       workspaces: if(state.enabled, do: backlogs(state), else: [])
     }, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    {_reply, state} = pass(state, nil)
    schedule(state)
    {:noreply, state}
  end

  defp schedule(%{interval: interval}) when interval > 0,
    do: Process.send_after(self(), :tick, interval)

  defp schedule(_state), do: :ok

  # ---------------------------------------------------------------------------
  # A pass: the workspace purges waiting, then every workspace, a few pages
  # each, in ledger order.
  # ---------------------------------------------------------------------------

  defp pass(state, only) do
    with {:ok, state} <- provision(state) do
      {done, state} = process_requests(state)
      requested = done |> Map.values() |> Enum.sum()

      {totals, state} =
        Enum.reduce_while(workspaces(state, only), {@empty, state}, fn workspace, {totals, state} ->
          case publish_workspace(state, workspace, @pages_per_pass, @empty) do
            {:ok, counts, state} ->
              {:cont, {add(totals, counts), state}}

            {:error, reason, counts, state} ->
              {:halt, {add(totals, counts), failed(state, reason)}}
          end
        end)

      state = if state.state in ["error", "buffering"], do: state, else: settled(state)
      totals = %{totals | purged: totals.purged + requested}

      reply =
        case state.state do
          "buffering" -> {:error, :not_connected}
          "error" -> {:error, state.last_error}
          settled -> {:ok, Map.put(totals, :state, settled)}
        end

      {reply,
       %{
         state
         | published: state.published + totals.published,
           purged: state.purged + totals.purged,
           more: false
       }}
    else
      {:error, :not_connected} ->
        {{:error, :not_connected}, %{state | state: "buffering"}}

      {:error, reason} ->
        {{:error, reason}, failed(state, reason)}
    end
  rescue
    # A seal that fails or times out (a long apply holding the ledger lock)
    # raises in `Sync.changes/3`; the pass ends, the cursors stay where they
    # were, and the next pass goes on from them.
    error ->
      Logger.warning("[NATS] ledger pass failed: #{Exception.message(error)}")
      {{:error, :pass_failed}, failed(state, :pass_failed)}
  catch
    kind, reason ->
      Logger.warning("[NATS] ledger pass failed: #{kind} #{inspect(reason)}")
      {{:error, :pass_failed}, failed(state, :pass_failed)}
  end

  defp add(a, b), do: Map.merge(a, b, fn _key, x, y -> x + y end)

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
  defp publish_workspace(state, _workspace, 0, counts), do: {:ok, counts, %{state | more: true}}

  defp publish_workspace(state, {tenant, ws} = workspace, pages, counts) do
    with {:ok, cursor, state} <- cursor(state, workspace) do
      page = Sync.changes(tenant, ws, since: cursor, limit: @page)
      forgets = later_forgets(tenant, ws, page["mutations"])

      case publish_all(state, workspace, page["mutations"], forgets) do
        {:ok, page_counts} ->
          state = put_in(state, [:cursors, workspace], page["cursor"])
          counts = add(counts, page_counts)

          state =
            if page_counts.published > 0, do: %{state | last_published_at: now()}, else: state

          if page["more"] do
            publish_workspace(state, workspace, pages - 1, counts)
          else
            record_forgets(state, workspace, counts, page["cursor"])
            {:ok, counts, state}
          end

        {:error, reason, page_counts, through} ->
          state = if through, do: put_in(state, [:cursors, workspace], through), else: state
          counts = add(counts, page_counts)
          record_forgets(state, workspace, counts, through)
          {:error, reason, counts, state}
      end
    else
      {:error, reason} -> {:error, reason, counts, state}
    end
  end

  # One at a time, each acknowledged before the next: the workspace's subjects
  # hold its changes in ledger order. A forget purges the row's earlier
  # messages before its tombstone; a change a later forget covers is withheld.
  defp publish_all(state, workspace, mutations, forgets) do
    mutations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, @empty}, fn {mutation, index}, {:ok, counts} ->
      result =
        cond do
          forget?(mutation) -> forget(state, workspace, mutation)
          forgotten_later?(mutation, forgets) -> {:ok, :withheld}
          true -> publish(state, workspace, mutation, mutation)
        end

      case result do
        {:ok, :withheld} ->
          {:cont, {:ok, counts}}

        {:ok, {:forgot, purged}} ->
          {:cont,
           {:ok,
            %{
              counts
              | published: counts.published + 1,
                purged: counts.purged + purged,
                forgotten: counts.forgotten + 1
            }}}

        {:ok, _ack} ->
          {:cont, {:ok, %{counts | published: counts.published + 1}}}

        {:error, reason} ->
          through = if index > 0, do: Enum.at(mutations, index - 1)["sequence"]
          {:halt, {:error, reason, counts, through}}
      end
    end)
  end

  defp forget(state, workspace, mutation) do
    with {:ok, purged} <-
           JetStream.purge(state.connection, stream(state), row_subject(state, workspace, mutation)),
         {:ok, _ack} <- publish(state, workspace, mutation, tombstone(mutation)) do
      {:ok, {:forgot, purged}}
    end
  end

  # A delete carries the row's key already; a forgotten memory keeps its id
  # and the flag, nothing it said.
  defp tombstone(%{"operation" => "delete"} = mutation), do: mutation

  defp tombstone(mutation) do
    row = (mutation["payload"] || %{}) |> Map.get("row", %{}) |> Map.take(["id", "is_forgotten"])
    %{mutation | "payload" => %{"row" => row}, "payload_hash" => nil}
  end

  defp forget?(%{"operation" => "delete"}), do: true

  defp forget?(%{"entity_type" => "memories", "payload" => %{"row" => %{"is_forgotten" => flag}}}),
    do: flag in [1, true, "1"]

  defp forget?(_mutation), do: false

  defp forgotten_later?(mutation, forgets) do
    case Map.fetch(forgets, {mutation["entity_type"], mutation["entity_id"]}) do
      {:ok, sequence} -> sequence > mutation["sequence"]
      :error -> false
    end
  end

  # The latest forget in the ledger, after this page began, of each row the
  # page changes: one query a page.
  defp later_forgets(_tenant, _ws, []), do: %{}

  defp later_forgets(tenant, ws, mutations) do
    ids = mutations |> Enum.map(& &1["entity_id"]) |> Enum.uniq()
    from = mutations |> hd() |> Map.get("sequence")
    placeholders = Enum.map_join(1..length(ids), ", ", &"?#{&1 + 3}")

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT entity_type, entity_id, sequence, operation, payload FROM sync_mutations
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3
          AND entity_id IN (#{placeholders})
          AND (operation = 'delete' OR entity_type = 'memories')
        """,
        [tenant, ws, from | ids]
      )

    Enum.reduce(rows, %{}, fn [type, id, sequence, operation, payload], acc ->
      payload = if is_binary(payload), do: Jason.decode!(payload), else: payload

      if forget?(%{"entity_type" => type, "operation" => operation, "payload" => payload}),
        do: Map.update(acc, {type, id}, sequence, &max(&1, sequence)),
        else: acc
    end)
  end

  defp publish(state, {tenant, ws} = workspace, mutation, body) do
    body = body |> Map.put("tenant_id", tenant) |> Map.put("workspace_id", ws)

    JetStream.publish(
      state.connection,
      row_subject(state, workspace, mutation),
      Jason.encode!(body),
      msg_id: mutation["id"],
      headers: %{
        "Optimal-Ledger-Seq" => mutation["sequence"],
        "Optimal-Entity-Type" => mutation["entity_type"],
        "Optimal-Operation" => mutation["operation"],
        "Optimal-Replica" => mutation["device_id"]
      }
    )
  end

  defp record_forgets(_state, _workspace, %{forgotten: 0}, _through), do: :ok

  defp record_forgets(state, {tenant, ws}, counts, through) do
    record_event(tenant, "workspace:" <> ws, %{
      flow: "ledger",
      stream: stream(state),
      workspace_id: ws,
      reason: "rows deleted or forgotten",
      rows_forgotten: counts.forgotten,
      messages_purged: counts.purged,
      through_sequence: through
    })
  end

  # Where a workspace stands: in memory, or the last message under its subjects.
  defp cursor(state, workspace) do
    case Map.fetch(state.cursors, workspace) do
      {:ok, cursor} ->
        {:ok, cursor, state}

      :error ->
        case JetStream.get_message(state.connection, stream(state),
               last_by_subject: workspace_subjects(state, workspace)
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

  # ---------------------------------------------------------------------------
  # Workspace purges: requested in `events`, done when NATS is reachable.
  # ---------------------------------------------------------------------------

  defp request_purge(namespace, tenant, ws, reason) do
    {:ok, [[id]]} =
      Store.raw_query(
        """
        INSERT INTO events (tenant_id, principal, kind, target_uri, metadata)
        VALUES (?1, 'system:nats', 'nats_purge_requested', ?2, ?3) RETURNING id
        """,
        [
          tenant,
          "workspace:" <> ws,
          Jason.encode!(%{
            flow: "ledger",
            namespace: namespace,
            tenant_id: tenant,
            workspace_id: ws,
            reason: reason
          })
        ]
      )

    id
  end

  defp pending_requests(state) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT r.id, r.metadata FROM events r
        WHERE r.kind = 'nats_purge_requested'
          AND NOT EXISTS (
            SELECT 1 FROM events d
            WHERE d.kind = 'nats_purge' AND d.target_uri = 'nats-purge-request:' || CAST(r.id AS TEXT)
          )
        ORDER BY r.id
        LIMIT 500
        """,
        []
      )

    for [id, meta] <- rows,
        meta = Jason.decode!(meta),
        meta["namespace"] == state.namespace,
        do: {id, meta}
  end

  # Each purge is a workspace's subject tree in this namespace; the result is
  # keyed by request id. One that fails stays pending for the next pass.
  defp process_requests(state) do
    Enum.reduce(pending_requests(state), {%{}, state}, fn {id, meta}, {done, state} ->
      workspace = {meta["tenant_id"], meta["workspace_id"]}
      filter = workspace_subjects(state, workspace)

      case JetStream.purge(state.connection, stream(state), filter) do
        {:ok, purged} ->
          record_event(meta["tenant_id"], "nats-purge-request:#{id}", %{
            flow: "ledger",
            stream: stream(state),
            subjects: filter,
            workspace_id: meta["workspace_id"],
            reason: meta["reason"],
            messages_purged: purged
          })

          {Map.put(done, id, purged), %{state | cursors: Map.delete(state.cursors, workspace)}}

        {:error, reason} ->
          Logger.warning("[NATS] workspace purge #{id} not done yet: #{inspect(reason)}")
          {done, state}
      end
    end)
  end

  defp record_event(tenant, target_uri, metadata) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO events (tenant_id, principal, kind, target_uri, metadata) VALUES (?1, 'system:nats', 'nats_purge', ?2, ?3)",
        [tenant, target_uri, Jason.encode!(metadata)]
      )

    :ok
  end

  # Active workspaces enabled for replication; an archived one is not published.
  defp workspaces(state, only) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT s.tenant_id, s.workspace_id FROM sync_workspaces s
        JOIN workspaces w ON w.id = s.workspace_id AND w.status = 'active'
        ORDER BY s.enabled_at, s.workspace_id
        """,
        []
      )

    rows
    |> Enum.map(fn [tenant, ws] -> {tenant, ws} end)
    |> only(state.only)
    |> only(only)
  end

  defp only(rows, nil), do: rows
  defp only(rows, ids), do: Enum.filter(rows, fn {_tenant, ws} -> ws in ids end)

  # Sealed first, so a write the triggers captured counts before a pass ran.
  defp backlogs(state) do
    seal_for_status()

    for {tenant, ws} = workspace <- workspaces(state, nil) do
      through = Map.get(state.cursors, workspace)

      {:ok, [[backlog]]} =
        Store.raw_query(
          "SELECT COUNT(*) FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3",
          [tenant, ws, through || 0]
        )

      %{tenant_id: tenant, workspace_id: ws, published_through: through, backlog: backlog}
    end
  end

  # A status never fails over a seal: one that cannot run now leaves the
  # backlog counting the ledger as it stands.
  defp seal_for_status do
    OptimalEngine.Sync.Capture.seal()
  rescue
    error -> Logger.warning("[NATS] ledger status could not seal: #{Exception.message(error)}")
  catch
    kind, reason ->
      Logger.warning("[NATS] ledger status could not seal: #{kind} #{inspect(reason)}")
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

  defp workspace_prefix(state, {tenant, ws}),
    do: "#{state.namespace}.ledger.#{Protocol.token(tenant)}.#{Protocol.token(ws)}"

  defp workspace_subjects(state, workspace), do: workspace_prefix(state, workspace) <> ".>"

  defp row_subject(state, workspace, mutation) do
    workspace_prefix(state, workspace) <>
      "." <> token(mutation["entity_type"]) <> "." <> token(mutation["entity_id"])
  end

  # An empty id would leave an empty subject token.
  defp token(value) when is_binary(value) and value != "", do: Protocol.token(value)
  defp token(value) when is_integer(value), do: Integer.to_string(value)
  defp token(_value), do: "_"

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
