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
    `none`) and a data-class gate on both send and receive.
  * Conflicts: when both sides changed the same row since the last sync,
    the newer change wins and the conflict is recorded; for facts, both
    versions also become claims in the review queue. Nothing is dropped
    silently: refused, gated, and failed changes are counted and failures
    are recorded.
  * Version safety: a peer with a different schema migration pauses with a
    clear message until both run the same version.
  * Seeding: a new replica imports a workspace bundle exported after sync
    was enabled, then pulls from the bundle's `ledger_sequence`.
  """

  require Logger

  alias OptimalEngine.Connectors.{Credential, HTTP}
  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Capture

  @classes ~w(public internal confidential restricted)
  @page 500

  # -- identity and enablement -------------------------------------------------

  @doc "This Engine's replica id."
  @spec replica_id() :: String.t()
  def replica_id do
    {:ok, [[id]]} = Store.raw_query("SELECT replica_id FROM sync_identity WHERE id = 1", [])
    id
  end

  @doc "Enables capture for a workspace (idempotent) and installs triggers."
  @spec enable(String.t(), String.t(), String.t()) :: {:ok, map()}
  def enable(tenant_id, workspace_id, by) do
    {:ok, _} =
      Store.raw_query(
        "INSERT OR IGNORE INTO sync_workspaces (tenant_id, workspace_id, enabled_by) VALUES (?1, ?2, ?3)",
        [tenant_id, workspace_id, by]
      )

    {:ok, triggers} = Capture.install()

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
  that originated on `requester` (so nothing echoes back). Returns the page,
  the cursor to continue from, and engine info.
  """
  @spec changes(String.t(), String.t(), keyword()) :: map()
  def changes(tenant_id, workspace_id, opts \\ []) do
    {:ok, _} = Capture.seal()
    since = Keyword.get(opts, :since, 0)
    limit = opts |> Keyword.get(:limit, @page) |> max(1) |> min(2_000)
    requester = opts[:requester] || ""

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
      for [seq, id, device, type, entity, op, payload, hash, key, at] <- rows,
          device != requester do
        %{
          "sequence" => seq,
          "id" => id,
          "device_id" => device,
          "entity_type" => type,
          "entity_id" => entity,
          "operation" => op,
          "payload" => payload && Jason.decode!(payload),
          "payload_hash" => hash,
          "idempotency_key" => key,
          "occurred_at" => at
        }
      end

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
    gate = Keyword.get(opts, :max_class, "confidential")
    last_sync = opts[:since] || "1970-01-01T00:00:00"

    if workspace_class(workspace_id) |> above?(gate) do
      {:error, :workspace_class_above_gate}
    else
      plans = Enum.map(mutations, &plan(&1, tenant_id, workspace_id, local, gate, last_sync))
      execute(tenant_id, workspace_id, plans)
    end
  end

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

    Enum.map(rows, &(&1 |> to_peer() |> run_peer()))
  end

  @doc "Pulls from and pushes to one peer, honoring its policy."
  @spec run_peer(map()) :: map()
  def run_peer(peer) do
    with {:ok, key} <- peer_key(peer) do
      pulled =
        if peer.policy in ["pull", "both"], do: pull(peer, key), else: {:ok, %{skipped: :policy}}

      # Reload: a pull learns the peer's replica id, which push must not echo to.
      peer = reload_peer(peer)

      pushed =
        if peer.policy in ["push", "both"], do: push(peer, key), else: {:ok, %{skipped: :policy}}

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

  defp plan(mutation, tenant_id, workspace_id, local, gate, last_sync) do
    cond do
      mutation["device_id"] == local ->
        {:skip, :own, mutation}

      known?(mutation["id"]) ->
        {:skip, :duplicate, mutation}

      restricted_row?(mutation, gate) ->
        {:skip, :gated, mutation}

      true ->
        table = mutation["entity_type"]
        columns = Capture.columns(table)

        cond do
          columns == [] ->
            {:fail, :unknown_table, mutation}

          not Enum.all?(Map.keys(get_in(mutation, ["payload", "row"]) || %{}), fn name ->
            Enum.any?(columns, &(&1.name == name))
          end) ->
            {:fail, :unknown_columns, mutation}

          true ->
            conflict =
              local_conflict(
                tenant_id,
                workspace_id,
                table,
                mutation["entity_id"],
                local,
                last_sync
              )

            {:apply, %{mutation: mutation, columns: columns, conflict: conflict}}
        end
    end
  end

  defp execute(tenant_id, workspace_id, plans) do
    result =
      Store.transaction(fn txn ->
        {:ok, _} = Store.txn_execute(txn, "UPDATE sync_identity SET applying = 1 WHERE id = 1", [])
        {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])

        outcome =
          Enum.reduce(
            plans,
            %{applied: 0, skipped: %{}, failed: [], conflicts: [], fact_conflicts: []},
            fn
              {:skip, reason, _mutation}, acc ->
                update_in(acc, [:skipped, reason], &((&1 || 0) + 1))

              {:fail, reason, mutation}, acc ->
                record_failure(txn, tenant_id, workspace_id, mutation, reason)
                %{acc | failed: [%{id: mutation["id"], reason: reason} | acc.failed]}

              {:apply, step}, acc ->
                apply_step(txn, tenant_id, workspace_id, step, acc)
            end
          )

        {:ok, _} = Store.txn_execute(txn, "UPDATE sync_identity SET applying = 0 WHERE id = 1", [])
        {:ok, outcome}
      end)

    case result do
      {:ok, outcome} ->
        Enum.each(outcome.fact_conflicts, &raise_fact_claims(tenant_id, workspace_id, &1))

        {:ok,
         %{
           applied: outcome.applied,
           skipped: outcome.skipped,
           failed: Enum.reverse(outcome.failed),
           conflicts: length(outcome.conflicts)
         }}

      error ->
        error
    end
  end

  defp apply_step(
         txn,
         tenant_id,
         workspace_id,
         %{mutation: mutation, columns: columns, conflict: conflict},
         acc
       ) do
    table = mutation["entity_type"]
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

        case write(txn, table, columns, mutation, workspace_id, tenant_id) do
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
            record_failure(txn, tenant_id, workspace_id, mutation, reason)
            %{acc | failed: [%{id: mutation["id"], reason: inspect(reason)} | acc.failed]}
        end
    end
  end

  defp write(txn, table, columns, mutation, workspace_id, tenant_id) do
    payload = mutation["payload"] || %{}
    blobs = payload["blobs"] || %{}

    row =
      (payload["row"] || %{})
      |> Map.merge(
        Map.new(blobs, fn {name, hex} -> {name, {:blob, Base.decode16!(hex, case: :mixed)}} end)
      )
      |> then(fn r ->
        if Map.has_key?(r, "workspace_id"), do: Map.put(r, "workspace_id", workspace_id), else: r
      end)
      |> then(fn r ->
        if Map.has_key?(r, "tenant_id"), do: Map.put(r, "tenant_id", tenant_id), else: r
      end)

    keys = Capture.key_columns(columns)
    append_only = Capture.rowid_key?(columns)
    t = quote_name(table)

    {sql, params} =
      case {mutation["operation"], append_only} do
        {"delete", _} ->
          where =
            keys
            |> Enum.with_index(1)
            |> Enum.map_join(" AND ", fn {k, i} -> "#{quote_name(k)} = ?#{i}" end)

          {"DELETE FROM #{t} WHERE #{where}", Enum.map(keys, &row[&1])}

        {_, append_only} when append_only or keys == [] ->
          row = Map.drop(row, if(append_only, do: keys, else: []))
          names = Map.keys(row)

          {"INSERT OR IGNORE INTO #{t} (#{columns_sql(names)}) VALUES (#{placeholders(names)})",
           Enum.map(names, &row[&1])}

        {_, false} ->
          names = Map.keys(row)

          updates =
            names
            |> Enum.reject(&(&1 in keys))
            |> Enum.map_join(", ", &"#{quote_name(&1)} = excluded.#{quote_name(&1)}")

          conflict = if updates == "", do: "DO NOTHING", else: "DO UPDATE SET #{updates}"

          {"INSERT INTO #{t} (#{columns_sql(names)}) VALUES (#{placeholders(names)}) ON CONFLICT (#{columns_sql(keys)}) #{conflict}",
           Enum.map(names, &row[&1])}
      end

    case Store.txn_execute(txn, sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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
          mutation["entity_type"] || "unknown",
          mutation["entity_id"],
          Jason.encode!(mutation["payload"]),
          mutation["device_id"],
          inspect(reason)
        ]
      )
  end

  # Both versions of a contested fact go to the review queue as claims.
  defp raise_fact_claims(tenant_id, workspace_id, {local, mutation}) do
    alias OptimalEngine.MemoryCore.SourcePackage
    alias OptimalEngine.MemoryCore.Store, as: CoreStore

    local_text = get_in(decode(local.payload), ["row", "fact_text"])
    remote_text = get_in(mutation, ["payload", "row", "fact_text"])

    texts =
      Enum.reject([{"local", local_text}, {"remote", remote_text}], fn {_, text} -> is_nil(text) end)

    if texts != [] do
      raw = Enum.map_join(texts, "\n", fn {side, text} -> "#{side}: #{text}" end)

      source =
        SourcePackage.from_text("Replication conflict on fact #{mutation["entity_id"]}\n" <> raw,
          tenant_id: tenant_id,
          workspace_id: workspace_id,
          source_type: "sync_conflict",
          source_system: "optimal-sync"
        )

      _ = CoreStore.insert_source_package(source)

      Enum.each(texts, fn {side, text} ->
        CoreStore.insert_claim(%{
          id: "clm_sync_" <> random_id(),
          tenant_id: tenant_id,
          workspace_id: workspace_id,
          source_package_id: source.id,
          claim_text: text,
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

  defp known?(id) when is_binary(id) do
    match?({:ok, [_]}, Store.raw_query("SELECT 1 FROM sync_mutations WHERE id = ?1", [id]))
  end

  defp known?(_id), do: true

  defp restricted_row?(mutation, gate) do
    labels = get_in(mutation, ["payload", "row", "security_labels"])

    labels =
      case labels do
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        list when is_list(list) ->
          list

        _ ->
          []
      end

    Enum.any?(labels, &(to_string(&1) in @classes and above?(to_string(&1), gate)))
  end

  defp above?(class, gate), do: rank(class) > rank(gate)
  defp rank(class), do: Enum.find_index(@classes, &(&1 == class)) || 1

  defp workspace_class(workspace_id) do
    case OptimalEngine.Workspace.get(workspace_id) do
      {:ok, %{metadata: %{"data_class" => class}}} when class in @classes -> class
      _ -> "internal"
    end
  end

  # ---------------------------------------------------------------------------
  # Peers

  # A relay peer (`relay+https://host/api/v1/engines/<id>/sync`) is a MIOSA relay
  # in front of a managed Engine, which a laptop behind NAT can reach but a
  # managed Engine cannot dial back. The laptop is always the initiator: it pulls
  # from `<base>/pull` and pushes to `<base>/push`, with the same bodies as
  # `/api/sync/changes`. Nothing here opens a connection to another Engine.
  defp pull_url(%{url: "relay+" <> base}), do: base <> "/pull?"
  defp pull_url(%{url: url}), do: url <> "/api/sync/changes?"

  defp push_url(%{url: "relay+" <> base}), do: base <> "/push"
  defp push_url(%{url: url}), do: url <> "/api/sync/changes"

  defp pull(peer, key) do
    url =
      pull_url(peer) <>
        URI.encode_query(%{
          "workspace" => peer.workspace_id,
          "since" => peer.last_pulled_seq,
          "limit" => @page
        })

    with {:ok,
          %{status: 200, body: %{"mutations" => mutations, "cursor" => cursor, "engine" => engine}}} <-
           HTTP.get_json(url, headers: headers(key), timeout: 15_000),
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

      {:ok, Map.put(result, :cursor, cursor)}
    else
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, _} = error -> error
    end
  end

  defp push(peer, key) do
    {:ok, _} = Capture.seal()
    local = replica_id()

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT sequence, id, device_id, entity_type, entity_id, operation, payload, payload_hash, idempotency_key, occurred_at
        FROM sync_mutations
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3 AND device_id != ?4
        ORDER BY sequence LIMIT ?5
        """,
        [peer.tenant_id, peer.workspace_id, peer.last_pushed_seq, peer.peer_replica_id || "", @page]
      )

    if rows == [] do
      {:ok, %{sent: 0}}
    else
      mutations =
        rows
        |> Enum.map(fn [_seq, id, device, type, entity, op, payload, hash, idem, at] ->
          %{
            "id" => id,
            "device_id" => device,
            "entity_type" => type,
            "entity_id" => entity,
            "operation" => op,
            "payload" => decode(payload),
            "payload_hash" => hash,
            "idempotency_key" => idem,
            "occurred_at" => at
          }
        end)
        |> Enum.reject(&restricted_row?(&1, peer.max_class))

      cursor = rows |> List.last() |> hd()

      body = %{
        "workspace" => peer.workspace_id,
        "replica_id" => local,
        "engine" => engine_info(),
        "mutations" => mutations
      }

      case HTTP.post_json(push_url(peer), body,
             headers: headers(key),
             timeout: 30_000
           ) do
        {:ok, %{status: 200, body: result}} ->
          {:ok, _} =
            Store.raw_query(
              "UPDATE sync_peers SET last_pushed_seq = ?4 WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3",
              [peer.tenant_id, peer.workspace_id, peer.url, cursor]
            )

          {:ok, %{sent: length(mutations), gated: length(rows) - length(mutations), remote: result}}

        {:ok, %{status: 409, body: %{"error" => "version_mismatch", "message" => message}}} ->
          {:error, {:version_mismatch, message}}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_status, status, body}}

        {:error, _} = error ->
          error
      end
    end
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
    case Store.raw_query(
           "SELECT COUNT(*) FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3 AND device_id != ?4",
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
