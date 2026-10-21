defmodule Mix.Tasks.Optimal.RepairUris do
  @shortdoc "Plan, or with --apply carry out, the separation of contexts that share an optimal:// URI"

  @moduledoc """
  Gives every active context that shares an `optimal://` URI with another
  context in its workspace an address of its own, and every one of them its own
  file again, written from its row (`OptimalEngine.UriRepair`).

  Without `--apply` it only plans: it prints the totals and writes nothing.
  `--apply` writes files, a journal and backups, and changes rows.

  **Not beside a running Engine.** This task opens the store itself. Against an
  Engine that is running, use its API (`optimal uris plan`, `optimal uris apply`,
  or `GET`/`POST /api/maintenance/uris`); two processes must not write one store.

  ## Usage

      mix optimal.repair_uris --out plan.json
      mix optimal.repair_uris --workspace default --apply --limit 50

  ## Options

    * `--workspace W`: only contexts in workspace W (default: every workspace)
    * `--limit N`: take at most N groups (a run: repeat until none are left)
    * `--after CURSOR`: start after the `next_after` of the previous answer
    * `--out FILE`: write the whole answer, every group, to FILE as JSON
    * `--apply`: carry the plan out
  """

  use Mix.Task

  alias OptimalEngine.UriRepair

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          workspace: :string,
          limit: :integer,
          after: :string,
          out: :string,
          apply: :boolean
        ]
      )

    apply? = Keyword.get(opts, :apply, false)

    run_opts =
      [dry_run: not apply?] ++
        Enum.flat_map(
          [workspace: :workspace_id, limit: :limit, after: :after],
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
        write_out(Keyword.get(opts, :out), report, shell)
        print(shell, report)

      {:error, reason} ->
        Mix.raise("URI repair failed: #{inspect(reason)}")
    end
  end

  defp write_out(nil, _report, _shell), do: :ok

  defp write_out(path, report, shell) do
    case OptimalEngine.AtomicFile.create(path, Jason.encode!(report, pretty: true) <> "\n") do
      :ok -> shell.info("Wrote #{path}")
      {:error, reason} -> Mix.raise("cannot write #{path}: #{inspect(reason)} (it must not exist)")
    end
  end

  defp print(shell, report) do
    shell.info("#{if report.dry_run, do: "Plan (nothing written)", else: "Repair"}:")

    [
      {"groups sharing a URI", :groups},
      {"groups left for another run", :groups_remaining},
      {"groups skipped: a context has no text", :groups_skipped_empty_content},
      {"groups skipped: a path outside its workspace", :groups_skipped_outside_workspace},
      {"contexts in the groups", :contexts},
      {"keep their address", :kept},
      {"given a new address", :repaired},
      {"  of which the URI is not their path's address", :uri_differs_from_path},
      {"  of which an old file stays in another folder", :old_files_left_in_place},
      {"files to write (plan)", :files_to_write},
      {"kept files to replace (plan)", :files_to_rewrite},
      {"kept files left alone (plan)", :files_left_alone},
      {"kept files already correct (plan)", :files_already_correct},
      {"bytes to write (plan)", :bytes_to_write},
      {"files written", :files_written},
      {"kept files replaced", :files_rewritten},
      {"cross-reference copies written", :cross_copies_written},
      {"cross-reference copies replaced", :cross_copies_rewritten},
      {"backups taken", :backups},
      {"acl rows copied", :acls_copied},
      {"memories moved", :memories_moved},
      {"open loops moved", :open_loops_moved},
      {"left alone: archived", :skipped_archived},
      {"left alone: rows of the same file", :skipped_twins},
      {"left alone: no file", :skipped_no_file},
      {"left alone: not signals", :skipped_not_signal}
    ]
    |> Enum.each(fn {label, key} ->
      shell.info("  #{String.pad_trailing(label <> ":", 50)}#{Map.fetch!(report, key)}")
    end)

    if report.journal, do: shell.info("  journal: #{report.journal}")
    if report.next_after, do: shell.info("  next: --after #{report.next_after}")

    Enum.each(report.errors, fn error -> shell.error("  error #{error.id}: #{error.reason}") end)
  end
end
