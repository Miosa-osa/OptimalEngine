defmodule Mix.Tasks.Optimal.ImportNotion do
  @shortdoc "Import a Notion export zip (Markdown and CSV) into a workspace"

  @moduledoc """
  Imports a Notion export into one workspace through the same durable job as
  `POST /api/import/notion`, runs it to the end, and prints the counts.

      mix optimal.import_notion export.zip --workspace default:docs

  The zip is copied into the Engine's imports folder first, so the job keeps
  its source if the task is interrupted and the Engine finishes it later.
  Every page, database and database row without a page becomes a context at
  `optimal://<workspace>/notion/<id>`, with `child_of` and `links_to` edges;
  importing the same export again updates in place. See
  `docs/guides/notion-import.md`.

  Options:

    * `--workspace` (required) - an existing active workspace
    * `--key` - an idempotency key: running again with the same key reports
      the first import instead of importing again
    * `--json` - print the final status as JSON
  """

  use Mix.Task

  alias OptimalEngine.Imports

  @terminal ~w(completed failed)

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [workspace: :string, key: :string, json: :boolean])

    zip =
      case {rest, invalid} do
        {[path], []} ->
          Path.expand(path)

        _ ->
          Mix.raise(
            "Usage: mix optimal.import_notion <export.zip> --workspace <id> [--key k] [--json]"
          )
      end

    workspace = opts[:workspace] || Mix.raise("--workspace is required")
    unless File.regular?(zip), do: Mix.raise("Not a file: #{zip}")

    Mix.Task.run("app.start")

    bytes = File.stat!(zip).size
    max = Imports.max_bytes()
    if bytes > max, do: Mix.raise("#{zip} is #{bytes} bytes; imports accept at most #{max}")

    staged = Imports.stage()
    File.cp!(zip, staged.source)

    source = %{"kind" => "upload", "bytes" => bytes}
    enqueue_opts = [actor_id: "local:mix-import", idempotency_key: opts[:key]]

    job =
      case Imports.enqueue_notion(workspace, staged, source, enqueue_opts) do
        {:ok, job, _outcome} -> job
        {:error, :workspace_not_found} -> Mix.raise("No active workspace #{workspace}")
        {:error, reason} -> Mix.raise("Could not enqueue the import: #{inspect(reason)}")
      end

    Mix.shell().info("import #{job.id} queued for #{workspace}")
    status = wait(job.id, workspace)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(status, pretty: true))
    else
      print(status)
    end

    if status.status == "failed", do: exit({:shutdown, 1})
  end

  # Runs queued imports of this workspace until this one ends. The Engine's
  # own worker may take it first; then this only waits.
  defp wait(job_id, workspace) do
    {:ok, status} = Imports.status(job_id, workspace)

    if status.status in @terminal do
      status
    else
      case Imports.drain(workspace_id: workspace) do
        {:ok, :idle} -> Process.sleep(1_000)
        {:ok, _job} -> :ok
        {:error, reason} -> Mix.shell().error("drain: #{inspect(reason)}")
      end

      wait(job_id, workspace)
    end
  end

  defp print(status) do
    c = status.counts

    Mix.shell().info("""
    #{status.status}: #{c["pages"]} pages, #{c["databases"]} databases, #{c["rows"]} rows
      contexts written #{c["contexts"]}, unchanged #{c["unchanged"]}
      edges child_of #{c["edges_child_of"]}, links_to #{c["edges_links_to"]}, unresolved links #{c["links_unresolved"]}
      assets #{c["assets"]} (not imported), skipped #{c["skipped"]}, errors #{c["errors"]}\
    """)

    Enum.each(Enum.take(status.errors, 20), fn error ->
      Mix.shell().info("  #{error["reason"]}: #{error["path"]}")
    end)

    if status.failure, do: Mix.shell().error("failed: #{status.last_error}")
  end
end
