defmodule OptimalEngine.Store.PostgresTwoWritersTest do
  @moduledoc """
  Stage 3 acceptance for the PostgreSQL provider.

  Two engine nodes, each a separate BEAM operating-system process with its own
  `OptimalEngine.Store.Postgres`, write one workspace in one PostgreSQL
  database at the same time (`OptimalEngine.Test.PostgresWriter`). Then:

  - nothing is lost: every context, every counter increment and every claim
    is there exactly once, and a context both nodes replaced holds one
    version's entities, never a mix;
  - the embedded SQLite store, given the same writes, answers 20 queries
    exactly as PostgreSQL does.

  The embedded copy replays every write both nodes made, in one process, then
  the version of each shared context that won on PostgreSQL. Edges are never
  removed when a context is replaced, on either store, so the copy holds the
  edges of every version, as PostgreSQL does.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Postgres, as: PgStore
  alias OptimalEngine.Test.{PostgresStore, PostgresWriter}

  @moduletag :postgres
  @moduletag timeout: 600_000

  @rounds 50

  setup_all do
    schema = PostgresStore.unique_schema()
    workspace = "pg-proof-#{System.unique_integer([:positive])}"
    options = PostgresStore.options(schema, pool_size: 6)

    peers = for _ <- 1..2, do: start_peer()

    # The two nodes start together: the schema is created once between them.
    started =
      peers
      |> Enum.map(
        &Task.async(fn -> :peer.call(&1, PostgresWriter, :start_store, [options], 180_000) end)
      )
      |> Task.await_many(200_000)

    assert started == [:ok, :ok]

    start_supervised!({PgStore, options})
    on_exit(fn -> PostgresStore.drop_schema(schema) end)

    register_workspace(workspace)

    :ok =
      PgStore.raw_execute(
        "INSERT INTO sessions (id, message_count, workspace_id) VALUES (?1, 0, ?2)",
        ["#{workspace}-counter", workspace]
      )

    reports =
      peers
      |> Enum.with_index(1)
      |> Enum.map(fn {peer, writer} ->
        Task.async(fn ->
          :peer.call(peer, PostgresWriter, :run, [writer, workspace, @rounds], 500_000)
        end)
      end)
      |> Task.await_many(520_000)

    Enum.each(peers, &:peer.stop/1)

    %{workspace: workspace, reports: reports}
  end

  defp start_peer do
    args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: args, wait_boot: 60_000})

    peer
  end

  defp register_workspace(workspace) do
    sql =
      "INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name) VALUES (?1, 'default', ?1, ?1)"

    :ok = Store.raw_execute(sql, [workspace])
    :ok = PgStore.raw_execute(sql, [workspace])
  end

  defp pg!(sql, params) do
    {:ok, rows} = PgStore.raw_query(sql, params)
    rows
  end

  describe "two engine nodes writing one workspace" do
    test "neither node saw an error", %{reports: reports} do
      for report <- reports, do: assert(report.errors == [], inspect(report.errors))
    end

    test "the nodes really conflicted, and PostgreSQL's aborts were run again",
         %{reports: reports} do
      retried = Enum.sum(Enum.map(reports, & &1.retried_transactions))

      IO.puts(
        "two writers: #{retried} transactions and " <>
          "#{Enum.sum(Enum.map(reports, & &1.retried_statements))} statements ran again"
      )

      assert retried > 0
    end

    test "every context is there exactly once", %{workspace: workspace} do
      # Each node: 40 single rounds, 10 batch rounds of 5; plus 10 shared ids.
      own = 2 * (40 + 10 * 5)
      assert [[count]] = pg!("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [workspace])
      assert count == own + 10
    end

    test "no counter increment is lost", %{workspace: workspace} do
      assert [[count]] =
               pg!("SELECT message_count FROM sessions WHERE id = ?1", ["#{workspace}-counter"])

      assert count == 2 * @rounds
    end

    test "every key is claimed by exactly one node", %{workspace: workspace, reports: reports} do
      claimed = Enum.flat_map(reports, & &1.claimed)
      assert length(claimed) == 25
      assert length(Enum.uniq(claimed)) == 25

      assert [[25]] =
               pg!("SELECT COUNT(*) FROM sessions WHERE workspace_id = ?1 AND id LIKE ?2", [
                 workspace,
                 "#{workspace}-claim-%"
               ])
    end

    test "a context both nodes replaced holds one version's entities", %{workspace: workspace} do
      for i <- 0..9 do
        id = "#{workspace}-shared-#{i}"
        {:ok, context} = PgStore.get_context(id)

        entities =
          "SELECT name FROM entities WHERE context_id = ?1"
          |> pg!([id])
          |> Enum.map(&hd/1)
          |> Enum.sort()

        assert entities == Enum.sort(context.entities)
        assert Enum.count(entities, &String.contains?(&1, "-writer-")) == 1
      end
    end
  end

  describe "the embedded SQLite copy" do
    setup %{workspace: workspace} do
      :ok = PostgresWriter.replay(Store, PgStore, workspace, @rounds)
    end

    test "answers 20 queries exactly as PostgreSQL does", %{workspace: workspace} do
      assert length(PostgresWriter.parity_queries(workspace)) == 20

      mismatches = PostgresWriter.mismatches(Store, PgStore, workspace)
      assert mismatches == [], inspect(mismatches, pretty: true)
    end
  end
end
