defmodule Mix.Tasks.Optimal.RepairUris do
  @shortdoc "Separate contexts that share an optimal:// URI"

  @moduledoc """
  Gives every active context that shares an `optimal://` URI with another
  context in its workspace an address of its own (`OptimalEngine.UriRepair`):
  the earliest keeps the address, the others take their file name with a suffix
  of their id, and every context has its own file again, written from its row,
  with its cross-reference copies.

  Idempotent: a second run finds nothing to do. Run it with `--dry-run` first.

  ## Usage

      mix optimal.repair_uris --dry-run
      mix optimal.repair_uris --workspace default
      mix optimal.repair_uris

  ## Options

    * `--workspace W` : only contexts in workspace W (default: every workspace)
    * `--limit N`     : separate at most N groups in this run (default: all)
    * `--dry-run`     : report what would change; write nothing

  A running Engine does this through `POST /api/maintenance/uris`.
  """

  use Mix.Task

  alias OptimalEngine.UriRepair

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [workspace: :string, limit: :integer, dry_run: :boolean])

    run_opts =
      [dry_run: Keyword.get(opts, :dry_run, false)] ++
        Enum.flat_map(
          [workspace: :workspace_id, limit: :limit],
          fn {flag, key} ->
            case Keyword.get(opts, flag) do
              nil -> []
              value -> [{key, value}]
            end
          end
        )

    shell = Mix.shell()

    case UriRepair.run(run_opts) do
      {:ok, report} ->
        print(shell, report)

      {:error, reason} ->
        Mix.raise("URI repair failed: #{inspect(reason)}")
    end
  end

  defp print(shell, report) do
    shell.info("#{if report.dry_run, do: "Plan (nothing written)", else: "Repaired"}:")

    [
      {"groups sharing a URI", :groups},
      {"groups left for another run", :groups_remaining},
      {"contexts in those groups", :contexts},
      {"keep their address", :kept},
      {"given a new address", :repaired},
      {"files regenerated", :files_regenerated},
      {"  new files of repaired contexts", :files_written},
      {"  kept files rewritten", :files_rewritten},
      {"  cross-reference copies written", :cross_copies_written},
      {"  cross-reference copies rewritten", :cross_copies_rewritten},
      {"kept files already correct", :files_unchanged},
      {"kept files left alone", :files_left_alone},
      {"repaired contexts without text", :without_content},
      {"left alone: archived", :skipped_archived},
      {"left alone: rows of the same file", :skipped_twins},
      {"left alone: no file", :skipped_no_file},
      {"left alone: not signals", :skipped_not_signal},
      {"left alone: not file-addressed", :skipped_not_file_addressed}
    ]
    |> Enum.each(fn {label, key} ->
      shell.info("  #{String.pad_trailing(label <> ":", 40)}#{Map.fetch!(report, key)}")
    end)

    Enum.each(report.changes, fn change ->
      shell.info("  #{change.id}: #{change.from} -> #{change.to}")
    end)

    Enum.each(report.errors, fn error -> shell.error("  error #{error.id}: #{error.reason}") end)
  end
end
