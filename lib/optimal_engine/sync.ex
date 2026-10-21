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
  * Conflicts: when both sides changed the same row since the last sync,
    the newer change wins and the conflict is recorded; for facts, both
    versions also become claims in the review queue. Nothing is dropped
    silently: refused, gated, and failed changes are counted and failures
    are recorded.
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

  alias OptimalEngine.Connectors.{Credential, HTTP}
  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Migrations
  alias OptimalEngine.Sync.{Capture, Gate, GateCache, Lineage}

  @classes ~w(public internal confidential restricted)
  @page 500
  @cycle_pages 20
  @cycle_budget 60_000
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
      "migration" => OptimalEngine.Store.Migrations.all() |> List.last() |> elem(0)
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
        [_seq, _id, device, type | _] = row <- rows,
        device != requester,
        Capture.replicated?(type),
        do: to_mutation(row)
      )
      |> releasable(tenant_id, workspace_id, max_class)

    %{
      "workspace_id" => workspace_id,
      "mutations" => mutations,
      "cursor" => cursor,
      "more" => length(rows) == limit,
      "engine" => engine_info()
    }
  end

  @doc """
  Applies a batch of mutations to `workspace_id`. Options: `:max_class`
  (data-class gate, default `confidential`), `:since` (ISO time of the last
  sync with this peer, for conflict detection). Returns counts and conflicts.
  """
  @spec apply_changes(String.t(), String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def apply_changes(tenant_id, workspace_id, mutations, opts \\ []) do
    {:ok, _} = Capture.seal()
    local = replica_id()
    max_class = Keyword.get(opts, :max_class, "confidential")
    last_sync = opts[:since] || "1970-01-01T00:00:00"

    if Gate.workspace_rank(workspace_id) > Gate.class_rank(max_class) do
      {:error, :workspace_class_above_gate}
    else
      columns = batch_columns(mutations)

      plans =
        Enum.map(
          mutations,
          &plan(&1, tenant_id, workspace_id, local, max_class, last_sync, columns)
        )

      execute(tenant_id, workspace_id, plans)
    end
  end

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
  `purge_unreplicated/0`, once for each version of the replicated list: the
  list's version is kept in the database file (`PRAGMA user_version`), so a later
  boot does not scan the whole ledger again, and a change to the list (a table
  demoted from it drops its unsent ledger rows) runs the purge once more.
  """
  @spec purge_unreplicated_once() :: {:ok, %{String.t() => non_neg_integer()}}
  def purge_unreplicated_once do
    version = list_version()

    case Store.raw_query("PRAGMA user_version", []) do
      {:ok, [[^version]]} ->
        {:ok, %{}}

      _ ->
        with {:ok, purged} <- purge_unreplicated() do
          {:ok, _} = Store.raw_query("PRAGMA user_version = #{version}", [])
          {:ok, purged}
        end
    end
  end

  # A positive 31-bit number that changes with the replicated list.
  defp list_version, do: :erlang.phash2(Capture.replicated_tables(), 2_000_000_000) + 1

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
      Store.raw_query(peer_sql() <> "WHERE status != 'disabled' AND policy != 'none'", [])

    Enum.map(rows, fn row ->
      peer = to_peer(row)

      try do
        run_peer(peer)
      rescue
        # One peer's failure does not stop the others.
        error ->
          Logger.error("[Sync] cycle for #{peer.url} failed: #{Exception.message(error)}")
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
    budget = Application.get_env(:optimal_engine, :sync_cycle_budget_ms, @cycle_budget)
    deadline = System.monotonic_time(:millisecond) + budget

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
          peer.policy in ["push", "both"] -> push(peer, key, deadline)
          true -> {:ok, %{skipped: :policy}}
        end

      status =
        case {pulled, pushed} do
          {{:error, {:version_mismatch, message}}, _} -> {"paused_version", message}
          {_, {:error, {:version_mismatch, message}}} -> {"paused_version", message}
          {{:error, reason}, _} -> {"error", inspect(reason)}
          {_, {:error, reason}} -> {"error", inspect(reason)}
          _ -> {"active", nil}
        end

      update_peer_status(peer, status)

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

      {:error, reason} ->
        update_peer_status(peer, {"error", inspect(reason)})
        %{workspace_id: peer.workspace_id, url: peer.url, status: "error", reason: reason}
    end
  end

  @doc "Replication state for a workspace: lag, last sync, pending, conflicts."
  @spec status(String.t(), String.t()) :: map()
  def status(tenant_id, workspace_id) do
    {:ok, _} = Capture.seal()

    {:ok, [[open_conflicts]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM sync_conflicts WHERE tenant_id = ?1 AND workspace_id = ?2 AND state = 'open'",
        [tenant_id, workspace_id]
      )

    local_seq = workspace_sequence(tenant_id, workspace_id)
    local = replica_id()

    %{
      workspace_id: workspace_id,
      enabled: enabled?(workspace_id),
      replica_id: local,
      ledger_sequence: local_seq,
      open_conflicts: open_conflicts,
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
        detail: detail,
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

  defp plan(mutation, _tenant_id, _workspace_id, _local, _gate, _last_sync, _columns)
       when not is_map(mutation),
       do: {:skip, :invalid, %{}}

  defp plan(mutation, tenant_id, workspace_id, local, gate, last_sync, columns) do
    table = mutation["entity_type"]
    invalid = invalid_reason(mutation)

    cond do
      mutation["device_id"] == local ->
        {:skip, :own, mutation}

      invalid ->
        {:fail, invalid, mutation}

      known?(mutation["id"]) ->
        {:skip, :duplicate, mutation}

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
          last_sync,
          Map.get(columns, table, [])
        )
    end
  end

  defp plan_row(mutation, tenant_id, workspace_id, local, gate, last_sync, columns) do
    table = target_table(mutation["entity_type"])
    append_only = Capture.rowid_key?(columns)
    payload = mutation["payload"]
    names = Map.keys(payload["row"]) ++ Map.keys(payload["blobs"] || %{})

    with :ok <- known_columns(columns, names),
         :ok <- supported_operation(append_only, mutation["operation"]),
         :ok <- known_signal_values(table, mutation),
         {:ok, mutation} <- confine_paths(table, mutation) do
      # An append-only row is named by its capture sequence on the Engine that
      # wrote it, so a local row with the same name is a different row: it is
      # always added, never a conflict.
      conflict =
        if append_only do
          nil
        else
          tenant_id
          |> local_conflict(workspace_id, table, mutation["entity_id"], local, last_sync)
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

  defp drop_path(mutation, column) do
    mutation
    |> put_in(["payload", "row", column], nil)
    |> Map.delete("payload_hash")
  end

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
    result =
      Store.transaction(fn txn ->
        {:ok, _} = Store.txn_execute(txn, "UPDATE sync_identity SET applying = 1 WHERE id = 1", [])

        if foreign_keys == :deferred,
          do: {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])

        outcome =
          Enum.reduce(
            plans,
            %{applied: 0, skipped: %{}, failed: [], conflicts: [], fact_conflicts: [], retry: []},
            fn
              {:skip, reason, _mutation}, acc ->
                update_in(acc, [:skipped, reason], &((&1 || 0) + 1))

              {:fail, reason, mutation}, acc ->
                record_failure(txn, tenant_id, workspace_id, mutation, reason)
                %{acc | failed: [%{id: mutation["id"], reason: reason} | acc.failed]}

              # Planned outside this transaction, so a concurrent apply of the
              # same change (`POST /api/sync/run` during a scheduler tick) may
              # have committed it since; an append-only row would be added twice.
              {:apply, step}, acc ->
                if txn_known?(txn, step.mutation["id"]),
                  do: update_in(acc, [:skipped, :duplicate], &((&1 || 0) + 1)),
                  else: apply_step(txn, tenant_id, workspace_id, step, acc, foreign_keys)
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
        Enum.each(outcome.fact_conflicts, &raise_fact_claims(tenant_id, workspace_id, &1))

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

  defp apply_step(
         txn,
         tenant_id,
         workspace_id,
         %{mutation: mutation, columns: columns, conflict: conflict, gate: gate} = step,
         acc,
         foreign_keys
       ) do
    table = target_table(mutation["entity_type"])
    remote_at = mutation["occurred_at"]

    case conflict do
      %{occurred_at: local_at} = local when local_at > remote_at ->
        record_conflict(txn, tenant_id, workspace_id, mutation, local, "kept_local_newer")
        record_ledger(txn, tenant_id, workspace_id, mutation)
        acc = %{acc | conflicts: [mutation["id"] | acc.conflicts]}

        if table == "facts",
          do: %{acc | fact_conflicts: [{local, mutation} | acc.fact_conflicts]},
          else: acc

      _ ->
        savepoint = "sync_" <> Integer.to_string(System.unique_integer([:positive]))
        {:ok, _} = Store.txn_execute(txn, "SAVEPOINT #{savepoint}", [])

        case write(txn, table, columns, mutation, workspace_id, tenant_id, gate) do
          :ok ->
            {:ok, _} = Store.txn_execute(txn, "RELEASE #{savepoint}", [])
            record_ledger(txn, tenant_id, workspace_id, mutation)

            acc = %{acc | applied: acc.applied + 1}

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
                update_in(acc, [:skipped, :gated], &((&1 || 0) + 1))

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
          mutation["payload_hash"] || :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower),
          mutation["idempotency_key"] || mutation["id"],
          mutation["occurred_at"]
        ]
      )
  end

  defp record_conflict(txn, tenant_id, workspace_id, mutation, local, resolution) do
    {:ok, _} =
      Store.txn_execute(
        txn,
        """
        INSERT INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind, resolution,
                                    local_payload, remote_payload, remote_device)
        VALUES (?1, ?2, ?3, ?4, ?5, 'concurrent_change', ?6, ?7, ?8, ?9)
        """,
        [
          "sc_" <> random_id(),
          tenant_id,
          workspace_id,
          mutation["entity_type"],
          mutation["entity_id"],
          resolution,
          local.payload,
          Jason.encode!(mutation["payload"]),
          mutation["device_id"]
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

  defp local_conflict(tenant_id, workspace_id, table, entity_id, local, last_sync) do
    case Store.raw_query(
           """
           SELECT occurred_at, payload FROM sync_mutations
           WHERE tenant_id = ?1 AND workspace_id = ?2 AND entity_type = ?3 AND entity_id = ?4
             AND device_id = ?5 AND occurred_at > ?6
           ORDER BY sequence DESC LIMIT 1
           """,
           [tenant_id, workspace_id, table, entity_id, local, last_sync]
         ) do
      {:ok, [[at, payload]]} -> %{occurred_at: at, payload: payload}
      _ -> nil
    end
  end

  # Bookkeeping columns record when this Engine wrote a row, not what the row
  # says. Two Engines that derive the same row (a registry entry both create at
  # boot) differ only there, and that is not a conflict.
  @bookkeeping_columns ~w(created_at updated_at modified_at inserted_at recorded_at indexed_at
                          transaction_time_start transaction_time_end)

  defp unless_same_content(nil, _mutation), do: nil

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

  defp known?(id) when is_binary(id) do
    match?({:ok, [_]}, Store.raw_query("SELECT 1 FROM sync_mutations WHERE id = ?1", [id]))
  end

  defp known?(_id), do: true

  defp txn_known?(txn, id) do
    sql = "SELECT 1 FROM sync_mutations WHERE id = ?1"
    match?({:ok, [_ | _]}, Store.txn_query(txn, sql, [id]))
  end

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
      {:ok, remember_peer_replica(peer, status["replica_id"])}
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
    {:ok, _} =
      Store.raw_query(
        "UPDATE sync_peers SET peer_replica_id = ?4 WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3",
        [peer.tenant_id, peer.workspace_id, peer.url, replica]
      )

    %{peer | peer_replica_id: replica}
  end

  defp remember_peer_replica(peer, _replica), do: peer

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
         {:ok, result} <-
           apply_changes(peer.tenant_id, peer.workspace_id, mutations,
             max_class: peer.max_class,
             since: peer.last_sync_at
           ) do
      {:ok, _} =
        Store.raw_query(
          "UPDATE sync_peers SET last_pulled_seq = ?4, peer_replica_id = ?5 WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3",
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
      {:ok, body} -> {:error, {:not_a_change_page, Map.keys(body)}}
      {:error, _} = error -> error
    end
  end

  # Local changes are pushed a page at a time, up to @cycle_pages a cycle and
  # within the cycle's time budget. The push cursor moves to the last sequence
  # of a page only after the peer acknowledged it with its `applied` count (or
  # when every row of the page stays home, which sends nothing). A page the
  # peer finds too large (413) is sent again as pages half its size.
  defp push(peer, key, deadline) do
    {:ok, _} = Capture.seal()
    totals = %{sent: 0, gated: 0, applied: 0, pages: 0}

    Gate.with_gate(peer.tenant_id, peer.workspace_id, peer.max_class, fn gate ->
      push_pages(peer, key, gate, peer.last_pushed_seq, totals, @cycle_pages, @page, deadline)
    end)
  rescue
    # A gate that cannot read what it classifies by sends nothing.
    error in [RuntimeError, ArgumentError, Gate.StoreError] ->
      Logger.error("[Sync] push to #{peer.url} held back: #{Exception.message(error)}")
      {:error, {:gate_unreadable, Exception.message(error)}}
  end

  defp push_pages(peer, key, gate, since, totals, pages_left, page, deadline) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT sequence, id, device_id, entity_type, entity_id, operation, payload, payload_hash, idempotency_key, occurred_at
        FROM sync_mutations
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3 AND device_id != ?4
        ORDER BY sequence LIMIT ?5
        """,
        [peer.tenant_id, peer.workspace_id, since, peer.peer_replica_id || "", page]
      )

    if rows == [] do
      {:ok, totals}
    else
      mutations =
        rows
        |> Enum.map(&to_mutation/1)
        |> Enum.filter(&Capture.replicated?(&1["entity_type"]))
        |> releasable(gate)

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
              gated: totals.gated + length(rows) - length(mutations),
              applied: totals.applied + ((remote || %{})["applied"] || 0),
              pages: totals.pages + 1
          }

          totals = if remote, do: Map.put(totals, :remote, remote), else: totals

          if length(rows) == page and pages_left > 1 and in_budget?(deadline),
            do: push_pages(peer, key, gate, cursor, totals, pages_left - 1, page, deadline),
            else: {:ok, totals}

        {:error, {:http_status, 413, _body}} when length(rows) > 1 ->
          half = max(div(length(rows), 2), 1)
          push_pages(peer, key, gate, since, totals, pages_left, half, deadline)

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

  # A page whose rows all stay home (the data-class gate) is not sent: an empty
  # batch is refused by a relay, and it would stop the cursor for good.
  defp send_page(_peer, _key, []), do: {:ok, nil}

  defp send_page(peer, key, mutations) do
    body = %{
      "workspace" => peer.workspace_id,
      "replica_id" => replica_id(),
      "engine" => engine_info(),
      "mutations" => mutations
    }

    # Only an answer that says what it applied acknowledges the page.
    case request(:post, push_url(peer), body, key, 30_000) do
      {:ok, %{"applied" => applied} = remote} when is_integer(applied) -> {:ok, remote}
      {:ok, remote} -> {:error, {:push_not_acknowledged, Map.keys(remote)}}
      {:error, _} = error -> error
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

  defp update_peer_status(peer, {status, message}) do
    {:ok, _} =
      Store.raw_query(
        """
        UPDATE sync_peers SET status = ?4, message = ?5,
          last_sync_at = CASE WHEN ?4 = 'active' THEN strftime('%Y-%m-%dT%H:%M:%f', 'now') ELSE last_sync_at END
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3
        """,
        [peer.tenant_id, peer.workspace_id, peer.url, status, message]
      )
  end

  defp pending_push(tenant_id, workspace_id, peer, _local) do
    replicated = Enum.map_join(Capture.replicated_tables(), ", ", &"'#{&1}'")

    case Store.raw_query(
           """
           SELECT COUNT(*) FROM sync_mutations
           WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3 AND device_id != ?4
             AND entity_type IN (#{replicated})
           """,
           [tenant_id, workspace_id, peer.last_pushed_seq, peer.peer_replica_id || ""]
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
           last_pushed_seq, last_sync_at, status, message
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
