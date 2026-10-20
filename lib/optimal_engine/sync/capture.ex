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
  and this Engine's replica id, preserving order.

  Tables whose primary key is a single `INTEGER` row id are append-only
  derivations (their ids differ per Engine); they replicate inserts only, and
  `append_only_tables/0` lists them.
  """

  alias OptimalEngine.Store

  @excluded ~w(sync_capture sync_mutations sync_cursors sync_workspaces sync_peers sync_conflicts
               metric_samples uri_redirects federation_peers events connector_runs processor_runs
               surfacing_events workspaces workspace_handles audit_samples)
  @max_columns 60

  @doc "Installs (or refreshes) capture triggers on every eligible table."
  @spec install() :: {:ok, %{tables: non_neg_integer(), skipped: [String.t()]}}
  def install do
    {installed, skipped} =
      Enum.reduce(eligible_tables(), {0, []}, fn table, {count, skipped} ->
        case install(table) do
          :ok -> {count + 1, skipped}
          {:skipped, _reason} -> {count, [table | skipped]}
        end
      end)

    {:ok, %{tables: installed, skipped: Enum.reverse(skipped)}}
  end

  @doc "Installs capture triggers on one table (for tables created at runtime)."
  @spec install(String.t()) :: :ok | {:skipped, atom()}
  def install(table) do
    columns = columns(table)

    cond do
      table in @excluded or String.starts_with?(table, "authority_") ->
        {:skipped, :excluded}

      not Enum.any?(columns, &(&1.name == "workspace_id")) ->
        {:skipped, :not_workspace_scoped}

      length(columns) > @max_columns ->
        {:skipped, :too_many_columns}

      true ->
        statements = statements(table, columns)
        creates = Enum.reject(statements, &String.starts_with?(&1, "DROP"))

        # Triggers already in place are left alone, so a restart does no DDL;
        # a changed table is re-triggered in one transaction.
        if installed_triggers(table) == MapSet.new(creates, &String.trim/1) do
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
  end

  defp installed_triggers(table) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?1 AND name LIKE 'sync_capture_%'",
        [table]
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
    Enum.filter(eligible_tables(), &rowid_key?(columns(&1)))
  end

  @doc """
  Moves captured changes into the `sync_mutations` ledger. Returns how many
  were sealed.
  """
  @spec seal() :: {:ok, non_neg_integer()}
  def seal do
    {:ok, [[replica_id]]} = Store.raw_query("SELECT replica_id FROM sync_identity WHERE id = 1", [])

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT c.seq, c.table_name, c.operation, c.workspace_id, c.entity_key, c.row_data, c.blob_data,
               c.occurred_at, w.tenant_id, w.organization_id
        FROM sync_capture c JOIN workspaces w ON w.id = c.workspace_id
        ORDER BY c.seq LIMIT 5000
        """,
        []
      )

    if rows == [] do
      {:ok, 0}
    else
      Store.transaction(fn txn ->
        Enum.each(rows, fn [
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
        {:ok, length(rows)}
      end)
    end
  end

  @doc "Eligible tables: every table with a workspace_id column that is not excluded."
  @spec eligible_tables() :: [String.t()]
  def eligible_tables do
    {:ok, rows} =
      Store.raw_query("SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name", [])

    for [name, sql] <- rows,
        name not in @excluded,
        not String.starts_with?(name, "authority_"),
        not String.starts_with?(name, "sqlite_"),
        not (is_binary(sql) and String.contains?(sql, "VIRTUAL")),
        not Regex.match?(~r/_fts_(data|idx|docsize|config|content)\z/, name),
        Enum.any?(columns(name), &(&1.name == "workspace_id")) do
      name
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

  defp key_expr(_keys, _row, true), do: "NULL"
  defp key_expr([key], row, false), do: "CAST(#{row}.#{quote_name(key)} AS TEXT)"

  defp key_expr(keys, row, false) do
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
