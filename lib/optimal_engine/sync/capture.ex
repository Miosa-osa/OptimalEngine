defmodule OptimalEngine.Sync.Capture do
  @moduledoc """
  Change capture for replication: every create, update, and delete of a
  workspace row is recorded in the same transaction as the write.

  Capture is done by SQLite triggers, so no write path can forget it. For
  each table that carries a `workspace_id` column the Engine installs
  `AFTER INSERT`, `AFTER UPDATE`, and `AFTER DELETE` triggers that append the
  row (or, for a delete, its key) to `sync_capture`, but only for
  workspaces enabled for sync and never while replicated changes are being
  applied (`sync_identity.applying`), so applied changes are not echoed.

  `seal/0` moves captured rows into the `sync_mutations` ledger with a
  SHA-256 of the payload, an idempotency key of `<replica>:<capture seq>`,
  and this Engine's replica id, preserving order. It works through the whole
  backlog, a batch at a time, so a caller that seals before it reads sees
  every change captured so far.

  Tables whose primary key is a single `INTEGER` row id are append-only
  derivations (their ids differ per Engine); they replicate inserts only, and
  `append_only_tables/0` lists them.

  What replicates is an explicit list (`replicated_tables/0`): workspace
  knowledge, and nothing that grants a capability. Every other table stays on
  its Engine (`local_only?/1`): it is not captured, not served, not pushed, and
  a change for it that a peer sends is skipped. A new table is therefore local
  until someone puts it on the list, and a test fails until it is on one list
  or the other. `docs/guides/replication.md` gives the reason for each table.

  The gate (`OptimalEngine.Sync.Gate`) also reads the tables that stay local and
  carry a label or a class (`stamped_tables/0`: assets, active pools, context
  packages, model and tool runs, skill packages, tool definitions). Nothing is
  captured from them, but a write to a row of a workspace that syncs moves
  `sync_local_stamp`, a table that never holds a row and only keeps a counter in
  `sqlite_sequence`, which the gate cache reads with the sequences of the
  capture and the ledger. A write counts only when it can change what the gate
  finds: a row that may name a class is inserted or deleted, or a column the
  gate reads changes to or from one.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Lineage

  # What replicates: workspace knowledge. A peer that holds the `sync` scope may
  # write these tables and no others, so nothing here may grant a capability
  # (members, roles, tools, storage, credentials), reach a path or a SQL
  # identifier outside the workspace, or name a row that exists on one Engine
  # only: every foreign key of a table here points at another table here (or at
  # `workspaces`, `tenants`, `organizations`), and a test checks it.
  # Demoting a table from this list drops its unsent ledger rows at the next boot
  # (`Sync.purge_unreplicated_once/0`).
  @replicated ~w(analysis_reports canonical_entities chunk_embeddings chunks citations claims
                 classifications cluster_members clusters contexts data_quality_snapshots decisions
                 derivation_ledger edges entities entity_aliases entity_identifiers entity_lineage
                 entity_mentions episodes facts generalized_workflows graph_edges intents memories
                 memory_association_paths memory_associations memory_consolidation_proposals
                 memory_detail_objects memory_embeddings memory_objects memory_path_feedback
                 memory_path_priors memory_reconstruction_outcomes memory_reconstruction_runs memory_relations
                 node_relationships node_types nodes observations open_loops optimality_assessments
                 procedural_memory_objects relationship_edges rhythm_notes sessions signal_events
                 source_packages training_examples vectors wiki_pages workflow_traces)

  # Engine state: stays on its Engine and is not moved with a workspace either.
  # `connectors` carry credentials sealed with this Engine's CONNECTOR_KEY and
  # per-Engine cursors; `jobs` and `dead_letter_jobs` are a queue that would run
  # twice on a second Engine; `workspaces` and `workspace_handles` name this
  # Engine's workspaces; the rest is sync bookkeeping and run logs.
  @engine_state ~w(sync_capture sync_mutations sync_cursors sync_workspaces sync_peers sync_conflicts
                   sync_local_stamp metric_samples uri_redirects federation_peers connectors
                   connector_runs processor_runs jobs dead_letter_jobs workspaces workspace_handles
                   graph_backfills)

  # Per-Engine as well, but a workspace bundle carries them (a move takes the
  # workspace's whole state). Each is here for a reason:
  #
  # * grants a capability a peer must not hand out: workspace_members (membership
  #   and roles), node_members and principal_skills (they name a principal, which
  #   exists on one Engine only), mcp_tool_definitions and skill_packages (tools
  #   and skills an agent runs), routing_rules (steers where intake files
  #   documents);
  # * reaches outside the database: data_collections, data_changes, data_files and
  #   data_schema_migrations (a collection's `table_name` is interpolated into the
  #   SQL that serves it), assets and every asset_* table (`storage_path` names a
  #   file on the Engine's disk or a bucket; asset files do not sync);
  # * decodes into atoms: surfacing_subscriptions;
  # * how this Engine stores data and which models it runs: storage_provider_configs,
  #   workspace_storage_policies, model_call_operations, model_adapters;
  # * what this Engine executed or wrote out, and what is derived from it: the run
  #   records (model_call_runs, tool_call_runs, decomposition_runs, training_runs,
  #   evaluation_runs), evaluation_cases (they point at an evaluation run),
  #   context_packages and active_memory_pools, export_records, projection_revisions,
  #   link_health_records;
  # * telemetry whose ids differ per Engine: events, surfacing_events, audit_samples;
  # * configuration or review state kept per Engine: architectures, rhythm_templates,
  #   skills, topology_change_requests, resolution_decisions.
  @per_engine ~w(active_memory_pools architectures asset_adapter_runs asset_embedding_refs
                 asset_extractions asset_ocr_spans asset_transcripts asset_visual_observations assets
                 audit_samples context_packages data_changes data_collections data_files
                 data_schema_migrations decomposition_runs evaluation_cases
                 evaluation_runs events export_records link_health_records mcp_tool_definitions
                 model_adapters model_call_operations model_call_runs node_members principal_skills
                 projection_revisions resolution_decisions rhythm_templates routing_rules
                 skill_packages skills storage_provider_configs surfacing_events
                 surfacing_subscriptions tool_call_runs topology_change_requests training_runs
                 workspace_members workspace_storage_policies)
  @max_columns 60
  @seal_batch 5_000
  @stamp_table "sync_local_stamp"

  @doc """
  The tables that replicate, an explicit list. It is the allow-list for applying
  a peer's changes and the only set captured, served and pushed.
  """
  @spec replicated_tables() :: [String.t()]
  def replicated_tables, do: @replicated

  @doc "Whether `table` replicates."
  @spec replicated?(term()) :: boolean()
  def replicated?(table) when is_binary(table), do: table in @replicated
  def replicated?(_table), do: false

  @doc """
  Whether `table` stays on its Engine: everything that does not replicate, a
  table nobody has classified yet included.
  """
  @spec local_only?(term()) :: boolean()
  def local_only?(table), do: not replicated?(table)

  @doc """
  The tables classified as local, `authority_*` tables aside (those are
  recognised by prefix, see `known_local?/1`).
  """
  @spec local_tables() :: [String.t()]
  def local_tables, do: Enum.sort(@engine_state ++ @per_engine)

  @doc """
  Whether `table` is one a peer is known to send by name and is skipped as
  local-only. Any other table that is not replicated is refused instead.
  """
  @spec known_local?(term()) :: boolean()
  def known_local?(table) when is_binary(table),
    do: table in @engine_state or table in @per_engine or String.starts_with?(table, "authority_")

  def known_local?(_table), do: false

  @doc """
  Whether a workspace bundle leaves `table` behind: Engine state and authority
  state. The other local tables travel with a moved workspace.
  """
  @spec bundle_excluded?(term()) :: boolean()
  def bundle_excluded?(table) when is_binary(table),
    do: table in @engine_state or String.starts_with?(table, "authority_")

  def bundle_excluded?(_table), do: false

  @doc """
  Installs (or refreshes) capture triggers on every replicated table, and removes
  any from a table that is not replicated: an earlier binary, which captured
  every workspace table, may have put one there.
  """
  @spec install() :: {:ok, %{tables: non_neg_integer(), skipped: [String.t()]}}
  def install do
    {installed, skipped} =
      Enum.reduce(@replicated, {0, []}, fn table, {count, skipped} ->
        case install(table) do
          :ok -> {count + 1, skipped}
          {:skipped, _reason} -> {count, [table | skipped]}
        end
      end)

    drop_stale_triggers()
    install_stamp()

    {:ok, %{tables: installed, skipped: Enum.reverse(skipped)}}
  end

  @doc """
  Installs capture triggers on one table (for tables created at runtime). A
  table that is excluded gets none, and loses any it has.
  """
  @spec install(String.t()) :: :ok | {:skipped, atom()}
  def install(table) do
    columns = columns(table)

    cond do
      local_only?(table) ->
        drop_capture_triggers(table)
        {:skipped, :excluded}

      not Enum.any?(columns, &(&1.name == "workspace_id")) ->
        {:skipped, :not_workspace_scoped}

      length(columns) > @max_columns ->
        {:skipped, :too_many_columns}

      true ->
        ensure_triggers(table, "sync_capture_", statements(table, columns))
    end
  end

  # Triggers already in place are left alone, so a restart does no DDL; a
  # changed table is re-triggered in one transaction.
  defp ensure_triggers(table, prefix, statements) do
    creates = Enum.reject(statements, &String.starts_with?(&1, "DROP"))

    if installed_triggers(table, prefix) == MapSet.new(creates, &String.trim/1) do
      :ok
    else
      {:ok, _} =
        Store.transaction(fn txn ->
          Enum.each(statements, fn sql -> {:ok, _} = Store.txn_execute(txn, sql, []) end)
          {:ok, :installed}
        end)

      :ok
    end
  end

  @doc """
  The tables the gate scans for a label that stay on this Engine: the tables
  `Lineage.scanned_tables/0` names that do not replicate. A write to one is not
  captured; it moves the local stamp instead (see the module doc).
  """
  @spec stamped_tables() :: [String.t()]
  def stamped_tables, do: Enum.reject(Lineage.scanned_tables(), &replicated?/1)

  # The counter table is created here, not by a migration: like the capture
  # triggers it is installed at boot and when sync is enabled, and a gate that
  # reads the stamp before it exists just sees no entry for it.
  defp install_stamp do
    :ok =
      Store.raw_execute(
        "CREATE TABLE IF NOT EXISTS #{@stamp_table} (seq INTEGER PRIMARY KEY AUTOINCREMENT)",
        []
      )

    stamped = stamped_tables()

    for table <- stamped do
      columns = columns(table)
      read = stamp_columns(table)

      if Enum.all?(read, fn column -> Enum.any?(columns, &(&1.name == column)) end),
        do: ensure_triggers(table, "sync_stamp_", stamp_statements(table, read))
    end

    drop_stale_stamp_triggers(stamped)
  end

  @doc """
  The columns of a stamped table the gate reads: the ones it takes the class
  from (`Lineage.class_columns/1`, the columns `Gate` builds its scan on) and
  the scope of the row. An update that writes none of them cannot change what
  the gate finds.
  """
  @spec stamp_columns(String.t()) :: [String.t()]
  def stamp_columns(table) do
    classes = table |> Lineage.spec() |> Lineage.class_columns() |> Enum.map(&elem(&1, 1))
    classes ++ ["tenant_id", "workspace_id"]
  end

  # The counter of `sync_local_stamp` moves (insert a row, delete it; the
  # sequence stays) when a row of a workspace that syncs is written in a way that
  # can change what the gate finds:
  #
  # * an insert or a delete of a row that may name a class
  #   (`Lineage.may_name_class_sql/2`), not of one that cannot: a row without
  #   labels is not above any gate, and a run table gets a row per call;
  # * an update that changes a column the gate reads, to or from a row that may
  #   name a class. An update that writes the same value (a re-registration
  #   rewrites the columns it always writes) moves nothing.
  #
  # `NULL` and text that is not JSON are labels the gate cannot read, so they
  # count as naming a class.
  defp stamp_statements(table, read) do
    t = quote_name(table)
    classes = table |> Lineage.spec() |> Lineage.class_columns()
    updated = Enum.map_join(read, ", ", &quote_name/1)
    changed = Enum.map_join(read, " OR ", &"OLD.#{quote_name(&1)} IS NOT NEW.#{quote_name(&1)}")

    syncing = fn row ->
      "EXISTS (SELECT 1 FROM sync_workspaces WHERE workspace_id = #{row}.\"workspace_id\")"
    end

    matters = fn row -> Enum.map_join(classes, " OR ", &Lineage.may_name_class_sql(&1, row)) end
    bump = "INSERT INTO #{@stamp_table} (seq) VALUES (NULL); DELETE FROM #{@stamp_table};"

    drops =
      for suffix <- ~w(ai au ad),
          do: "DROP TRIGGER IF EXISTS #{quote_name("sync_stamp_#{suffix}_#{table}")}"

    drops ++
      [
        """
        CREATE TRIGGER #{quote_name("sync_stamp_ai_#{table}")} AFTER INSERT ON #{t}
        WHEN #{syncing.("NEW")} AND (#{matters.("NEW")})
        BEGIN
          #{bump}
        END
        """,
        """
        CREATE TRIGGER #{quote_name("sync_stamp_au_#{table}")} AFTER UPDATE OF #{updated} ON #{t}
        WHEN (#{changed}) AND (#{syncing.("NEW")} OR #{syncing.("OLD")})
          AND ((#{matters.("NEW")}) OR (#{matters.("OLD")}))
        BEGIN
          #{bump}
        END
        """,
        """
        CREATE TRIGGER #{quote_name("sync_stamp_ad_#{table}")} AFTER DELETE ON #{t}
        WHEN #{syncing.("OLD")} AND (#{matters.("OLD")})
        BEGIN
          #{bump}
        END
        """
      ]
  end

  # A table that stopped being scanned or started to replicate keeps the
  # triggers an earlier version put on it.
  defp drop_stale_stamp_triggers(stamped) do
    keep = MapSet.new(stamped)

    {:ok, rows} =
      Store.raw_query(
        "SELECT name, tbl_name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync_stamp_%'",
        []
      )

    for [name, table] <- rows, not MapSet.member?(keep, table) do
      :ok = Store.raw_execute("DROP TRIGGER IF EXISTS #{quote_name(name)}", [])
    end

    :ok
  end

  defp drop_capture_triggers(table) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?1 AND name LIKE 'sync_capture_%'",
        [table]
      )

    Enum.each(rows, fn [name] ->
      :ok = Store.raw_execute("DROP TRIGGER IF EXISTS #{quote_name(name)}", [])
    end)
  end

  # A table that stopped being captured (it became local-only, or outgrew the
  # column limit) keeps the triggers an earlier version installed, which would
  # go on filling `sync_capture`. Triggers are removed from every table that is
  # not replicated.
  defp drop_stale_triggers do
    replicated = MapSet.new(@replicated)

    {:ok, rows} =
      Store.raw_query(
        "SELECT name, tbl_name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync_capture_%'",
        []
      )

    for [name, table] <- rows, not MapSet.member?(replicated, table) do
      :ok = Store.raw_execute("DROP TRIGGER IF EXISTS #{quote_name(name)}", [])
    end

    :ok
  end

  defp installed_triggers(table, prefix) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?1 AND name LIKE ?2",
        [table, prefix <> "%"]
      )

    MapSet.new(rows, fn [sql] -> String.trim(sql || "") end)
  end

  @doc "Removes capture triggers from every table."
  @spec uninstall() :: :ok
  def uninstall do
    {:ok, rows} =
      Store.raw_query(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync_capture_%'",
        []
      )

    Enum.each(rows, fn [name] ->
      :ok = Store.raw_execute("DROP TRIGGER IF EXISTS #{quote_name(name)}", [])
    end)
  end

  @doc "Tables that replicate inserts only (single INTEGER row-id key)."
  @spec append_only_tables() :: [String.t()]
  def append_only_tables do
    Enum.filter(@replicated, &rowid_key?(columns(&1)))
  end

  @doc """
  Moves captured changes into the `sync_mutations` ledger. Returns how many
  were sealed.
  """
  @spec seal() :: {:ok, non_neg_integer()}
  def seal, do: seal_backlog(0)

  # A batch is at most @seal_batch rows; sealing goes on until the backlog is
  # empty, so one call never leaves captured rows behind for the caller to miss.
  defp seal_backlog(sealed) do
    case seal_batch() do
      {:ok, 0, _sealed} -> {:ok, sealed}
      {:ok, _taken, batch} -> seal_backlog(sealed + batch)
    end
  end

  defp seal_batch do
    {:ok, [[replica_id]]} = Store.raw_query("SELECT replica_id FROM sync_identity WHERE id = 1", [])

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT c.seq, c.table_name, c.operation, c.workspace_id, c.entity_key, c.row_data, c.blob_data,
               c.occurred_at, w.tenant_id, w.organization_id
        FROM sync_capture c JOIN workspaces w ON w.id = c.workspace_id
        ORDER BY c.seq LIMIT #{@seal_batch}
        """,
        []
      )

    if rows == [] do
      {:ok, 0, 0}
    else
      # Rows captured by a trigger an earlier version installed on a table that
      # is now local-only are dropped, not sealed.
      sealable = Enum.filter(rows, fn [_seq, table | _] -> replicated?(table) end)

      {:ok, sealed} =
        Store.transaction(fn txn ->
          Enum.each(sealable, fn [
                                   seq,
                                   table,
                                   op,
                                   workspace_id,
                                   key,
                                   row,
                                   blobs,
                                   occurred_at,
                                   tenant_id,
                                   org_id
                                 ] ->
            payload = Jason.encode!(%{"row" => Jason.decode!(row), "blobs" => decode_blobs(blobs)})

            {:ok, _} =
              Store.txn_execute(
                txn,
                """
                INSERT OR IGNORE INTO sync_mutations
                  (id, tenant_id, organization_id, workspace_id, device_id, entity_type, entity_id, operation,
                   payload, payload_hash, idempotency_key, occurred_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                """,
                [
                  "mut_" <> replica_id <> "_" <> Integer.to_string(seq),
                  tenant_id,
                  org_id,
                  workspace_id,
                  replica_id,
                  table,
                  key || "row:#{seq}",
                  op,
                  payload,
                  :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower),
                  replica_id <> ":" <> Integer.to_string(seq),
                  occurred_at
                ]
              )
          end)

          max_seq = rows |> List.last() |> hd()
          {:ok, _} = Store.txn_execute(txn, "DELETE FROM sync_capture WHERE seq <= ?1", [max_seq])
          {:ok, length(sealable)}
        end)

      {:ok, length(rows), sealed}
    end
  end

  @doc false
  def columns(table) do
    {:ok, rows} =
      Store.raw_query("SELECT name, type, pk FROM pragma_table_info(?1) ORDER BY cid", [table])

    Enum.map(rows, fn [name, type, pk] -> %{name: name, type: String.upcase(type || ""), pk: pk} end)
  end

  @doc false
  def key_columns(columns) do
    columns |> Enum.filter(&(&1.pk > 0)) |> Enum.sort_by(& &1.pk) |> Enum.map(& &1.name)
  end

  @doc false
  def rowid_key?(columns) do
    match?([%{type: "INTEGER"}], Enum.filter(columns, &(&1.pk > 0)))
  end

  # ---------------------------------------------------------------------------

  defp statements(table, columns) do
    t = quote_name(table)
    keys = key_columns(columns)
    append_only = rowid_key?(columns)

    guard = fn row ->
      """
      (SELECT applying FROM sync_identity WHERE id = 1) = 0
        AND EXISTS (SELECT 1 FROM sync_workspaces WHERE workspace_id = #{row}."workspace_id")
      """
    end

    capture = fn op, row, data ->
      """
      INSERT INTO sync_capture (table_name, operation, workspace_id, entity_key, row_data, blob_data)
      VALUES ('#{table}', '#{op}', #{row}."workspace_id", #{key_expr(keys, row, append_only)}, #{data}, #{blobs_expr(columns, row)});
      """
    end

    drops =
      for suffix <- ~w(ai au ad),
          do: "DROP TRIGGER IF EXISTS #{quote_name("sync_capture_#{suffix}_#{table}")}"

    insert = """
    CREATE TRIGGER #{quote_name("sync_capture_ai_#{table}")} AFTER INSERT ON #{t}
    WHEN #{guard.("NEW")}
    BEGIN
      #{capture.("create", "NEW", row_expr(columns, "NEW"))}
    END
    """

    updates =
      if append_only or keys == [] do
        []
      else
        [
          """
          CREATE TRIGGER #{quote_name("sync_capture_au_#{table}")} AFTER UPDATE ON #{t}
          WHEN #{guard.("NEW")}
          BEGIN
            #{capture.("update", "NEW", row_expr(columns, "NEW"))}
          END
          """,
          """
          CREATE TRIGGER #{quote_name("sync_capture_ad_#{table}")} AFTER DELETE ON #{t}
          WHEN #{guard.("OLD")}
          BEGIN
            #{capture.("delete", "OLD", row_expr(Enum.filter(columns, &(&1.name in keys)), "OLD"))}
          END
          """
        ]
      end

    drops ++ [insert | updates]
  end

  # Values that are BLOBs at run time go to the blob object as hex; json
  # cannot hold them.
  defp row_expr(columns, row) do
    pairs =
      Enum.map_join(columns, ", ", fn %{name: name} ->
        "'#{name}', CASE WHEN typeof(#{row}.#{quote_name(name)}) = 'blob' THEN NULL ELSE #{row}.#{quote_name(name)} END"
      end)

    "json_object(#{pairs})"
  end

  # Every column is checked: SQLite typing is per value, so any column may
  # hold a BLOB.
  defp blobs_expr(columns, row) do
    pairs =
      Enum.map_join(columns, ", ", fn %{name: name} ->
        "'#{name}', CASE WHEN typeof(#{row}.#{quote_name(name)}) = 'blob' THEN hex(#{row}.#{quote_name(name)}) END"
      end)

    "json_object(#{pairs})"
  end

  @doc false
  # The SQL that gives a captured row its `entity_key`. `Sync` computes the same
  # key from a payload (`Sync.entity_key/2`), and a test compares the two.
  def key_expr(_keys, _row, true), do: "NULL"
  def key_expr([key], row, false), do: "CAST(#{row}.#{quote_name(key)} AS TEXT)"

  def key_expr(keys, row, false) do
    "json_array(" <> Enum.map_join(keys, ", ", &"#{row}.#{quote_name(&1)}") <> ")"
  end

  defp decode_blobs(nil), do: %{}

  defp decode_blobs(json) do
    json
    |> Jason.decode!()
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp quote_name(name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
      do: ~s("#{name}"),
      else: raise(ArgumentError, "unsafe identifier #{inspect(name)}")
  end
end
