defmodule Mix.Tasks.Optimal.Backup do
  @shortdoc "Create a live backup of the engine database"

  @moduledoc """
  Online SQLite backup — runs without blocking the engine.

  ## Usage

      mix optimal.backup /var/backups/engine-$(date +%F).db
      mix optimal.backup /tmp/snap.db --verify
      mix optimal.backup /tmp/snap.db --offsite
      mix optimal.backup --list-offsite

  ## Options

    --verify         Run PRAGMA integrity_check on the result before exit.
    --offsite        Copy the verified backup to the configured object store
                     and mark its catalog row offsite.
    --list-offsite   List backups that have an offsite copy instead of taking one.

  The backup is complete locally whether or not the offsite copy succeeds; a
  failed copy is reported and exits non-zero rather than being hidden.

  ## Related

      mix optimal.restore <path>                  — restore a backup (engine must be stopped)
      mix optimal.restore --from-offsite <id>     — restore an offsite copy
  """

  use Mix.Task

  alias OptimalEngine.Backup

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, rest, _} =
      OptionParser.parse(args,
        strict: [verify: :boolean, offsite: :boolean, list_offsite: :boolean]
      )

    if Keyword.get(parsed, :list_offsite, false) do
      list_offsite()
    else
      create(parsed, rest)
    end
  end

  defp create(parsed, rest) do
    target =
      case rest do
        [path | _] -> path
        [] -> Mix.raise("Usage: mix optimal.backup <path> [--verify] [--offsite]")
      end

    case Backup.create(target, offsite: Keyword.get(parsed, :offsite, false)) do
      {:ok, info} ->
        IO.puts("Backup complete.")
        IO.puts("  target:           #{info.target}")
        IO.puts("  size_bytes:       #{info.size_bytes}")
        IO.puts("  rows_backed_up:   #{info.rows_backed_up}")
        IO.puts("  duration_ms:      #{info.duration_ms}")

        verify_target(parsed, target)
        report_offsite(info.offsite)

      {:error, reason} ->
        Mix.raise("Backup failed: #{inspect(reason)}")
    end
  end

  defp verify_target(parsed, target) do
    if Keyword.get(parsed, :verify, false) do
      case Backup.verify(target) do
        {:ok, :ok} ->
          IO.puts("  integrity_check:  OK")

        {:ok, issues} ->
          IO.puts("  integrity_check:  FAILED - #{inspect(issues)}")
          System.halt(1)

        {:error, reason} ->
          IO.puts("  integrity_check:  ERROR - #{inspect(reason)}")
          System.halt(1)
      end
    end
  end

  defp report_offsite(nil), do: :ok

  defp report_offsite(%{status: "shipped"} = offsite) do
    IO.puts("  offsite:          #{offsite.uri} (#{offsite.size_bytes} bytes, checksum verified)")
  end

  defp report_offsite(%{status: "failed"} = offsite) do
    IO.puts("  offsite:          FAILED - #{offsite.reason}")
    System.halt(1)
  end

  defp list_offsite do
    case Backup.list_offsite() do
      {:ok, []} ->
        IO.puts("No offsite backups.")

      {:ok, backups} ->
        IO.puts("Offsite backups (newest first):")

        Enum.each(backups, fn backup ->
          IO.puts("  #{backup.id}")
          IO.puts("    uri:        #{backup.offsite_uri}")
          IO.puts("    shipped_at: #{backup.shipped_at}")
          IO.puts("    checksum:   #{backup.checksum_sha256}")
        end)

      {:error, reason} ->
        Mix.raise("Listing offsite backups failed: #{inspect(reason)}")
    end
  end
end
