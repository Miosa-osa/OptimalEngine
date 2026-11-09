defmodule Mix.Tasks.Optimal.Postgres.Migrate do
  @shortdoc "Copy an SQLite Engine's store into PostgreSQL and verify the copy"
  @moduledoc """
  Moves an existing SQLite Engine's canonical store to PostgreSQL
  (`OptimalEngine.Store.Postgres.Migrate`, stage 4 of
  `docs/guides/postgres-provider.md`).

  The Engine's database file is only read: it is snapshotted with
  `VACUUM INTO`, the snapshot is brought to this build's schema, copied in one
  PostgreSQL transaction, and committed only when every table's row count and
  checksum and the parity queries match. Stop the Engine's writes first.

  Usage:

      OPTIMAL_POSTGRES_URL=postgres://... mix optimal.postgres.migrate --schema public
      mix optimal.postgres.migrate --source .optimal/index.db --dry-run
      mix optimal.postgres.migrate --snapshot backup.db --schema engine_b --replace

  Options:

    * `--source PATH` - the SQLite database (default the configured `db_path`)
    * `--snapshot PATH` - copy this backup file instead of a live database
    * `--schema NAME` - the PostgreSQL schema (default `OPTIMAL_POSTGRES_SCHEMA` or `public`)
    * `--replace` - empty a schema that already holds tables, and copy into it
    * `--ignore-unknown` - leave behind tables and columns this build does not know
    * `--dry-run` - copy and verify, then roll back
    * `--timeout MS` - the transaction's limit (default one hour)
    * `--json` - print the report as JSON

  In a release, run the same function:

      bin/optimal eval 'OptimalEngine.Store.Postgres.Migrate.run(schema: "public") |> IO.inspect()'

  The connection URL is never printed. Exit status is 1 when the migration
  was refused or its verification failed; nothing is committed then.
  """

  use Mix.Task

  alias OptimalEngine.Store.Postgres.Migrate

  @switches [
    source: :string,
    snapshot: :string,
    schema: :string,
    replace: :boolean,
    ignore_unknown: :boolean,
    dry_run: :boolean,
    timeout: :integer,
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:telemetry)

    {json, opts} = Keyword.pop(opts, :json, false)

    case Migrate.run(opts) do
      {:ok, report} ->
        if json, do: Mix.shell().info(Jason.encode!(report)), else: print(report)

      {:error, reason} ->
        Mix.shell().error("migration refused or failed, nothing committed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print(report) do
    shell = Mix.shell()
    verb = if report.dry_run, do: "verified (dry run, rolled back)", else: "copied and verified"
    shell.info("SQLite snapshot sha256 #{report.snapshot.sha256} (#{report.snapshot.bytes} bytes)")
    shell.info("#{verb} into schema #{report.schema}:")

    for %{table: table, rows: rows, checksum: checksum} <- report.tables, rows > 0 do
      shell.info("  #{table}: #{rows} rows, checksum #{String.slice(checksum, 0, 16)}")
    end

    rows = Enum.sum(Enum.map(report.tables, & &1.rows))
    shell.info("  #{length(report.tables)} tables, #{rows} rows")

    shell.info(
      "  parity: #{report.parity.queries} queries over #{report.parity.workspaces} workspaces match"
    )

    if report.full_text != [],
      do: shell.info("  full-text indexes rebuilt: #{Enum.join(report.full_text, ", ")}")

    for {kind, names} <- report.ignored, names != [] do
      shell.info("  left behind (#{kind}): #{Enum.join(names, ", ")}")
    end
  end
end
