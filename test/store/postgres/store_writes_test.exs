defmodule OptimalEngine.Store.PostgresWritesTest do
  @moduledoc """
  The write side of the PostgreSQL store, against the embedded SQLite store:
  each write goes to both, and the rows each database then holds must match.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Context, Store}
  alias OptimalEngine.Store.Postgres, as: PgStore
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres

  setup_all do
    schema = PostgresStore.unique_schema()
    start_supervised!({PgStore, PostgresStore.options(schema, pool_size: 8)})
    on_exit(fn -> PostgresStore.drop_schema(schema) end)
    :ok
  end

  setup do
    %{run: "pgw-#{System.unique_integer([:positive])}"}
  end

  defp context(id, node, entities, opts \\ []) do
    %Context{
      id: id,
      uri: "optimal://nodes/#{node}/#{id}",
      type: Keyword.get(opts, :type, :resource),
      path: "#{node}/#{id}.md",
      title: Keyword.get(opts, :title, "Title #{id}"),
      content: "Body of #{id}",
      l0_abstract: "abstract",
      l1_overview: "overview",
      node: node,
      sn_ratio: 0.5,
      entities: entities,
      created_at: ~U[2026-10-01 09:00:00Z],
      modified_at: Keyword.get(opts, :modified_at, ~U[2026-10-02 09:00:00Z]),
      routed_to: Keyword.get(opts, :routed_to, [node]),
      supersedes: Keyword.get(opts, :supersedes),
      metadata: %{"k" => "v"},
      workspace_id: Keyword.get(opts, :workspace_id, "default")
    }
  end

  # The same statement on both stores, compared as sorted rows.
  defp both(sql, params) do
    {:ok, sqlite} = Store.raw_query(sql, params)
    {:ok, postgres} = PgStore.raw_query(sql, params)
    {Enum.sort(sqlite), Enum.sort(postgres)}
  end

  defp assert_same(sql, params) do
    {sqlite, postgres} = both(sql, params)
    assert postgres == sqlite, sql
    sqlite
  end

  describe "contexts" do
    test "a written context, its entities and its edges match SQLite", %{run: run} do
      names = ["#{run}-alice", "#{run}-bob", "#{run}-carol"]

      ctx =
        context("#{run}-1", "#{run}-node", names,
          routed_to: ["#{run}-node", "#{run}-other"],
          supersedes: "#{run}-0"
        )

      :ok = Store.insert_context(ctx)
      :ok = PgStore.insert_context(ctx)

      assert {:ok, postgres} = PgStore.get_context(ctx.id)
      assert {:ok, ^postgres} = Store.get_context(ctx.id)

      assert [_, _, _] =
               assert_same(
                 "SELECT context_id, name, type, workspace_id FROM entities WHERE context_id = ?1",
                 [ctx.id]
               )

      edges =
        assert_same(
          "SELECT source_id, target_id, relation, weight, workspace_id, tenant_id FROM graph_edges " <>
            "WHERE source_id = ?1 OR target_id = ?1 OR (source_id LIKE ?2 AND target_id LIKE ?2)",
          [ctx.id, "#{run}-%"]
        )

      relations = edges |> Enum.map(&Enum.at(&1, 2)) |> Enum.uniq() |> Enum.sort()
      assert relations == ["co_occurs", "cross_ref", "lives_in", "mentioned_in", "supersedes"]
    end

    test "an unregistered <tenant>:<slug> workspace gives its contexts and edges that tenant",
         %{run: run} do
      tenant = "#{run}-t"

      for store <- [Store, PgStore] do
        :ok =
          store.raw_execute("INSERT INTO tenants (id, name) VALUES (?1, ?2)", [tenant, tenant])
      end

      named = "#{tenant}:ops"
      unknown = "#{run}-missing:ops"

      for {id, ws} <- [{"#{run}-named", named}, {"#{run}-unknown", unknown}] do
        ctx = context(id, "#{run}-node", ["#{run}-alice"], workspace_id: ws)
        :ok = Store.insert_context(ctx)
        :ok = PgStore.insert_context(ctx)
      end

      assert [[_, ^tenant], [_, "default"]] =
               assert_same(
                 "SELECT id, tenant_id FROM contexts WHERE id IN (?1, ?2) ORDER BY id",
                 ["#{run}-named", "#{run}-unknown"]
               )

      assert [[^unknown, "default"], [^named, ^tenant]] =
               assert_same(
                 "SELECT DISTINCT workspace_id, tenant_id FROM graph_edges WHERE workspace_id IN (?1, ?2)",
                 [named, unknown]
               )
    end

    test "writing a context again replaces it the way INSERT OR REPLACE does", %{run: run} do
      first = context("#{run}-1", "#{run}-node", ["alice", "bob"], title: "first")
      second = %{first | title: "second", entities: ["bob", "dave"]}

      for ctx <- [first, second] do
        :ok = Store.insert_context(ctx)
        :ok = PgStore.insert_context(ctx)
      end

      assert {:ok, %Context{title: "second"}} = PgStore.get_context(first.id)

      assert_same("SELECT name FROM entities WHERE context_id = ?1", [first.id])
      assert_same("SELECT COUNT(*) FROM contexts WHERE id = ?1", [first.id])
    end

    test "insert_contexts writes all in one transaction", %{run: run} do
      contexts = for i <- 1..5, do: context("#{run}-#{i}", "#{run}-node", ["e#{i}"])

      assert {:ok, 5} = Store.insert_contexts(contexts)
      assert {:ok, 5} = PgStore.insert_contexts(contexts)

      {:ok, sqlite} = Store.get_by_node("#{run}-node")
      {:ok, postgres} = PgStore.get_by_node("#{run}-node")
      assert Enum.sort_by(postgres, & &1.id) == Enum.sort_by(sqlite, & &1.id)
    end

    test "deleting a context deletes its entities, as on SQLite", %{run: run} do
      ctx = context("#{run}-1", "#{run}-node", ["alice"])

      for store <- [Store, PgStore] do
        :ok = store.insert_context(ctx)
        :ok = store.delete_context(ctx.id)
        assert {:error, :not_found} = store.get_context(ctx.id)
      end

      assert [[0]] = assert_same("SELECT COUNT(*) FROM entities WHERE context_id = ?1", [ctx.id])
    end
  end

  describe "statements and transactions" do
    test "raw_execute and raw_query take SQLite statements", %{run: run} do
      sql = "INSERT OR IGNORE INTO decisions (title, decision, decided_by) VALUES (?1, ?2, ?3)"

      assert :ok = PgStore.raw_execute(sql, [run, "ship it", "tester"])

      assert {:ok, [[^run, "ship it", decided_at]]} =
               PgStore.raw_query(
                 "SELECT title, decision, decided_at FROM decisions WHERE title = ?1",
                 [run]
               )

      assert decided_at =~ ~r/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/
    end

    test "txn_execute returns the changed row count and the fun's result commits", %{run: run} do
      :ok = PgStore.insert_context(context("#{run}-1", "#{run}-node", []))

      assert {:ok, {1, 0}} =
               PgStore.transaction(fn txn ->
                 {:ok, changed} =
                   PgStore.txn_execute(txn, "UPDATE contexts SET title = ?1 WHERE id = ?2", [
                     "renamed",
                     "#{run}-1"
                   ])

                 {:ok, none} =
                   PgStore.txn_execute(txn, "UPDATE contexts SET title = ?1 WHERE id = ?2", [
                     "x",
                     "#{run}-missing"
                   ])

                 {:ok, [[title]]} =
                   PgStore.txn_query(txn, "SELECT title FROM contexts WHERE id = ?1", ["#{run}-1"])

                 assert title == "renamed"
                 {:ok, {changed, none}}
               end)

      assert {:ok, %Context{title: "renamed"}} = PgStore.get_context("#{run}-1")
    end
  end

  describe "pipeline rows" do
    test "chunks, classifications, intents, embeddings and clusters match SQLite", %{run: run} do
      ctx = context("#{run}-doc", "#{run}-node", [])
      :ok = Store.insert_context(ctx)
      :ok = PgStore.insert_context(ctx)

      chunk = %{
        id: "#{run}-chunk",
        tenant_id: "default",
        signal_id: ctx.id,
        parent_id: nil,
        scale: :document,
        offset_bytes: 0,
        length_bytes: 12,
        text: "chunk text",
        modality: :text,
        asset_ref: nil,
        classification_level: "internal",
        created_at: "2026-10-01T09:00:00Z",
        workspace_id: "default"
      }

      classification = %{
        chunk_id: chunk.id,
        mode: :linguistic,
        genre: "note",
        signal_type: :inform,
        format: :markdown,
        structure: "prose",
        sn_ratio: 0.8,
        confidence: 0.9
      }

      intent = %{chunk_id: chunk.id, intent: :record_fact, confidence: 0.7, evidence: "why"}

      embedding = %{
        chunk_id: chunk.id,
        model: "test-embed",
        modality: :text,
        vector: [0.0, 0.5, -1.25, 3.0]
      }

      cluster = %{
        id: "#{run}-cluster",
        theme: "theme",
        intent_dominant: :record_fact,
        member_count: 1,
        centroid: [1.0, 0.0],
        updated_at: "2026-10-01 09:00:00"
      }

      member = %{cluster_id: cluster.id, chunk_id: chunk.id, weight: 0.5}

      for store <- [Store, PgStore] do
        assert :ok = store.insert_chunks([chunk])
        assert :ok = store.insert_classifications([classification])
        assert :ok = store.insert_intents([intent])
        assert :ok = store.insert_embeddings([embedding])
        assert :ok = store.insert_clusters([cluster])
        assert :ok = store.insert_cluster_members([member])
      end

      id = [chunk.id]

      assert [_] =
               assert_same(
                 "SELECT id, tenant_id, signal_id, scale, offset_bytes, length_bytes, text, modality, " <>
                   "classification_level, created_at, workspace_id FROM chunks WHERE id = ?1",
                 id
               )

      assert [_] =
               assert_same(
                 "SELECT mode, genre, signal_type, format, structure, sn_ratio, confidence FROM classifications WHERE chunk_id = ?1",
                 id
               )

      assert [_] =
               assert_same(
                 "SELECT intent, confidence, evidence FROM intents WHERE chunk_id = ?1",
                 id
               )

      assert [[_model, _dim, vector]] =
               assert_same(
                 "SELECT model, dim, vector FROM chunk_embeddings WHERE chunk_id = ?1",
                 id
               )

      assert byte_size(vector) == 16

      assert [_] =
               assert_same(
                 "SELECT theme, intent_dominant, member_count, centroid, updated_at FROM clusters WHERE id = ?1",
                 [cluster.id]
               )

      assert [_] = assert_same("SELECT weight FROM cluster_members WHERE chunk_id = ?1", id)

      # A chunk written again replaces the row as INSERT OR REPLACE does.
      for store <- [Store, PgStore] do
        assert :ok = store.insert_chunks([%{chunk | text: "rewritten"}])
      end

      assert_same("SELECT text FROM chunks WHERE id = ?1", id)
      assert_same("SELECT COUNT(*) FROM classifications WHERE chunk_id = ?1", id)
      assert_same("SELECT COUNT(*) FROM chunk_embeddings WHERE chunk_id = ?1", id)
    end
  end

  test "concurrent writers in one workspace lose nothing", %{run: run} do
    :ok = PgStore.raw_execute("INSERT INTO decisions (title, decision) VALUES (?1, '0')", [run])

    results =
      1..8
      |> Task.async_stream(
        fn writer ->
          contexts = for i <- 1..10, do: context("#{run}-#{writer}-#{i}", "#{run}-node", ["shared"])
          {:ok, 10} = PgStore.insert_contexts(contexts)

          for _ <- 1..5 do
            {:ok, _} =
              PgStore.transaction(fn txn ->
                {:ok, [[n]]} =
                  PgStore.txn_query(txn, "SELECT decision FROM decisions WHERE title = ?1", [run])

                {:ok, 1} =
                  PgStore.txn_execute(txn, "UPDATE decisions SET decision = ?1 WHERE title = ?2", [
                    Integer.to_string(String.to_integer(n) + 1),
                    run
                  ])

                {:ok, n}
              end)
          end

          :done
        end,
        timeout: 120_000,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :done}))

    assert {:ok, [[80]]} =
             PgStore.raw_query("SELECT COUNT(*) FROM contexts WHERE node = ?1", ["#{run}-node"])

    assert {:ok, [["40"]]} =
             PgStore.raw_query("SELECT decision FROM decisions WHERE title = ?1", [run])

    assert {:ok, [[80]]} =
             PgStore.raw_query(
               "SELECT COUNT(*) FROM graph_edges WHERE relation = 'mentioned_in' AND source_id = 'shared' " <>
                 "AND target_id LIKE ?1",
               ["#{run}-%"]
             )
  end
end
