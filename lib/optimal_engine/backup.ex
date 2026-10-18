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

  alias OptimalEngine.Store

  @type backup_result :: %{
          id: String.t(),
          target: String.t(),
          size_bytes: non_neg_integer(),
          rows_backed_up: non_neg_integer(),
          duration_ms: non_neg_integer(),
          checksum_sha256: String.t(),
          integrity_status: String.t()
        }

  @doc """
  Create a backup at `target_path`. Runs online — the engine keeps
  serving throughout. Parent directory must exist.
  """
  @spec create(String.t()) :: {:ok, backup_result()} | {:error, term()}
  def create(target_path) when is_binary(target_path) do
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
         integrity_status: integrity_status
       }}
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
