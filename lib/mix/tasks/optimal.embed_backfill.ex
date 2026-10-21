defmodule Mix.Tasks.Optimal.EmbedBackfill do
  @shortdoc "Backfill chunk_embeddings for chunks that have none (fixes 0% coverage)"

  @moduledoc """
  Embeds every stored chunk that is missing a `chunk_embeddings` row and
  persists its vector, keyed to `chunk_id` (joinable to contexts via
  `chunks.signal_id`). The work is `OptimalEngine.Embed.ChunkBackfill`; an
  Engine without Mix runs the same backfill as a job through
  `POST /api/maintenance/embeddings {"kind": "chunks"}`, and its sweep queues
  it by itself when chunks are missing and the embedder is healthy.

  ## Behaviour

    * **Idempotent**: only chunks with no embedding are read, so re-running is
      safe and resumes where it left off.
    * **Batched**: embeds and commits one batch at a time, so a large backlog
      never blocks in one huge transaction and partial progress survives an
      interrupt.
    * **Graceful**: a chunk the embedder rejects is counted as skipped and
      left for a later run; an unavailable embedder stops the run.

  ## Usage

      mix optimal.embed_backfill
      mix optimal.embed_backfill --batch 100
      mix optimal.embed_backfill --workspace default --limit 500
      mix optimal.embed_backfill --dry-run

  ## Options

    * `--batch N`     chunks per batch (default 50)
    * `--limit N`     stop after N chunks total (default: all)
    * `--workspace W` only backfill chunks in workspace W
    * `--dry-run`     report what would be embedded; write nothing
  """

  use Mix.Task

  alias OptimalEngine.Embed.ChunkBackfill

  @default_batch 50

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [batch: :integer, limit: :integer, workspace: :string, dry_run: :boolean]
      )

    batch_size = Keyword.get(opts, :batch, @default_batch)
    limit = Keyword.get(opts, :limit)
    dry_run = Keyword.get(opts, :dry_run, false)
    scope = if workspace = opts[:workspace], do: [workspace_id: workspace], else: []

    shell = Mix.shell()

    pending =
      case ChunkBackfill.status(scope) do
        {:ok, %{missing: missing}} -> missing
        {:error, _} -> 0
      end

    target = if limit, do: min(limit, pending), else: pending

    shell.info("Chunks missing embeddings: #{pending}")

    shell.info(
      "Backfilling: #{target} (batch=#{batch_size}#{if dry_run, do: ", dry-run", else: ""})"
    )

    cond do
      target == 0 ->
        shell.info("Nothing to do: embedding coverage already complete.")

      dry_run ->
        shell.info("")
        shell.info("Done. Embedded: 0  Skipped: #{target}")

      true ->
        backfill(scope, batch_size, target, shell)
    end
  end

  defp backfill(scope, batch_size, target, shell) do
    on_page = fn page, total ->
      shell.info(
        "  …#{total.embedded + total.failed}/#{target}  " <>
          "(+#{page.embedded} embedded, +#{page.failed} skipped)"
      )
    end

    case ChunkBackfill.run(scope ++ [limit: target, page: batch_size, on_page: on_page]) do
      {:ok, totals} ->
        shell.info("")
        shell.info("Done. Embedded: #{totals.embedded}  Skipped: #{totals.failed}")

      {:error, {:embedder_unavailable, reason}} ->
        shell.error(
          "Stopped: the embedder is unavailable (#{inspect(reason)}); " <>
            "run again once it answers"
        )

      {:error, reason} ->
        shell.error("Stopped: #{inspect(reason)}")
    end
  end
end
