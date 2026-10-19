defmodule Mix.Tasks.Optimal.Backup do
  @shortdoc "Create a live backup of the engine database"

  @moduledoc """
  Online SQLite backup - runs without blocking the engine.

  ## Usage

      mix optimal.backup /var/backups/engine-$(date +%F).db
      mix optimal.backup /tmp/snap.db --verify
      mix optimal.backup /tmp/snap.db --offsite
      mix optimal.backup --list-offsite
      mix optimal.backup --list-offsite-objects

  ## Options

    --verify                Run PRAGMA integrity_check on the result before exit.
    --offsite               Encrypt the verified backup with OPTIMAL_BACKUP_KEY, copy
                            it to the configured object store, and mark its
                            catalog row offsite. Refused without the key.
    --list-offsite          List cataloged backups that have an offsite copy, and
                            the scheduled offsite backup status.
    --list-offsite-objects  List the backup objects in the bucket, whether or not
                            this engine's catalog knows them (after losing the
                            machine, this is how the copies are found again).

  The backup is complete locally whether or not the offsite copy succeeds; a
  failed copy is reported and exits non-zero rather than being hidden.

  ## Related

      mix optimal.restore <path>                    - restore a backup (engine must be stopped)
      mix optimal.restore --from-offsite <id>       - restore a cataloged offsite copy
      mix optimal.restore --from-offsite-key <key>  - restore a sealed object without a catalog
  """

  use Mix.Task

  alias OptimalEngine.Backup
  alias OptimalEngine.Backup.Schedule

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, rest, _} =
      OptionParser.parse(args,
        strict: [
          verify: :boolean,
          offsite: :boolean,
          list_offsite: :boolean,
          list_offsite_objects: :boolean
        ]
      )

    cond do
      Keyword.get(parsed, :list_offsite, false) -> list_offsite()
      Keyword.get(parsed, :list_offsite_objects, false) -> list_offsite_objects()
      true -> create(parsed, rest)
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
        Mix.raise("Backup failed: #{Backup.explain(reason)}")
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
    IO.puts(
      "  offsite:          #{offsite.uri} (#{offsite.ciphertext_bytes} bytes, #{offsite.cipher}, key #{offsite.key_id}, checksums verified)"
    )
  end

  defp report_offsite(%{status: "failed"} = offsite) do
    IO.puts("  offsite:          FAILED - #{Map.get(offsite, :message, offsite.reason)}")
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
          IO.puts("    encrypted:  #{encryption_line(backup)}")
        end)

      {:error, reason} ->
        Mix.raise("Listing offsite backups failed: #{Backup.explain(reason)}")
    end

    report_schedule(Schedule.status())
  end

  defp encryption_line(%{encrypted: true} = backup),
    do: "#{backup.cipher}, key #{backup.key_id}, ciphertext #{backup.ciphertext_sha256}"

  defp encryption_line(_backup), do: "no (shipped before offsite encryption)"

  defp report_schedule(%{enabled: false}) do
    IO.puts("Scheduled offsite backups: off (OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS)")
  end

  defp report_schedule(status) do
    IO.puts(
      "Scheduled offsite backups: #{status.state}, every #{status.interval_ms} ms, keeping #{status.keep} offsite and #{status.keep_local} local"
    )

    if status.last_success, do: IO.puts("  last shipped: #{status.last_success.shipped_at}")

    if status.last_job && status.last_job.last_error,
      do: IO.puts("  last error:   #{status.last_job.last_error}")

    for problem <- [status.encryption.problem, status.object_store.problem], is_binary(problem) do
      IO.puts("  problem:      #{problem}")
    end
  end

  defp list_offsite_objects do
    case Backup.list_offsite_objects() do
      {:ok, %{keys: []}} ->
        IO.puts("No backup objects in the bucket.")

      {:ok, listing} ->
        IO.puts("Backup objects in the bucket (newest name first):")
        Enum.each(listing.keys, &IO.puts("  #{&1}"))
        if listing.more, do: IO.puts("  (more objects exist beyond this listing)")

      {:error, reason} ->
        Mix.raise("Listing backup objects failed: #{Backup.explain(reason)}")
    end
  end
end
