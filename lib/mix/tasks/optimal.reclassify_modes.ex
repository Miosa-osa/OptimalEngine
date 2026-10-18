defmodule Mix.Tasks.Optimal.ReclassifyModes do
  @shortdoc "Recompute stored signal modes (and bridge-default genres) for a workspace"

  @moduledoc """
  Recomputes the Mode of every signal in a workspace with today's intake
  classification, and re-detects the genre where it is the Signal Theory
  bridge's old `"chat"` default. See `OptimalEngine.Signal.Reclassifier`.

  Prints the number of signals scanned and the mode and genre transitions.
  Nothing is written with `--dry-run`.

  ## Usage

      mix optimal.reclassify_modes --workspace default --dry-run
      mix optimal.reclassify_modes --workspace default
      mix optimal.reclassify_modes --workspace default --no-files

  ## Options

    * `--workspace` / `-w` - workspace id (required)
    * `--dry-run` - report the changes without writing them
    * `--no-files` - update the store only, leave signal files on disk as they are
  """

  use Mix.Task

  alias OptimalEngine.Signal.Reclassifier

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [workspace: :string, dry_run: :boolean, files: :boolean],
        aliases: [w: :workspace]
      )

    workspace_id =
      Keyword.get(opts, :workspace) ||
        Mix.raise("Usage: mix optimal.reclassify_modes --workspace <id> [--dry-run] [--no-files]")

    Mix.Task.run("app.start")

    {:ok, %{scanned: scanned, changes: changes}} = Reclassifier.plan(workspace_id)
    summary = Reclassifier.summarize(changes)

    IO.puts("Workspace: #{workspace_id}")
    IO.puts("Signals scanned: #{scanned}")
    IO.puts("Signals to change: #{length(changes)}")
    print_transitions("Mode changes", summary.mode)
    print_transitions("Genre changes", summary.genre)

    if Keyword.get(opts, :dry_run, false) do
      IO.puts("Dry run: nothing written.")
    else
      case Reclassifier.apply_changes(changes, files: Keyword.get(opts, :files, true)) do
        {:ok, %{rows: rows, files: files}} ->
          IO.puts("Updated #{rows} signals and #{files} signal files.")

        {:error, reason} ->
          Mix.raise("Reclassification failed, nothing written: #{inspect(reason)}")
      end
    end
  end

  defp print_transitions(label, transitions) when map_size(transitions) == 0,
    do: IO.puts("#{label}: none")

  defp print_transitions(label, transitions) do
    IO.puts("#{label}:")

    transitions
    |> Enum.sort_by(fn {_transition, count} -> -count end)
    |> Enum.each(fn {{from, to}, count} ->
      IO.puts("  #{from || "(none)"} -> #{to || "(none)"}: #{count}")
    end)
  end
end
