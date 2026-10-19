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

  ## Options

    --target        Destination database path (default: the configured engine database).
    --data-dir      Destination directory, restored to `<data-dir>/index.db`.
    --checksum      Expected SHA-256 when the backup is not in the catalog.
    --from-offsite  Restore a cataloged backup from its offsite object copy
                    instead of a local path.

  The backup's checksum must match the catalog entry or `--checksum`, and
  `PRAGMA integrity_check` must pass, before anything is replaced. The
  previous database and its `-wal`/`-shm` sidecars are archived first.

  An offsite restore downloads the object, checks it against the catalog
  checksum, restores it exactly as a local backup, and removes the temporary
  download. The bucket is read, never modified, so a restore drill is repeatable.
  """

  use Mix.Task

  alias OptimalEngine.Backup

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {parsed, rest, _} =
      OptionParser.parse(args,
        strict: [target: :string, data_dir: :string, checksum: :string, from_offsite: :string]
      )

    case {parsed[:from_offsite], rest} do
      {backup_id, _rest} when is_binary(backup_id) -> restore_offsite(backup_id, parsed)
      {nil, [path | _]} -> restore_local(path, parsed)
      _ -> Mix.raise("Usage: mix optimal.restore <backup-path> | --from-offsite <backup-id>")
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
        Mix.raise("Restore failed: #{inspect(reason)}")
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
        Mix.raise("Offsite restore failed: #{inspect(reason)}")
    end
  end
end
