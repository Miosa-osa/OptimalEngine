defmodule Mix.Tasks.Optimal.GraphBackfill do
  @shortdoc "Backfill knowledge-graph edges from existing contexts and claims"

  @moduledoc """
  Builds the relationship-edge graph from the already-indexed contexts and the
  extracted claims, attributing every edge to the SIGNAL's real workspace.

  The work is `OptimalEngine.Graph.Backfill`; an Engine without Mix runs the
  same backfill as a job through `POST /api/maintenance/graph/backfill`. For
  each context this writes (all idempotent via `INSERT OR IGNORE`):

    * `entity --mentioned_in--> context`
    * `entity --co_occurs--> entity`  (both directions, for each shared pair)
    * `context --lives_in--> node`
    * `context --cross_ref--> node`   (extra routed-to destinations)
    * `context --supersedes--> context`
    * `context --mentions--> entity`
    * `entity --co_occurs_with--> entity`  (both directions, for each shared pair)

  For each claim it writes:

    * `claim --about--> entity`  (entities taken from the claim's source context)

  ## Behaviour

    * **Idempotent** — every insert is `INSERT OR IGNORE`, so re-running adds no
      duplicate edges. Safe to run repeatedly.
    * **Batched** — contexts are streamed in batches so a large backlog never
      builds one huge transaction.
    * **Workspace-correct** — each edge carries the workspace_id of the context
      it was derived from; no cross-workspace leakage.

  ## Usage

      mix optimal.graph_backfill
      mix optimal.graph_backfill --batch 100
      mix optimal.graph_backfill --workspace default
      mix optimal.graph_backfill --no-claims

  ## Options

    * `--batch N`     contexts per batch (default 200)
    * `--workspace W` only backfill edges for contexts in workspace W
    * `--no-claims`   skip the claim->about->entity pass

  One run without `--workspace` covers every workspace, and is the one an
  upgrade that created `graph_edges` needs: when every edge write succeeded
  and the claim pass ran, it is recorded, and `GET /api/maintenance/graph`
  then reads `"backfill_needed": false`. It starts the Engine application,
  so stop the running Engine service first. On a release build, run
  `OptimalEngine.Release.graph_backfill/1` instead.
  """

  use Mix.Task

  alias OptimalEngine.Graph.Backfill

  @default_batch 200

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [batch: :integer, workspace: :string, claims: :boolean]
      )

    shell = Mix.shell()

    backfill_opts = [
      workspace_id: Keyword.get(opts, :workspace),
      page: Keyword.get(opts, :batch, @default_batch),
      claims: Keyword.get(opts, :claims, true),
      on_page: fn {phase, n} -> shell.info("  #{phase}: #{n}") end
    ]

    case Backfill.run(backfill_opts) do
      {:ok, result} ->
        shell.info("")
        shell.info("Done. Edges: #{result.edges_before} -> #{result.edges_after}")
        shell.info("Contexts: #{result.contexts}  Claims: #{result.claims}")

        if result.failed_edges > 0,
          do: Mix.raise("#{result.failed_edges} edge writes failed; run the backfill again")

      {:error, reason} ->
        Mix.raise("graph backfill failed: #{inspect(reason)}")
    end
  end
end
