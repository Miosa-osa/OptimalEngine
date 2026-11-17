defmodule Mix.Tasks.Optimal.Ledger.Redact do
  @shortdoc "Redact erased content from the replication ledger (one-time backfill)"

  @moduledoc """
  Redacts what this Engine erased before it redacted its replication ledger
  (`OptimalEngine.Sync.Redaction.backfill/1`): the earlier changes of deleted
  rows, of rows that no longer exist, and of forgotten memories, in
  `sync_mutations`, plus the capture and conflict rows of workspaces that no
  longer exist. A forgotten memory of a workspace that replicates gets a
  redaction request, so peers redact their own copies, and the NATS ledger
  publisher purges the rows' subjects when the `ledger` flow is on.

  ## Usage

      mix optimal.ledger.redact --dry-run   # counts only, changes nothing
      mix optimal.ledger.redact

  The report is JSON on stdout and holds counts only, never an id or a word of
  content: the workspaces that replicate, the registered peers, and per table
  the rows still exposed and their ledger changes. Safe to run again: a second
  run finds nothing. On a release build run
  `bin/optimal eval 'OptimalEngine.Release.redact_ledger(dry_run: true)'`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {parsed, _rest, _} = OptionParser.parse(args, strict: [dry_run: :boolean])
    Mix.Task.run("app.start")

    {:ok, report} =
      OptimalEngine.Sync.Redaction.backfill(dry_run: Keyword.get(parsed, :dry_run, false))

    Mix.shell().info(Jason.encode!(report, pretty: true))
  end
end
