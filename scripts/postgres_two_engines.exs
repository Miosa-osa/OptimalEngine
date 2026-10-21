# One role of scripts/proof-postgres-two-engines.sh. Run with `mix run` in a
# build compiled with OPTIMAL_STORE=postgres:
#
#   setup            create the proof workspace and its counter row
#   writer <n>       boot the engine, wait for the start signal, write the
#                    workspace through OptimalEngine.Store, report what happened
#   check            (mix run --no-start) check the workspace on PostgreSQL and
#                    compare it with an embedded SQLite copy of the same writes
#
# OPTIMAL_PROOF_WORKSPACE names the workspace and OPTIMAL_PROOF_DIR the
# directory the roles share signal and report files through.

Code.require_file("test/support/postgres_writer.ex")
Logger.configure(level: :warning)

defmodule ProofTwoEngines do
  alias OptimalEngine.Test.PostgresWriter

  @rounds 50

  # A policy pack's version is read in the transaction that publishes it, so
  # packs both engines publish for one scope at the same time each take their
  # own version.
  @packs 10

  # What the PostgreSQL store does not have yet is refused by name.
  @refusals %{
    search: {:error, {:unsupported, "full-text search is not available on the PostgreSQL store"}},
    ask: {:error, {:unsupported, "full-text search is not available on the PostgreSQL store"}},
    replication: {:error, {:unsupported, "replication is not available on the PostgreSQL store"}}
  }

  def main(["setup"]) do
    start_stores(sqlite: false)
    workspace = workspace()

    :ok =
      OptimalEngine.Store.Postgres.raw_execute(
        "INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name) VALUES (?1, 'default', ?1, ?1)",
        [workspace]
      )

    :ok =
      OptimalEngine.Store.Postgres.raw_execute(
        "INSERT OR IGNORE INTO sessions (id, message_count, workspace_id) VALUES (?1, 0, ?2)",
        ["#{workspace}-counter", workspace]
      )

    IO.puts("setup: workspace #{workspace} on #{inspect(OptimalEngine.Store.Postgres.schema_report().fingerprint)}")
  end

  def main(["writer", n]) do
    writer = String.to_integer(n)
    true = OptimalEngine.Store.selected?(OptimalEngine.Store.Postgres)
    {:ok, stats} = OptimalEngine.Store.stats()
    children = Supervisor.count_children(OptimalEngine.Supervisor)

    IO.puts(
      "engine #{writer}: up on #{inspect(OptimalEngine.Store.adapter())}, " <>
        "#{children.active} of #{children.specs} children running, #{map_size(stats)} stats"
    )

    File.touch!(path("ready-#{writer}"))
    wait_for(path("go"))

    publishing = Task.async(fn -> publish(writer) end)
    report = PostgresWriter.run(writer, workspace(), @rounds, OptimalEngine.Store)

    report =
      Map.merge(report, %{
        publish_errors: for({:error, reason} <- Task.await(publishing, 120_000), do: reason),
        refused: refused(writer)
      })

    File.write!(path("report-#{writer}.etf"), :erlang.term_to_binary(report))
  end

  def main(["check"]) do
    start_stores(sqlite: true)
    workspace = workspace()
    pg = OptimalEngine.Store.Postgres
    reports = for w <- 1..2, do: path("report-#{w}.etf") |> File.read!() |> :erlang.binary_to_term()

    :ok =
      OptimalEngine.Store.SQLite.raw_execute(
        "INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name) VALUES (?1, 'default', ?1, ?1)",
        [workspace]
      )

    for {report, writer} <- Enum.with_index(reports, 1) do
      IO.puts(
        "engine #{writer}: #{length(report.errors)} errors, #{length(report.claimed)} claims, " <>
          "#{report.retried_transactions} transactions and #{report.retried_statements} " <>
          "statements ran again after PostgreSQL aborted them"
      )

      if report.errors != [], do: IO.inspect(report.errors, label: "engine #{writer} errors")

      if report.publish_errors != [],
        do: IO.inspect(report.publish_errors, label: "engine #{writer} publish errors")

      if report.refused != @refusals,
        do: IO.inspect(report.refused, label: "engine #{writer} refusals")
    end

    claimed = Enum.flat_map(reports, & &1.claimed)

    checks = [
      {"neither engine saw an error", Enum.all?(reports, &(&1.errors == []))},
      {"every context is stored exactly once",
       count(pg, "SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [workspace]) == 2 * 90 + 10},
      {"no counter increment is lost",
       count(pg, "SELECT message_count FROM sessions WHERE id = ?1", ["#{workspace}-counter"]) ==
         2 * @rounds},
      {"every key is claimed by exactly one engine",
       length(claimed) == 25 and length(Enum.uniq(claimed)) == 25},
      {"each shared context holds one version's entities", shared_consistent?(pg, workspace)},
      {"the engines really conflicted", Enum.sum(Enum.map(reports, & &1.retried_transactions)) > 0},
      {"#{2 * @packs} policy packs published at once took #{2 * @packs} versions, one active",
       Enum.all?(reports, &(&1.publish_errors == [])) and packs_versioned?(pg, workspace)},
      {"search, asking and replication are refused by name",
       Enum.all?(reports, &(&1.refused == @refusals))}
    ]

    :ok = PostgresWriter.replay(OptimalEngine.Store.SQLite, pg, workspace, @rounds)
    mismatches = PostgresWriter.mismatches(OptimalEngine.Store.SQLite, pg, workspace)

    checks =
      checks ++
        [
          {"#{length(PostgresWriter.parity_queries(workspace))} queries match the embedded SQLite copy",
           mismatches == []}
        ]

    for {name, ok} <- checks, do: IO.puts("#{if ok, do: "PASS", else: "FAIL"} #{name}")
    if mismatches != [], do: IO.inspect(mismatches, label: "mismatches", limit: :infinity)

    unless Enum.all?(checks, &elem(&1, 1)), do: System.halt(1)
  end

  defp publish(writer) do
    for i <- 1..@packs do
      OptimalEngine.Authority.Policy.publish(
        "default",
        "workspace",
        workspace(),
        %{"name" => "proof #{writer}.#{i}", "rules" => []},
        "engine-#{writer}"
      )
    end
  end

  defp refused(writer) do
    %{
      search: OptimalEngine.Retrieval.Search.search("proof"),
      ask: OptimalEngine.Retrieval.RAG.ask("proof"),
      replication: OptimalEngine.Sync.enable("default", workspace(), "engine-#{writer}")
    }
  end

  defp packs_versioned?(pg, workspace) do
    {:ok, rows} =
      pg.raw_query(
        "SELECT version, status FROM authority_policies WHERE tenant_id = 'default' AND scope_type = 'workspace' AND scope_id = ?1 ORDER BY version",
        [workspace]
      )

    Enum.map(rows, &hd/1) == Enum.to_list(1..(2 * @packs)) and
      Enum.count(rows, fn [_version, status] -> status == "active" end) == 1
  end

  defp shared_consistent?(pg, workspace) do
    Enum.all?(0..9, fn i ->
      id = "#{workspace}-shared-#{i}"
      {:ok, context} = pg.get_context(id)
      {:ok, rows} = pg.raw_query("SELECT name FROM entities WHERE context_id = ?1", [id])
      Enum.sort(Enum.map(rows, &hd/1)) == Enum.sort(context.entities)
    end)
  end

  defp count(store, sql, params) do
    {:ok, [[n]]} = store.raw_query(sql, params)
    n
  end

  # The check role runs without the engine: it starts the two stores itself.
  defp start_stores(sqlite: sqlite?) do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = OptimalEngine.Store.Postgres.start_link()
    if sqlite?, do: {:ok, _} = OptimalEngine.Store.SQLite.start_link()
  end

  defp wait_for(file) do
    unless File.exists?(file) do
      Process.sleep(50)
      wait_for(file)
    end
  end

  defp workspace, do: System.fetch_env!("OPTIMAL_PROOF_WORKSPACE")
  defp path(name), do: Path.join(System.fetch_env!("OPTIMAL_PROOF_DIR"), name)
end

ProofTwoEngines.main(System.argv())
