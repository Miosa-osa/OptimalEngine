defmodule Mix.Tasks.Optimal.Restore do
  @shortdoc "Restore a verified backup into the engine database"

  @moduledoc """
  Restore a backup created by `mix optimal.backup`.

  The engine must be stopped when restoring over the live database. This task
  loads configuration without starting the application, so it never races a
  running Store for the database file.

  ## Usage

      mix optimal.restore /var/backups/engine-2026-01-05.db
      mix optimal.restore /tmp/snap.db --target /tmp/restored.db
      mix optimal.restore /offsite/snap.db --checksum <sha256>
      mix optimal.restore --from-offsite <backup-id> --data-dir /tmp/restore
      mix optimal.restore --from-offsite-key <object-key> --data-dir /tmp/restore

  ## Options

    --target        Destination database path (default: the configured engine database).
    --data-dir      Destination directory, restored to `<data-dir>/index.db`.
    --checksum      Expected SHA-256 when the backup is not in the catalog.
    --from-offsite  Restore a cataloged backup from its offsite object copy
                    instead of a local path.
    --from-offsite-key
                    Restore a sealed object by its key without a catalog row,
                    as after losing the machine. Find keys with
                    `mix optimal.backup --list-offsite-objects`.

  The backup's checksum must match the catalog entry or `--checksum`, and
  `PRAGMA integrity_check` must pass, before anything is replaced. The
  previous database and its `-wal`/`-shm` sidecars are archived first.

  An offsite restore downloads the object, checks it against the catalog,
  decrypts it with `OPTIMAL_BACKUP_KEY` (the key that sealed it), checks the
  plaintext against the catalog checksum, restores it exactly as a local
  backup, and removes the temporary files. A wrong key or a changed object
  fails before anything is replaced. The bucket is read, never modified, so a
  restore drill is repeatable.
  """

  use Mix.Task

  alias OptimalEngine.Backup

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {parsed, rest, _} =
      OptionParser.parse(args,
        strict: [
          target: :string,
          data_dir: :string,
          checksum: :string,
          from_offsite: :string,
          from_offsite_key: :string
        ]
      )

    cond do
      is_binary(parsed[:from_offsite]) ->
        restore_offsite(parsed[:from_offsite], parsed)

      is_binary(parsed[:from_offsite_key]) ->
        restore_offsite_object(parsed[:from_offsite_key], parsed)

      match?([_ | _], rest) ->
        restore_local(hd(rest), parsed)

      true ->
        Mix.raise(
          "Usage: mix optimal.restore <backup-path> | --from-offsite <backup-id> | --from-offsite-key <object-key>"
        )
    end
  end

  defp restore_local(source, parsed) do
    opts =
      [target: parsed[:target], checksum_sha256: parsed[:checksum]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Backup.restore(source, opts) do
      {:ok, result} ->
        IO.puts("Restore complete.")
        IO.puts("  target:           #{result.target}")
        IO.puts("  checksum_sha256:  #{result.checksum_sha256}")
        IO.puts("  previous archive: #{result.archived || "none"}")

      {:error, reason} ->
        Mix.raise("Restore failed: #{Backup.explain(reason)}")
    end
  end

  defp restore_offsite(backup_id, parsed) do
    opts =
      [target: parsed[:target], data_dir: parsed[:data_dir]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Backup.restore_offsite(backup_id, opts) do
      {:ok, result} ->
        IO.puts("Offsite restore complete.")
        IO.puts("  backup_id:        #{result.backup_id}")
        IO.puts("  source:           #{result.source_uri}")
        IO.puts("  source_bytes:     #{result.source_bytes}")
        IO.puts("  checksum_sha256:  #{result.checksum_sha256}")
        IO.puts("  target:           #{result.target}")
        IO.puts("  previous archive: #{result.archived || "none"}")

      {:error, reason} ->
        Mix.raise("Offsite restore failed: #{Backup.explain(reason)}")
    end
  end

  defp restore_offsite_object(object_key, parsed) do
    opts =
      [target: parsed[:target], data_dir: parsed[:data_dir]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Backup.restore_offsite_object(object_key, opts) do
      {:ok, result} ->
        IO.puts("Offsite restore complete (no catalog).")
        IO.puts("  backup_id:        #{result.backup_id}")
        IO.puts("  source:           #{result.source_uri}")
        IO.puts("  sealed_at:        #{result.sealed_at}")
        IO.puts("  key_id:           #{result.key_id}")
        IO.puts("  checksum_sha256:  #{result.checksum_sha256}")
        IO.puts("  target:           #{result.target}")
        IO.puts("  previous archive: #{result.archived || "none"}")

      {:error, reason} ->
        Mix.raise("Offsite restore failed: #{Backup.explain(reason)}")
    end
  end
end
