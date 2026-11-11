defmodule Mix.Tasks.Optimal.QdrantSync do
  @shortdoc "Push the embeddings to the Qdrant projection and remove its orphans"

  @moduledoc """
  Brings the Qdrant projection level with the embedded stores: every row of
  `vectors`, `chunk_embeddings` and `memory_embeddings` is upserted to its
  collection, then every point whose row is gone (or moved to another
  workspace) is deleted. The work is `OptimalEngine.Storage.Qdrant.Sync`.

  ## Behaviour

    * **Idempotent**: a point's id comes from the row's key, so a second run
      writes the same points and adds none.
    * **Bounded**: the run goes in slices of `--batch` rows and points, each
      resuming where the last stopped.
    * **Needs Qdrant**: `OPTIMAL_QDRANT_URL` (and `OPTIMAL_QDRANT_API_KEY` when
      the server asks for one). Without it, or with `OPTIMAL_QDRANT_SERVING=off`,
      it changes nothing and fails.

  ## Usage

      mix optimal.qdrant_sync
      mix optimal.qdrant_sync --workspace default:ops
      mix optimal.qdrant_sync --batch 500

  It starts the Engine application, so stop the running Engine service first.
  In a release, `bin/optimal maintenance qdrant_sync` runs the same task. A
  running Engine heals a workspace on its own: a search that finds the counts
  differ queues a `maintenance.qdrant_sync` job for it.
  """

  use Mix.Task

  alias OptimalEngine.Storage.Qdrant.Sync

  @default_batch 2_000

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case main(args) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end

  # The task without Mix: `bin/optimal maintenance` runs it in a release
  # (OptimalEngine.Release.Maintenance), with the Engine already started.
  @doc false
  def main(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [workspace: :string, batch: :integer])

    run_opts = [
      workspace_id: Keyword.get(opts, :workspace),
      limit: max(Keyword.get(opts, :batch, @default_batch), 1)
    ]

    loop(run_opts, nil, %{upserted: 0, deleted: 0, skipped: 0})
  end

  defp loop(run_opts, cursor, totals) do
    case Sync.run(Keyword.put(run_opts, :after, cursor)) do
      {:ok, result} ->
        totals = %{
          upserted: totals.upserted + result.upserted,
          deleted: totals.deleted + result.deleted,
          skipped: totals.skipped + result.skipped
        }

        case result.next do
          nil ->
            IO.puts(
              "Done. Upserted: #{totals.upserted}  Orphans deleted: #{totals.deleted}  " <>
                "Skipped (empty or malformed vectors): #{totals.skipped}"
            )

            :ok

          %{"phase" => phase} = next ->
            IO.puts("  #{phase}: upserted #{totals.upserted}, deleted #{totals.deleted}")
            loop(run_opts, next, totals)
        end

      {:error, :not_configured} ->
        {:error,
         "the Qdrant projection is off: set OPTIMAL_QDRANT_URL (and leave OPTIMAL_QDRANT_SERVING unset)"}

      {:error, reason} ->
        {:error, "qdrant sync failed: #{inspect(reason)}"}
    end
  end
end
