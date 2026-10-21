defmodule OptimalEngine.Test.PostgresWriter do
  @moduledoc false
  # The workload one engine node runs in the two-writer proof. In the test
  # (test/store/postgres/two_writers_test.exs) it runs inside a peer BEAM
  # process with its own PostgreSQL store; in
  # scripts/proof-postgres-two-engines.sh it runs inside a whole engine built
  # with the PostgreSQL store, through OptimalEngine.Store. Either way the two
  # writers share nothing but the database.
  #
  # Every round a writer does four things to one workspace:
  #
  # - writes a context of its own (alone, or in a batch of five);
  # - writes a context every writer also writes, with its own entities, so the
  #   two replace each other's rows;
  # - increments a shared counter with a read-check-write transaction;
  # - claims a key with an insert-if-absent transaction.

  alias OptimalEngine.Context
  alias OptimalEngine.Store.Postgres, as: PgStore

  @doc "Starts this node's store, unlinked from the caller."
  def start_store(opts) do
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.configure(level: :error)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    caller = self()

    spawn(fn ->
      send(caller, {:store, PgStore.start_link(opts)})

      receive do
        :stop -> :ok
      end
    end)

    receive do
      {:store, {:ok, _pid}} -> :ok
      {:store, other} -> {:error, other}
    after
      120_000 -> {:error, :timeout}
    end
  end

  @doc """
  The contexts `writer` writes, round by round: its own (one, or a batch of
  five every fifth round) and the shared one.
  """
  def plan(writer, workspace, rounds) do
    for round <- 1..rounds do
      %{
        round: round,
        own: own_contexts(writer, workspace, round),
        shared: shared_context(writer, workspace, round)
      }
    end
  end

  @doc "Every context `writer` writes, in order."
  def contexts(writer, workspace, rounds) do
    writer
    |> plan(workspace, rounds)
    |> Enum.flat_map(&(&1.own ++ [&1.shared]))
  end

  @doc """
  Runs `rounds` rounds as `writer` against `workspace` and returns what
  happened, with how many statements and transactions PostgreSQL aborted and
  the store ran again.
  """
  def run(writer, workspace, rounds, store \\ PgStore) do
    retries = :counters.new(2, [])

    :telemetry.attach(
      {__MODULE__, :retries},
      [:optimal_engine, :store, :retry],
      &__MODULE__.count_retry/4,
      retries
    )

    results =
      for step <- plan(writer, workspace, rounds) do
        %{
          own: write_own(store, step.own),
          shared: store.insert_context(step.shared),
          increment: increment(store, workspace),
          claim: claim(store, writer, workspace, step.round)
        }
      end

    %{
      errors:
        for(
          result <- results,
          {step, outcome} <- result,
          not ok?(outcome),
          do: {step, outcome}
        ),
      claimed: for(%{claim: {:ok, {:claimed, key}}} <- results, do: key),
      retried_statements: :counters.get(retries, 1),
      retried_transactions: :counters.get(retries, 2)
    }
  end

  @doc false
  def count_retry(_event, _measurements, %{scope: :statement}, retries),
    do: :counters.add(retries, 1, 1)

  def count_retry(_event, _measurements, %{scope: :transaction}, retries),
    do: :counters.add(retries, 2, 1)

  defp ok?(:ok), do: true
  defp ok?({:ok, _}), do: true
  defp ok?(_), do: false

  # A batch is written in one transaction.
  defp write_own(store, [context]), do: store.insert_context(context)
  defp write_own(store, contexts), do: store.insert_contexts(contexts)

  defp own_contexts(writer, workspace, round) do
    if rem(round, 5) == 0 do
      for i <- 1..5 do
        context("#{workspace}-w#{writer}-#{round}-#{i}", workspace, writer, [
          "#{workspace}-person-#{rem(round + i, 7)}"
        ])
      end
    else
      [
        context("#{workspace}-w#{writer}-#{round}", workspace, writer, [
          "#{workspace}-person-#{rem(round, 7)}",
          "#{workspace}-person-#{rem(round + writer, 7)}"
        ])
      ]
    end
  end

  @doc """
  The shared context `writer` writes in `round`. Both writers write the same
  ids; whichever commits last owns the row and its entities, and nothing of the
  other version may remain.
  """
  def shared_context(writer, workspace, round) do
    id = "#{workspace}-shared-#{rem(round, 10)}"

    context(id, workspace, writer, [
      "#{workspace}-writer-#{writer}",
      "#{workspace}-round-#{round}"
    ])
  end

  defp increment(store, workspace) do
    counter = "#{workspace}-counter"

    store.transaction(fn txn ->
      {:ok, [[count]]} =
        store.txn_query(txn, "SELECT message_count FROM sessions WHERE id = ?1", [counter])

      {:ok, 1} =
        store.txn_execute(txn, "UPDATE sessions SET message_count = ?1 WHERE id = ?2", [
          count + 1,
          counter
        ])

      {:ok, count + 1}
    end)
  end

  defp claim(store, writer, workspace, round) do
    key = "#{workspace}-claim-#{rem(round, 25)}"

    store.transaction(fn txn ->
      case store.txn_query(txn, "SELECT summary FROM sessions WHERE id = ?1", [key]) do
        {:ok, []} ->
          {:ok, 1} =
            store.txn_execute(
              txn,
              "INSERT INTO sessions (id, summary, workspace_id) VALUES (?1, ?2, ?3)",
              [key, "writer-#{writer}", workspace]
            )

          {:ok, {:claimed, key}}

        {:ok, [[_owner]]} ->
          {:ok, :taken}
      end
    end)
  end

  @doc "A context written by `writer` in `workspace`."
  def context(id, workspace, writer, entities) do
    %Context{
      id: id,
      uri: "optimal://workspaces/#{workspace}/#{id}",
      type: Enum.at([:resource, :memory, :signal], :erlang.phash2(id, 3)),
      path: "#{workspace}/#{id}.md",
      title: "Context #{id}",
      content: "Written by writer #{writer}",
      l0_abstract: "abstract",
      l1_overview: "overview",
      node: "#{workspace}-node-#{writer}",
      sn_ratio: 0.25 * writer,
      entities: entities,
      created_at: ~U[2026-10-20 09:00:00Z],
      modified_at: DateTime.add(~U[2026-10-20 09:00:00Z], :erlang.phash2(id, 10_000), :second),
      routed_to: ["#{workspace}-node-#{writer}", "#{workspace}-hub"],
      metadata: %{"writer" => "writer-#{writer}", "kind" => "proof"},
      workspace_id: workspace
    }
  end

  @doc """
  Builds the embedded copy: every write both writers made, in one process, on
  `sqlite`, then the version of each shared context that won on `postgres`,
  as the winning writer wrote it, and the counter and claim rows.
  """
  def replay(sqlite, postgres, workspace, rounds) do
    writes = for writer <- 1..2, do: contexts(writer, workspace, rounds)
    {:ok, _} = sqlite.insert_contexts(List.flatten(writes))
    {:ok, 10} = sqlite.insert_contexts(Enum.map(0..9, &winner(postgres, workspace, &1)))

    {:ok, sessions} =
      postgres.raw_query(
        "SELECT id, summary, message_count FROM sessions WHERE workspace_id = ?1",
        [workspace]
      )

    for [id, summary, count] <- sessions do
      :ok =
        sqlite.raw_execute(
          "INSERT OR REPLACE INTO sessions (id, summary, message_count, workspace_id) " <>
            "VALUES (?1, ?2, ?3, ?4)",
          [id, summary, count, workspace]
        )
    end

    :ok
  end

  defp winner(postgres, workspace, i) do
    {:ok, %{metadata: %{"writer" => "writer-" <> writer}, entities: entities}} =
      postgres.get_context("#{workspace}-shared-#{i}")

    ["round-" <> round] =
      for entity <- entities,
          suffix = String.replace_prefix(entity, "#{workspace}-", ""),
          String.starts_with?(suffix, "round-"),
          do: suffix

    shared_context(String.to_integer(writer), workspace, String.to_integer(round))
  end

  @doc "The parity queries whose rows differ between the two stores."
  def mismatches(sqlite, postgres, workspace) do
    for {sql, params} <- parity_queries(workspace),
        {:ok, expected} = sqlite.raw_query(sql, params),
        {:ok, actual} = postgres.raw_query(sql, params),
        expected != actual,
        do: %{sql: sql, sqlite: Enum.take(expected, 5), postgres: Enum.take(actual, 5)}
  end

  # Twenty reads of the shapes the engine issues: counts, ordering and
  # pagination, grouping, joins, subqueries, JSON fields, text timestamps,
  # entities, edges, and the signals view. Each is scoped to the proof's
  # workspace, so rows other tests left in the embedded store do not count.
  def parity_queries(ws) do
    [
      {"SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [ws]},
      {"SELECT id, title, node, type, sn_ratio FROM contexts WHERE workspace_id = ?1 ORDER BY id",
       [ws]},
      {"SELECT node, COUNT(*) FROM contexts WHERE workspace_id = ?1 GROUP BY node ORDER BY node",
       [ws]},
      {"SELECT id FROM contexts WHERE workspace_id = ?1 ORDER BY modified_at DESC, id LIMIT 10",
       [ws]},
      {"SELECT id FROM contexts WHERE workspace_id = ?1 ORDER BY modified_at DESC, id LIMIT 10 OFFSET 10",
       [ws]},
      {"SELECT type, COUNT(*), MIN(sn_ratio), MAX(sn_ratio) FROM contexts WHERE workspace_id = ?1 GROUP BY type ORDER BY type",
       [ws]},
      {"SELECT name, COUNT(*) FROM entities WHERE workspace_id = ?1 GROUP BY name ORDER BY name",
       [ws]},
      {"SELECT e.name, c.id FROM entities e JOIN contexts c ON c.id = e.context_id WHERE c.workspace_id = ?1 ORDER BY e.name, c.id",
       [ws]},
      {"SELECT relation, COUNT(*) FROM graph_edges WHERE workspace_id = ?1 GROUP BY relation ORDER BY relation",
       [ws]},
      {"SELECT source_id, target_id, weight FROM graph_edges WHERE workspace_id = ?1 AND relation = 'co_occurs' ORDER BY source_id, target_id",
       [ws]},
      {"SELECT id, json_extract(metadata, '$.writer') FROM contexts WHERE workspace_id = ?1 ORDER BY id",
       [ws]},
      {"SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1 AND json_extract(metadata, '$.kind') = ?2",
       [ws, "proof"]},
      {"SELECT COUNT(DISTINCT node) FROM contexts WHERE workspace_id = ?1", [ws]},
      {"SELECT c.id, (SELECT COUNT(*) FROM entities e WHERE e.context_id = c.id) FROM contexts c WHERE c.workspace_id = ?1 ORDER BY c.id",
       [ws]},
      {"SELECT id FROM contexts c WHERE workspace_id = ?1 AND EXISTS (SELECT 1 FROM entities e WHERE e.context_id = c.id AND e.name = ?2) ORDER BY id",
       [ws, "#{ws}-writer-1"]},
      {"SELECT id, CASE WHEN sn_ratio >= 0.5 THEN 'high' ELSE 'low' END FROM contexts WHERE workspace_id = ?1 ORDER BY id",
       [ws]},
      {"SELECT id FROM contexts WHERE workspace_id = ?1 AND modified_at >= ?2 ORDER BY id",
       [ws, "2026-10-20T10:00:00Z"]},
      {"SELECT id, title, genre FROM signals WHERE id IN (SELECT id FROM contexts WHERE workspace_id = ?1) ORDER BY id",
       [ws]},
      {"SELECT id, summary, message_count FROM sessions WHERE workspace_id = ?1 ORDER BY id", [ws]},
      {"SELECT target_id, COUNT(*) FROM graph_edges WHERE workspace_id = ?1 AND relation IN ('lives_in', 'cross_ref') GROUP BY target_id HAVING COUNT(*) > 1 ORDER BY target_id",
       [ws]}
    ]
  end
end
