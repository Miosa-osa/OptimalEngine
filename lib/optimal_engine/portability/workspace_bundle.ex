defmodule OptimalEngine.Portability.WorkspaceBundle do
  @moduledoc """
  Moves one workspace between Engines without reindexing: split a workspace
  out of an org Engine into its own Engine, merge it back, or seed a new
  Engine from a snapshot.

  A bundle is a gzip tar file:

      manifest.json            format, versions, workspace, per-table and per-file SHA-256
      tables/<table>.jsonl     every row of the workspace, one JSON object per line
      files/<relative path>    the workspace's directory on disk

  Every table that carries a `workspace_id` column is included, plus child
  rows that hang off them without one, the principals the workspace's
  memberships name, and workspace-scoped operating documents. Connectors,
  their run log and queued jobs stay with the Engine that runs them. Embeddings and
  other binary columns travel as base64, so vectors are copied, not
  recomputed; full-text indexes are filled by the Engine's own triggers as
  rows are inserted. Authority state (keys, packs, grants, evidence) stays
  with the Engine that issued it; replica cursors and metric samples are
  operational and are not moved.

  A bundle is a whole-workspace move and does not follow the data-class gate
  of replication (`OptimalEngine.Sync.Gate`): it carries every row and file,
  restricted ones included, because `finalize_move/4` deletes the source and
  a move that left them behind would lose them. A replica cleared for less
  than the workspace holds must not be seeded from it.

  Import verifies every checksum before writing, rewrites tenant and
  workspace ids to the target, lets integer row ids be reassigned, and
  either refuses an existing workspace (`mode: :create`, default) or keeps
  existing rows (`mode: :merge`). Rows are written in short transactions of
  `:batch_rows` rows (default 1,000), tables in foreign-key order and rows of
  a self-referencing table parents first, so a large workspace never holds
  the single-writer Store long enough to stall the Engine or time out. A
  failed create import removes everything it wrote and the workspace record;
  a failed merge can be run again (it only adds missing rows). `finalize_move/4` then removes the
  workspace from the source Engine and records a redirect, so `optimal://`
  citations keep resolving (`resolve/2`).

  A table replaced by a successor (`Store.Migrations.superseded_tables/0`,
  such as `edges` by `graph_edges`) is not exported, and the rows an older
  Engine's bundle carries for it are imported into its successor, keeping
  rows the target already holds.
  """

  require Logger

  alias OptimalEngine.Authority.CanonicalJSON
  alias OptimalEngine.Compliance.Artifacts
  alias OptimalEngine.Store
  alias OptimalEngine.Store.FileCache.Maintenance, as: Cache
  alias OptimalEngine.Store.Migrations
  alias OptimalEngine.Store.ReadSnapshot
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Workspace
  alias OptimalEngine.Workspace.Filesystem

  @format "optimal-workspace-bundle"
  @version 1

  # Engine bookkeeping that names a workspace but is not its data stays on the
  # source Engine: `Capture.bundle_excluded?/1` says which tables (connectors carry
  # credentials sealed with this Engine's CONNECTOR_KEY and pull on its
  # schedule, so the target registers its own; queued jobs would run twice).

  # Registry rows every Engine derives for itself under the same id: a target
  # that already holds one keeps it.
  @keep_existing ~w(principals model_call_operations)
  @children %{"memory_reconstruction_steps" => {"run_id", "memory_reconstruction_runs"}}
  # Registry tables an export reads by membership and scope, not by a
  # workspace_id column.
  @member_tables ~w(workspace_members node_members)
  @principals "principals"
  @documents "operating_documents"
  # Columns, and keys of a row's metadata, that hold where a stored file is
  # (relocate_files/3).
  @file_columns %{"assets" => ["storage_path"], "source_packages" => ["verbatim_archive_uri"]}
  @file_metadata_keys ["local_path", "storage_path"]
  @batch_rows 1_000
  @snapshot_attempts 20
  @stale_staging_seconds 7_200

  @doc """
  Writes a bundle for `workspace_id` to `path`. Returns the manifest.

  `:observe` is told how the export goes and may stop it: it is called with
  `{:phase, phase}` (`:sealing`, `:reading`, `:files`, `:packing`) and with
  `{:rows, table, n}` after each page, and returns `:ok` to go on or
  `:cancel` to stop, which answers `{:error, :cancelled}` and writes nothing
  to `path`.

  An export first checks that the disk holds what it will write (see
  `export_bytes/2`, twice over for the staged files and the archive, and a
  margin of `config :optimal_engine, :bundle_export_margin_bytes`, 256 MiB by
  default, for what the database writes while the export holds its snapshot)
  and answers `{:error, :insufficient_storage}` otherwise, before it stages
  anything.
  """
  @spec export(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(tenant_id, workspace_id, path, opts \\ []) do
    observe = Keyword.get(opts, :observe, fn _event -> :ok end)

    with {:ok, workspace} <- Workspace.get(workspace_id),
         true <- workspace.tenant_id == tenant_id || {:error, :not_found},
         :ok <- room_to_export(tenant_id, workspace_id) do
      staging = staging_dir()

      try do
        observed(observe, {:phase, :sealing})

        with {:ok, {mark, tables}} <- snapshot_tables(tenant_id, workspace_id, staging, observe) do
          observed(observe, {:phase, :files})
          files = export_files(workspace_id, staging)
          observed(observe, {:phase, :packing})
          write_bundle(tenant_id, workspace, mark, tables, files, staging, path)
        end
      catch
        :bundle_cancelled -> {:error, :cancelled}
      after
        File.rm_rf(staging)
      end
    end
  end

  # Reports an event to the caller's observer, and stops the run when it asks.
  # Only where nothing is written yet: once an import has planned its target,
  # it stops between batches instead (batch_written/3), which undoes a create.
  defp observed(observe, event) do
    case observe.(event) do
      :cancel -> throw(:bundle_cancelled)
      _ -> :ok
    end
  end

  # Reports an event without offering to stop.
  defp notify(observe, event) do
    observe.(event)
    :ok
  end

  defp write_bundle(tenant_id, workspace, mark, tables, files, staging, path) do
    manifest =
      %{
        "format" => @format,
        "version" => @version,
        "engine_version" => engine_version(),
        "migration" => current_migration(),
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "tenant_id" => tenant_id,
        "workspace" => %{
          "id" => workspace.id,
          "slug" => workspace.slug,
          "name" => workspace.name,
          "description" => workspace.description,
          "external_id" => workspace.external_id,
          "metadata" => workspace.metadata
        },
        "tables" => tables,
        "files" => files,
        "ledger_sequence" => mark
      }
      |> then(&Map.put(&1, "bundle_sha256", CanonicalJSON.hash(&1)))

    File.write!(Path.join(staging, "manifest.json"), Jason.encode!(manifest, pretty: true))
    :ok = pack(staging, path)
    {:ok, manifest}
  end

  # The ledger mark and every row come from one read of the database, on a
  # connection of its own (`OptimalEngine.Store.ReadSnapshot`). A write that
  # lands while the export runs is in neither the bundle nor at or below the
  # mark, so a replica seeded from the bundle pulls it exactly once, and a row
  # re-written meanwhile is in the bundle once, as it was.
  #
  # Changes captured before the read are sealed into the ledger first. A
  # change captured but not yet sealed when the read begins would be in the
  # rows and sealed later above the mark, so the read is started again while
  # the workspace has one, a bounded number of times.
  defp snapshot_tables(tenant_id, workspace_id, staging, observe, attempt \\ 1) do
    with {:ok, _sealed} <- Capture.seal() do
      result =
        ReadSnapshot.run(fn snap ->
          if pending_captures(snap, workspace_id) == 0 do
            observed(observe, {:phase, :reading})
            mark = ledger_mark(snap, tenant_id, workspace_id)
            {:ok, {mark, export_tables(snap, tenant_id, workspace_id, staging, observe)}}
          else
            :captures_pending
          end
        end)

      case result do
        :captures_pending when attempt < @snapshot_attempts ->
          Process.sleep(min(10 * attempt, 200))
          snapshot_tables(tenant_id, workspace_id, staging, observe, attempt + 1)

        :captures_pending ->
          {:error, :writes_in_progress}

        other ->
          other
      end
    end
  end

  defp pending_captures(snap, workspace_id) do
    {:ok, [[n]]} =
      ReadSnapshot.query(snap, "SELECT COUNT(*) FROM sync_capture WHERE workspace_id = ?1", [
        workspace_id
      ])

    n
  end

  @doc """
  Imports a bundle into `tenant_id`. Options: `:workspace_id` (target id;
  default the source id with the target tenant), `:organization_id`,
  `:mode` (`:create` or `:merge`), `:consume` (delete the bundle file once
  it is unpacked, for an upload nobody keeps, so a large import holds one copy
  of the bundle on disk instead of two), and `:cross_tenant`. Returns a summary
  with the bundle hash.

  A bundle exported by another tenant is refused with
  `{:error, :bundle_from_another_tenant}` before anything is written, unless
  `cross_tenant: true` says the move between tenants is intended (the Engine
  operator seeding a tenant, or one database standing in for two Engines).

  `:written_log` is a file the import appends to, after each batch it commits,
  naming the rows that batch inserted (by primary key, or by the range the
  table's key took). `discard_written/4` takes those rows out again and no
  others, so a failed or cancelled import can be undone without touching what
  another writer put in the workspace meanwhile. The default is a file in the
  import's staging folder.

  `:observe` is told how the import goes, as for `export/4`: `{:phase, phase}`
  (`:verifying`, `:planning`, `:writing`, `:files`), `{:total, rows, files}`
  from the manifest, `{:target, %{created: created, empty: empty}}` once the
  target is planned (this run made the workspace record; the workspace held
  nothing), and `{:rows, table, n}` after each batch. It may stop
  the import with `:cancel` until the target is planned, and between batches
  after that; a stopped create removes what it wrote. The answer is then
  `{:error, :cancelled}`.
  """
  @spec import(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import(path, tenant_id, opts \\ []) do
    staging = staging_dir()
    observe = Keyword.get(opts, :observe, fn _event -> :ok end)

    try do
      with :ok <- unpack(path, staging),
           :ok <- if(opts[:consume], do: File.rm(path), else: :ok),
           {:ok, manifest} <- read_manifest(staging),
           :ok <- permitted(manifest),
           :ok <- files_inside(manifest),
           :ok <- observed(observe, {:phase, :verifying}),
           :ok <-
             observed(observe, {:total, manifest_rows(manifest), length(manifest["files"] || [])}),
           :ok <- verify(manifest, staging),
           :ok <- same_tenant(manifest, tenant_id, opts),
           :ok <- observed(observe, {:phase, :planning}),
           {:ok, plan} <- plan(manifest, tenant_id, opts),
           :ok <- announce_target(observe, plan),
           :ok <- compatible(manifest, staging),
           :ok <- notify(observe, {:phase, :writing}),
           {:ok, counts} <-
             write_rows(
               manifest,
               staging,
               plan,
               opts
               |> Keyword.put(:observe, observe)
               |> Keyword.put_new(:written_log, Path.join(staging, "written.jsonl"))
             ),
           :ok <- notify(observe, {:phase, :files}),
           {:ok, file_count} <- write_files(manifest, staging, plan) do
        {:ok,
         %{
           workspace_id: plan.workspace_id,
           tenant_id: tenant_id,
           mode: plan.mode,
           rows: counts,
           files: file_count,
           bundle_sha256: manifest["bundle_sha256"],
           ledger_sequence: manifest["ledger_sequence"],
           source_workspace_id: manifest["workspace"]["id"],
           external_id: plan.external_id,
           imported_external_id: plan.imported_external_id
         }}
      end
    catch
      :bundle_cancelled -> {:error, :cancelled}
    after
      File.rm_rf(staging)
    end
  end

  # What the import itself made of the target, told before anything is written
  # and before the checks that may still refuse the bundle: whether this run
  # created the workspace record, and whether the workspace held nothing.
  defp announce_target(observe, plan) do
    empty = plan.created or workspace_empty?(plan.tenant_id, plan.workspace_id)
    notify(observe, {:target, %{created: plan.created, empty: empty}})
  end

  defp manifest_rows(manifest),
    do: manifest |> Map.get("tables", []) |> Enum.map(&(&1["rows"] || 0)) |> Enum.sum()

  @doc """
  The Engine's backup dir (`OPTIMAL_BACKUP_DIR`, or `backups` next to the
  database), which holds the tenants' bundle folders and the bundle staging.
  """
  @spec backup_dir() :: String.t()
  def backup_dir, do: backup_base()

  @doc """
  Removes the rows an import wrote, as its `:written_log` names them, and no
  others: a row another writer put in the workspace while the import ran stays.
  With `record: true` the workspace record goes too, when nothing is left in
  the workspace. For an import that did not finish into a target that held
  nothing before it: a create it made, or a merge into an empty workspace.

  The batches go last written first, so a row's dependants (a memory that
  points at it, a table that references it) are gone before it is, with foreign
  keys checked at each commit. It never raises: it answers `:ok`, or
  `{:incomplete, why}` when some of what the log names could not be removed (a
  line of the log was torn by a full disk, or a delete was refused), which the
  caller reports as a partial import.
  """
  @spec discard_written(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:incomplete, term()}
  def discard_written(log_path, tenant_id, workspace_id, opts \\ []) do
    {batches, damaged} = log_batches(log_path)
    refused = discard_batches(batches, log_path, tenant_id, workspace_id)

    if opts[:record] == true and workspace_empty?(tenant_id, workspace_id),
      do:
        Store.raw_query("DELETE FROM workspaces WHERE id = ?1 AND tenant_id = ?2", [
          workspace_id,
          tenant_id
        ])

    if damaged + refused == 0,
      do: :ok,
      else: {:incomplete, %{unreadable: damaged, refused: refused}}
  rescue
    error -> {:incomplete, Exception.message(error)}
  catch
    kind, reason -> {:incomplete, "#{kind}: #{inspect(reason)}"}
  end

  # Where each batch of the log is in the file, newest first, and how many
  # lines could not be read. An append that fails at a full disk leaves a torn
  # last line: it is counted, not read.
  defp log_batches(log_path) do
    if File.regular?(log_path) do
      {batches, damaged, _offset} =
        log_path
        |> File.stream!()
        |> Enum.reduce({[], 0, 0}, fn line, {batches, damaged, offset} ->
          size = byte_size(line)

          case log_table(line) do
            {:ok, table} -> {[{table, offset, size} | batches], damaged, offset + size}
            :error -> {batches, damaged + 1, offset + size}
          end
        end)

      {batches, damaged}
    else
      {[], 0}
    end
  end

  defp log_table(line) do
    case Jason.decode(line) do
      {:ok, %{"table" => table, "columns" => [_ | _], "keys" => keys}}
      when is_binary(table) and is_list(keys) ->
        {:ok, table}

      {:ok, %{"table" => table, "column" => column, "range" => [_, _]}}
      when is_binary(table) and is_binary(column) ->
        {:ok, table}

      _ ->
        :error
    end
  end

  # Returns how many batches could not be removed.
  defp discard_batches([], _log_path, _tenant_id, _workspace_id), do: 0

  defp discard_batches(batches, log_path, tenant_id, workspace_id) do
    case File.open(log_path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          {refused, _scopes} =
            Enum.reduce(batches, {0, %{}}, fn {table, offset, size}, {refused, scopes} ->
              {scope, scopes} = discard_scope(scopes, table, tenant_id, workspace_id)

              if discard_batch(io, table, offset, size, scope),
                do: {refused, scopes},
                else: {refused + 1, scopes}
            end)

          refused
        after
          File.close(io)
        end

      {:error, _reason} ->
        length(batches)
    end
  end

  # A table with a workspace column is also bound to the workspace, whatever
  # the log says.
  defp discard_scope(scopes, table, tenant_id, workspace_id) do
    case scopes do
      %{^table => scope} ->
        {scope, scopes}

      _ ->
        columns = columns(table)

        scope =
          if Enum.any?(columns, &(elem(&1, 0) == "workspace_id")),
            do: scope_clause(table, columns, tenant_id, workspace_id),
            else: {nil, []}

        {scope, Map.put(scopes, table, scope)}
    end
  end

  # True when the batch is gone. All of a batch's statements run in one
  # transaction, with foreign keys checked at its commit: a batch holds a
  # parent and its children, and the chunks of a large batch must not be
  # committed one at a time.
  defp discard_batch(io, table, offset, size, scope) do
    with {:ok, data} <- :file.pread(io, offset, size),
         {:ok, entry} <- Jason.decode(data) do
      statements = discard_statements(table, entry, scope)

      match?(
        {:ok, _},
        Store.transaction(fn txn ->
          {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])

          Enum.reduce_while(statements, {:ok, :removed}, fn {sql, params}, removed ->
            case Store.txn_execute(txn, sql, params) do
              {:ok, _} -> {:cont, removed}
              {:error, _} = error -> {:halt, error}
            end
          end)
        end)
      )
    else
      _ -> false
    end
  rescue
    _error -> false
  end

  # The DELETE statements for one batch of the log: rows by key, in chunks, or
  # the range a table's key took.
  defp discard_statements(table, %{"columns" => cols, "keys" => keys}, {scope_where, scope_params}) do
    chunk = max(1, div(500, length(cols)))
    offset = length(scope_params)

    for keys <- Enum.chunk_every(keys, chunk) do
      {condition, params} =
        case cols do
          [col] ->
            marks = Enum.map_join(1..length(keys), ", ", &"?#{offset + &1}")
            {"#{quote_name(col)} IN (#{marks})", Enum.map(keys, &decode_value(hd(&1)))}

          _ ->
            width = length(cols)

            groups =
              keys
              |> Enum.with_index()
              |> Enum.map_join(" OR ", fn {_key, row} ->
                cols
                |> Enum.with_index(1)
                |> Enum.map_join(" AND ", fn {col, i} ->
                  "#{quote_name(col)} = ?#{offset + row * width + i}"
                end)
                |> then(&"(#{&1})")
              end)

            {"(#{groups})", Enum.flat_map(keys, fn key -> Enum.map(key, &decode_value/1) end)}
        end

      {delete_sql(table, scope_where, condition), scope_params ++ params}
    end
  end

  defp discard_statements(
         table,
         %{"column" => col, "range" => [low, high]},
         {scope_where, scope_params}
       ) do
    offset = length(scope_params)
    column = key_column(col)
    condition = "#{column} >= ?#{offset + 1} AND #{column} <= ?#{offset + 2}"
    [{delete_sql(table, scope_where, condition), scope_params ++ [low, high]}]
  end

  defp delete_sql(table, nil, condition),
    do: "DELETE FROM #{quote_name(table)} WHERE #{condition}"

  defp delete_sql(table, scope_where, condition),
    do: "DELETE FROM #{quote_name(table)} WHERE (#{scope_where}) AND #{condition}"

  # `rowid` is not a declared column, so it is not quoted as one.
  defp key_column("rowid"), do: "rowid"
  defp key_column(name), do: quote_name(name)

  @doc "True when no workspace table holds a row of the workspace."
  @spec workspace_empty?(String.t(), String.t()) :: boolean()
  def workspace_empty?(tenant_id, workspace_id) do
    Enum.all?(workspace_tables(), fn table ->
      {where, params} = scope_clause(table, columns(table), tenant_id, workspace_id)

      match?(
        {:ok, []},
        Store.raw_query("SELECT 1 FROM #{quote_name(table)} WHERE #{where} LIMIT 1", params)
      )
    end)
  end

  @doc """
  Removes what a run that never finished left behind: raw uploads still being
  received (`.upload-*.part`) or received and not yet imported
  (`.upload-*.tar.gz`) in the tenants' bundle folders, and the `bundle-*`
  staging folders of exports and imports last changed more than two hours
  ago. A run removes its own files whatever happens, so these are only left by
  an Engine that stopped mid-way. Nothing else is touched: an upload's name
  starts with a dot, which no bundle name may (`bundle_path/2`), so a retained
  export is never taken for one. The Engine that serves the API calls this at
  boot, before it takes requests. Returns how many were removed.
  """
  @spec sweep_leftovers() :: non_neg_integer()
  def sweep_leftovers do
    uploads =
      Path.wildcard(Path.join([backup_base(), "bundles", "*", ".upload-*.{part,tar.gz}"]),
        match_dot: true
      )

    cutoff = System.os_time(:second) - @stale_staging_seconds

    staged =
      staging_root()
      |> Path.join("bundle-*")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        match?({:ok, %{mtime: mtime}} when mtime < cutoff, File.stat(path, time: :posix))
      end)

    Enum.each(uploads, &File.rm/1)
    Enum.each(staged, &File.rm_rf/1)
    length(uploads) + length(staged)
  end

  @doc """
  The folder a tenant's bundles live in, `<backup dir>/bundles/<tenant>/`
  (the backup dir is `OPTIMAL_BACKUP_DIR`, or `backups` next to the database).
  Exports are written there, a download or an import by name reads only from
  there, and a raw upload is staged there, so one tenant never reaches another
  tenant's bundles. A tenant id that is not a plain file name gets a folder
  named after its SHA-256.
  """
  @spec bundle_dir(String.t()) :: String.t()
  def bundle_dir(tenant_id) when is_binary(tenant_id) do
    dir = Path.join([backup_base(), "bundles", tenant_folder(tenant_id)])
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  The path of the bundle `name` in the tenant's folder. Only a plain bundle
  file name is accepted, so a request can never name another path on the host.
  """
  @spec bundle_path(String.t(), term()) :: {:ok, String.t()} | {:error, :invalid_bundle_name}
  def bundle_path(tenant_id, name) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,200}\.tar\.gz\z/, name),
      do: {:ok, Path.join(bundle_dir(tenant_id), name)},
      else: {:error, :invalid_bundle_name}
  end

  def bundle_path(_tenant_id, _name), do: {:error, :invalid_bundle_name}

  @doc """
  The tenant a bundle was exported from, read from its manifest without
  unpacking the rest. Bundles are packed with the manifest first, so for them
  only the first entry is read; an older bundle is searched for its manifest.
  """
  @spec source_tenant(String.t()) :: {:ok, String.t()} | {:error, term()}
  def source_tenant(path) do
    with {:ok, json} <- manifest_json(path),
         {:ok, %{"format" => @format, "tenant_id" => tenant_id}} when is_binary(tenant_id) <-
           Jason.decode(json) do
      {:ok, tenant_id}
    else
      {:error, {:unreadable_bundle, _}} = error -> error
      _ -> {:error, :not_a_workspace_bundle}
    end
  end

  @doc """
  The workspace a bundle was exported from, read from its manifest the way
  `source_tenant/1` reads the tenant.
  """
  @spec source_workspace(String.t()) :: {:ok, String.t()} | {:error, term()}
  def source_workspace(path) do
    with {:ok, json} <- manifest_json(path),
         {:ok, %{"format" => @format, "workspace" => %{"id" => workspace_id}}}
         when is_binary(workspace_id) <- Jason.decode(json) do
      {:ok, workspace_id}
    else
      {:error, {:unreadable_bundle, _}} = error -> error
      _ -> {:error, :not_a_workspace_bundle}
    end
  end

  @doc "Reads and verifies a bundle's manifest without importing it."
  @spec inspect_bundle(String.t()) :: {:ok, map()} | {:error, term()}
  def inspect_bundle(path) do
    staging = staging_dir()

    try do
      with :ok <- unpack(path, staging),
           {:ok, manifest} <- read_manifest(staging),
           :ok <- verify(manifest, staging) do
        {:ok, manifest}
      end
    after
      File.rm_rf(staging)
    end
  end

  @doc """
  Completes a move on the source Engine: removes the workspace's rows, files
  and filesystem cache, marks it moved, and records where it went.
  `bundle_sha256` must be the hash the target reported after importing, so
  nothing is deleted until the target holds a verified copy.
  """
  @spec finalize_move(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def finalize_move(tenant_id, workspace_id, bundle_sha256, %{"target_url" => target_url} = target)
      when is_binary(bundle_sha256) and is_binary(target_url) do
    with {:ok, workspace} <- Workspace.get(workspace_id),
         true <- workspace.tenant_id == tenant_id || {:error, :not_found},
         :ok <- movable(workspace_id),
         {:ok, [[expected]]} <-
           Store.raw_query(
             "SELECT bundle_sha256 FROM uri_redirects WHERE tenant_id = ?1 AND workspace_id = ?2 AND state = 'pending'",
             [tenant_id, workspace_id]
           ),
         true <- expected == bundle_sha256 || {:error, :checksum_mismatch} do
      # The rows that point at the workspace's decomposition checkpoints go with it, so
      # what the purge has to remove is read first.
      plan = artifact_plan(workspace_id)
      deleted = delete_rows(tenant_id, workspace_id)
      :ok = remove_files(workspace_id)

      cache_purged =
        Cache.summary(Cache.purge_workspace(workspace_id, :move, plan_option(plan)))

      # Only the move keys are written; the archived stub keeps its slugs and
      # its external id value (archiving releases the id itself).
      {:ok, _} =
        Store.raw_query(
          """
          UPDATE workspaces SET status = 'archived',
            metadata = json_set(CASE WHEN json_valid(metadata) THEN metadata ELSE '{}' END,
                                '$.moved_to', ?2, '$.moved_at', ?3)
          WHERE id = ?1
          """,
          [workspace_id, target_url, DateTime.utc_now() |> DateTime.to_iso8601()]
        )

      {:ok, _} =
        Store.raw_query(
          """
          UPDATE uri_redirects SET state = 'moved', target_url = ?3, target_workspace_id = ?4,
            moved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          WHERE tenant_id = ?1 AND workspace_id = ?2
          """,
          [tenant_id, workspace_id, target_url, target["target_workspace_id"] || workspace_id]
        )

      {:ok,
       %{
         workspace_id: workspace_id,
         deleted_rows: deleted,
         cache_purged: cache_purged,
         target_url: target_url
       }}
    else
      {:ok, []} -> {:error, :no_pending_export}
      error -> error
    end
  end

  def finalize_move(_tenant_id, _workspace_id, _sha, _target), do: {:error, :target_url_required}

  defp artifact_plan(workspace_id) do
    case Artifacts.plan(workspace_id) do
      {:ok, plan} -> plan
      {:error, _} -> nil
    end
  end

  defp plan_option(nil), do: []
  defp plan_option(plan), do: [plan: plan]

  @doc """
  Records that `workspace_id` was exported for a move, with the bundle hash
  the target must report back before `finalize_move/4` deletes anything.
  """
  @spec prepare_move(String.t(), String.t(), String.t()) ::
          :ok | {:error, :workspace_directory_shared}
  def prepare_move(tenant_id, workspace_id, bundle_sha256) do
    with :ok <- movable(workspace_id) do
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO uri_redirects (tenant_id, workspace_id, bundle_sha256, state)
          VALUES (?1, ?2, ?3, 'pending')
          ON CONFLICT(tenant_id, workspace_id) DO UPDATE SET bundle_sha256 = excluded.bundle_sha256, state = 'pending'
          """,
          [tenant_id, workspace_id, bundle_sha256]
        )

      :ok
    end
  end

  @doc """
  `:ok` when a move may take the workspace off this Engine, which removes the
  workspace's directory. Only a directory that holds that workspace alone may
  go: a direct child of the Engine root that the root does not use for itself
  (`Filesystem.reserved_names/0`, any hidden name), or `tenants/<tenant>/<slug>`.
  Anything else (the root itself, which is the default workspace's directory,
  a directory the root uses, a hidden one) holds more than the workspace, so the
  move is refused with `:workspace_directory_shared`.
  """
  @spec movable(String.t()) :: :ok | {:error, :workspace_directory_shared}
  def movable(workspace_id) do
    root = Path.expand(root())

    segments =
      root
      |> Filesystem.path(workspace_id)
      |> Path.expand()
      |> Path.relative_to(root)
      |> Path.split()

    if own_directory?(segments), do: :ok, else: {:error, :workspace_directory_shared}
  end

  defp own_directory?([name]),
    do: own_name?(name) and String.downcase(name) not in Filesystem.reserved_names()

  defp own_directory?(["tenants", tenant, slug]), do: own_name?(tenant) and own_name?(slug)
  defp own_directory?(_segments), do: false

  # `_` is where a blank or dot segment lands, so several ids can share it.
  defp own_name?(name), do: name not in ["", "_"] and not String.starts_with?(name, ".")

  @doc """
  Removes the directory a workspace owns, and only that: `:ok` after removing
  it (or finding it gone), `{:error, :workspace_directory_shared}` when the
  directory holds more than the workspace (`movable/1`) and is left alone.
  """
  @spec remove_files(String.t()) :: :ok | {:error, :workspace_directory_shared}
  def remove_files(workspace_id) do
    with :ok <- movable(workspace_id) do
      File.rm_rf(Filesystem.path(root(), workspace_id))
      :ok
    end
  end

  @doc """
  Resolves an `optimal://<workspace>/...` address: `{:local, uri}` when this
  Engine serves it, `{:moved, location}` when the workspace moved, or
  `{:error, :not_found}`. An address written with a slug the workspace holds
  now or held before a rename resolves locally to the address by its id.
  """
  @spec resolve(String.t(), String.t()) :: {:local, String.t()} | {:moved, map()} | {:error, atom()}
  def resolve(tenant_id, "optimal://" <> rest = uri) do
    [workspace_id | path] = String.split(rest, "/", parts: 2)

    case Store.raw_query(
           "SELECT target_url, target_workspace_id FROM uri_redirects WHERE tenant_id = ?1 AND workspace_id = ?2 AND state = 'moved'",
           [tenant_id, workspace_id]
         ) do
      {:ok, [[url, target_workspace]]} ->
        {:moved,
         %{
           "engine_url" => url,
           "workspace_id" => target_workspace,
           "uri" => "optimal://" <> Enum.join([target_workspace | path], "/")
         }}

      _ ->
        case Workspace.get(workspace_id) do
          {:ok, %{tenant_id: ^tenant_id}} -> {:local, uri}
          {:error, :not_found} -> resolve_handle(tenant_id, workspace_id, path)
          _ -> {:error, :not_found}
        end
    end
  end

  def resolve(_tenant_id, _uri), do: {:error, :invalid_uri}

  # An address written with a slug names the workspace by its id, which is
  # then resolved as any address by id is: a workspace that moved answers
  # `{:moved, location}`, not local.
  defp resolve_handle(tenant_id, handle, path) do
    with [^tenant_id, slug] <- String.split(handle, ":", parts: 2),
         {:ok, workspace} <- Workspace.get_by_handle(slug, tenant_id) do
      resolve(tenant_id, "optimal://" <> Enum.join([workspace.id | path], "/"))
    else
      _ -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Export

  defp export_tables(snap, tenant_id, workspace_id, staging, observe) do
    File.mkdir_p!(Path.join(staging, "tables"))

    tenant_id
    |> export_sources(workspace_id)
    |> Enum.map(fn {table, columns, where, params} ->
      write_table({snap, observe}, staging, table, columns, where, params)
    end)
    |> Enum.reject(&(&1["rows"] == 0))
  end

  # Every read an export makes, as `{table, columns, where, params}` in the
  # order it writes them: the workspace's own tables, the child tables read
  # through a parent, the principals of its members and its operating
  # documents. The size estimate reads the same sources.
  defp export_sources(tenant_id, workspace_id) do
    scoped =
      for table <- workspace_tables() -- Map.keys(Migrations.superseded_tables()) do
        columns = columns(table)
        {where, params} = scope_clause(table, columns, tenant_id, workspace_id)

        {table, columns, where, params}
      end

    children =
      for {table, {fk, parent}} <- @children, table_exists?(table) do
        columns = columns(table)
        parent_columns = columns(parent)
        {where, params} = scope_clause(parent, parent_columns, tenant_id, workspace_id)

        {table, columns,
         "#{quote_name(fk)} IN (SELECT id FROM #{quote_name(parent)} WHERE #{where})", params}
      end

    principals =
      {@principals, columns(@principals),
       """
       id IN (
         SELECT principal_id FROM workspace_members WHERE workspace_id = ?1
         UNION SELECT principal_id FROM node_members WHERE workspace_id = ?1
       )
       """, [workspace_id]}

    documents =
      {@documents, columns(@documents),
       "tenant_id = ?1 AND scope_type = 'workspace' AND scope_id = ?2", [tenant_id, workspace_id]}

    scoped ++ children ++ [principals, documents]
  end

  # Writes the rows of `table` that match `where` as JSON lines. The table is
  # read from the snapshot a page at a time and each page is written and
  # hashed before the next is read, so a large workspace is never held in
  # memory.
  defp write_table(reader, staging, table, columns, where, params) do
    file = Path.join([staging, "tables", table <> ".jsonl"])
    names = Enum.map(columns, &elem(&1, 0))

    {rows, hash} =
      File.open!(file, [:write, :binary], fn io ->
        reader
        |> table_rows(table, where, params)
        |> Enum.reduce({0, :crypto.hash_init(:sha256)}, fn row, {count, hash} ->
          line = json_line(names, row)

          IO.binwrite(io, line)
          {count + 1, :crypto.hash_update(hash, line)}
        end)
      end)

    %{
      "name" => table,
      "rows" => rows,
      "columns" => names,
      "sha256" => hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    }
  end

  defp json_line(names, row) do
    names
    |> Enum.zip(row)
    |> Map.new(fn {name, value} -> {name, encode_value(value)} end)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  # Streams the rows of a table that match `where` from the snapshot, one page
  # of `:bundle_export_page_rows` rows at a time (default 1,000). The snapshot
  # does not move, so one statement reads the table from start to end.
  defp table_rows({snap, observe}, table, where, params) do
    snap
    |> ReadSnapshot.stream(
      "SELECT * FROM #{quote_name(table)} WHERE #{where}",
      params,
      export_page_rows()
    )
    |> Stream.each(fn page ->
      page_read(table, length(page))
      observed(observe, {:rows, table, length(page)})
    end)
    |> Stream.concat()
  end

  # Rows read per page of an export (`config :optimal_engine,
  # :bundle_export_page_rows`, default 1,000).
  defp export_page_rows, do: Application.get_env(:optimal_engine, :bundle_export_page_rows, 1_000)

  # Each page read is a `[:optimal_engine, :bundle, :export_page]` event with
  # the rows read and the table.
  defp page_read(table, rows),
    do: :telemetry.execute([:optimal_engine, :bundle, :export_page], %{rows: rows}, %{table: table})

  defp export_files(workspace_id, staging) do
    target = Path.join(staging, "files")
    {source, files} = workspace_files(workspace_id)

    files
    |> Enum.map(fn file ->
      relative = Path.relative_to(file, source)
      destination = Path.join(target, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(file, destination)

      %{
        "path" => relative,
        "bytes" => File.stat!(file).size,
        "sha256" => file_sha256(file)
      }
    end)
    |> Enum.sort_by(& &1["path"])
  end

  # The workspace's folder and the regular files in it. The default
  # workspace's folder is the Engine's own root, so it has none.
  defp workspace_files(workspace_id) do
    source = Filesystem.path(root(), workspace_id)

    files =
      if File.dir?(source) and movable(workspace_id) == :ok do
        source |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)
      else
        []
      end

    {source, files}
  end

  # What the disk must hold for an export: the rows and files staged, the
  # archive made of them (never more than the staged bytes), and a margin. The
  # export's snapshot holds back the database's checkpoints, so what the Engine
  # writes meanwhile grows its WAL. An estimate that cannot be made, or a
  # free-space reading that cannot be had, lets the export go on.
  defp room_to_export(tenant_id, workspace_id) do
    margin = export_margin_bytes()

    with free when is_integer(free) <- free_bytes(staging_root()),
         true <- free >= margin || {:error, :insufficient_storage},
         bytes when is_integer(bytes) <- export_bytes(tenant_id, workspace_id) do
      if free < 2 * bytes + margin, do: {:error, :insufficient_storage}, else: :ok
    else
      {:error, :insufficient_storage} = error -> error
      _unknown -> :ok
    end
  end

  defp export_margin_bytes,
    do: Application.get_env(:optimal_engine, :bundle_export_margin_bytes, 256 * 1024 * 1024)

  @sample_rows 50

  @doc """
  About how many bytes an export of the workspace stages before it packs: its
  rows as JSON lines and its files. A table's share is its row count times the
  average size of a sample of its first rows, encoded as the export encodes
  them, so a workspace is never read whole. Read from the live database, it is
  an estimate: `nil` when it cannot be made.
  """
  @spec export_bytes(String.t(), String.t()) :: non_neg_integer() | nil
  def export_bytes(tenant_id, workspace_id) do
    sources = export_sources(tenant_id, workspace_id)

    rows =
      ReadSnapshot.run(fn snap ->
        Enum.reduce_while(sources, 0, fn source, total ->
          case source_bytes(snap, source) do
            {:ok, bytes} -> {:cont, total + bytes}
            :error -> {:halt, :error}
          end
        end)
      end)

    if is_integer(rows), do: rows + file_bytes(workspace_id)
  end

  defp source_bytes(snap, {table, columns, where, params}) do
    names = Enum.map(columns, &elem(&1, 0))
    from = "FROM #{quote_name(table)} WHERE #{where}"

    with {:ok, [[count]]} <- ReadSnapshot.query(snap, "SELECT COUNT(*) " <> from, params),
         true <- count > 0 || {:empty, 0},
         {:ok, [_ | _] = sample} <-
           ReadSnapshot.query(snap, "SELECT * " <> from <> " LIMIT #{@sample_rows}", params) do
      bytes = sample |> Enum.map(&byte_size(json_line(names, &1))) |> Enum.sum()
      {:ok, div(bytes * count, length(sample))}
    else
      {:empty, 0} -> {:ok, 0}
      _failed -> :error
    end
  end

  defp file_bytes(workspace_id) do
    {_source, files} = workspace_files(workspace_id)
    Enum.sum(for file <- files, {:ok, %{size: size}} <- [File.stat(file)], do: size)
  end

  # ---------------------------------------------------------------------------
  # Import

  defp read_manifest(staging) do
    with {:ok, json} <- File.read(Path.join(staging, "manifest.json")),
         {:ok, %{"format" => @format, "version" => @version} = manifest} <- Jason.decode(json) do
      {:ok, manifest}
    else
      {:ok, _other} -> {:error, :not_a_workspace_bundle}
      _ -> {:error, :manifest_unreadable}
    end
  end

  @doc """
  Exactly the tables an export can write, and so the only ones an import
  accepts: the workspace's own tables, the child tables read through a parent,
  and the registry tables an export selects by membership or scope (the
  principals of the workspace's members, its operating documents).
  """
  @spec exportable_tables() :: [String.t()]
  def exportable_tables do
    Enum.uniq(workspace_tables() ++ Map.keys(@children) ++ [@principals, @documents])
  end

  # A bundle carries a workspace's data, and only that. Anyone can write one
  # and sign its manifest, so the tables it names are checked against the ones
  # this Engine exports: never a table it keeps for itself (connectors and their
  # credentials, jobs, sync state) and never one the manifest invents.
  #
  # What a bundle may still do within those tables: add rows to the workspace it
  # creates or merges into, and add principals to the importing tenant (every
  # principals row is written with that tenant, and an id the Engine already has
  # keeps its existing row).
  defp permitted(%{"tables" => tables}) when is_list(tables) do
    allowed = exportable_tables()

    refused =
      for table <- tables, name = table_name(table), name not in allowed, do: name

    if refused == [], do: :ok, else: {:error, {:table_not_allowed, Enum.sort(refused)}}
  end

  defp permitted(_manifest), do: {:error, :manifest_unreadable}

  defp table_name(%{"name" => name}) when is_binary(name), do: name
  defp table_name(_table), do: "(unnamed)"

  defp verify(manifest, staging) do
    claimed = manifest["bundle_sha256"]
    recomputed = manifest |> Map.delete("bundle_sha256") |> CanonicalJSON.hash()

    table_ok =
      Enum.all?(manifest["tables"], fn table ->
        file_sha256(Path.join([staging, "tables", table["name"] <> ".jsonl"])) == table["sha256"]
      end)

    files_ok =
      Enum.all?(manifest["files"], fn file ->
        file_sha256(Path.join([staging, "files", file["path"]])) == file["sha256"]
      end)

    cond do
      claimed != recomputed -> {:error, :manifest_checksum_mismatch}
      not table_ok -> {:error, :table_checksum_mismatch}
      not files_ok -> {:error, :file_checksum_mismatch}
      true -> :ok
    end
  end

  defp same_tenant(%{"tenant_id" => tenant_id}, tenant_id, _opts), do: :ok

  defp same_tenant(_manifest, _tenant_id, opts) do
    if opts[:cross_tenant] == true, do: :ok, else: {:error, :bundle_from_another_tenant}
  end

  defp plan(manifest, tenant_id, opts) do
    with {:ok, requested} <- requested_workspace_id(opts[:workspace_id], tenant_id) do
      plan_target(manifest, tenant_id, Keyword.put(opts, :workspace_id, requested))
    end
  end

  # A workspace id names its tenant (`<tenant>:<slug>`), so a caller that asks
  # for one may not take another tenant's name; a bare slug gets this tenant's.
  # Either way the id is one `Workspace.check_id/2` accepts for the tenant.
  defp requested_workspace_id(nil, _tenant_id), do: {:ok, nil}

  defp requested_workspace_id(id, tenant_id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [^tenant_id, slug] when slug != "" -> checked_id(id, tenant_id)
      [_other_tenant, _slug] -> {:error, :workspace_id_not_in_tenant}
      [slug] when slug != "" -> checked_id(tenant_id <> ":" <> slug, tenant_id)
      _blank -> {:error, :invalid_workspace_id}
    end
  end

  defp requested_workspace_id(_id, _tenant_id), do: {:error, :invalid_workspace_id}

  defp checked_id(id, tenant_id), do: with(:ok <- Workspace.check_id(id, tenant_id), do: {:ok, id})

  defp plan_target(manifest, tenant_id, opts) do
    source = manifest["workspace"]
    mode = Keyword.get(opts, :mode, :create)
    target_id = opts[:workspace_id] || target_id(source, tenant_id, mode)

    # A renamed workspace keeps its id and its current slug; any other
    # target takes the slug its id names.
    target_slug =
      if target_id == source["id"],
        do: source["slug"],
        else: target_id |> String.split(":", parts: 2) |> List.last()

    # The target is a workspace id of the tenant, and a bundle that carries
    # files lands in a directory that holds that workspace alone: both are
    # known before the first row is written.
    with :ok <- Workspace.check_id(target_id, tenant_id),
         :ok <- own_directory_for_files(manifest, target_id) do
      plan_workspace(manifest, tenant_id, opts, target_id, target_slug)
    end
  end

  defp plan_workspace(manifest, tenant_id, opts, target_id, target_slug) do
    source = manifest["workspace"]
    mode = Keyword.get(opts, :mode, :create)

    case {Workspace.get(target_id), mode} do
      {{:ok, _existing}, :create} ->
        {:error, :workspace_exists}

      {{:ok, existing}, :merge} ->
        if existing.tenant_id == tenant_id,
          do:
            {:ok,
             %{
               workspace_id: target_id,
               tenant_id: tenant_id,
               mode: :merge,
               created: false,
               source: source,
               external_id: existing.external_id,
               imported_external_id: nil
             }},
          else: {:error, :workspace_exists}

      {{:error, :not_found}, _mode} ->
        metadata = source["metadata"] || %{}

        attrs = %{
          id: target_id,
          tenant_id: tenant_id,
          slug: target_slug,
          name: source["name"] || target_slug,
          description: source["description"],
          external_id: source["external_id"] || metadata["external_id"],
          # Slugs the source held are reserved on the source Engine only.
          metadata:
            metadata
            |> Map.drop(["previous_slugs", "external_id"])
            |> Map.put("imported_from", source["id"]),
          organization_id:
            opts[:organization_id] || OptimalEngine.Organization.default_for(tenant_id)
        }

        case create_keeping_external_id(attrs) do
          {:ok, workspace, set_aside} ->
            {:ok,
             %{
               workspace_id: target_id,
               tenant_id: tenant_id,
               mode: mode,
               created: true,
               source: source,
               external_id: workspace.external_id,
               imported_external_id: set_aside
             }}

          error ->
            error
        end
    end
  end

  # An external id names at most one active workspace of a tenant (an
  # archived holder released it), so a copy into a tenant where an active
  # workspace holds it, or a bundle carrying a malformed one, gets none: the
  # copy keeps it as `imported_external_id` and the import summary reports it.
  defp create_keeping_external_id(%{external_id: nil} = attrs) do
    with {:ok, workspace} <- Workspace.create(attrs), do: {:ok, workspace, nil}
  end

  defp create_keeping_external_id(%{external_id: external_id} = attrs) do
    case Workspace.create(attrs) do
      {:ok, workspace} ->
        {:ok, workspace, nil}

      {:error, reason} when reason in [:external_id_taken, :invalid_external_id] ->
        aside = %{
          attrs
          | external_id: nil,
            metadata: Map.put(attrs.metadata, "imported_external_id", external_id)
        }

        with {:ok, workspace} <- Workspace.create(aside), do: {:ok, workspace, external_id}

      error ->
        error
    end
  end

  # A workspace keeps its id when it lands in the tenant it came from and the
  # id is free there (or, for a merge, already the target): a renamed
  # workspace's id is not the one its slug derives, and links name the id.
  # Anywhere else the id derives from the slug, as for a new workspace.
  defp target_id(source, tenant_id, mode) do
    derived =
      if tenant_id == "default",
        do: "default:" <> source["slug"],
        else: "#{tenant_id}:#{source["slug"]}"

    id = source["id"]

    # The manifest is data a bundle's writer supplies: its id is used only
    # when it is an id the importing tenant could have (`Workspace.check_id/2`),
    # else the id derives from the slug like any other target's.
    same_tenant? = is_binary(id) and Workspace.check_id(id, tenant_id) == :ok

    cond do
      not same_tenant? -> derived
      mode == :merge -> id
      match?({:error, :not_found}, Workspace.get(id)) -> id
      true -> derived
    end
  end

  # The tenant's default organization, created on first use.
  # Every column a bundle carries must exist in the target Engine.
  defp compatible(manifest, _staging) do
    missing =
      for table <- manifest["tables"], not fits?(table) do
        table["name"]
      end

    if missing == [], do: :ok, else: {:error, {:incompatible_tables, missing}}
  end

  defp fits?(table) do
    target = target_table(table["name"])

    table_exists?(target) and
      table["columns"] -- Enum.map(columns(target), &elem(&1, 0)) == []
  end

  defp write_rows(manifest, staging, plan, opts) do
    insert = if plan.mode == :merge, do: "INSERT OR IGNORE", else: "INSERT"
    batch_rows = opts |> Keyword.get(:batch_rows, @batch_rows) |> max(1)
    names = Enum.map(manifest["tables"], & &1["name"])

    # Schema reads go through the Store process, so they happen before any
    # transaction (which runs inside that process).
    drops = Map.new(names, &{&1, autoincrement_key(columns(target_table(&1)))})
    keys = Map.new(names, &{&1, foreign_keys(target_table(&1))})

    column_names =
      Map.new(names, &{&1, MapSet.new(columns(target_table(&1)), fn {column, _, _} -> column end)})

    files =
      {Filesystem.path(root(), plan.workspace_id), MapSet.new(manifest["files"], & &1["path"])}

    # What each table's rows are known by, for the log of what this run wrote.
    trackers = Map.new(names, &{&1, tracker(&1, columns(target_table(&1)))})
    record = recorder(opts[:written_log])

    # Every table is checked before any is written, so a refused bundle leaves
    # nothing behind.
    result =
      with :ok <- check_tables(names, staging, column_names, plan) do
        names
        |> parents_first(keys)
        |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, counts} ->
          target = target_table(name)

          verb =
            if name in @keep_existing or target != name, do: "INSERT OR IGNORE", else: insert

          rows =
            Path.join([staging, "tables", name <> ".jsonl"])
            |> File.stream!()
            |> Stream.map(&Jason.decode!/1)
            |> Stream.map(fn row ->
              row
              |> rewrite(name, plan, column_names[name])
              |> relocate_files(name, files)
              |> Map.drop(drops[name])
            end)
            |> self_parents_first(Enum.filter(keys[name], &(&1.table == name)))

          case write_batches(target, rows, verb, batch_rows, opts[:observe], trackers[name], record) do
            {:ok, written} -> {:cont, {:ok, Map.put(counts, name, written)}}
            {:error, :cancelled} -> {:halt, {:error, :cancelled}}
            {:error, reason} -> {:halt, {:error, {:import_failed, name, reason}}}
          end
        end)
      end

    with {:error, _} = error <- result do
      if plan.mode == :create, do: undo_import(plan, opts[:written_log])
      error
    end
  end

  # Each batch is its own transaction with foreign keys checked at its commit;
  # parents are always written in an earlier batch than their children.
  defp write_batches(name, rows, verb, batch_rows, observe, tracker, record) do
    rows
    |> Stream.chunk_every(batch_rows)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, total} ->
      with {:ok, written, entry} <- write_batch(name, batch, verb, tracker),
           :ok <- record.(name, entry),
           :ok <- import_batch(name, length(batch)),
           :ok <- batch_written(observe, name, length(batch)) do
        {:cont, {:ok, total + written}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Each batch written is a `[:optimal_engine, :bundle, :import_batch]` event
  # with the rows and the table.
  defp import_batch(table, rows) do
    :telemetry.execute([:optimal_engine, :bundle, :import_batch], %{rows: rows}, %{table: table})
  end

  # A batch is the point where an observed import reports its rows and may
  # be stopped; a stopped create removes what it wrote, like a failed one.
  defp batch_written(nil, _name, _rows), do: :ok

  defp batch_written(observe, name, rows) do
    case observe.({:rows, name, rows}) do
      :cancel -> {:error, :cancelled}
      _ -> :ok
    end
  end

  # A batch is one transaction, and the Store runs it alone, so what it
  # inserted is told by the keys of its rows, or by how far a table's key
  # moved. Returns the number written and the log entry for the batch.
  defp write_batch(name, batch, verb, tracker) do
    result =
      Store.transaction(fn txn ->
        {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])
        before = high_water(txn, name, tracker)

        {written, keys} =
          Enum.reduce(batch, {0, []}, fn row, {count, keys} ->
            names = Map.keys(row)

            placeholders =
              names |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

            {:ok, changed} =
              Store.txn_execute(
                txn,
                "#{verb} INTO #{quote_name(name)} (#{Enum.map_join(names, ", ", &quote_name/1)}) VALUES (#{placeholders})",
                Enum.map(names, &decode_value(row[&1]))
              )

            {count + changed, if(changed > 0, do: key_of(tracker, row, keys), else: keys)}
          end)

        {:ok, {written, entry(txn, name, tracker, before, Enum.reverse(keys))}}
      end)

    with {:ok, {written, entry}} <- result, do: {:ok, written, entry}
  rescue
    error -> {:error, Exception.message(error)}
  end

  # A table with a single INTEGER key lets the target assign it, and a table
  # with no key has only its rowid: both are told by how far the key moved.
  # Otherwise the rows are told by their keys. The principals and operation
  # definitions a bundle brings are shared by the tenant, not the workspace's.
  defp tracker(name, _columns) when name in @keep_existing, do: nil

  defp tracker(_name, columns) do
    case autoincrement_key(columns) do
      [column] ->
        {:range, column}

      [] ->
        case columns |> Enum.filter(&(elem(&1, 2) > 0)) |> Enum.sort_by(&elem(&1, 2)) do
          [] -> {:range, "rowid"}
          keyed -> {:keys, Enum.map(keyed, &elem(&1, 0))}
        end
    end
  end

  defp high_water(_txn, _name, {:keys, _}), do: nil
  defp high_water(_txn, _name, nil), do: nil

  defp high_water(txn, name, {:range, column}) do
    {:ok, [[mark]]} =
      Store.txn_query(
        txn,
        "SELECT COALESCE(MAX(#{key_column(column)}), 0) FROM #{quote_name(name)}",
        []
      )

    mark
  end

  defp key_of({:keys, columns}, row, keys), do: [Enum.map(columns, &Map.get(row, &1)) | keys]
  defp key_of(_tracker, _row, keys), do: keys

  defp entry(_txn, _name, nil, _before, _keys), do: nil
  defp entry(_txn, _name, {:keys, _}, _before, []), do: nil

  defp entry(_txn, _name, {:keys, columns}, _before, keys),
    do: %{"columns" => columns, "keys" => keys}

  defp entry(txn, name, {:range, column} = tracker, before, _keys) do
    after_mark = high_water(txn, name, tracker)

    if after_mark > before,
      do: %{"column" => column, "range" => [before + 1, after_mark]},
      else: nil
  end

  # Appends one line per batch to the log, after the batch is committed: a crash
  # between the two leaves rows unlogged, never a row logged that was not written.
  defp recorder(nil), do: fn _name, _entry -> :ok end

  defp recorder(path) do
    # A log starts empty (a stale one would name rows this run did not write),
    # and it names rows by key, so like the job's other private files it is the
    # Engine's alone.
    File.write(path, "")
    File.chmod(path, 0o600)

    fn
      _name, nil ->
        :ok

      name, entry ->
        line = Jason.encode!(Map.put(entry, "table", name)) <> "\n"

        case File.write(path, line, [:append]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:written_log, reason}}
        end
    end
  end

  # A failed create import leaves nothing behind: the rows it wrote, then the
  # workspace record it made, if nothing else is in the workspace.
  defp undo_import(plan, log_path) do
    case discard_written(log_path, plan.tenant_id, plan.workspace_id,
           record: plan[:created] == true
         ) do
      :ok ->
        :ok

      {:incomplete, why} ->
        Logger.error(
          "[WorkspaceBundle] could not remove all of the failed import of #{plan.workspace_id}: #{inspect(why)}"
        )
    end
  end

  # Tables a table points at come first; tables outside the bundle and
  # self-references do not constrain the order, and a cycle keeps its tables
  # in bundle order.
  defp parents_first(names, keys) do
    in_bundle = MapSet.new(names)

    deps =
      Map.new(names, fn name ->
        parents =
          for %{table: parent} <- keys[name], parent != name, parent in in_bundle, do: parent

        {name, MapSet.new(parents)}
      end)

    order(names, deps, MapSet.new(), [])
  end

  defp order([], _deps, _placed, acc), do: Enum.reverse(acc)

  defp order(pending, deps, placed, acc) do
    case Enum.split_with(pending, &MapSet.subset?(deps[&1], placed)) do
      {[], [first | rest]} -> order(rest, deps, MapSet.put(placed, first), [first | acc])
      {ready, rest} -> order(rest, deps, Enum.into(ready, placed), Enum.reverse(ready) ++ acc)
    end
  end

  # Rows of a table that points at itself (a memory's parent memory, a node's
  # parent node) are ordered so a parent precedes its children; other tables
  # stream through unchanged.
  defp self_parents_first(rows, []), do: rows

  defp self_parents_first(rows, self_keys) do
    rows = Enum.to_list(rows)
    ids = for row <- rows, key <- self_keys, into: MapSet.new(), do: row[key.to]
    place_rows(rows, self_keys, ids, MapSet.new(), [])
  end

  defp place_rows([], _keys, _ids, _placed, acc), do: Enum.reverse(acc)

  defp place_rows(pending, keys, ids, placed, acc) do
    ready? = fn row ->
      Enum.all?(keys, fn key ->
        parent = row[key.from]
        is_nil(parent) or not MapSet.member?(ids, parent) or MapSet.member?(placed, parent)
      end)
    end

    case Enum.split_with(pending, ready?) do
      {[], [first | rest]} ->
        place_rows(rest, keys, ids, mark(placed, first, keys), [first | acc])

      {ready, rest} ->
        placed = Enum.reduce(ready, placed, &mark(&2, &1, keys))
        place_rows(rest, keys, ids, placed, Enum.reverse(ready) ++ acc)
    end
  end

  defp mark(placed, row, keys), do: Enum.reduce(keys, placed, &MapSet.put(&2, row[&1.to]))

  defp foreign_keys(table) do
    case Store.raw_query(
           "SELECT \"table\", \"from\", \"to\" FROM pragma_foreign_key_list(?1)",
           [table]
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [parent, from, to] -> %{table: parent, from: from, to: to} end)

      _ ->
        []
    end
  end

  # Every row is written into the importing tenant and the workspace it makes,
  # whatever the bundle says, and whether or not it says anything: a column the
  # table has is always set, so a missing key cannot fall to the column's
  # default. An operating document is always the workspace's, never the tenant's.
  defp rewrite(row, name, plan, columns) do
    row
    |> scope_column(columns, "tenant_id", plan.tenant_id)
    |> scope_column(columns, "workspace_id", plan.workspace_id)
    |> document_scope(name, plan)
  end

  defp scope_column(row, columns, column, value) do
    if MapSet.member?(columns, column), do: Map.put(row, column, value), else: row
  end

  defp document_scope(row, "operating_documents", plan),
    do: row |> Map.put("scope_type", "workspace") |> Map.put("scope_id", plan.workspace_id)

  defp document_scope(row, _name, _plan), do: row

  # A stored file's row names it by its path on the source Engine's disk. The
  # import copied the file under the target workspace's folder, so a local path
  # that ends in one of the bundle's files is pointed at that copy; an object
  # store URI, and a path to a file the bundle does not carry, stay as they are.
  defp relocate_files(row, name, {folder, bundled}) do
    case Map.fetch(@file_columns, name) do
      {:ok, columns} ->
        row
        |> Map.new(fn
          {column, value} when is_binary(value) ->
            cond do
              column in columns -> {column, relocated(value, folder, bundled)}
              column == "metadata" -> {column, relocated_metadata(value, folder, bundled)}
              true -> {column, value}
            end

          pair ->
            pair
        end)

      :error ->
        row
    end
  end

  defp relocated_metadata(json, folder, bundled) do
    case Jason.decode(json) do
      {:ok, metadata} when is_map(metadata) ->
        moved =
          Map.new(metadata, fn
            {key, value} when key in @file_metadata_keys and is_binary(value) ->
              {key, relocated(value, folder, bundled)}

            pair ->
              pair
          end)

        if moved == metadata, do: json, else: Jason.encode!(moved)

      _ ->
        json
    end
  end

  # The longest tail of the path that is one of the bundle's files.
  defp relocated(path, folder, bundled) do
    if Path.type(path) == :absolute do
      segments = Path.split(path)

      found =
        Enum.find_value(1..(length(segments) - 1)//1, fn drop ->
          tail = segments |> Enum.drop(drop) |> Path.join()
          if MapSet.member?(bundled, tail), do: tail
        end)

      if found, do: Path.join(folder, found), else: path
    else
      path
    end
  end

  # What a table's rows may be, checked before any of them is written. Every key
  # must be a column of the table, spelled as the table spells it: SQLite matches
  # column names without regard to case and takes the first of two that match, so
  # a key that only looks like a column could carry a value past `rewrite/4`.
  # And a member of the workspace must be a principal of the importing tenant.
  defp check_tables(names, staging, column_names, plan) do
    Enum.find_value(names, :ok, fn name ->
      path = Path.join([staging, "tables", name <> ".jsonl"])

      with :ok <- check_columns(path, column_names[name]),
           :ok <- if(name in @member_tables, do: check_members(path, plan.tenant_id), else: :ok) do
        nil
      else
        {:error, reason} -> {:error, {:import_failed, name, reason}}
      end
    end)
  end

  defp check_columns(path, columns) do
    known? =
      path
      |> File.stream!()
      |> Enum.all?(fn line ->
        case Jason.decode(line) do
          {:ok, row} when is_map(row) -> Enum.all?(Map.keys(row), &MapSet.member?(columns, &1))
          _not_a_row -> false
        end
      end)

    if known?, do: :ok, else: {:error, :unknown_column}
  end

  defp check_members(path, tenant_id) do
    foreign? =
      path
      |> File.stream!()
      |> Stream.map(&(&1 |> Jason.decode!() |> Map.get("principal_id")))
      |> Stream.reject(&is_nil/1)
      |> Stream.uniq()
      |> Stream.chunk_every(200)
      |> Enum.any?(&principals_of_another_tenant?(&1, tenant_id))

    if foreign?, do: {:error, :foreign_principal}, else: :ok
  end

  defp principals_of_another_tenant?(ids, tenant_id) do
    marks = Enum.map_join(1..length(ids), ", ", &"?#{&1}")

    {:ok, rows} =
      Store.raw_query(
        "SELECT 1 FROM principals WHERE id IN (#{marks}) AND tenant_id != ?#{length(ids) + 1} LIMIT 1",
        ids ++ [tenant_id]
      )

    rows != []
  end

  # The plan has already refused a bundle with a file outside the workspace or
  # a directory that is not the workspace's own; both are checked again here,
  # because this is the function that writes.
  defp write_files(manifest, staging, plan) do
    with :ok <- own_directory_for_files(manifest, plan.workspace_id),
         :ok <- files_inside(manifest) do
      target = Filesystem.path(root(), plan.workspace_id)

      Enum.each(manifest["files"] || [], fn file ->
        destination = Path.join(target, file["path"])
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(Path.join([staging, "files", file["path"]]), destination)
      end)

      {:ok, length(manifest["files"] || [])}
    end
  end

  # A bundle's files are named by relative paths under the workspace's
  # directory. One that is absolute, empty, climbs out of it (`../x`) or holds
  # a NUL byte refuses the bundle: the importer never skips such a file and
  # carries on, and never reads one while verifying.
  defp files_inside(manifest) do
    inside? = fn
      %{"path" => path} when is_binary(path) ->
        not String.contains?(path, <<0>>) and
          match?({:ok, safe} when safe != "", Path.safe_relative(path))

      _entry ->
        false
    end

    if Enum.all?(manifest["files"] || [], inside?),
      do: :ok,
      else: {:error, :file_path_outside_workspace}
  end

  # A bundle that carries files needs a directory that holds its workspace
  # alone (`movable/1`): never the Engine root, a directory the root uses, or
  # a hidden one.
  defp own_directory_for_files(manifest, workspace_id) do
    if (manifest["files"] || []) == [], do: :ok, else: movable(workspace_id)
  end

  defp delete_rows(tenant_id, workspace_id) do
    # Statements are planned before the transaction: schema reads go through
    # the Store process the transaction runs in.
    child_statements =
      for {table, {fk, parent}} <- @children, table_exists?(table) do
        {where, params} = scope_clause(parent, columns(parent), tenant_id, workspace_id)

        {"DELETE FROM #{quote_name(table)} WHERE #{quote_name(fk)} IN (SELECT id FROM #{quote_name(parent)} WHERE #{where})",
         params}
      end

    scoped_statements =
      for table <- workspace_tables() do
        {where, params} = scope_clause(table, columns(table), tenant_id, workspace_id)
        {"DELETE FROM #{quote_name(table)} WHERE #{where}", params}
      end

    {:ok, total} =
      Store.transaction(fn txn ->
        {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])

        total =
          Enum.reduce(child_statements ++ scoped_statements, 0, fn {sql, params}, acc ->
            {:ok, n} = Store.txn_execute(txn, sql, params)
            acc + n
          end)

        {:ok, total}
      end)

    total
  end

  # ---------------------------------------------------------------------------
  # Schema helpers

  defp workspace_tables do
    {:ok, rows} =
      Store.raw_query("SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name", [])

    for [name, sql] <- rows,
        not Capture.bundle_excluded?(name),
        not String.starts_with?(name, "sqlite_"),
        not (is_binary(sql) and String.contains?(sql, "VIRTUAL")),
        not fts_shadow?(name),
        Enum.any?(columns(name), &(elem(&1, 0) == "workspace_id")) do
      name
    end
  end

  defp fts_shadow?(name), do: Regex.match?(~r/_fts_(data|idx|docsize|config|content)\z/, name)

  defp columns(table) do
    {:ok, rows} =
      Store.raw_query("SELECT name, type, pk FROM pragma_table_info(?1) ORDER BY cid", [table])

    Enum.map(rows, fn [name, type, pk] -> {name, String.upcase(type || ""), pk} end)
  end

  # Rows a bundle carries for a superseded table go to its successor.
  defp target_table(name), do: Map.get(Migrations.superseded_tables(), name, name)

  defp table_exists?(table) do
    match?(
      {:ok, [_]},
      Store.raw_query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", [table])
    )
  end

  # A single INTEGER PRIMARY KEY is a rowid alias: let the target assign it.
  defp autoincrement_key(columns) do
    case Enum.filter(columns, fn {_name, _type, pk} -> pk > 0 end) do
      [{name, "INTEGER", _}] -> [name]
      _ -> []
    end
  end

  # A table with a tenant column is bound to the tenant. A mention written
  # before it recorded one has none, and belongs to the workspace, which is
  # the tenant's.
  defp scope_clause(table, columns, tenant_id, workspace_id) do
    cond do
      not Enum.any?(columns, &(elem(&1, 0) == "tenant_id")) ->
        {"workspace_id = ?1", [workspace_id]}

      # A superseded table's tenant_id was never written, so its rows are found
      # by workspace alone (workspace ids are unique across tenants).
      Map.has_key?(Migrations.superseded_tables(), table) ->
        {"workspace_id = ?1", [workspace_id]}

      table == "entity_mentions" ->
        {"workspace_id = ?1 AND (tenant_id = ?2 OR tenant_id IS NULL)", [workspace_id, tenant_id]}

      true ->
        {"workspace_id = ?1 AND tenant_id = ?2", [workspace_id, tenant_id]}
    end
  end

  defp quote_name(name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
      do: ~s("#{name}"),
      else: raise(ArgumentError, "unsafe identifier #{inspect(name)}")
  end

  defp encode_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$b64" => Base.encode64(value)}
  end

  defp encode_value(value), do: value

  defp decode_value(%{"$b64" => data}), do: {:blob, Base.decode64!(data)}
  defp decode_value(value), do: value

  # ---------------------------------------------------------------------------
  # Packing

  defp pack(staging, path) do
    File.mkdir_p!(Path.dirname(path))

    # The manifest goes first, so its tenant and checksums can be read
    # without decompressing the rest (source_tenant/1).
    entries =
      staging
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, staging))
      |> Enum.sort_by(&(&1 != "manifest.json"))
      |> Enum.map(fn relative ->
        {String.to_charlist(relative), String.to_charlist(Path.join(staging, relative))}
      end)

    :erl_tar.create(String.to_charlist(path), entries, [:compressed])
  end

  # The manifest of a bundle: the first entry when it is named manifest.json
  # (a ustar header of 512 bytes, then the file), otherwise found by erl_tar.
  defp manifest_json(path) do
    first =
      case File.open(path, [:read, :binary, :compressed]) do
        {:ok, io} ->
          try do
            with <<name::binary-size(100), _::binary-size(24), size::binary-size(12),
                   _::binary-size(376)>> <- IO.binread(io, 512),
                 "manifest.json" <- name |> :binary.split(<<0>>) |> hd(),
                 {bytes, _} <-
                   size |> :binary.split(<<0>>) |> hd() |> String.trim() |> Integer.parse(8),
                 json when is_binary(json) and byte_size(json) == bytes <- IO.binread(io, bytes) do
              {:ok, json}
            else
              _ -> :search
            end
          after
            File.close(io)
          end

        {:error, reason} ->
          {:error, {:unreadable_bundle, reason}}
      end

    case first do
      :search -> search_manifest(path)
      found -> found
    end
  end

  defp search_manifest(path) do
    case :erl_tar.extract(String.to_charlist(path), [
           :compressed,
           :memory,
           {:files, [~c"manifest.json"]}
         ]) do
      {:ok, [{_name, json}]} -> {:ok, json}
      {:ok, _} -> {:error, :not_a_workspace_bundle}
      {:error, reason} -> {:error, {:unreadable_bundle, reason}}
    end
  end

  defp unpack(path, staging) do
    case :erl_tar.extract(String.to_charlist(path), [
           :compressed,
           {:cwd, String.to_charlist(staging)}
         ]) do
      :ok -> if escaped?(staging), do: {:error, :unsafe_bundle}, else: :ok
      {:error, reason} -> {:error, {:unreadable_bundle, reason}}
    end
  end

  @doc false
  # Bytes free on the filesystem holding `dir`, or nil when it cannot be read.
  @spec free_bytes(String.t()) :: non_neg_integer() | nil
  def free_bytes(dir) do
    File.mkdir_p(dir)

    case System.cmd("df", ["-Pk", dir], stderr_to_stdout: true) do
      {out, 0} ->
        with [_header, line | _] <- String.split(out, "\n", trim: true),
             [_fs, _blocks, _used, available | _] <- String.split(line),
             {kb, ""} <- Integer.parse(available) do
          kb * 1_024
        else
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # erl_tar refuses absolute and parent-relative names; still confirm nothing
  # landed outside the staging directory through a link.
  defp escaped?(staging) do
    staging
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.any?(fn file ->
      case File.lstat(file) do
        {:ok, %{type: :symlink}} -> true
        _ -> false
      end
    end)
  end

  # Exports and imports unpack in a folder of their own under the Engine's
  # backup dir, on its data volume, rather than in the shared temp dir, so the
  # Engine can clear what a stopped run left there without touching another's.
  defp staging_dir do
    dir = Path.join(staging_root(), "bundle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp staging_root, do: Path.join(backup_base(), "staging")

  defp root, do: Application.get_env(:optimal_engine, :root_path, File.cwd!())

  defp backup_base do
    case Application.get_env(:optimal_engine, :backup_dir) do
      dir when is_binary(dir) and dir != "" ->
        Path.expand(dir)

      _ ->
        Application.get_env(:optimal_engine, :db_path, ".optimal/index.db")
        |> Path.expand()
        |> Path.dirname()
        |> Path.join("backups")
    end
  end

  defp tenant_folder(tenant_id) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, tenant_id),
      do: tenant_id,
      else: "tenant-" <> (:crypto.hash(:sha256, tenant_id) |> Base.encode16(case: :lower))
  end

  # Hashes a file a megabyte at a time; nil when it is missing or unreadable.
  defp file_sha256(path) do
    if File.regular?(path) do
      path
      |> File.stream!([], 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    end
  end

  # The replication ledger's high-water mark in the snapshot: a replica
  # seeded from this bundle pulls from here.
  defp ledger_mark(snap, tenant_id, workspace_id) do
    case ReadSnapshot.query(
           snap,
           "SELECT COALESCE(MAX(sequence), 0) FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2",
           [tenant_id, workspace_id]
         ) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  defp engine_version, do: Application.spec(:optimal_engine, :vsn) |> to_string()

  defp current_migration do
    case Store.raw_query("SELECT MAX(version) FROM schema_migrations", []) do
      {:ok, [[n]]} -> n
      _ -> nil
    end
  end
end
