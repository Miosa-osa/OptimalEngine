defmodule Mix.Tasks.Optimal.Context.Sweep do
  @shortdoc "Empty Context Packages a refresh stored beyond their authorization envelope"

  @moduledoc """
  Run once after upgrading. See `OptimalEngine.MemoryCore.ContextPackageSweep`.

  Before refreshes read under an explicit envelope, a refresh stored packages
  that held objects their recorded envelope does not admit. This task finds
  them and empties them: a package still in use becomes stale and is rebuilt
  inside its envelope by the next refresh. Safe to repeat.

  ## Usage

      mix optimal.context.sweep --dry-run
      mix optimal.context.sweep
      mix optimal.context.sweep --workspace default --tenant default --json

  ## Options

    * `--tenant` / `-t` - only this tenant (default: all)
    * `--workspace` / `-w` - only this workspace (default: all)
    * `--dry-run` - report the packages without changing them
    * `--json` - print the summary as JSON

  Exits 1 when any package was skipped (its objects could not be looked up, or
  it changed while the sweep ran): nothing was changed for it, and running the
  task again retries it.
  """

  use Mix.Task

  alias OptimalEngine.MemoryCore.ContextPackageSweep

  @doc false
  @spec exit_status(map()) :: 0 | 1
  def exit_status(%{skipped: []}), do: 0
  def exit_status(%{skipped: [_ | _]}), do: 1

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [tenant: :string, workspace: :string, dry_run: :boolean, json: :boolean],
        aliases: [t: :tenant, w: :workspace]
      )

    opts =
      [
        tenant_id: Keyword.get(parsed, :tenant),
        workspace_id: Keyword.get(parsed, :workspace),
        dry_run: Keyword.get(parsed, :dry_run, false)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case ContextPackageSweep.run(opts) do
      {:ok, summary} ->
        if Keyword.get(parsed, :json, false) do
          Mix.shell().info(Jason.encode!(summary))
        else
          verb = if Keyword.get(opts, :dry_run, false), do: "would empty", else: "emptied"

          Mix.shell().info(
            "Checked #{summary.scanned} refreshed Context Package(s); " <>
              "#{verb} #{length(summary.offenders)}."
          )

          if summary.skipped != [] do
            Mix.shell().info(
              "Skipped #{length(summary.skipped)} (nothing was changed for them; run again to retry):"
            )

            Enum.each(summary.skipped, fn entry ->
              Mix.shell().info(
                "  #{entry.id} (#{entry.tenant_id}/#{entry.workspace_id}): #{entry.reason}"
              )
            end)
          end

          Enum.each(summary.offenders, fn offender ->
            Mix.shell().info(
              "  #{offender.id} (#{offender.tenant_id}/#{offender.workspace_id}): #{offender.reason}"
            )
          end)
        end

        # A deploy script must not take a sweep that left packages unjudged for done.
        if exit_status(summary) != 0, do: exit({:shutdown, exit_status(summary)})

      {:error, reason} ->
        Mix.shell().error("Context package sweep failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
