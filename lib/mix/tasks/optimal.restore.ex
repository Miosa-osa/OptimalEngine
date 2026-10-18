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

  ## Options

    --target     Destination path (default: the configured engine database).
    --checksum   Expected SHA-256 when the backup is not in the catalog.

  The backup's checksum must match the catalog entry or `--checksum`, and
  `PRAGMA integrity_check` must pass, before anything is replaced. The
  previous database and its `-wal`/`-shm` sidecars are archived first.
  """

  use Mix.Task

  alias OptimalEngine.Backup

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {parsed, rest, _} = OptionParser.parse(args, strict: [target: :string, checksum: :string])

    source =
      case rest do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix optimal.restore <backup-path> [--target path]")
      end

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
end
