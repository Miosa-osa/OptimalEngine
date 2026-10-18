defmodule OptimalEngine.Backup do
  @moduledoc """
  Backup + restore for the engine's SQLite database.

  SQLite's online backup uses `VACUUM INTO 'target.db'` — atomic,
  safe to run while the engine keeps serving, and produces a
  self-contained single file with no WAL trail attached. That one
  file plus any migration metadata is the complete engine state.

  ## Usage

      # Live backup while the engine runs
      OptimalEngine.Backup.create("/var/backups/engine-2026-01-05.db")

      # Restore over the live database (requires supervisor shutdown first —
      # we fail loudly if it's still up)
      OptimalEngine.Backup.restore("/var/backups/engine-2026-01-05.db")

      # Restore a verified copy into a separate path while the engine runs
      OptimalEngine.Backup.restore("/var/backups/engine-2026-01-05.db",
        target: "/tmp/engine-restored.db"
      )

  The backup is not encrypted. Treat the file as sensitive —
  connector credentials live in it (encrypted envelope, but the
  envelope key lives outside the DB by design).
  """

  require Logger

  alias OptimalEngine.Storage.S3
  alias OptimalEngine.Store

  @type backup_result :: %{
          id: String.t(),
          target: String.t(),
          size_bytes: non_neg_integer(),
          rows_backed_up: non_neg_integer(),
          duration_ms: non_neg_integer(),
          checksum_sha256: String.t(),
          integrity_status: String.t(),
          offsite: map() | nil
        }

  @doc """
  Create a backup at `target_path`. Runs online — the engine keeps
  serving throughout. Parent directory must exist.

  Options:

    * `:offsite` — when true, copy the verified backup to the S3 object store
      after it is cataloged. The local backup is complete either way; a failed
      ship is reported in `:offsite` with `status: "failed"` rather than
      discarding it or pretending the copy exists.

  Returns the backup result with an `:offsite` key: `nil` when no offsite copy
  was requested, `%{status: "shipped", ...}`, or `%{status: "failed", ...}`.
  """
  @spec create(String.t(), keyword()) :: {:ok, backup_result()} | {:error, term()}
  def create(target_path, opts \\ []) when is_binary(target_path) do
    parent = Path.dirname(target_path)

    with :ok <- ensure_parent_dir(parent),
         :ok <- ensure_no_existing(target_path),
         started <- System.monotonic_time(:millisecond),
         :ok <- vacuum_into(target_path),
         size <- File.stat!(target_path).size,
         rows <- count_backup_rows(target_path),
         checksum <- checksum_sha256(target_path),
         {:ok, integrity} <- verify(target_path),
         integrity_status <- if(integrity == :ok, do: "verified", else: "failed"),
         id <- backup_id(),
         :ok <- catalog_backup(id, target_path, size, checksum, integrity_status) do
      {:ok,
       %{
         id: id,
         target: target_path,
         size_bytes: size,
         rows_backed_up: rows,
         duration_ms: System.monotonic_time(:millisecond) - started,
         checksum_sha256: checksum,
         integrity_status: integrity_status,
         offsite: offsite_result(id, target_path, opts)
       }}
    end
  end

  defp offsite_result(id, _target_path, opts) do
    if Keyword.get(opts, :offsite, false) do
      case ship_offsite(id, Keyword.take(opts, [:tenant_id, :timeout])) do
        {:ok, offsite} -> offsite
        {:error, reason} -> %{status: "failed", reason: inspect(reason)}
      end
    end
  end

  @doc """
  Copy a cataloged, verified backup to the object store and mark its catalog
  row offsite.

  The backup must already be a verified `backup_records` row: the local file is
  re-hashed and checked against the catalog checksum before anything is
  uploaded, and the checksum the object store reports back must match too. A
  mismatch deletes the object it just wrote rather than leaving an unverifiable
  copy in the bucket.

  The object key is `backups/<tenant>/<file name>` under the configured prefix.
  """
  @spec ship_offsite(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ship_offsite(backup_id, opts \\ []) when is_binary(backup_id) do
    with {:ok, row} <- catalog_row(backup_id, opts),
         :ok <- ensure_local_copy(row),
         :ok <- local_matches_catalog(row),
         key <- offsite_key(row.target, opts),
         {:ok} <- ship_object(key, row),
         :ok <- mark_offsite(row, key) do
      {:ok,
       %{
         status: "shipped",
         backup_id: row.id,
         uri: S3.uri(key),
         key: key,
         checksum_sha256: row.checksum_sha256,
         size_bytes: row.size_bytes,
         provider: "s3"
       }}
    end
  end

  defp ship_object(key, row) do
    with {:ok, object} <- S3.put_file(key, row.target, []),
         :ok <- match_object_checksum(object, row) do
      {:ok}
    else
      {:error, reason} ->
        discard_object(key, reason)
        {:error, reason}
    end
  end

  defp match_object_checksum(%{checksum_sha256: object_checksum}, %{checksum_sha256: catalog}) do
    if object_checksum == catalog,
      do: :ok,
      else: {:error, {:offsite_checksum_mismatch, catalog, object_checksum}}
  end

  # An object that did not match the catalog checksum must not stay in the
  # bucket where a restore could later trust it.
  defp discard_object(key, reason) do
    case S3.delete_object(key) do
      :ok ->
        :ok

      {:error, delete_reason} ->
        Logger.error(
          "offsite backup abandoned after #{inspect(reason)} but the object could not be removed: #{inspect(delete_reason)}"
        )
    end
  end

  defp ensure_local_copy(%{target: target}) do
    if File.regular?(target), do: :ok, else: {:error, {:local_backup_missing, target}}
  end

  defp local_matches_catalog(%{target: target, checksum_sha256: expected}) do
    case checksum_sha256(target) do
      ^expected -> :ok
      actual -> {:error, {:checksum_mismatch, expected, actual}}
    end
  end

  defp offsite_key(target, opts) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    S3.object_key(["backups", tenant_id, Path.basename(target)])
  end

  defp mark_offsite(row, key) do
    metadata =
      row.metadata
      |> Map.put("offsite_uri", S3.uri(key))
      |> Map.put("offsite_key", key)
      |> Map.put("offsite_provider", "s3")
      |> Map.put("offsite_shipped_at", DateTime.utc_now() |> DateTime.to_iso8601())

    case Store.raw_execute(
           "UPDATE backup_records SET offsite = 1, metadata = ?1, verified_at = datetime('now') WHERE id = ?2",
           [Jason.encode!(metadata), row.id]
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:catalog_update_failed, reason}}
    end
  end

  @doc """
  Backups with an offsite copy, newest first.

  Each entry carries the local path, the object URI it was shipped to, and the
  checksum both copies are verified against, so a restore can be planned and
  audited without the bucket being reachable.
  """
  @spec list_offsite(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_offsite(opts \\ []) do
    limit = Keyword.get(opts, :limit, 25)

    sql = """
    SELECT id, storage_uri, size_bytes, checksum_sha256, integrity_status, created_at, verified_at, metadata
    FROM backup_records
    WHERE offsite = 1
    ORDER BY created_at DESC LIMIT ?1
    """

    case Store.raw_query(sql, [limit]) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [id, uri, size, checksum, integrity, created, verified, metadata] ->
           metadata = decode_metadata(metadata)

           %{
             id: id,
             local_path: uri,
             offsite_uri: metadata["offsite_uri"],
             offsite_key: metadata["offsite_key"],
             shipped_at: metadata["offsite_shipped_at"],
             size_bytes: size,
             checksum_sha256: checksum,
             integrity_status: integrity,
             created_at: created,
             verified_at: verified
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Restore an offsite backup into a database path.

  The object is downloaded, its SHA-256 must match the catalog checksum, and
  the restored database must pass the same checks `restore/2` applies. The
  temporary download is removed afterwards; the local backup and its catalog row
  are left untouched, so a drill is repeatable.

  Options:

    * `:target` — destination database path (required; restoring over the live
      database requires the engine to be stopped, as `restore/2` enforces)
    * `:data_dir` — destination directory, restored to `<data_dir>/index.db`
    * `:keep_download` — keep the downloaded copy and return its path
  """
  @spec restore_offsite(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def restore_offsite(backup_id, opts \\ []) when is_binary(backup_id) do
    with {:ok, row} <- catalog_row(backup_id, opts),
         :ok <- ensure_offsite(row),
         {:ok, target} <- restore_target(opts) do
      download = download_path(backup_id)

      try do
        with {:ok, object} <- S3.get_object_to_file(row.offsite_key, download),
             :ok <- match_download(object, row),
             {:ok, restored} <-
               restore(download, target: target, checksum_sha256: row.checksum_sha256) do
          {:ok,
           %{
             backup_id: row.id,
             source_uri: S3.uri(row.offsite_key),
             source_bytes: object.size_bytes,
             checksum_sha256: row.checksum_sha256,
             target: restored.target,
             archived: restored.archived,
             download_path: if(Keyword.get(opts, :keep_download, false), do: download)
           }}
        end
      after
        unless Keyword.get(opts, :keep_download, false), do: File.rm(download)
      end
    end
  end

  defp match_download(%{checksum_sha256: downloaded}, %{checksum_sha256: catalog}) do
    if downloaded == catalog,
      do: :ok,
      else: {:error, {:offsite_download_mismatch, catalog, downloaded}}
  end

  defp ensure_offsite(%{offsite_key: key, offsite: true}) when is_binary(key), do: :ok

  defp ensure_offsite(%{id: id}) do
    {:error, {:backup_not_offsite, id}}
  end

  defp restore_target(opts) do
    cond do
      is_binary(Keyword.get(opts, :target)) ->
        {:ok, Path.expand(Keyword.get(opts, :target))}

      is_binary(Keyword.get(opts, :data_dir)) ->
        # A restore drill targets a fresh data directory, which need not exist
        # yet, so it is created here rather than failing on a missing parent.
        dir = Path.expand(Keyword.get(opts, :data_dir))

        with :ok <- File.mkdir_p(dir), do: {:ok, Path.join(dir, "index.db")}

      true ->
        {:error, :restore_target_required}
    end
  end

  defp download_path(backup_id) do
    Path.join([
      System.tmp_dir!(),
      "optimal-offsite-restore",
      "#{backup_id}-#{System.unique_integer([:positive])}.db"
    ])
  end

  # The catalog is read straight from the database file, so an offsite restore
  # works before boot when the Store process that normally owns it is not
  # running. This mirrors how `catalog_checksum/2` reads it.
  defp catalog_row(backup_id, opts) do
    catalog_path = Keyword.get(opts, :catalog_path, Application.get_env(:optimal_engine, :db_path))

    sql = """
    SELECT id, storage_uri, size_bytes, checksum_sha256, offsite, metadata
    FROM backup_records
    WHERE id = ?1 AND status = 'completed'
    LIMIT 1
    """

    with true <- is_binary(catalog_path) and File.regular?(catalog_path),
         {:ok, db} <- Exqlite.Sqlite3.open(catalog_path, mode: :readonly) do
      try do
        with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
             :ok <- Exqlite.Sqlite3.bind(stmt, [backup_id]) do
          rows = drain(db, stmt, [])
          Exqlite.Sqlite3.release(db, stmt)
          row_from(rows, backup_id)
        else
          _ -> {:error, :backup_catalog_unavailable}
        end
      after
        Exqlite.Sqlite3.close(db)
      end
    else
      _ -> {:error, :backup_catalog_unavailable}
    end
  end

  defp row_from([[id, uri, size, checksum, offsite, metadata]], _backup_id)
       when is_binary(checksum) do
    metadata = decode_metadata(metadata)

    {:ok,
     %{
       id: id,
       target: uri,
       size_bytes: size,
       checksum_sha256: checksum,
       offsite: offsite == 1,
       offsite_key: metadata["offsite_key"],
       metadata: metadata
     }}
  end

  defp row_from([[id, _uri, _size, nil, _offsite, _metadata]], _backup_id),
    do: {:error, {:backup_not_verified, id}}

  defp row_from(_rows, backup_id), do: {:error, {:backup_not_cataloged, backup_id}}

  defp decode_metadata(nil), do: %{}

  defp decode_metadata(metadata) do
    case Jason.decode(metadata) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  @doc """
  Restore from `source_path` into a database path.

  The backup must prove itself before any byte is replaced:

    * its SHA-256 must match the `backup_records` catalog entry for that
      path (read from the catalog database, by default the live engine
      database) or an explicit `:checksum_sha256`; uncataloged files are
      refused with `:backup_not_cataloged`
    * `PRAGMA integrity_check` must pass
    * it must not carry an uncheckpointed `-wal` sidecar, which the checksum
      would not cover

  The current target and its `-wal`/`-shm` sidecars are archived to
  `<target>.pre-restore-<epoch>` so the operator has a rollback. Stale
  sidecars are then removed, because SQLite would otherwise replay the old
  WAL over the restored file. The restored file is written to a temporary
  path and renamed into place, then checked against the expected checksum.

  Options:

    * `:target` — destination path (default: `:optimal_engine, :db_path`).
      Replacing the live database requires the supervisor to be stopped;
      restoring into any other path is safe while the engine runs.
    * `:checksum_sha256` — expected checksum when no catalog entry exists.
    * `:catalog_path` — database holding `backup_records` (default:
      `:optimal_engine, :db_path`).
  """
  @spec restore(String.t(), keyword()) ::
          {:ok, %{target: String.t(), archived: String.t() | nil, checksum_sha256: String.t()}}
          | {:error, term()}
  def restore(source_path, opts \\ []) when is_binary(source_path) do
    live_path = Application.get_env(:optimal_engine, :db_path)
    target = Keyword.get(opts, :target, live_path)
    catalog_path = Keyword.get(opts, :catalog_path, live_path)

    with :ok <- refuse_live_replacement(target, live_path),
         :ok <- ensure_source_exists(source_path),
         :ok <- ensure_no_wal(source_path),
         {:ok, expected} <- expected_checksum(source_path, catalog_path, opts),
         :ok <- match_checksum(source_path, expected),
         :ok <- ensure_integrity(source_path),
         :ok <- ensure_parent_dir(Path.dirname(target)),
         {:ok, archived} <- archive_current(target),
         :ok <- replace_target(source_path, target),
         :ok <- match_checksum(target, expected) do
      {:ok, %{target: target, archived: archived, checksum_sha256: expected}}
    end
  end

  @doc """
  The engine's backup directory: `:optimal_engine, :backup_dir`
  (`OPTIMAL_BACKUP_DIR`), defaulting to `backups/` beside the database.
  """
  @spec backup_dir() :: String.t()
  def backup_dir do
    case Application.get_env(:optimal_engine, :backup_dir) do
      dir when is_binary(dir) and dir != "" ->
        Path.expand(dir)

      _ ->
        db_path = Application.get_env(:optimal_engine, :db_path, ".optimal/index.db")
        db_path |> Path.dirname() |> Path.join("backups") |> Path.expand()
    end
  end

  @doc """
  Resolve a caller-supplied backup name to a file directly inside
  `backup_dir/0`, creating the directory when needed. `nil` yields a
  timestamped name. Anything that would land outside the directory,
  including nested paths and `..` segments, is refused.
  """
  @spec resolve_target(String.t() | nil) ::
          {:ok, String.t()} | {:error, {:outside_backup_dir, String.t()} | term()}
  def resolve_target(name \\ nil) do
    dir = backup_dir()

    name =
      name ||
        "optimal-backup-#{System.os_time(:second)}-#{System.unique_integer([:positive])}.db"

    expanded = if is_binary(name), do: Path.expand(name, dir)

    cond do
      not is_binary(name) or String.trim(name) == "" -> {:error, {:outside_backup_dir, dir}}
      Path.dirname(expanded) != dir -> {:error, {:outside_backup_dir, dir}}
      true -> with :ok <- File.mkdir_p(dir), do: {:ok, expanded}
    end
  end

  @doc """
  Quick integrity check on a backup file — opens it as a read-only
  SQLite, runs `PRAGMA integrity_check`, and closes. Returns
  `{:ok, :ok}` for clean DBs or `{:ok, issues}` for anything else.
  """
  @spec verify(String.t()) :: {:ok, term()} | {:error, term()}
  def verify(path) when is_binary(path) do
    with {:ok, db} <- Exqlite.Sqlite3.open(path, mode: :readonly),
         {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "PRAGMA integrity_check"),
         :ok <- :ok,
         rows <- drain(db, stmt, []),
         _ <- Exqlite.Sqlite3.release(db, stmt),
         :ok <- Exqlite.Sqlite3.close(db) do
      case rows do
        [["ok"]] -> {:ok, :ok}
        issues -> {:ok, issues}
      end
    end
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp ensure_parent_dir(parent) do
    if File.dir?(parent), do: :ok, else: {:error, {:parent_missing, parent}}
  end

  defp ensure_no_existing(path) do
    if File.exists?(path), do: {:error, {:target_exists, path}}, else: :ok
  end

  defp ensure_source_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, {:source_missing, path}}
  end

  # Use an independent SQLite connection so a large online backup does not
  # monopolize the Store GenServer and stall every request behind it.
  defp vacuum_into(target_path) do
    source_path = Application.fetch_env!(:optimal_engine, :db_path)

    with {:ok, db} <- Exqlite.Sqlite3.open(source_path) do
      try do
        with {:ok, statement} <- Exqlite.Sqlite3.prepare(db, "VACUUM INTO ?1"),
             :ok <- Exqlite.Sqlite3.bind(statement, [target_path]) do
          result =
            case Exqlite.Sqlite3.step(db, statement) do
              :done -> :ok
              {:error, reason} -> {:error, reason}
              other -> {:error, {:unexpected_vacuum_result, other}}
            end

          Exqlite.Sqlite3.release(db, statement)
          result
        end
      after
        Exqlite.Sqlite3.close(db)
      end
    end
  end

  defp catalog_backup(id, path, size, checksum, integrity_status) do
    sql = """
    INSERT INTO backup_records (
      id, tenant_id, storage_provider, storage_uri, status, encrypted, offsite,
      size_bytes, checksum_sha256, integrity_status, verified_at
    ) VALUES (?1, 'default', 'local', ?2, 'completed', 0, 0, ?3, ?4, ?5, datetime('now'))
    """

    case Store.raw_query(sql, [id, Path.expand(path), size, checksum, integrity_status]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:catalog_failed, reason}}
    end
  end

  defp backup_id do
    "backup_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp checksum_sha256(path) do
    digest =
      path
      |> File.stream!([], 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    Base.encode16(digest, case: :lower)
  end

  @sidecars ["-wal", "-shm"]

  defp refuse_live_replacement(target, live_path) do
    if is_binary(live_path) and Path.expand(target) == Path.expand(live_path),
      do: refuse_if_supervisor_up(),
      else: :ok
  end

  defp refuse_if_supervisor_up do
    case Process.whereis(OptimalEngine.Supervisor) do
      nil -> :ok
      _ -> {:error, :supervisor_still_running}
    end
  end

  defp ensure_no_wal(path) do
    wal = path <> "-wal"

    case File.stat(wal) do
      {:ok, %{size: size}} when size > 0 -> {:error, {:source_has_wal, wal}}
      _ -> :ok
    end
  end

  defp expected_checksum(source_path, catalog_path, opts) do
    case Keyword.get(opts, :checksum_sha256) do
      checksum when is_binary(checksum) -> {:ok, String.downcase(checksum)}
      nil -> catalog_checksum(source_path, catalog_path)
    end
  end

  # Read the catalog straight from the database file so restore works before
  # boot, when the Store process that normally owns it is not running.
  defp catalog_checksum(source_path, catalog_path) do
    sql = """
    SELECT checksum_sha256 FROM backup_records
    WHERE storage_uri = ?1 AND status = 'completed' AND checksum_sha256 IS NOT NULL
    ORDER BY created_at DESC LIMIT 1
    """

    with true <- is_binary(catalog_path) and File.regular?(catalog_path),
         {:ok, db} <- Exqlite.Sqlite3.open(catalog_path, mode: :readonly) do
      try do
        with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
             :ok <- Exqlite.Sqlite3.bind(stmt, [Path.expand(source_path)]) do
          rows = drain(db, stmt, [])
          Exqlite.Sqlite3.release(db, stmt)

          case rows do
            [[checksum]] when is_binary(checksum) -> {:ok, checksum}
            _ -> {:error, :backup_not_cataloged}
          end
        else
          _ -> {:error, :backup_not_cataloged}
        end
      after
        Exqlite.Sqlite3.close(db)
      end
    else
      _ -> {:error, :backup_not_cataloged}
    end
  end

  defp match_checksum(path, expected) do
    case checksum_sha256(path) do
      ^expected -> :ok
      actual -> {:error, {:checksum_mismatch, expected, actual}}
    end
  end

  defp ensure_integrity(path) do
    case verify(path) do
      {:ok, :ok} -> :ok
      {:ok, issues} -> {:error, {:integrity_failed, issues}}
      {:error, reason} -> {:error, {:integrity_failed, reason}}
    end
  end

  defp archive_current(db_path) do
    if File.exists?(db_path) do
      dest = "#{db_path}.pre-restore-#{System.os_time(:second)}"

      with :ok <- File.cp(db_path, dest),
           :ok <- copy_sidecars(db_path, dest) do
        {:ok, dest}
      end
    else
      {:ok, nil}
    end
  end

  defp copy_sidecars(from, to) do
    Enum.reduce_while(@sidecars, :ok, fn suffix, :ok ->
      if File.exists?(from <> suffix) do
        case File.cp(from <> suffix, to <> suffix) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:archive_failed, suffix, reason}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp replace_target(source_path, target) do
    staging = "#{target}.restore-#{System.unique_integer([:positive])}"

    with :ok <- File.cp(source_path, staging),
         :ok <- remove_sidecars(target),
         :ok <- File.rename(staging, target) do
      :ok
    else
      {:error, reason} ->
        File.rm(staging)
        {:error, {:restore_failed, reason}}
    end
  end

  defp remove_sidecars(path) do
    Enum.reduce_while(@sidecars, :ok, fn suffix, :ok ->
      case File.rm(path <> suffix) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Sum of `COUNT(*)` across the primary engine tables — gives a
  # rough "how much data is in this backup" number without opening
  # every table.
  defp count_backup_rows(path) do
    try do
      {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

      total =
        ~w(contexts signals wiki_pages connectors chunks citations)
        |> Enum.reduce(0, fn table, acc ->
          case exec(db, "SELECT COUNT(*) FROM #{table}") do
            [[n]] when is_integer(n) -> acc + n
            _ -> acc
          end
        end)

      Exqlite.Sqlite3.close(db)
      total
    rescue
      _ -> 0
    end
  end

  defp exec(db, sql) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         rows <- drain(db, stmt, []) do
      Exqlite.Sqlite3.release(db, stmt)
      rows
    else
      _ -> []
    end
  end

  defp drain(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> drain(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      _ -> Enum.reverse(acc)
    end
  end
end
