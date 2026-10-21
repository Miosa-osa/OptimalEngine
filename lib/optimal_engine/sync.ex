defmodule OptimalEngine.Sync do
  @moduledoc """
  Replication between separate Engines (a laptop and a cloud Engine, or a
  workspace Engine and an org Engine), each with its own disk.

  * Enable a workspace (`enable/3`): its writes are captured
    (`OptimalEngine.Sync.Capture`) and sealed into the ordered
    `sync_mutations` ledger.
  * Serve changes (`changes/3`): mutations after a sequence, never the
    requesting replica's own, with this Engine's identity and schema version.
  * Apply changes (`apply_changes/4`): idempotent by mutation id, in origin
    order, each in its own savepoint; applied changes are added to the local
    ledger under their origin device so a hub forwards them, and are never
    re-captured.
  * Peers (`add_peer/3`, `run_peer/1`): pull from and push to another
    Engine with a replica key, per-workspace policy (`push`, `pull`, `both`,
    `none`) and a data-class gate on both send and receive
    (`OptimalEngine.Sync.Gate`): a row stays home when its own labels, or
    those of any row it was copied or derived from, are above the peer's
    class.
  * Conflicts: concurrency is ledger order, the winner is the clock. Two
    changes of a row are concurrent when the sender had not seen the other
    (judged against the sender's `base_seq` on a push, and on a pull against
    this Engine's own ledger sequence at the start of the last complete cycle
    with that peer); the newer change wins, the later device id on a tie, and
    the conflict is recorded with its kind and why. A change the sender made after
    seeing the other is applied with no clock check: a sender pushes only what
    stands after what it took from the peer, or won against it. A change this
    Engine did not take is not put in its ledger, so nothing forwards it. For
    facts, both versions also become claims in the review queue. Nothing is
    dropped silently: refused, gated, and failed changes are counted and
    failures are recorded.
  * What replicates: only the tables `Capture.replicated_tables/0` lists, an
    explicit list of workspace knowledge. A peer cannot write any other table
    (credentials, roles, API keys, tenants, members, tools, storage, the job
    queue, connectors): such a mutation is skipped as local-only or refused,
    never written, and the rest of its page still applies. Every applied row
    is stamped with the target tenant and workspace, and a row whose key
    already exists in another tenant or workspace is refused.
  * Version safety: a peer with a different schema migration pauses with a
    clear message until both run the same version.
  * Seeding: a new replica imports a workspace bundle exported after sync
    was enabled, then pulls from the bundle's `ledger_sequence`.
  """

  require Logger

  alias OptimalEngine.Compliance.DerivedData
  alias OptimalEngine.Connectors.{Credential, HTTP}
  alias OptimalEngine.LogUrl
  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Store.FileCache.Maintenance, as: Cache
  alias OptimalEngine.Store.Migrations
  alias OptimalEngine.Sync.{Capture, Gate, GateCache, Lineage}

  @classes ~w(public internal confidential restricted)
  @page 500
  @cycle_pages 20
  @cycle_budget 60_000
  # A peer whose cursors were reset is not reset again within this many seconds.
  @replace_window 600
  # How many times a day a peer's cursors are reset before the peer is halted.
  @resets_a_day 2
  @version_refused "the peer refused this Engine's schema version; sync pauses until both run the same Engine version"
  @version_unreported "the relay did not report the other Engine's schema version; sync pauses until it does"

  # -- identity and enablement -------------------------------------------------

  @doc "This Engine's replica id."
  @spec replica_id() :: String.t()
  def replica_id do
    {:ok, [[id]]} = Store.raw_query("SELECT replica_id FROM sync_identity WHERE id = 1", [])
    id
  end

  # Capture is SQLite triggers and applying reads SQLite's catalog, so a
  # PostgreSQL store refuses to start replicating rather than recording
  # changes nothing will send (`OptimalEngine.Storage.Postgres.unavailable/0`).
  @unavailable {:unsupported, "replication is not available on the PostgreSQL store"}

  @doc "Enables capture for a workspace (idempotent) and installs triggers."
  @spec enable(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def enable(tenant_id, workspace_id, by) do
    if Store.selected?(OptimalEngine.Store.SQLite),
      do: do_enable(tenant_id, workspace_id, by),
      else: {:error, @unavailable}
  end

  defp do_enable(tenant_id, workspace_id, by) do
    {:ok, _} =
      Store.raw_query(
        "INSERT OR IGNORE INTO sync_workspaces (tenant_id, workspace_id, enabled_by) VALUES (?1, ?2, ?3)",
        [tenant_id, workspace_id, by]
      )

    {:ok, triggers} = Capture.install()
    GateCache.clear()

    {:ok,
     %{
       workspace_id: workspace_id,
       replica_id: replica_id(),
       ledger_sequence: ledger_sequence(),
       triggers: triggers
     }}
  end

  @doc "Stops capturing a workspace. Existing ledger entries stay."
  @spec disable(String.t(), String.t()) :: :ok
  def disable(tenant_id, workspace_id) do
    {:ok, _} =
      Store.raw_query("DELETE FROM sync_workspaces WHERE tenant_id = ?1 AND workspace_id = ?2", [
        tenant_id,
        workspace_id
      ])

    GateCache.clear()
    :ok
  end

  @doc "Whether a workspace is enabled for sync."
  @spec enabled?(String.t()) :: boolean()
  def enabled?(workspace_id) do
    match?(
      {:ok, [_]},
      Store.raw_query("SELECT 1 FROM sync_workspaces WHERE workspace_id = ?1", [workspace_id])
    )
  end

  @doc "The highest sequence in the local ledger."
  @spec ledger_sequence() :: non_neg_integer()
  def ledger_sequence do
    case Store.raw_query("SELECT COALESCE(MAX(sequence), 0) FROM sync_mutations", []) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  @doc """
  The highest data class this Engine hands to a peer that pulls from it
  (`changes/3`, and the storage ledger reader). A peer that pulls does not
  say what it is cleared for, so this is the Engine's own ceiling:
  `config :optimal_engine, :sync_serve_max_class`, default `confidential`.
  """
  @spec serve_max_class() :: String.t()
  def serve_max_class do
    case Application.get_env(:optimal_engine, :sync_serve_max_class, "confidential") do
      class when class in @classes -> class
      _unknown -> "confidential"
    end
  end

  @doc "Identity and schema version, sent with every change page."
  @spec engine_info() :: map()
  def engine_info do
    %{
      "replica_id" => replica_id(),
      "version" => Application.spec(:optimal_engine, :vsn) |> to_string(),
      "migration" => OptimalEngine.Store.Migrations.all() |> Enum.map(&elem(&1, 0)) |> Enum.max()
    }
  end

  # -- serving and applying ----------------------------------------------------

  @doc """
  Mutations for `workspace_id` after `since`, oldest first, excluding those
  that originated on `requester` (so nothing echoes back) and those the
  data-class gate keeps home (`:max_class`, default `serve_max_class/0`; the
  cursor moves past them). Returns the page, the cursor to continue from, and
  engine info.
  """
  @spec changes(String.t(), String.t(), keyword()) :: map()
  def changes(tenant_id, workspace_id, opts \\ []) do
    {:ok, _} = Capture.seal()
    since = Keyword.get(opts, :since, 0)
    limit = opts |> Keyword.get(:limit, @page) |> max(1) |> min(2_000)
    requester = opts[:requester] || ""
    max_class = opts[:max_class] || serve_max_class()

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT sequence, id, device_id, entity_type, entity_id, operation, payload, payload_hash,
               idempotency_key, occurred_at
        FROM sync_mutations
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3
        ORDER BY sequence LIMIT ?4
        """,
        [tenant_id, workspace_id, since, limit]
      )

    cursor = if rows == [], do: since, else: rows |> List.last() |> hd()

    mutations =
      for(
        [_seq, id, device, type, _entity, _op, _payload, _hash, key, _at] = row <- rows,
        device != requester,
        Capture.replicated?(type),
        change_row?(id, device, key),
        do: to_mutation(row)
      )
      |> releasable(tenant_id, workspace_id, max_class)

    %{
      "workspace_id" => workspace_id,
      "mutations" => mutations,
      "cursor" => cursor,
      "more" => length(rows) == limit,
      "head" => workspace_sequence(tenant_id, workspace_id),
      "engine" => engine_info()
    }
  end

  @doc """
  Applies a batch of mutations to `workspace_id`. Options: `:max_class`
  (data-class gate, default `confidential`), and what the sender had seen of
  this Engine, for conflict detection:

  * `:base_seq` with `:base_replica_id`: this Engine's ledger sequence the
    sender had pulled when it pushed, and the replica id it believed it was
    pulling from. A change here after the sequence is concurrent with the
    sender's; one at or before it was seen, and the incoming change is applied
    without a clock check (the sender only pushes the changes that stand after
    what it saw). A sequence from another ledger (the replica id differs or is
    missing) or past this workspace's ledger head cannot be trusted and counts
    as no base.
  * `:local_floor`: a sequence of this Engine's own ledger, for a batch it
    pulled: this Engine's ledger head at the start of the last cycle with that
    peer in which the pull reached the end of the peer's ledger and the push
    sent everything. Its own changes at or below it are taken as seen by the
    peer; the ones after it are concurrent. It is a sequence of this ledger,
    so the two Engines' clocks do not enter into it.
  * `:sender`: the replica id of the Engine that pushed. Its own earlier
    changes, and those of the incoming change's origin, are never concurrent
    with it; changes here from any other device are.
  * `:direction`: `:pull` when this Engine fetched the batch from the peer
    (only its own changes are candidates for a conflict), `:push` (default)
    when the peer sent it.
  * none of the base options: every change of the row here counts as
    concurrent, and the conflict is recorded as `unknown_base`.

  The sender is a claim of the replica that holds the key: a `:sender` that
  names this Engine is ignored, and a `:base_seq` that passes the checks above
  is believed, so a replica key is trusted to report what it saw.

  Returns counts, the conflicts, and `:base`, the base used (`"seq"`,
  `"floor"` or `"unknown"`).
  """
  @spec apply_changes(String.t(), String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def apply_changes(tenant_id, workspace_id, mutations, opts \\ []) do
    {:ok, _} = Capture.seal()
    local = replica_id()
    max_class = Keyword.get(opts, :max_class, "confidential")
    base = base_for(opts, tenant_id, workspace_id, local)

    if Gate.workspace_rank(workspace_id) > Gate.class_rank(max_class) do
      {:error, :workspace_class_above_gate}
    else
      columns = batch_columns(mutations)

      plans =
        Enum.map(
          mutations,
          &plan(&1, tenant_id, workspace_id, local, max_class, base, columns)
        )

      with {:ok, result} <- execute(tenant_id, workspace_id, plans) do
        {:ok, result |> Map.put(:base, Atom.to_string(base.kind)) |> put_base_rejected(base)}
      end
    end
  end

  defp put_base_rejected(result, %{rejected: nil}), do: result
  defp put_base_rejected(result, %{rejected: why}), do: Map.put(result, :base_rejected, why)

  # What the sender had seen, as far as it can be trusted. A sequence belongs to
  # one ledger: it means something here only when the sender says it pulled
  # from this replica, and it cannot be past what this workspace's ledger holds.
  # Zero claims nothing seen, so it needs no proof.
  defp base_for(opts, tenant_id, workspace_id, local) do
    direction = Keyword.get(opts, :direction, :push)

    base = %{
      kind: :unknown,
      seen: nil,
      floor: nil,
      rejected: nil,
      direction: direction,
      sender: sender_other_than(opts[:sender], local)
    }

    case {opts[:base_seq], opts[:local_floor]} do
      {seq, _floor} when is_integer(seq) and seq >= 0 ->
        cond do
          seq == 0 -> %{base | kind: :seq, seen: 0}
          opts[:base_replica_id] != local -> %{base | rejected: "replica_mismatch"}
          seq > workspace_sequence(tenant_id, workspace_id) -> %{base | rejected: "above_head"}
          true -> %{base | kind: :seq, seen: seq}
        end

      {_seq, floor} when is_integer(floor) and floor >= 0 ->
        %{base | kind: :floor, floor: floor}

      _ ->
        base
    end
  end

  # A sender names itself, and the name decides whose changes are left out of the
  # candidates, so one that names this Engine is ignored.
  defp sender_other_than(local, local), do: nil
  defp sender_other_than(sender, _local), do: sender

  @doc """
  The tables this Engine replicates and the ones it keeps local, with its schema
  migration. A relay reads it instead of keeping a list of its own.
  """
  @spec tables() :: %{replicated: [String.t()], local_only: [String.t()], migration: integer()}
  def tables do
    {:ok, authority} =
      Store.raw_query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND substr(name, 1, 10) = 'authority_' ORDER BY name",
        []
      )

    %{
      replicated: Capture.replicated_tables(),
      local_only: Enum.sort(Capture.local_tables() ++ List.flatten(authority)),
      migration: engine_info()["migration"]
    }
  end

  # Ledger rows are removed a batch at a time, so one DELETE never holds the Store
  # for a whole ledger, and the Store is given back between batches.
  @purge_batch 5_000
  @purge_yield_ms 10

  # Tables whose rows grant access or move Engine state: a peer that pushed one
  # wrote it as the Engine's own (an API key, a principal, a role, a tenant, a
  # migration, a workspace, a peer, an authority record). What each purged ledger
  # row said is logged before it is removed, so the operator can check the table.
  @evidence_tables ~w(api_keys principals roles role_grants tenants schema_migrations workspaces
                       workspace_members node_members principal_skills mcp_tool_definitions
                       skill_packages routing_rules storage_provider_configs data_collections
                       sync_peers)

  # Only a ledger row that names a table of this Engine (or an `authority_*`
  # table) is removed. The ledger also holds the storage replication entries
  # `OptimalEngine.Storage.PolicyStore.append_mutation/1` writes, whose entity
  # types are free-form and name no table: those stay.
  @purge_scope "(entity_type IN (SELECT name FROM sqlite_master WHERE type = 'table') OR " <>
                 "entity_type LIKE 'authority\\_%' ESCAPE '\\')"

  @doc """
  Removes the ledger rows of tables that do not replicate: an earlier version
  captured every workspace table, and applied whatever a peer named. Returns the
  rows removed per table. The rows those entries wrote into the tables
  themselves are not touched; a table that is not on the list can hold a row no
  one on this Engine wrote, and only its operator can tell.

  A ledger row is removed only when it names a table of this Engine or an
  `authority_*` table: the storage replication entries, whose entity types name
  no table, stay.

  Of the tables that grant access or hold Engine state (keys, principals, roles
  and grants, tenants, migrations, workspaces and their members, skills, tools,
  routing, storage providers, collections, peers and every `authority_*` table)
  each row is logged first, with its mutation id, entity id, device and time,
  never its payload.
  """
  @spec purge_unreplicated() :: {:ok, %{String.t() => non_neg_integer()}}
  def purge_unreplicated do
    names = Capture.replicated_tables()
    marks = names |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)
    purge_batches(names, marks, 0, %{})
  end

  defp purge_batches(names, marks, after_sequence, counts) do
    n = length(names)

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT sequence, id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, occurred_at
        FROM sync_mutations
        WHERE sequence > ?#{n + 1} AND entity_type NOT IN (#{marks}) AND #{@purge_scope}
        ORDER BY sequence LIMIT ?#{n + 2}
        """,
        names ++ [after_sequence, @purge_batch]
      )

    if rows == [] do
      {:ok, counts}
    else
      Enum.each(rows, &log_purged/1)
      last = rows |> List.last() |> hd()

      {:ok, _} =
        Store.raw_query(
          "DELETE FROM sync_mutations WHERE sequence > ?#{n + 1} AND sequence <= ?#{n + 2} " <>
            "AND entity_type NOT IN (#{marks}) AND #{@purge_scope}",
          names ++ [after_sequence, last]
        )

      counts =
        Enum.reduce(rows, counts, fn [_seq, _id, _tenant, _ws, _dev, type | _], acc ->
          Map.update(acc, type, 1, &(&1 + 1))
        end)

      Process.sleep(@purge_yield_ms)
      purge_batches(names, marks, last, counts)
    end
  end

  defp log_purged([_seq, id, tenant, workspace, device, type, entity, operation, at]) do
    if type in @evidence_tables or String.starts_with?(type, "authority_") do
      Logger.warning(
        "[Sync] purged ledger row #{id}: #{operation} #{type} #{entity} " <>
          "(tenant #{tenant}, workspace #{workspace}, device #{device}, at #{at})"
      )
    end
  end

  @doc """
  `purge_unreplicated/0` and `report_colon_ids/0`, once for each version of the
  replicated list and of the boot checks of the ledger: the version is kept in the
  database file (`PRAGMA user_version`), so a later boot does not scan the whole
  ledger again, and a change to the list (a table demoted from it drops its
  unsent ledger rows) or a new check runs them once more.
  """
  @spec purge_unreplicated_once() :: {:ok, %{String.t() => non_neg_integer()}}
  def purge_unreplicated_once do
    version = list_version()

    case Store.raw_query("PRAGMA user_version", []) do
      {:ok, [[^version]]} ->
        {:ok, %{}}

      _ ->
        with {:ok, purged} <- purge_unreplicated(),
             {:ok, _reported} <- report_colon_ids() do
          {:ok, _} = Store.raw_query("PRAGMA user_version = #{version}", [])
          {:ok, purged}
        end
    end
  end

  # Raised when a boot check of the ledger is added, so it runs once on an
  # Engine that already ran the others. 1: `report_colon_ids/0`.
  @ledger_checks 1

  # A positive 31-bit number that changes with the replicated list and the checks.
  defp list_version,
    do: :erlang.phash2({Capture.replicated_tables(), @ledger_checks}, 2_000_000_000) + 1

  @doc """
  Logs every ledger row whose mutation id has a colon, the shape of a capture
  key (`<replica>:<n>`), which no mutation id has: an Engine before the id check
  stored such a change from a peer as it came. Each row is logged with its
  sequence, id, scope, device, table, entity id and time, never its payload. It
  is no change of a row (`change_row?/3`), so it is not served, pushed or
  counted. Returns how many were found.
  """
  @spec report_colon_ids() :: {:ok, non_neg_integer()}
  def report_colon_ids, do: report_colon_ids(0, 0)

  defp report_colon_ids(after_sequence, found) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT sequence, id, tenant_id, workspace_id, device_id, entity_type, entity_id, occurred_at
        FROM sync_mutations
        WHERE sequence > ?1 AND instr(id, ':') > 0
        ORDER BY sequence LIMIT ?2
        """,
        [after_sequence, @purge_batch]
      )

    Enum.each(rows, fn [sequence, id, tenant, workspace, device, type, entity, at] ->
      Logger.warning(
        "[Sync] ledger row #{sequence} has a colon in its mutation id #{id}, so it is not " <>
          "served or pushed: #{type} #{entity} (tenant #{tenant}, workspace #{workspace}, " <>
          "device #{device}, at #{at})"
      )
    end)

    case rows do
      [] ->
        {:ok, found}

      _ ->
        Process.sleep(@purge_yield_ms)
        report_colon_ids(rows |> List.last() |> hd(), found + length(rows))
    end
  end

  # A mutation id never has a colon (`change_row?/3`).
  defp colon_id?(id), do: String.contains?(id, ":")

  # -- peers -------------------------------------------------------------------

  @doc """
  Registers a peer Engine for a workspace. Attrs: `url`, `api_key` (a key on
  the peer scoped to the workspace with the `sync` scope), `policy`
  (default `both`), `max_class` (default `confidential`), `since` (the peer
  ledger sequence to start pulling from, for a seeded replica).
  """
  @spec add_peer(String.t(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def add_peer(tenant_id, attrs, by) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    policy = attrs["policy"] || "both"
    max_class = attrs["max_class"] || "confidential"

    cond do
      not Store.selected?(OptimalEngine.Store.SQLite) ->
        {:error, @unavailable}

      not (is_binary(attrs["workspace_id"]) and attrs["workspace_id"] != "") ->
        {:error, :workspace_id_required}

      not (is_binary(attrs["url"]) and String.match?(attrs["url"], ~r{\A(relay\+)?https?://})) ->
        {:error, :invalid_url}

      not is_binary(attrs["api_key"]) ->
        {:error, :api_key_required}

      policy not in ~w(push pull both none) ->
        {:error, :invalid_policy}

      max_class not in @classes ->
        {:error, :invalid_max_class}

      true ->
        store_peer(tenant_id, attrs, policy, max_class, by)
    end
  end

  @doc "Peers, without their keys."
  @spec peers(String.t(), String.t() | nil) :: [map()]
  def peers(tenant_id, workspace_id \\ nil) do
    {sql, params} =
      if workspace_id,
        do: {"WHERE tenant_id = ?1 AND workspace_id = ?2", [tenant_id, workspace_id]},
        else: {"WHERE tenant_id = ?1", [tenant_id]}

    {:ok, rows} = Store.raw_query(peer_sql() <> sql, params)
    Enum.map(rows, &(&1 |> to_peer() |> Map.delete(:credential)))
  end

  @doc "Runs one pull and push cycle for every active peer. Returns per-peer results."
  @spec run_all() :: [map()]
  def run_all do
    {:ok, rows} =
      Store.raw_query(
        peer_sql() <> "WHERE status NOT IN ('disabled', 'halted') AND policy != 'none'",
        []
      )

    Enum.map(rows, fn row ->
      peer = to_peer(row)

      try do
        run_peer(peer)
      rescue
        # One peer's failure does not stop the others. The message can quote
        # the peer's URL, so the log names only the exception; the peer's
        # status keeps the message for the operator.
        error ->
          Logger.error(
            "[Sync] cycle for #{LogUrl.render(peer.url)} failed (#{inspect(error.__struct__)}); " <>
              "the peer's status has the message"
          )

          update_peer_status(peer, {"error", Exception.message(error)})

          %{
            workspace_id: peer.workspace_id,
            url: peer.url,
            status: "error",
            reason: Exception.message(error)
          }
      end
    end)
  end

  @doc """
  Pulls from and pushes to one peer, honoring its policy. Paging stops once
  the cycle has run `:sync_cycle_budget_ms` (default 60 s) and resumes on the
  next cycle, so one slow peer cannot hold the scheduler.
  """
  @spec run_peer(map()) :: map()
  def run_peer(peer) do
    # One run of a peer at a time: the scheduler's tick and `POST /api/sync/run`
    # would otherwise pull and push the same pages twice, and race on the cursors.
    lock = {{:sync_peer, peer.tenant_id, peer.workspace_id, peer.url}, self()}

    case :global.trans(lock, fn -> run_peer_locked(peer) end, [node()], 0) do
      :aborted ->
        %{workspace_id: peer.workspace_id, url: peer.url, status: "busy", reason: :already_running}

      result ->
        result
    end
  end

  defp run_peer_locked(peer) do
    budget = Application.get_env(:optimal_engine, :sync_cycle_budget_ms, @cycle_budget)
    deadline = System.monotonic_time(:millisecond) + budget
    started = utc_now_iso()

    # Sealed first, so the head counts every change captured so far: it is the
    # floor the next pull judges this Engine's own changes against.
    {:ok, _} = Capture.seal()
    head = workspace_sequence(peer.tenant_id, peer.workspace_id)

    with {:ok, key} <- peer_key(peer),
         {:ok, peer} <- prepare(peer, key) do
      pulled =
        if peer.policy in ["pull", "both"],
          do: pull(peer, key, deadline),
          else: {:ok, %{skipped: :policy}}

      # Reload: a pull learns the peer's replica id, which push must not echo to.
      peer = reload_peer(peer)

      pushed =
        cond do
          # A peer on another schema version is sent nothing until both match.
          match?({:error, {:version_mismatch, _}}, pulled) -> {:ok, %{skipped: :paused_version}}
          # Nor is one whose identity is not settled: what it acknowledges may be another Engine's.
          identity_error?(pulled) -> {:ok, %{skipped: :identity}}
          peer.policy in ["push", "both"] -> push(peer, key, deadline)
          true -> {:ok, %{skipped: :policy}}
        end

      status =
        case {pulled, pushed} do
          {{:error, {:version_mismatch, message}}, _} -> {"paused_version", message}
          {_, {:error, {:version_mismatch, message}}} -> {"paused_version", message}
          {{:error, :peer_halted}, _} -> {"halted", error_message(:peer_halted)}
          {{:error, reason}, _} -> {"error", error_message(reason)}
          {_, {:error, reason}} -> {"error", error_message(reason)}
          _ -> {"active", base_message(pushed)}
        end

      update_peer_status(peer, status, cycle_synced(peer, pulled, pushed, started, head))

      %{
        workspace_id: peer.workspace_id,
        url: peer.url,
        pull: pulled,
        push: pushed,
        status: elem(status, 0)
      }
    else
      {:error, {:version_mismatch, message}} ->
        update_peer_status(peer, {"paused_version", message})
        %{workspace_id: peer.workspace_id, url: peer.url, status: "paused_version", reason: message}

      {:error, :peer_halted} ->
        update_peer_status(peer, {"halted", error_message(:peer_halted)})
        %{workspace_id: peer.workspace_id, url: peer.url, status: "halted", reason: :peer_halted}

      {:error, reason} ->
        update_peer_status(peer, {"error", error_message(reason)})
        %{workspace_id: peer.workspace_id, url: peer.url, status: "error", reason: reason}
    end
  end

  defp identity_error?({:error, reason}),
    do: reason in [:peer_identity_unstable, :peer_replica_unreported, :peer_halted]

  defp identity_error?(_pulled), do: false

  defp error_message(:peer_halted),
    do:
      "the peer changed its replica id again within a day, twice already; sync is halted for it until it is added again (POST /api/sync/peers) once the Engine behind the URL is settled"

  defp error_message(:peer_identity_unstable),
    do:
      "the peer answers under more than one replica id (two Engines behind one URL, or a relay that does not report this Engine's own id); its cursors were not reset again"

  defp error_message(:peer_replica_unreported),
    do: "the peer's change page does not say which replica it is; sync pauses until it does"

  defp error_message(reason), do: inspect(reason)

  # A push the peer answered, but whose base it did not accept, still moved
  # everything; the message says why its conflict checks were conservative.
  defp base_message({:ok, %{base_rejected: why}}),
    do:
      "the peer did not accept the base this Engine sent (#{why}), so it judged concurrent changes conservatively; check that the relay reports this peer's own replica id"

  defp base_message(_pushed), do: nil

  @doc "Replication state for a workspace: lag, last sync, pending, conflicts."
  @spec status(String.t(), String.t()) :: map()
  def status(tenant_id, workspace_id) do
    {:ok, _} = Capture.seal()

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT table_name, COUNT(*) FROM sync_conflicts
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND state = 'open'
        GROUP BY table_name
        """,
        [tenant_id, workspace_id]
      )

    by_table = Map.new(rows, fn [table, count] -> {table, count} end)
    local_seq = workspace_sequence(tenant_id, workspace_id)
    local = replica_id()

    %{
      workspace_id: workspace_id,
      enabled: enabled?(workspace_id),
      replica_id: local,
      ledger_sequence: local_seq,
      open_conflicts: by_table |> Map.values() |> Enum.sum(),
      conflicts_by_table: by_table,
      append_only_tables: Capture.append_only_tables(),
      peers:
        Enum.map(peers(tenant_id, workspace_id), fn peer ->
          Map.put(peer, :pending_push, pending_push(tenant_id, workspace_id, peer, local))
        end)
    }
  end

  @doc "Conflicts for a workspace (open by default)."
  @spec conflicts(String.t(), String.t(), String.t()) :: [map()]
  def conflicts(tenant_id, workspace_id, state \\ "open") do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, table_name, entity_key, kind, resolution, local_payload, remote_payload, remote_device,
               state, detail, created_at, resolved_by, resolved_at
        FROM sync_conflicts WHERE tenant_id = ?1 AND workspace_id = ?2 AND (?3 = 'all' OR state = ?3)
        ORDER BY created_at
        """,
        [tenant_id, workspace_id, state]
      )

    Enum.map(rows, fn [
                        id,
                        table,
                        key,
                        kind,
                        resolution,
                        local,
                        remote,
                        device,
                        state,
                        detail,
                        at,
                        by,
                        resolved_at
                      ] ->
      %{
        id: id,
        table: table,
        entity_key: key,
        kind: kind,
        resolution: resolution,
        local: decode(local),
        remote: decode(remote),
        remote_device: device,
        state: state,
        detail: decode_detail(detail),
        created_at: at,
        resolved_by: by,
        resolved_at: resolved_at
      }
    end)
  end

  @doc "Marks a conflict resolved (after review)."
  @spec resolve_conflict(String.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def resolve_conflict(tenant_id, id, by) do
    case Store.transaction(fn txn ->
           Store.txn_execute(
             txn,
             """
             UPDATE sync_conflicts SET state = 'resolved', resolved_by = ?3, resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
             WHERE tenant_id = ?1 AND id = ?2 AND state = 'open'
             """,
             [tenant_id, id, by]
           )
         end) do
      {:ok, 1} -> :ok
      _ -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Applying

  # The columns of each replicated table a batch names, read once per batch.
  defp batch_columns(mutations) do
    for %{"entity_type" => table} <- mutations, Capture.replicated?(table), into: %{} do
      {table, Capture.columns(target_table(table))}
    end
  end

  defp plan(mutation, _tenant_id, _workspace_id, _local, _gate, _base, _columns)
       when not is_map(mutation),
       do: {:skip, :invalid, %{}}

  defp plan(mutation, tenant_id, workspace_id, local, gate, base, columns) do
    invalid = invalid_reason(mutation)

    cond do
      mutation["device_id"] == local ->
        {:skip, :own, mutation}

      invalid ->
        {:fail, invalid, mutation}

      # The ids this Engine's own changes get are its own: a peer may not take one.
      own_id_space?(mutation, local) ->
        {:fail, :mutation_id_in_use, mutation}

      # A colon is the shape of a capture key (`<replica>:<capture sequence>`),
      # which no mutation id has.
      String.contains?(mutation["id"], ":") ->
        {:fail, :invalid_mutation_id, mutation}

      true ->
        case id_state(tenant_id, workspace_id, mutation["id"]) do
          :duplicate -> {:skip, :duplicate, mutation}
          :elsewhere -> {:fail, :mutation_id_in_use, mutation}
          :new -> plan_table(mutation, tenant_id, workspace_id, local, gate, base, columns)
        end
    end
  end

  # `mut_<replica>_<capture sequence>` and `<replica>:<capture sequence>` are what
  # `Capture.seal/0` gives this Engine's changes. One that arrives from another
  # device, as an id or as a key, would take the id of a change still to come,
  # and the ledger ignores the second row with an id or a key, so the Engine's own
  # change would never be sealed.
  defp own_id_space?(mutation, local) do
    id = mutation["id"]
    key = mutation["idempotency_key"]

    String.starts_with?(id, "mut_" <> local <> "_") or String.starts_with?(id, local <> ":") or
      (is_binary(key) and String.starts_with?(key, local <> ":"))
  end

  defp plan_table(mutation, tenant_id, workspace_id, local, gate, base, columns) do
    table = mutation["entity_type"]

    cond do
      # A table that stays on its Engine (members, tools, storage, connectors,
      # the job queue, ...) is not applied from a peer, whatever the peer sent.
      Capture.known_local?(table) ->
        {:skip, :local_only, mutation}

      # The peer names the table, so only the tables this Engine replicates
      # are accepted: never credentials, roles, API keys, tenants or the like.
      not Capture.replicated?(table) ->
        {:fail, not_replicated_reason(table), mutation}

      Gate.held_on_receive?(mutation, gate) ->
        {:skip, :gated, mutation}

      true ->
        plan_row(
          mutation,
          tenant_id,
          workspace_id,
          local,
          gate,
          base,
          Map.get(columns, table, [])
        )
    end
  end

  defp plan_row(mutation, tenant_id, workspace_id, local, gate, base, columns) do
    table = target_table(mutation["entity_type"])
    append_only = Capture.rowid_key?(columns)
    payload = mutation["payload"]
    names = Map.keys(payload["row"]) ++ Map.keys(payload["blobs"] || %{})

    with :ok <- known_columns(columns, names),
         :ok <- supported_operation(append_only, mutation["operation"]),
         :ok <- known_signal_values(table, mutation),
         {:ok, mutation} <- confine_paths(table, mutation) do
      mutation = with_row_key(mutation, columns, append_only, tenant_id, workspace_id)

      # An append-only row is named by its capture sequence on the Engine that
      # wrote it, so a local row with the same name is a different row: it is
      # always added, never a conflict.
      conflict =
        if append_only do
          nil
        else
          tenant_id
          |> local_conflict(workspace_id, mutation, local, base)
          |> unless_same_content(mutation)
        end

      {:apply, %{mutation: mutation, columns: columns, conflict: conflict, gate: gate}}
    else
      {:error, reason} -> {:fail, reason, mutation}
    end
  end

  # A document's or chunk's mode, signal type and format are read back as atoms
  # from fixed sets. A value in none of them is not a signal this Engine wrote,
  # so it is refused rather than stored (reads fall back to a default anyway, and
  # never mint an atom).
  @signal_tables ~w(contexts classifications)

  defp known_signal_values(table, mutation) when table in @signal_tables do
    row = mutation["payload"]["row"]

    ok? =
      signal_value?(row["mode"], Signal.valid_modes()) and
        signal_value?(row["signal_type"], Signal.valid_types()) and
        signal_value?(row["format"], Signal.valid_formats())

    if ok?, do: :ok, else: {:error, :invalid_signal_value}
  end

  defp known_signal_values(_table, _mutation), do: :ok

  defp signal_value?(nil, _valid), do: true

  defp signal_value?(value, valid) when is_binary(value),
    do: value in Enum.map(valid, &Atom.to_string/1)

  defp signal_value?(_value, _valid), do: false

  # The sender names the row's `entity_id`, which the conflict check and the
  # ledger look rows up by. The row says which row it is: its key is the one the
  # payload's key columns give, written the way capture writes it (with the scope
  # columns stamped as `write/6` stamps them), so a sender cannot name one row and
  # change another to escape the check.
  defp with_row_key(mutation, columns, append_only, tenant_id, workspace_id) do
    keys = Capture.key_columns(columns)
    stamped = %{"tenant_id" => tenant_id, "workspace_id" => workspace_id}
    scope = Map.take(stamped, Enum.map(columns, & &1.name))
    row = Map.merge(mutation["payload"]["row"], scope)

    if append_only or keys == [] or not Enum.all?(keys, &(row[&1] != nil)),
      do: mutation,
      else: Map.put(mutation, "entity_id", entity_key(keys, row))
  end

  @doc false
  # The key capture gives a row (`Capture.key_expr/3`), computed from its values.
  def entity_key([key], row), do: key_text(row[key])
  def entity_key(keys, row), do: keys |> Enum.map(&row[&1]) |> Jason.encode!()

  defp key_text(value) when is_binary(value), do: value
  defp key_text(value), do: to_string(value)

  # Every name the payload carries, a blob's as well as a row column's, must be
  # a column of the table: a name is quoted into the statement that writes it.
  defp known_columns([], _names), do: {:error, :unknown_table}

  defp known_columns(columns, names) do
    known = MapSet.new(columns, & &1.name)
    if Enum.all?(names, &MapSet.member?(known, &1)), do: :ok, else: {:error, :unknown_columns}
  end

  # An append-only table is keyed by the capture sequence of the Engine that
  # wrote the row, which says nothing about a row here: there is nothing to
  # delete by that key, and deleting by it could remove an unrelated row.
  defp supported_operation(true, "delete"), do: {:error, :operation_not_supported}
  defp supported_operation(_append_only, _operation), do: :ok

  # Columns that name a place on this Engine's disk. A peer's value is confined:
  # relative to the workspace, no parent segment, no NUL. `contexts.path` is the
  # exception that proves the rule: the indexer stores the absolute path of the
  # file on the Engine that read it, which is no place on this one, so an
  # absolute value is dropped (NULL) instead of refused, and the context
  # replicates without it. The ledger keeps what was applied.
  @confined_columns %{
    "nodes" => ["slug", "path"],
    "node_types" => ["slug"],
    "wiki_pages" => ["slug"]
  }

  # A blob is written after the row's values are merged in, over any column of the
  # same name, so a blob named for a confined column would bypass the check on the
  # row: it is refused.
  defp confine_paths(table, mutation) do
    blob_names = Map.keys(mutation["payload"]["blobs"] || %{})

    if Enum.any?(blob_names, &(&1 in confined_columns(table))),
      do: {:error, :invalid_path},
      else: confine_row_paths(table, mutation)
  end

  defp confined_columns("contexts"), do: ["path"]
  defp confined_columns(table), do: Map.get(@confined_columns, table, [])

  defp confine_row_paths("contexts", mutation) do
    case get_in(mutation, ["payload", "row", "path"]) do
      nil ->
        {:ok, mutation}

      path when is_binary(path) ->
        cond do
          not safe_segments?(path) -> {:error, :invalid_path}
          Path.type(path) == :absolute or windows_path?(path) -> {:ok, drop_path(mutation, "path")}
          true -> {:ok, mutation}
        end

      _other ->
        {:error, :invalid_path}
    end
  end

  defp confine_row_paths(table, mutation) do
    columns = Map.get(@confined_columns, table, [])
    row = mutation["payload"]["row"]

    if Enum.all?(columns, &confined?(Map.get(row, &1))),
      do: {:ok, mutation},
      else: {:error, :invalid_path}
  end

  defp confined?(nil), do: true

  defp confined?(path) when is_binary(path),
    do: safe_segments?(path) and Path.type(path) == :relative and not windows_path?(path)

  defp confined?(_other), do: false

  defp safe_segments?(path) do
    not String.contains?(path, <<0>>) and ".." not in String.split(path, ["/", "\\"])
  end

  defp windows_path?(path), do: Regex.match?(~r/\A[A-Za-z]:|\A\\\\/, path)

  defp drop_path(mutation, column), do: put_in(mutation, ["payload", "row", column], nil)

  defp not_replicated_reason(table) do
    if Capture.columns(table) == [], do: :unknown_table, else: :table_not_replicated
  end

  @operations ~w(create update delete)

  # What a well-formed mutation holds, checked before anything is read from it:
  # a missing or mistyped field would otherwise fail a constraint (and the
  # whole batch) instead of this one mutation.
  defp invalid_reason(mutation) do
    cond do
      not Enum.all?(~w(id device_id entity_type entity_id), &text?(mutation[&1])) ->
        :invalid_mutation

      mutation["operation"] not in @operations ->
        :invalid_mutation

      not (is_nil(mutation["idempotency_key"]) or is_binary(mutation["idempotency_key"])) ->
        :invalid_mutation

      not is_binary(mutation["occurred_at"]) ->
        :invalid_occurred_at

      not valid_payload?(mutation["payload"]) ->
        :invalid_payload

      # A column holds a number, text or nothing. A list or an object cannot
      # be bound to a statement, and would end the whole batch with an error.
      not Enum.all?(mutation["payload"]["row"], fn {_name, value} -> scalar?(value) end) ->
        :unsupported_value

      true ->
        nil
    end
  end

  defp text?(value), do: is_binary(value) and value != ""

  defp valid_payload?(%{"row" => row} = payload) when is_map(row),
    do: valid_blobs?(Map.get(payload, "blobs"))

  defp valid_payload?(_payload), do: false

  # An integer that does not fit SQLite's 64 bits cannot be bound to a statement
  # (the driver raises), which would end the whole batch and, on a pull, the page
  # that never advances.
  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  defp scalar?(value) when is_integer(value), do: value >= @int64_min and value <= @int64_max

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp valid_blobs?(nil), do: true

  defp valid_blobs?(blobs) when is_map(blobs) do
    Enum.all?(blobs, fn {_name, hex} ->
      is_binary(hex) and match?({:ok, _}, Base.decode16(hex, case: :mixed))
    end)
  end

  defp valid_blobs?(_blobs), do: false

  # Foreign keys are checked at commit first, so a child that arrives before its
  # parent in the same batch still lands. When that commit fails, the batch is
  # run again with every foreign key checked as its row is written: the rows that
  # name something this Engine lacks fail alone, and the rest of the page applies.
  # A row refused for its foreign key in that run is tried once more after the
  # rest of the page, so a child that came before its parent still lands.
  defp execute(tenant_id, workspace_id, plans, foreign_keys \\ :deferred) do
    erasing = erased_context_ids(plans)
    file_plan = plan_erased_files(tenant_id, workspace_id, erasing, erased_package_ids(plans))

    result =
      Store.transaction(fn txn ->
        {:ok, _} = Store.txn_execute(txn, "UPDATE sync_identity SET applying = 1 WHERE id = 1", [])

        if foreign_keys == :deferred,
          do: {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])

        outcome =
          Enum.reduce(
            plans,
            %{
              applied: 0,
              skipped: %{},
              failed: [],
              conflicts: [],
              fact_conflicts: [],
              retry: [],
              held: [],
              erased?: false
            },
            fn
              {:skip, reason, _mutation}, acc ->
                count_skip(acc, reason)

              {:fail, reason, mutation}, acc ->
                record_failure(txn, tenant_id, workspace_id, mutation, reason)
                %{acc | failed: [%{id: mutation["id"], reason: reason} | acc.failed]}

              # Planned outside this transaction, so a concurrent apply of the
              # same change (`POST /api/sync/run` during a scheduler tick) may
              # have committed it since; an append-only row would be added twice.
              {:apply, step}, acc ->
                case txn_id_state(txn, tenant_id, workspace_id, step.mutation["id"]) do
                  :new ->
                    apply_step(txn, tenant_id, workspace_id, step, acc, foreign_keys)

                  :duplicate ->
                    count_skip(acc, :duplicate)

                  :elsewhere ->
                    record_failure(txn, tenant_id, workspace_id, step.mutation, :mutation_id_in_use)

                    %{
                      acc
                      | failed: [
                          %{id: step.mutation["id"], reason: :mutation_id_in_use} | acc.failed
                        ]
                    }
                end
            end
          )

        outcome =
          outcome.retry
          |> Enum.reverse()
          |> Enum.reduce(%{outcome | retry: []}, fn step, acc ->
            apply_step(txn, tenant_id, workspace_id, step, acc, :final)
          end)

        {:ok, _} = Store.txn_execute(txn, "UPDATE sync_identity SET applying = 0 WHERE id = 1", [])
        {:ok, outcome}
      end)

    case result do
      {:ok, outcome} ->
        # What the gate cached stands on the write sequences of the capture and
        # the ledger, which an apply moves (it writes with capture off, and
        # records each change in the ledger). Dropping it does not rest on that.
        if outcome.applied > 0 or outcome.conflicts != [], do: GateCache.clear()
        log_held(outcome.held)
        Enum.each(outcome.fact_conflicts, &raise_fact_claims(tenant_id, workspace_id, &1))
        if outcome.erased?, do: purge_erased(workspace_id, file_plan)

        {:ok,
         %{
           applied: outcome.applied,
           skipped: outcome.skipped,
           failed: Enum.reverse(outcome.failed),
           conflicts: length(outcome.conflicts)
         }}

      {:error, {:commit_failed, reason}} when foreign_keys == :deferred ->
        if foreign_key_failure?(reason),
          do: execute(tenant_id, workspace_id, plans, :immediate),
          else: {:error, {:commit_failed, reason}}

      error ->
        error
    end
  end

  defp foreign_key_failure?(reason), do: String.contains?(inspect(reason), "FOREIGN KEY")

  defp count_skip(acc, reason), do: update_in(acc, [:skipped, reason], &((&1 || 0) + 1))

  # A change a peer sent for a row this Engine holds above the class the peer is
  # cleared for is skipped (see `check_existing_labels/8`). It is logged once the
  # batch has committed, not inside the transaction, and only a few lines for a
  # batch (a peer can send many); the key is cut, never the row.
  @held_logged 10

  defp log_held([]), do: :ok

  defp log_held(held) do
    held = Enum.reverse(held)

    for mutation <- Enum.take(held, @held_logged) do
      Logger.warning(
        "[Sync] skipped #{mutation["operation"]} of #{mutation["entity_type"]} #{cut(mutation["entity_id"])} " <>
          "from #{cut(mutation["device_id"])}: this Engine holds the row above the class that peer is cleared for"
      )
    end

    if length(held) > @held_logged,
      do:
        Logger.warning(
          "[Sync] #{length(held) - @held_logged} more changes were skipped the same way"
        )

    :ok
  end

  # By bytes, not by graphemes: a single grapheme can hold any number of
  # combining marks, and a key is whatever a peer sent.
  @cut_bytes 64

  defp cut(value) when is_binary(value) do
    value |> binary_part(0, min(byte_size(value), @cut_bytes)) |> whole_characters(3) |> inspect()
  end

  defp cut(value), do: inspect(value, limit: 3, printable_limit: @cut_bytes)

  # A cut can leave the first bytes of a multi-byte character at the end.
  defp whole_characters(binary, drop) when drop > 0 and binary != "" do
    if String.valid?(binary),
      do: binary,
      else: whole_characters(binary_part(binary, 0, byte_size(binary) - 1), drop - 1)
  end

  defp whole_characters(binary, _drop), do: binary

  # A delete of a context that a peer made (an erasure, a retention delete, a move)
  # removed its rows here, and the derived rows that went with it arrive as deletes of
  # their own. What this Engine keeps outside the database does not: the embeddings
  # it cached from that text, and what it made from the context's source package (its
  # decomposition runs, checkpoints and assets, which are not replicated). The origin deletes
  # those with the package, so they go once the batch has committed and the package row is
  # gone (`DerivedData.remove_planned_files/1`). A failure is logged and never fails an apply
  # that has already committed.
  defp note_erased(acc, "contexts", %{"operation" => "delete"}), do: %{acc | erased?: true}
  defp note_erased(acc, "source_packages", %{"operation" => "delete"}), do: %{acc | erased?: true}
  defp note_erased(acc, _table, _mutation), do: acc

  # The contexts the batch asks to delete.
  defp erased_context_ids(plans) do
    for {:apply, %{mutation: %{"operation" => "delete"} = mutation}} <- plans,
        target_table(mutation["entity_type"]) == "contexts",
        id = get_in(mutation, ["payload", "row", "id"]) || mutation["entity_id"],
        is_binary(id),
        uniq: true,
        do: id
  end

  # The source packages the batch asks to delete: this Engine's own rows made from one (its
  # decomposition runs, its assets) are not replicated and are found by it.
  defp erased_package_ids(plans) do
    for {:apply, %{mutation: %{"operation" => "delete"} = mutation}} <- plans,
        target_table(mutation["entity_type"]) == "source_packages",
        id = get_in(mutation, ["payload", "row", "id"]) || mutation["entity_id"],
        is_binary(id),
        uniq: true,
        do: id
  end

  # Read before the batch, because the rows the files and rows are found by go with it
  # (the package an asset names is cleared when the package is deleted). A plan that cannot be
  # read is logged, and the batch goes on: what it would have removed stays, and the log
  # says so.
  defp plan_erased_files(_tenant_id, _workspace_id, [], []), do: []

  defp plan_erased_files(tenant_id, workspace_id, context_ids, package_ids) do
    case DerivedData.file_plan(tenant_id, workspace_id, context_ids, package_ids) do
      {:ok, entries} ->
        entries

      {:error, reason} ->
        Logger.error(
          "[Sync] could not read what this Engine made from the #{length(context_ids)} " <>
            "context(s) and #{length(package_ids)} source package(s) a peer deleted in " <>
            "#{workspace_id}; it stays: #{inspect(reason)}"
        )

        []
    end
  end

  defp purge_erased(workspace_id, file_plan) do
    # The embedding entries cannot be told apart per context; the files can, below.
    Cache.purge_workspace(workspace_id, :sync, artifacts: false)
    remove_planned_files(workspace_id, file_plan)
    :ok
  rescue
    error ->
      Logger.error(
        "[Sync] could not purge what #{workspace_id} kept of a deleted context: " <>
          Exception.message(error)
      )
  end

  # What was planned before the batch is asked again against what is committed now
  # (`DerivedData.remove_planned_files/1`): a delete that was not applied (held, or kept for a
  # newer local change), a context created in the same batch on the same package and a
  # write that came after the plan all keep the files.
  defp remove_planned_files(_workspace_id, []), do: :ok

  defp remove_planned_files(workspace_id, file_plan) do
    case DerivedData.remove_planned_files(file_plan) do
      {:ok, %{kept: kept}} when kept > 0 ->
        Logger.info(
          "[Sync] #{kept} source package(s) of #{workspace_id} keep their files and rows: a " <>
            "context or a claim still refers to them, or the package is still here"
        )

      {:ok, _removed} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Sync] could not remove the files of the contexts a peer deleted in #{workspace_id}: " <>
            inspect(reason)
        )
    end
  end

  defp apply_step(
         txn,
         tenant_id,
         workspace_id,
         %{mutation: mutation, columns: columns, conflict: conflict, gate: gate} = step,
         acc,
         foreign_keys
       ) do
    table = target_table(mutation["entity_type"])

    if conflict && local_wins?(conflict, mutation) do
      # The change here is newer: the incoming one is not applied, and it is
      # not put in the ledger either, so a hub never forwards a change this
      # Engine did not take. A repeat is judged the same way and the conflict
      # is recorded once (its id comes from the mutation).
      record_conflict(txn, tenant_id, workspace_id, mutation, conflict, "kept_local_newer")
      acc = %{acc | conflicts: [mutation["id"] | acc.conflicts]}

      if table == "facts",
        do: %{acc | fact_conflicts: [{conflict, mutation} | acc.fact_conflicts]},
        else: acc
    else
      savepoint = "sync_" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, _} = Store.txn_execute(txn, "SAVEPOINT #{savepoint}", [])

      case write(txn, table, columns, mutation, workspace_id, tenant_id, gate) do
        :ok ->
          {:ok, _} = Store.txn_execute(txn, "RELEASE #{savepoint}", [])
          record_ledger(txn, tenant_id, workspace_id, mutation)

          acc = %{acc | applied: acc.applied + 1} |> note_erased(table, mutation)

          if conflict do
            record_conflict(
              txn,
              tenant_id,
              workspace_id,
              mutation,
              conflict,
              "applied_remote_newer"
            )

            acc = %{acc | conflicts: [mutation["id"] | acc.conflicts]}

            if table == "facts",
              do: %{acc | fact_conflicts: [{conflict, mutation} | acc.fact_conflicts]},
              else: acc
          else
            acc
          end

        {:error, reason} ->
          {:ok, _} = Store.txn_execute(txn, "ROLLBACK TO #{savepoint}", [])
          {:ok, _} = Store.txn_execute(txn, "RELEASE #{savepoint}", [])

          cond do
            # The row it would overwrite or delete is above the gate: it stays as it is.
            reason == :gated ->
              acc = count_skip(acc, :gated)
              %{acc | held: [mutation | acc.held]}

            # Its parent may come later in the page: once more after the rest.
            foreign_keys == :immediate and foreign_key_failure?(reason) ->
              %{acc | retry: [step | acc.retry]}

            true ->
              record_failure(txn, tenant_id, workspace_id, mutation, reason)
              reason = if is_atom(reason), do: reason, else: inspect(reason)
              %{acc | failed: [%{id: mutation["id"], reason: reason} | acc.failed]}
          end
      end
    end
  end

  # Of two concurrent changes the newer wins, and when they carry the same time
  # the greater device id does, so both Engines keep the same version.
  defp local_wins?(local_change, mutation),
    do:
      {local_change.occurred_at, local_change.device} >
        {mutation["occurred_at"], mutation["device_id"]}

  # A change to a superseded table (one sealed before this Engine's upgrade,
  # Store.Migrations.superseded_tables/0) is applied to its successor.
  defp target_table(table), do: Map.get(Migrations.superseded_tables(), table, table)

  # The row is written into the target tenant and workspace whatever the peer
  # claims: the scope columns are stamped over the payload's, and a row whose
  # key already exists in another tenant or workspace is refused (a key is
  # often just `id`, so an upsert or a delete on it would otherwise reach a
  # row that is not this workspace's).
  defp write(txn, table, columns, mutation, workspace_id, tenant_id, gate) do
    payload = mutation["payload"]
    keys = Capture.key_columns(columns)
    append_only = Capture.rowid_key?(columns)
    delete? = mutation["operation"] == "delete"
    keyed? = keys != [] and (delete? or not append_only)

    scope =
      for {name, value} <- [{"tenant_id", tenant_id}, {"workspace_id", workspace_id}],
          Enum.any?(columns, &(&1.name == name)),
          do: {name, value}

    # A workspace belongs to one tenant, so the workspace is what keeps a row in
    # its place; the tenant guards a table that has no workspace column.
    guard =
      case List.keyfind(scope, "workspace_id", 0) do
        nil -> scope
        workspace -> [workspace]
      end

    row =
      (payload["row"] || %{})
      |> Map.merge(
        Map.new(payload["blobs"] || %{}, fn {name, hex} ->
          {name, {:blob, Base.decode16!(hex, case: :mixed)}}
        end)
      )
      |> Map.merge(Map.new(scope))

    with :ok <- check_keys(keyed?, delete?, keys, row),
         :ok <- check_scope(txn, table, keyed? and guard != [], keys, row, guard),
         :ok <- check_existing_labels(txn, table, columns, keyed?, keys, row, guard, gate),
         {:ok, row} <- grow_labels(txn, table, keys, row, mutation["operation"], append_only, gate),
         {sql, params} = statement(mutation["operation"], table, keys, append_only, guard, row),
         {:ok, _} <- Store.txn_execute(txn, sql, params) do
      :ok
    end
  end

  # The gate also applies to the row a change would overwrite or delete: a delete
  # carries no labels, and an overwrite may carry lower ones, so a peer limited
  # to `confidential` could otherwise remove or downgrade a `restricted` row. The
  # existing row is classified by what it carries itself, the way a received row
  # is (`Gate.held_on_receive?/2`): its labels, partitions, metadata labels and
  # classification level.
  defp check_existing_labels(txn, table, columns, true, keys, row, guard, gate) do
    with spec when not is_nil(spec) <- Lineage.spec(table),
         [_ | _] = names <-
           Enum.filter(Lineage.columns(spec), fn name -> Enum.any?(columns, &(&1.name == name)) end) do
      key_sql =
        (Enum.map(keys, &{&1, "="}) ++ Enum.map(guard, &{elem(&1, 0), "IS"}))
        |> Enum.with_index(1)
        |> Enum.map_join(" AND ", fn {{name, op}, i} -> "#{quote_name(name)} #{op} ?#{i}" end)

      params = Enum.map(keys, &row[&1]) ++ Enum.map(guard, &elem(&1, 1))

      case Store.txn_query(
             txn,
             "SELECT #{columns_sql(names)} FROM #{quote_name(table)} WHERE #{key_sql} LIMIT 1",
             params
           ) do
        {:ok, [values]} ->
          existing = names |> Enum.zip(values) |> Map.new()
          rank = Lineage.own_rank(spec, existing)

          if rank != nil and rank > Gate.class_rank(gate), do: {:error, :gated}, else: :ok

        {:ok, _none} ->
          :ok

        {:error, _} = error ->
          error
      end
    else
      _no_labels -> :ok
    end
  end

  defp check_existing_labels(_txn, _table, _columns, false, _keys, _row, _guard, _gate), do: :ok

  defp check_keys(true, _delete?, keys, row) do
    if Enum.all?(keys, &(row[&1] != nil)), do: :ok, else: {:error, :missing_key}
  end

  defp check_keys(false, true, _keys, _row), do: {:error, :missing_key}
  defp check_keys(false, false, _keys, _row), do: :ok

  defp check_scope(_txn, _table, false, _keys, _row, _scope), do: :ok

  defp check_scope(txn, table, true, keys, row, guard) do
    key_sql =
      keys
      |> Enum.with_index(1)
      |> Enum.map_join(" AND ", fn {k, i} -> "#{quote_name(k)} = ?#{i}" end)

    guard_sql =
      guard
      |> Enum.with_index(length(keys) + 1)
      |> Enum.map_join(" OR ", fn {{name, _value}, i} -> "#{quote_name(name)} IS NOT ?#{i}" end)

    params = Enum.map(keys, &row[&1]) ++ Enum.map(guard, &elem(&1, 1))

    case Store.txn_query(
           txn,
           "SELECT 1 FROM #{quote_name(table)} WHERE #{key_sql} AND (#{guard_sql}) LIMIT 1",
           params
         ) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, :cross_scope}
      {:error, _} = error -> error
    end
  end

  defp statement("delete", table, keys, _append_only, guard, row) do
    where =
      (Enum.map(keys, &{&1, "="}) ++ Enum.map(guard, &{elem(&1, 0), "IS"}))
      |> Enum.with_index(1)
      |> Enum.map_join(" AND ", fn {{name, op}, i} -> "#{quote_name(name)} #{op} ?#{i}" end)

    {"DELETE FROM #{quote_name(table)} WHERE #{where}",
     Enum.map(keys, &row[&1]) ++ Enum.map(guard, &elem(&1, 1))}
  end

  defp statement(_operation, table, keys, append_only, _guard, row) do
    t = quote_name(table)

    if append_only or keys == [] do
      row = Map.drop(row, if(append_only, do: keys, else: []))
      names = Map.keys(row)

      {"INSERT OR IGNORE INTO #{t} (#{columns_sql(names)}) VALUES (#{placeholders(names)})",
       Enum.map(names, &row[&1])}
    else
      names = Map.keys(row)

      updates =
        names
        |> Enum.reject(&(&1 in keys))
        |> Enum.map_join(", ", &"#{quote_name(&1)} = excluded.#{quote_name(&1)}")

      conflict = if updates == "", do: "DO NOTHING", else: "DO UPDATE SET #{updates}"

      {"INSERT INTO #{t} (#{columns_sql(names)}) VALUES (#{placeholders(names)}) ON CONFLICT (#{columns_sql(keys)}) #{conflict}",
       Enum.map(names, &row[&1])}
    end
  end

  # Labels only grow when a change is applied: a row this Engine already holds
  # keeps the labels, the metadata labels and the classification level it has,
  # whatever the sender wrote and however old its change is. What the change
  # carries is joined with what is held; a change that carries all of it is
  # written as sent. Labels that cannot be read count as `restricted`.
  #
  # A delete carries only the key, so what it removes is judged by the row held
  # here: a row above the class the peer is cleared for is not deleted by it
  # (the peer was never sent it, and a create that followed would otherwise
  # find no row to keep the labels of).
  defp grow_labels(_txn, _table, _keys, row, _operation, true, _max_class), do: {:ok, row}
  defp grow_labels(_txn, _table, [], row, _operation, _append_only, _max_class), do: {:ok, row}

  defp grow_labels(txn, table, keys, row, operation, false, max_class) do
    spec = Lineage.spec(table)

    columns =
      cond do
        spec == nil -> []
        operation == "delete" -> own_label_columns(spec)
        true -> label_columns(spec, row)
      end

    if columns == [] or not Enum.all?(keys, &Map.has_key?(row, &1)) do
      {:ok, row}
    else
      where =
        keys
        |> Enum.with_index(1)
        |> Enum.map_join(" AND ", fn {key, index} -> "#{quote_name(key)} = ?#{index}" end)

      sql =
        "SELECT #{Enum.map_join(columns, ", ", &quote_name/1)} FROM #{quote_name(table)} WHERE #{where}"

      case {operation, Store.txn_query(txn, sql, Enum.map(keys, &row[&1]))} do
        {_, {:error, reason}} ->
          {:error, {:labels_unreadable, reason}}

        {_, {:ok, []}} ->
          {:ok, row}

        {"delete", {:ok, [held]}} ->
          rank = Lineage.own_rank(spec, Map.new(Enum.zip(columns, held)))

          if rank != nil and rank > Gate.class_rank(max_class),
            do: {:error, :gated},
            else: {:ok, row}

        {_, {:ok, [held]}} ->
          {:ok, keep_held(spec, row, Map.new(Enum.zip(columns, held)))}
      end
    end
  end

  # The columns of a table that say how classified a row is.
  defp own_label_columns(spec) do
    Enum.filter(
      [
        if(spec.labels, do: "security_labels"),
        if(spec.partitions, do: "partition_ids"),
        spec.meta,
        spec.class
      ],
      & &1
    )
  end

  # The columns of the change that say how classified the row is.
  defp label_columns(spec, row) do
    [
      if(spec.labels, do: "security_labels"),
      if(spec.partitions, do: "partition_ids"),
      spec.meta,
      spec.class
    ]
    |> Enum.filter(&(&1 && Map.has_key?(row, &1)))
  end

  defp keep_held(spec, row, held) do
    row
    |> keep_labels("security_labels", spec.labels, held)
    |> keep_labels("partition_ids", spec.partitions, held)
    |> keep_metadata_labels(spec.meta, held)
    |> keep_class(spec.class, held)
  end

  defp keep_labels(row, _column, false, _held), do: row

  defp keep_labels(row, column, true, held) do
    sent = SecurityLabels.labels(plain(row[column]))

    case SecurityLabels.labels(plain(held[column])) -- sent do
      [] -> row
      missing -> Map.put(row, column, Jason.encode!(sent ++ missing))
    end
  end

  defp keep_metadata_labels(row, nil, _held), do: row

  defp keep_metadata_labels(row, column, held) do
    sent = row[column] |> plain() |> SecurityLabels.metadata_map()
    kept = held[column] |> plain() |> SecurityLabels.metadata_map()

    {merged, changed?} =
      Enum.reduce(["security_labels", "partition_ids"], {sent, false}, fn key, {acc, changed?} ->
        carried = SecurityLabels.labels(plain(acc[key]))

        case SecurityLabels.labels(plain(kept[key])) -- carried do
          [] -> {acc, changed?}
          missing -> {Map.put(acc, key, carried ++ missing), true}
        end
      end)

    if changed?, do: Map.put(row, column, Jason.encode!(merged)), else: row
  end

  # Only a level above `internal` (the column's default, which says nothing)
  # is kept; a level this Engine does not know is the highest.
  defp keep_class(row, nil, _held), do: row

  defp keep_class(row, column, held) do
    kept = plain(held[column])

    if class_level(kept) >= 2 and class_level(kept) > class_level(plain(row[column])),
      do: Map.put(row, column, kept),
      else: row
  end

  defp class_level(value) when value in [nil, ""], do: 0
  defp class_level(value), do: SecurityLabels.class_rank(value) || 3

  defp plain({:blob, bytes}), do: bytes
  defp plain(value), do: value

  defp record_ledger(txn, tenant_id, workspace_id, mutation) do
    payload = Jason.encode!(mutation["payload"])

    {:ok, _} =
      Store.txn_execute(
        txn,
        """
        INSERT OR IGNORE INTO sync_mutations
          (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload, payload_hash,
           idempotency_key, occurred_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        """,
        [
          mutation["id"],
          tenant_id,
          workspace_id,
          mutation["device_id"],
          mutation["entity_type"],
          mutation["entity_id"],
          mutation["operation"],
          payload,
          # The hash and the key are this Engine's: what the sender claims for them is
          # not stored. The id is unique in the ledger, and so is the key made from it,
          # which is namespaced apart from the keys `Capture.seal/0` gives
          # (`<replica>:<capture sequence>`), so no applied change can hold one.
          :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower),
          applied_key(mutation["id"]),
          mutation["occurred_at"]
        ]
      )
  end

  @doc false
  # The ledger key of a change this Engine applied from a peer.
  def applied_key(id), do: "peer:" <> id

  @doc """
  Whether a ledger row is a change of a row: written by change capture
  (`mut_<device>_<n>`, keyed `<device>:<n>`) or by a sync apply (keyed
  `peer:<id>`). Storage mutation entries share the ledger and are neither, so
  only these rows are served, pushed, counted as pending, or taken for this
  Engine's own change of a row, whatever entity type an entry names. A row
  whose id has a colon (the shape of a capture key, which no mutation id has)
  is none either: an Engine before the id check stored such a change from a
  peer as it came, and it is reported at boot instead (`report_colon_ids/0`).
  """
  @spec change_row?(term(), term(), term()) :: boolean()
  def change_row?(id, device, key) when is_binary(id) and is_binary(device) and is_binary(key) do
    prefix = device <> ":"

    not colon_id?(id) and
      (key == applied_key(id) or
         (String.starts_with?(key, prefix) and
            id == "mut_" <> device <> "_" <> String.replace_prefix(key, prefix, "")))
  end

  def change_row?(_id, _device, _key), do: false

  @doc false
  # `change_row?/3` as a condition on `sync_mutations`, or on the alias of it a
  # join names. Every reader of the ledger that takes a row for a change uses it.
  # It is written with LIKE, substr, length and ||, which the PostgreSQL store
  # translates (`OptimalEngine.Store.Dialect` refuses instr).
  @spec change_row_sql(String.t() | nil) :: String.t()
  def change_row_sql(table \\ nil) do
    [key, id, device] =
      for column <- ["idempotency_key", "id", "device_id"],
          do: if(table, do: "#{table}.#{column}", else: column)

    "(#{id} NOT LIKE '%:%' AND (#{key} = 'peer:' || #{id} OR " <>
      "(substr(#{key}, 1, length(#{device}) + 1) = #{device} || ':' AND " <>
      "#{id} = 'mut_' || #{device} || '_' || substr(#{key}, length(#{device}) + 2))))"
  end

  # Every conflict says why: its kind (`concurrent_edit`, `fact_divergence`,
  # `unknown_base`) and, in `detail`, the local change's sequence and device, the
  # base it was judged against, the time of each side's change, and the
  # resolution. Its id comes from the scope, the incoming mutation and the
  # resolution, so judging the same change again records nothing new, and a
  # mutation id another workspace or tenant used does not hide this one.
  defp record_conflict(txn, tenant_id, workspace_id, mutation, local, resolution) do
    detail = %{
      "mutation_id" => mutation["id"],
      "local_seq" => local.sequence,
      "local_device" => local.device,
      "base_seq" => local.base_seq,
      "local_floor" => local.local_floor,
      "local_occurred_at" => local.occurred_at,
      "remote_occurred_at" => mutation["occurred_at"],
      "resolution" => resolution
    }

    id =
      "sc_" <>
        (:crypto.hash(
           :sha256,
           Enum.join([tenant_id, workspace_id, mutation["id"], resolution], "|")
         )
         |> binary_part(0, 10)
         |> Base.url_encode64(padding: false))

    {:ok, _} =
      Store.txn_execute(
        txn,
        """
        INSERT OR IGNORE INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind,
                                              resolution, local_payload, remote_payload, remote_device, detail)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        """,
        [
          id,
          tenant_id,
          workspace_id,
          mutation["entity_type"],
          mutation["entity_id"],
          local.kind,
          resolution,
          local.payload,
          Jason.encode!(mutation["payload"]),
          mutation["device_id"],
          Jason.encode!(detail)
        ]
      )
  end

  defp record_failure(txn, tenant_id, workspace_id, mutation, reason) do
    {:ok, _} =
      Store.txn_execute(
        txn,
        """
        INSERT INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind, resolution,
                                    remote_payload, remote_device, detail)
        VALUES (?1, ?2, ?3, ?4, ?5, 'apply_failed', 'not_applied', ?6, ?7, ?8)
        """,
        [
          "sc_" <> random_id(),
          tenant_id,
          workspace_id,
          text_or(mutation["entity_type"], "unknown"),
          text_or(mutation["entity_id"], nil),
          Jason.encode!(mutation["payload"]),
          text_or(mutation["device_id"], nil),
          inspect(reason)
        ]
      )
  end

  # A refused mutation may carry any JSON in a field; only text is recorded as such.
  defp text_or(value, _default) when is_binary(value), do: value
  defp text_or(_value, default), do: default

  # Both versions of a contested fact go to the review queue as claims.
  defp raise_fact_claims(tenant_id, workspace_id, {local, mutation}) do
    alias OptimalEngine.MemoryCore.SourcePackage
    alias OptimalEngine.MemoryCore.Store, as: CoreStore

    local_row = Gate.mutation_row(%{"payload" => decode(local.payload)})
    remote_row = Gate.mutation_row(mutation)
    local_text = local_row["fact_text"]
    remote_text = remote_row["fact_text"]

    texts =
      Enum.reject([{"local", local_text}, {"remote", remote_text}], fn {_, text} -> is_nil(text) end)

    if texts != [] do
      raw = Enum.map_join(texts, "\n", fn {side, text} -> "#{side}: #{text}" end)

      # The claims quote the fact, so they carry its labels: those of both
      # versions and of the fact now. `fact_id` lets the gate follow a later
      # relabel of the fact.
      {labels, partitions} =
        conflict_scope(tenant_id, workspace_id, mutation["entity_id"], [local_row, remote_row])

      source =
        SourcePackage.from_text("Replication conflict on fact #{mutation["entity_id"]}\n" <> raw,
          tenant_id: tenant_id,
          workspace_id: workspace_id,
          source_type: "sync_conflict",
          source_system: "optimal-sync",
          security_labels: labels,
          partition_ids: partitions,
          metadata: %{"sync_conflict" => true, "fact_id" => mutation["entity_id"]}
        )

      _ = CoreStore.insert_source_package(source)
      raise_source_scope(source.id, labels, partitions, mutation["entity_id"])

      Enum.each(texts, fn {side, text} ->
        CoreStore.insert_claim(%{
          id: "clm_sync_" <> random_id(),
          tenant_id: tenant_id,
          workspace_id: workspace_id,
          source_package_id: source.id,
          claim_text: text,
          security_labels: labels,
          partition_ids: partitions,
          lifecycle_state: "pending",
          review_status: "unreviewed",
          metadata: %{"sync_conflict" => true, "side" => side, "fact_id" => mutation["entity_id"]}
        })
      end)
    end
  rescue
    error ->
      Logger.warning("[Sync] could not raise fact conflict claims: #{Exception.message(error)}")
  end

  # The labels and partitions of a contested fact: both versions' and the
  # stored fact's. A value that cannot be read counts as `restricted`; a Store
  # error raises, and the conflict is then not turned into claims at all.
  defp conflict_scope(tenant_id, workspace_id, fact_id, rows) do
    stored =
      case Store.raw_query(
             "SELECT security_labels, partition_ids FROM facts WHERE id = ?1 AND tenant_id = ?2 AND workspace_id = ?3",
             [fact_id, tenant_id, workspace_id]
           ) do
        {:ok, [[labels, partitions]]} ->
          [%{"security_labels" => labels, "partition_ids" => partitions}]

        {:ok, []} ->
          []

        {:error, reason} ->
          raise "could not read fact #{fact_id}: #{inspect(reason)}"
      end

    Enum.reduce(rows ++ stored, {[], []}, fn row, {labels, partitions} ->
      {labels, bad_labels?} = join_values(labels, row["security_labels"])
      {partitions, bad_partitions?} = join_values(partitions, row["partition_ids"])

      labels =
        if bad_labels? or bad_partitions?,
          do: SecurityLabels.merge(labels, ["restricted"]),
          else: labels

      {labels, partitions}
    end)
  end

  defp join_values(joined, value) do
    case SecurityLabels.decode(value) do
      {:ok, _} -> {SecurityLabels.merge(joined, value), false}
      :invalid -> {joined, true}
    end
  end

  # `insert_source_package` keeps the package that is already there when the
  # same conflict text is raised again, with the labels and the metadata it had.
  # Its labels and partitions only ever grow, and it names the fact either way.
  # A Store error raises, so no claims are raised beside a package whose labels
  # were not set.
  defp raise_source_scope(source_id, labels, partitions, fact_id) do
    with {:ok, [[stored_labels, stored_partitions]]} <-
           Store.raw_query(
             "SELECT security_labels, partition_ids FROM source_packages WHERE id = ?1",
             [source_id]
           ),
         {merged_labels, merged_partitions} =
           merge_scope(labels, partitions, stored_labels, stored_partitions),
         {:ok, _} <-
           Store.raw_query(
             """
             UPDATE source_packages
             SET security_labels = ?2, partition_ids = ?3,
                 metadata = json_set(COALESCE(metadata, '{}'), '$.sync_conflict', json('true'), '$.fact_id', ?4)
             WHERE id = ?1
             """,
             [source_id, Jason.encode!(merged_labels), Jason.encode!(merged_partitions), fact_id]
           ) do
      :ok
    else
      {:ok, []} -> :ok
      {:error, reason} -> raise "could not label conflict source #{source_id}: #{inspect(reason)}"
    end
  end

  defp merge_scope(labels, partitions, stored_labels, stored_partitions) do
    {merged_labels, bad_labels?} = join_values(labels, stored_labels)
    {merged_partitions, bad_partitions?} = join_values(partitions, stored_partitions)

    merged_labels =
      if bad_labels? or bad_partitions?,
        do: SecurityLabels.merge(merged_labels, ["restricted"]),
        else: merged_labels

    {merged_labels, merged_partitions}
  end

  # The latest change here to the incoming change's row that it may be
  # concurrent with, judged against what the sender had seen; nil when there is
  # none. With a base sequence the order is the ledger's, not the clock's: a
  # change here after the base is concurrent, whatever its time, and one at or
  # before it was seen by the sender. Which of two concurrent versions is newer
  # is their change time (then the device id), the rule both Engines use, so
  # they keep the same version.
  #
  # Which changes here are candidates depends on who sent the batch. A batch
  # this Engine pulled can only be concurrent with this Engine's own changes.
  # A batch pushed to it can be concurrent with any change here except the
  # sender's own and the incoming change's origin's (their order is the
  # sender's ledger's), including changes a third replica made.
  defp local_conflict(tenant_id, workspace_id, mutation, local, base) do
    table = mutation["entity_type"]

    floor =
      case base do
        %{kind: :floor, floor: sequence} -> sequence
        _ -> 0
      end

    {device_sql, devices} = candidate_devices(base, mutation, local)

    change =
      case Store.raw_query(
             """
             SELECT sequence, occurred_at, payload, device_id, operation FROM sync_mutations
             WHERE tenant_id = ?1 AND workspace_id = ?2 AND entity_type = ?3 AND entity_id = ?4
               AND sequence > ?5 AND #{device_sql} AND #{change_row_sql()}
             ORDER BY sequence DESC LIMIT 1
             """,
             [tenant_id, workspace_id, table, mutation["entity_id"], floor | devices]
           ) do
        {:ok, [[sequence, at, payload, device, operation]]} ->
          %{
            sequence: sequence,
            occurred_at: at,
            payload: payload,
            device: device,
            operation: operation
          }

        _ ->
          nil
      end

    case {change, base} do
      {nil, _} ->
        nil

      {%{sequence: sequence}, %{kind: :seq, seen: seen}} when sequence <= seen ->
        nil

      {change, base} ->
        change |> Map.merge(base_detail(base)) |> Map.put(:kind, conflict_kind(table, base))
    end
  end

  defp candidate_devices(%{direction: :pull}, _mutation, local), do: {"device_id = ?6", [local]}

  defp candidate_devices(base, mutation, _local) do
    excluded =
      [mutation["device_id"], base.sender] |> Enum.filter(&is_binary/1) |> Enum.uniq()

    placeholders = excluded |> Enum.with_index(6) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)
    {"device_id NOT IN (#{placeholders})", excluded}
  end

  defp base_detail(%{kind: :seq, seen: seen}), do: %{base_seq: seen, local_floor: nil}
  defp base_detail(%{kind: :floor, floor: floor}), do: %{base_seq: nil, local_floor: floor}
  defp base_detail(%{kind: :unknown}), do: %{base_seq: nil, local_floor: nil}

  defp conflict_kind(_table, %{kind: :unknown}), do: "unknown_base"
  defp conflict_kind("facts", _base), do: "fact_divergence"
  defp conflict_kind(_table, _base), do: "concurrent_edit"

  # A conflict's detail is a JSON object; a failure's is the reason as text.
  defp decode_detail(detail) when is_binary(detail) do
    case Jason.decode(detail) do
      {:ok, %{} = map} -> map
      _ -> detail
    end
  end

  defp decode_detail(detail), do: detail

  # Bookkeeping columns record when this Engine wrote a row, not what the row
  # says. Two Engines that derive the same row (a registry entry both create at
  # boot) differ only there, and that is not a conflict.
  @bookkeeping_columns ~w(created_at updated_at modified_at inserted_at recorded_at indexed_at
                          transaction_time_start transaction_time_end)

  defp unless_same_content(nil, _mutation), do: nil

  # A delete carries only the row's key, so it says nothing about the row's
  # content: it is the same change only as another delete, and a delete here is
  # the same only as an incoming delete.
  defp unless_same_content(%{operation: local_op} = conflict, %{"operation" => remote_op})
       when local_op == "delete" or remote_op == "delete" do
    if local_op == remote_op, do: nil, else: conflict
  end

  defp unless_same_content(%{payload: payload} = conflict, mutation) do
    local_row =
      case Jason.decode(payload || "") do
        {:ok, %{"row" => row}} when is_map(row) -> row
        _ -> %{}
      end

    remote_row = get_in(mutation, ["payload", "row"]) || %{}

    same? =
      remote_row != %{} and
        Enum.all?(remote_row, fn {name, value} ->
          name in @bookkeeping_columns or Map.get(local_row, name) == value
        end)

    if same?, do: nil, else: conflict
  end

  # A mutation id is unique in the ledger across tenants and workspaces, and a
  # sender chooses it. One already used by this workspace's change is a repeat
  # (skipped); one used by another workspace's or tenant's change is not this
  # workspace's repeat, and is refused instead of being taken as applied.
  defp id_state(tenant_id, workspace_id, id) when is_binary(id) do
    "SELECT tenant_id, workspace_id FROM sync_mutations WHERE id = ?1"
    |> Store.raw_query([id])
    |> classify_id(tenant_id, workspace_id)
  end

  defp txn_id_state(txn, tenant_id, workspace_id, id) do
    txn
    |> Store.txn_query("SELECT tenant_id, workspace_id FROM sync_mutations WHERE id = ?1", [id])
    |> classify_id(tenant_id, workspace_id)
  end

  defp classify_id({:ok, [[tenant, workspace] | _]}, tenant, workspace), do: :duplicate
  defp classify_id({:ok, [_ | _]}, _tenant, _workspace), do: :elsewhere
  defp classify_id(_result, _tenant, _workspace), do: :new

  # ---------------------------------------------------------------------------
  # Peers

  # A relay peer (`relay+https://host/api/v1/engines/<id>/sync`) is a MIOSA relay
  # in front of a managed Engine, which a laptop behind NAT can reach but a
  # managed Engine cannot dial back. The laptop is always the initiator: each
  # cycle it reads `<base>/status` (enabling sync with `<base>/enable` when the
  # status says it is off, and pausing when the other Engine runs another
  # migration or status does not say which), pulls from `<base>/pull`, and
  # pushes to `<base>/push`, each with `?workspace=`. Bodies are those of
  # `/api/sync/changes`; the relay wraps answers in `{"data": ...}` and refusals
  # in `{"error": {"code", "message"}}`. Nothing here opens a connection to
  # another Engine.
  defp relay_url(%{url: "relay+" <> base, workspace_id: workspace}, route),
    do: base <> "/" <> route <> "?" <> URI.encode_query(%{"workspace" => workspace})

  defp pull_url(%{url: "relay+" <> base}), do: base <> "/pull?"
  defp pull_url(%{url: url}), do: url <> "/api/sync/changes?"

  defp push_url(%{url: "relay+" <> _} = peer), do: relay_url(peer, "push")
  defp push_url(%{url: url}), do: url <> "/api/sync/changes"

  defp prepare(%{url: "relay+" <> _} = peer, key) do
    with {:ok, status} <- request(:get, relay_url(peer, "status"), nil, key, 15_000),
         :ok <- relay_compatible(status),
         :ok <- relay_enabled(peer, status, key) do
      remember_peer_replica(peer, status["replica_id"])
    end
  end

  defp prepare(peer, _key), do: {:ok, peer}

  # Status is the check before anything moves, so it fails closed: a status
  # without the other Engine's migration pauses the peer like a mismatch.
  defp relay_compatible(%{"migration" => migration} = status) when is_integer(migration),
    do: compatible(status)

  defp relay_compatible(_status), do: {:error, {:version_mismatch, @version_unreported}}

  defp relay_enabled(peer, %{"enabled" => false}, key) do
    with {:ok, _} <- request(:post, relay_url(peer, "enable"), %{}, key, 15_000), do: :ok
  end

  defp relay_enabled(_peer, _status, _key), do: :ok

  defp remember_peer_replica(peer, replica) when is_binary(replica) do
    case same_peer(peer, replica) do
      {:replaced, replica} -> replace_peer_replica(peer, replica, :replica_changed)
      :same_peer -> {:ok, store_peer_replica(peer, replica)}
    end
  end

  # A status that does not name the replica leaves the known one as it is; the
  # change pages must name it.
  defp remember_peer_replica(peer, _replica), do: {:ok, peer}

  defp store_peer_replica(peer, replica) do
    {:ok, _} =
      Store.raw_query(
        "UPDATE sync_peers SET peer_replica_id = COALESCE(?4, peer_replica_id) WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3",
        [peer.tenant_id, peer.workspace_id, peer.url, replica]
      )

    %{peer | peer_replica_id: replica}
  end

  # Pages are pulled from the cursor while the peer says there is `more`, up to
  # @cycle_pages a cycle and within the cycle's time budget; each page is
  # applied and its cursor kept before the next.
  defp pull(peer, key, deadline) do
    totals = %{applied: 0, skipped: %{}, failed: [], conflicts: 0, pages: 0}
    pull_pages(peer, key, peer.last_pulled_seq, totals, @cycle_pages, deadline)
  end

  defp pull_pages(peer, key, since, totals, pages_left, deadline) do
    url =
      pull_url(peer) <>
        URI.encode_query(%{"workspace" => peer.workspace_id, "since" => since, "limit" => @page})

    with {:ok, %{"mutations" => mutations, "cursor" => cursor, "engine" => engine} = page} <-
           request(:get, url, nil, key, 15_000),
         :ok <- compatible(engine),
         :ok <- replica_reported(engine),
         :same_peer <- same_peer(peer, engine["replica_id"]),
         :ok <- ledger_not_behind(page, since, engine["replica_id"]),
         {:ok, result} <-
           apply_changes(peer.tenant_id, peer.workspace_id, mutations,
             max_class: peer.max_class,
             local_floor: pull_floor(peer),
             direction: :pull
           ) do
      {:ok, _} =
        Store.raw_query(
          "UPDATE sync_peers SET last_pulled_seq = ?4, peer_replica_id = COALESCE(?5, peer_replica_id) WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3",
          [peer.tenant_id, peer.workspace_id, peer.url, cursor, engine["replica_id"]]
        )

      totals = %{
        totals
        | applied: totals.applied + result.applied,
          skipped: Map.merge(totals.skipped, result.skipped, fn _reason, a, b -> a + b end),
          failed: totals.failed ++ result.failed,
          conflicts: totals.conflicts + result.conflicts,
          pages: totals.pages + 1
      }

      more = page["more"] == true and cursor > since

      if more and pages_left > 1 and in_budget?(deadline),
        do: pull_pages(peer, key, cursor, totals, pages_left - 1, deadline),
        else: {:ok, Map.merge(totals, %{cursor: cursor, more: more})}
    else
      # The cursors counted another Engine's ledger: start over with this one,
      # once. A peer that goes on answering under another id is not followed.
      {:replaced, replica} ->
        reset_and_pull(peer, key, replica, :replica_changed, totals, pages_left, deadline)

      # The same Engine, restored from an older copy: its ledger ends before the
      # cursor, so nothing it holds is past the cursor and the page stays empty.
      {:behind, replica, head} ->
        why = {:ledger_behind, head, since}
        reset_and_pull(peer, key, replica, why, totals, pages_left, deadline)

      {:ok, body} ->
        {:error, {:not_a_change_page, Map.keys(body)}}

      {:error, _} = error ->
        error
    end
  end

  # No complete cycle yet (the floor is zero): there is no base to judge against,
  # and every change of this Engine's own counts as concurrent.
  defp pull_floor(%{pulled_local_seq: floor}) when is_integer(floor) and floor > 0, do: floor
  defp pull_floor(_peer), do: nil

  defp same_peer(%{peer_replica_id: known}, replica)
       when is_binary(known) and is_binary(replica) and known != replica,
       do: {:replaced, replica}

  defp same_peer(_peer, _replica), do: :same_peer

  # A page that does not say which replica it came from cannot be tied to the
  # cursors that were kept for one, and would switch the identity check off.
  defp replica_reported(%{"replica_id" => replica}) when is_binary(replica) and replica != "",
    do: :ok

  defp replica_reported(_engine), do: {:error, :peer_replica_unreported}

  # The page says how far the peer's ledger reaches (`head`). A ledger that ends
  # before this Engine's cursor is not the ledger the cursor counted.
  defp ledger_not_behind(%{"head" => head}, since, replica)
       when is_integer(head) and is_integer(since) and head < since,
       do: {:behind, replica, head}

  defp ledger_not_behind(_page, _since, _replica), do: :ok

  defp reset_and_pull(peer, key, replica, why, totals, pages_left, deadline) do
    case replace_peer_replica(peer, replica, why) do
      {:ok, peer} -> pull_pages(peer, key, 0, totals, pages_left, deadline)
      {:error, _} = error -> error
    end
  end

  # The peer answers with another replica id than the one its cursors were kept
  # for: the Engine behind the URL was replaced or restored under a new
  # identity, so its ledger sequences mean nothing to the cursors. Both cursors
  # (and the floor of the pull) go back to the start: everything is pulled and
  # pushed again, which the mutation ids make idempotent. The change is kept as
  # a resolved conflict.
  #
  # This happens at most once in a run, once in `@replace_window` seconds, and
  # twice in a day; a third change of identity in a day halts the peer
  # (`:peer_halted`, status `halted`) until an operator adds it again. A
  # peer that keeps changing its answer (a relay in front of two Engines, a
  # status that names another replica than the change pages) would otherwise
  # send every cycle back to the start, pulling and pushing the whole ledger
  # each time; it is reported as `:peer_identity_unstable` instead, and the
  # cursors stay where they are.
  defp replace_peer_replica(peer, replica, why) do
    cond do
      Map.get(peer, :replaced, false) ->
        identity_unstable(peer, replica, "again in the same run")

      resets_within(peer, @replace_window) >= 1 ->
        identity_unstable(peer, replica, "again within #{@replace_window} seconds")

      resets_within(peer, 86_400) >= @resets_a_day ->
        Logger.warning(
          "[Sync] peer #{LogUrl.render(peer.url)} answers as #{replica}, " <>
            "was #{peer.peer_replica_id}, after #{@resets_a_day} resets in a day; " <>
            "halted until it is added again"
        )

        {:error, :peer_halted}

      true ->
        {:ok, reset_peer_cursors(peer, replica, why)}
    end
  end

  defp identity_unstable(peer, replica, when_text) do
    Logger.warning(
      "[Sync] peer #{LogUrl.render(peer.url)} answers as #{replica}, " <>
        "was #{peer.peer_replica_id}, #{when_text}; cursors not reset again"
    )

    {:error, :peer_identity_unstable}
  end

  # The resets of this peer since it was last added (adding it again marks them
  # `operator`), within the last `seconds`.
  defp resets_within(peer, seconds) do
    case Store.raw_query(
           """
           SELECT COUNT(*) FROM sync_conflicts
           WHERE tenant_id = ?1 AND workspace_id = ?2 AND table_name = 'sync_peers' AND entity_key = ?3
             AND kind = 'peer_replaced' AND resolved_by = 'sync'
             AND created_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', ?4)
           """,
           [peer.tenant_id, peer.workspace_id, peer.url, "-#{seconds} seconds"]
         ) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  defp reset_peer_cursors(peer, replica, why) do
    Logger.warning(
      "[Sync] peer #{LogUrl.render(peer.url)} answers as #{replica}, " <>
        "was #{peer.peer_replica_id}; cursors reset"
    )

    detail =
      Map.merge(
        %{
          "previous_replica_id" => peer.peer_replica_id,
          "replica_id" => replica,
          "previous_pulled_seq" => peer.last_pulled_seq,
          "previous_pushed_seq" => peer.last_pushed_seq
        },
        reset_reason(why)
      )

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind, resolution,
                                    remote_device, state, detail, resolved_by, resolved_at)
        VALUES (?1, ?2, ?3, 'sync_peers', ?4, 'peer_replaced', 'cursors_reset', ?5, 'resolved', ?6, 'sync',
                strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        """,
        [
          "sc_" <> random_id(),
          peer.tenant_id,
          peer.workspace_id,
          peer.url,
          replica,
          Jason.encode!(detail)
        ]
      )

    {:ok, _} =
      Store.raw_query(
        """
        UPDATE sync_peers
        SET peer_replica_id = COALESCE(?4, peer_replica_id), last_pulled_seq = 0, last_pushed_seq = 0,
            pulled_local_seq = 0
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3
        """,
        [peer.tenant_id, peer.workspace_id, peer.url, replica]
      )

    peer
    |> Map.merge(%{last_pulled_seq: 0, last_pushed_seq: 0, pulled_local_seq: 0, replaced: true})
    |> Map.update!(:peer_replica_id, &(replica || &1))
  end

  defp reset_reason(:replica_changed), do: %{"reason" => "replica_changed"}

  defp reset_reason({:ledger_behind, head, cursor}),
    do: %{"reason" => "ledger_behind", "peer_head" => head, "cursor" => cursor}

  # Local changes are pushed a page at a time, up to @cycle_pages a cycle and
  # within the cycle's time budget. The push cursor moves to the last sequence
  # of a page only after the peer acknowledged it with its `applied` count (or
  # when every row of the page stays home, which sends nothing). A page the
  # peer finds too large (413) is sent again as pages half its size.
  defp push(peer, key, deadline) do
    {:ok, _} = Capture.seal()
    totals = %{sent: 0, gated: 0, superseded: 0, applied: 0, pages: 0, more: false}

    push_pages(peer, key, peer.last_pushed_seq, totals, @cycle_pages, @page, deadline)
  rescue
    # A gate that cannot read what it classifies by sends nothing.
    error in [RuntimeError, ArgumentError, Gate.StoreError] ->
      Logger.error(
        "[Sync] push to #{LogUrl.render(peer.url)} held back: #{Exception.message(error)}"
      )

      {:error, {:gate_unreadable, Exception.message(error)}}
  end

  # A gate is opened for each page, not for the cycle: a cycle can take a minute
  # and twenty pages, and what a gate learned of the workspace at its first page
  # (a row it loaded, the sources it indexed) must not outlive a write made
  # while that page was on its way. The scans of the workspace are shared
  # between the gates by `Sync.GateCache`, so a page costs a read of the stamp.
  defp push_pages(peer, key, since, totals, pages_left, page, deadline) do
    replicated = Enum.map_join(Capture.replicated_tables(), ", ", &"'#{&1}'")

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT sequence, id, device_id, entity_type, entity_id, operation, payload, payload_hash, idempotency_key, occurred_at
        FROM sync_mutations
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3 AND device_id != ?4
          AND entity_type IN (#{replicated})
        ORDER BY sequence LIMIT ?5
        """,
        [peer.tenant_id, peer.workspace_id, since, peer.peer_replica_id || "", page]
      )

    if rows == [] do
      {:ok, totals}
    else
      # Only rows that change capture or a sync apply wrote are sent; a storage
      # mutation entry shares the ledger and never leaves as a change.
      changes =
        rows
        |> Enum.map(&to_mutation/1)
        |> Enum.filter(&change_row?(&1["id"], &1["device_id"], &1["idempotency_key"]))

      # A change of this Engine's that a change from elsewhere came after (the
      # peer's, or one it forwarded) was overwritten here by it: the other
      # Engine already has the winner, so it is not sent. What is sent stands
      # after everything this Engine took from the peer, or won against it.
      lost = lost_sequences(peer, rows)

      {superseded, rest} = Enum.split_with(changes, &Map.has_key?(lost, &1["sequence"]))

      Enum.each(superseded, &record_superseded(peer, &1, Map.fetch!(lost, &1["sequence"])))

      mutations = releasable(rest, peer.tenant_id, peer.workspace_id, peer.max_class)

      case send_page(peer, key, mutations) do
        {:ok, remote} ->
          cursor = rows |> List.last() |> hd()

          {:ok, _} =
            Store.raw_query(
              "UPDATE sync_peers SET last_pushed_seq = ?4 WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3",
              [peer.tenant_id, peer.workspace_id, peer.url, cursor]
            )

          totals = %{
            totals
            | sent: totals.sent + length(mutations),
              gated: totals.gated + length(rest) - length(mutations),
              superseded: totals.superseded + length(superseded),
              applied: totals.applied + ((remote || %{})["applied"] || 0),
              pages: totals.pages + 1
          }

          totals = if remote, do: Map.put(totals, :remote, remote), else: totals
          totals = note_base_rejected(totals, remote)

          cond do
            length(rows) < page ->
              {:ok, totals}

            pages_left > 1 and in_budget?(deadline) ->
              push_pages(peer, key, cursor, totals, pages_left - 1, page, deadline)

            # A full page and no room for another: rows may be left for the next cycle.
            true ->
              {:ok, %{totals | more: true}}
          end

        {:error, {:http_status, 413, _body}} when length(rows) > 1 ->
          half = max(div(length(rows), 2), 1)
          push_pages(peer, key, since, totals, pages_left, half, deadline)

        {:error, _} = error ->
          error
      end
    end
  end

  # What the data-class gate lets leave this Engine: nothing from a workspace
  # classed above the peer, otherwise the rows not held by their own class or
  # the class of what they derive from.
  defp releasable([], _tenant_id, _workspace_id, _max_class), do: []

  defp releasable(mutations, tenant_id, workspace_id, max_class) do
    Gate.with_gate(tenant_id, workspace_id, max_class, &releasable(mutations, &1))
  end

  defp releasable(mutations, gate) do
    if Gate.workspace_above?(gate),
      do: [],
      else: Enum.reject(mutations, &Gate.hold?(gate, &1))
  end

  # The peer says in its reply when it did not trust the base this Engine sent.
  defp note_base_rejected(totals, %{"base_rejected" => why}) when is_binary(why),
    do: Map.put(totals, :base_rejected, why)

  defp note_base_rejected(totals, _remote), do: totals

  # The sequences, among this Engine's own changes in a page, that another
  # device's change to the same row came after in this ledger, each with the
  # device and sequence of the latest such change. An incoming change is in the
  # ledger only if it was applied, and it was applied over what was there, so the
  # later row is what the row holds.
  defp lost_sequences(peer, rows) do
    local = replica_id()

    sequences = for [sequence, _id, ^local | _] <- rows, do: sequence

    if sequences == [] do
      %{}
    else
      {:ok, lost} =
        Store.raw_query(
          """
          SELECT m.sequence, r.device_id, r.sequence
          FROM sync_mutations m
          JOIN sync_mutations r
            ON r.tenant_id = m.tenant_id AND r.workspace_id = m.workspace_id
           AND r.entity_type = m.entity_type AND r.entity_id = m.entity_id
           AND r.device_id != m.device_id AND r.sequence > m.sequence
          WHERE m.tenant_id = ?1 AND m.workspace_id = ?2 AND m.device_id = ?3
            AND m.sequence BETWEEN ?4 AND ?5
            AND #{change_row_sql("m")} AND #{change_row_sql("r")}
            AND r.sequence = (
              SELECT MAX(l.sequence) FROM sync_mutations l
              WHERE l.tenant_id = m.tenant_id AND l.workspace_id = m.workspace_id
                AND l.entity_type = m.entity_type AND l.entity_id = m.entity_id
                AND l.device_id != m.device_id AND #{change_row_sql("l")})
          """,
          [
            peer.tenant_id,
            peer.workspace_id,
            local,
            Enum.min(sequences),
            Enum.max(sequences)
          ]
        )

      Map.new(lost, fn [sequence, device, later] ->
        {sequence, %{device: device, sequence: later}}
      end)
    end
  end

  # A change not sent because the peer's came after it is kept as a resolved
  # record, so there is a row that says it lost (the ledger only has the two
  # changes). Its id comes from the scope and the mutation, so a repeat adds
  # nothing.
  defp record_superseded(peer, mutation, later) do
    id =
      "sc_" <>
        (:crypto.hash(
           :sha256,
           Enum.join([peer.tenant_id, peer.workspace_id, mutation["id"], "superseded"], "|")
         )
         |> binary_part(0, 10)
         |> Base.url_encode64(padding: false))

    detail = %{
      "mutation_id" => mutation["id"],
      "local_seq" => mutation["sequence"],
      "peer" => peer.url,
      "later_device" => later.device,
      "later_seq" => later.sequence
    }

    {:ok, _} =
      Store.raw_query(
        """
        INSERT OR IGNORE INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind,
                                              resolution, local_payload, remote_device, state, detail,
                                              resolved_by, resolved_at)
        VALUES (?1, ?2, ?3, ?4, ?5, 'superseded', 'not_sent_peer_has_newer', ?6, ?7, 'resolved', ?8, 'sync',
                strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        """,
        [
          id,
          peer.tenant_id,
          peer.workspace_id,
          mutation["entity_type"],
          mutation["entity_id"],
          Jason.encode!(mutation["payload"]),
          later.device,
          Jason.encode!(detail)
        ]
      )
  end

  # A page whose rows all stay home (the data-class gate) is not sent: an empty
  # batch is refused by a relay, and it would stop the cursor for good.
  defp send_page(_peer, _key, []), do: {:ok, nil}

  defp send_page(peer, key, mutations) do
    # base_seq: how much of the other Engine's ledger this one had pulled (a
    # sequence of that Engine's `sync_mutations`), and base_replica_id the
    # Engine it believed that ledger was, so the other side tells a concurrent
    # edit from one already seen and ignores a sequence from another ledger.
    body = %{
      "workspace" => peer.workspace_id,
      "replica_id" => replica_id(),
      "engine" => engine_info(),
      "base_seq" => peer.last_pulled_seq,
      "base_replica_id" => peer.peer_replica_id,
      "mutations" => mutations
    }

    # Only an answer that says what it applied acknowledges the page.
    case request(:post, push_url(peer), body, key, 30_000) do
      {:ok, %{"applied" => applied} = remote} when is_integer(applied) -> same_replied(peer, remote)
      {:ok, remote} -> {:error, {:push_not_acknowledged, Map.keys(remote)}}
      {:error, _} = error -> error
    end
  end

  # A reply that names the replica that applied the page must name the one the
  # cursors were kept for: otherwise the page went to another Engine, and the push
  # cursor must not move past it.
  defp same_replied(peer, remote) do
    case {get_in(remote, ["engine", "replica_id"]), peer.peer_replica_id} do
      {replied, known} when is_binary(replied) and is_binary(known) and replied != known ->
        {:error, :peer_identity_unstable}

      _ ->
        {:ok, remote}
    end
  end

  defp in_budget?(deadline), do: System.monotonic_time(:millisecond) < deadline

  # A peer Engine answers with the result itself; a relay wraps it in
  # {"data": ...} and reports a refusal as {"error": {"code", "message"}}, where
  # an Engine says {"error": "code", "message": ...}. Both are read here.
  defp request(method, url, body, key, timeout) do
    response =
      case method do
        :get -> HTTP.get_json(url, headers: headers(key), timeout: timeout)
        :post -> HTTP.post_json(url, body, headers: headers(key), timeout: timeout)
      end

    case response do
      {:ok, %{status: status, body: %{"data" => data}}} when status in 200..299 and is_map(data) ->
        {:ok, data}

      {:ok, %{status: status, body: data}} when status in 200..299 and is_map(data) ->
        {:ok, data}

      {:ok, %{status: status, body: body}} ->
        {:error, refusal(status, scrub(body, key))}

      {:error, _} = error ->
        error
    end
  end

  # A refusal is the other side's text. It is kept on the peer (`message`,
  # served by /api/sync/status) and returned by /api/sync/run, so the peer key
  # never stays in it, nor anything shaped like a key: a bearer token, a
  # prefixed key (msk_, oe_, sk_, pk_, rk_), or a long opaque token.
  @key_shaped ~r/Bearer\s+[^\s"',;}\[\]]+|\b(?:msk|oe|sk|pk|rk)_[A-Za-z0-9_\-]{6,}|\b(?=[A-Za-z0-9]*[0-9])(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{32,}\b/i

  defp scrub(text, key) when is_binary(text) do
    text =
      if is_binary(key) and byte_size(key) >= 8,
        do: String.replace(text, key, "[redacted]"),
        else: text

    Regex.replace(@key_shaped, text, "[redacted]")
  end

  defp scrub(map, key) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {name, value} -> {scrub(name, key), scrub(value, key)} end)

  defp scrub(list, key) when is_list(list), do: Enum.map(list, &scrub(&1, key))
  defp scrub(other, _key), do: other

  defp refusal(status, body) do
    {code, message} =
      case body do
        %{"error" => %{"code" => code} = error} when is_binary(code) -> {code, error["message"]}
        %{"error" => code} when is_binary(code) -> {code, body["message"]}
        _ -> {"", nil}
      end

    case String.downcase(code) do
      "version_mismatch" -> {:version_mismatch, message || @version_refused}
      _ -> {:http_status, status, body}
    end
  end

  defp to_mutation([seq, id, device, type, entity, op, payload, hash, key, at]) do
    %{
      "sequence" => seq,
      "id" => id,
      "device_id" => device,
      "entity_type" => type,
      "entity_id" => entity,
      "operation" => op,
      "payload" => decode(payload),
      "payload_hash" => hash,
      "idempotency_key" => key,
      "occurred_at" => at
    }
  end

  @doc false
  def compatible(%{"migration" => migration} = engine) do
    local = engine_info()["migration"]

    if migration == local,
      do: :ok,
      else:
        {:error,
         {:version_mismatch,
          "peer #{engine["replica_id"]} runs schema #{migration}, this Engine runs #{local}; sync pauses until both run the same Engine version"}}
  end

  def compatible(_engine),
    do: {:error, {:version_mismatch, "peer did not report its schema version"}}

  defp headers(key), do: [{"authorization", "Bearer " <> key}, {"x-optimal-replica", replica_id()}]

  defp store_peer(tenant_id, attrs, policy, max_class, by) do
    case Credential.encrypt(%{"api_key" => attrs["api_key"]}) do
      {:ok, envelope} ->
        {:ok, _} =
          Store.raw_query(
            """
            INSERT INTO sync_peers (tenant_id, workspace_id, url, credential, policy, max_class, last_pulled_seq)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(tenant_id, workspace_id, url) DO UPDATE SET
              credential = excluded.credential, policy = excluded.policy, max_class = excluded.max_class,
              status = 'active'
            """,
            [
              tenant_id,
              attrs["workspace_id"],
              String.trim_trailing(attrs["url"], "/"),
              envelope,
              policy,
              max_class,
              attrs["since"] || 0
            ]
          )

        # Adding a peer again is the operator's word that the Engine behind the URL
        # is settled: the resets before it no longer count against it.
        {:ok, _} =
          Store.raw_query(
            """
            UPDATE sync_conflicts SET resolved_by = 'operator'
            WHERE tenant_id = ?1 AND workspace_id = ?2 AND table_name = 'sync_peers' AND entity_key = ?3
              AND kind = 'peer_replaced' AND resolved_by = 'sync'
            """,
            [tenant_id, attrs["workspace_id"], String.trim_trailing(attrs["url"], "/")]
          )

        {:ok, _} = enable(tenant_id, attrs["workspace_id"], by)

        {:ok,
         %{
           workspace_id: attrs["workspace_id"],
           url: attrs["url"],
           policy: policy,
           max_class: max_class
         }}

      {:error, _} ->
        {:error, :connector_key_missing}
    end
  end

  defp reload_peer(peer) do
    case Store.raw_query(peer_sql() <> "WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3", [
           peer.tenant_id,
           peer.workspace_id,
           peer.url
         ]) do
      {:ok, [row]} -> to_peer(row)
      _ -> peer
    end
  end

  defp peer_key(%{credential: envelope}) do
    case Credential.decrypt(envelope) do
      {:ok, %{"api_key" => key}} -> {:ok, key}
      _ -> {:error, :peer_credential_unreadable}
    end
  end

  # A cycle is complete when the pull reached the end of the peer's ledger and
  # the push sent everything there was (or the policy leaves that direction out).
  # Only then do `last_sync_at` (when the cycle began) and `pulled_local_seq` (the
  # local ledger head at that moment) move. The head is the floor the next pull
  # judges this Engine's own changes against: what is at or below it was pushed
  # in a complete cycle and counts as seen by the peer; what came after it is
  # concurrent. After a cycle that stopped short, with pages still to come on
  # either side, the floor stays where it was, so nothing that may not have
  # reached the peer is taken as seen.
  defp cycle_synced(peer, pulled, pushed, started, head) do
    cond do
      not (pull_complete?(pulled) and push_complete?(pushed)) -> nil
      # A peer this Engine only pulls from never receives its changes, so none of
      # them counts as seen: the floor stays at zero and the clock decides each.
      peer.policy == "pull" -> {started, nil}
      true -> {started, head}
    end
  end

  defp update_peer_status(peer, {status, message}, synced \\ nil) do
    {at, floor} = synced || {nil, nil}

    {:ok, _} =
      Store.raw_query(
        """
        UPDATE sync_peers SET status = ?4, message = ?5,
          last_sync_at = CASE WHEN ?4 = 'active' AND ?6 IS NOT NULL THEN ?6 ELSE last_sync_at END,
          pulled_local_seq = CASE WHEN ?4 = 'active' AND ?7 IS NOT NULL THEN ?7 ELSE pulled_local_seq END
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3
        """,
        [peer.tenant_id, peer.workspace_id, peer.url, status, message, at, floor]
      )
  end

  # The format SQLite's strftime('%Y-%m-%dT%H:%M:%f', 'now') gives a change's
  # `occurred_at`, so the two compare as text.
  defp utc_now_iso do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:millisecond) |> NaiveDateTime.to_iso8601()
  end

  defp pull_complete?({:ok, %{more: more}}), do: more != true
  defp pull_complete?({:ok, %{skipped: :policy}}), do: true
  defp pull_complete?(_pulled), do: false

  defp push_complete?({:ok, %{more: more}}), do: more != true
  defp push_complete?({:ok, %{skipped: skipped}}) when skipped in [:policy], do: true
  defp push_complete?(_pushed), do: false

  defp pending_push(tenant_id, workspace_id, peer, _local) do
    replicated = Enum.map_join(Capture.replicated_tables(), ", ", &"'#{&1}'")

    case Store.raw_query(
           """
           SELECT COUNT(*) FROM sync_mutations m
           WHERE m.tenant_id = ?1 AND m.workspace_id = ?2 AND m.sequence > ?3 AND m.device_id != ?4
             AND m.entity_type IN (#{replicated}) AND #{change_row_sql("m")}
             AND NOT (m.device_id = ?5 AND EXISTS (
               SELECT 1 FROM sync_mutations r
               WHERE r.tenant_id = m.tenant_id AND r.workspace_id = m.workspace_id
                 AND r.entity_type = m.entity_type AND r.entity_id = m.entity_id
                 AND r.device_id != m.device_id AND r.sequence > m.sequence
                 AND #{change_row_sql("r")}))
           """,
           [tenant_id, workspace_id, peer.last_pushed_seq, peer.peer_replica_id || "", replica_id()]
         ) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  defp workspace_sequence(tenant_id, workspace_id) do
    case Store.raw_query(
           "SELECT COALESCE(MAX(sequence), 0) FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2",
           [tenant_id, workspace_id]
         ) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  defp peer_sql do
    """
    SELECT tenant_id, workspace_id, url, credential, policy, max_class, peer_replica_id, last_pulled_seq,
           last_pushed_seq, pulled_local_seq, last_sync_at, status, message
    FROM sync_peers
    """
  end

  defp to_peer([
         tenant,
         workspace,
         url,
         credential,
         policy,
         max_class,
         peer_replica,
         pulled,
         pushed,
         floor,
         at,
         status,
         message
       ]) do
    %{
      tenant_id: tenant,
      workspace_id: workspace,
      url: url,
      credential: credential,
      policy: policy,
      max_class: max_class,
      peer_replica_id: peer_replica,
      last_pulled_seq: pulled,
      last_pushed_seq: pushed,
      pulled_local_seq: floor,
      last_sync_at: at,
      status: status,
      message: message
    }
  end

  defp columns_sql(names), do: Enum.map_join(names, ", ", &quote_name/1)

  defp placeholders(names),
    do: names |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

  defp quote_name(name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
      do: ~s("#{name}"),
      else: raise(ArgumentError, "unsafe identifier #{inspect(name)}")
  end

  defp decode(nil), do: nil
  defp decode(json) when is_binary(json), do: Jason.decode!(json)
  defp decode(other), do: other

  defp random_id, do: :crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false)
end
