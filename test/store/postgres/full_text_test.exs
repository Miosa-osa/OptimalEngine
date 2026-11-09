defmodule OptimalEngine.Store.Postgres.FullTextTest do
  @moduledoc """
  The PostgreSQL full-text indexes hold FTS5's tokens and rank as FTS5's
  bm25() does: the same corpus is indexed by an FTS5 table and by the
  PostgreSQL store, and every query returns the same rows with the same
  scores. The index follows every insert, update, delete and cascade.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store.FullText
  alias OptimalEngine.Store.Postgres, as: PgStore
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres
  # Starts its own PostgreSQL store beside the embedded one, which a
  # PostgreSQL build already runs as OptimalEngine.Store.
  @moduletag :sqlite_store

  # Hyphens and underscores make phrases; repeats, long rows, diacritics, case,
  # other scripts and an empty title exercise tf, length normalisation and the
  # tokenizer.
  @corpus [
    {"a1", "Release plan", "The release plan for the platform launch. Launch the platform."},
    {"a2", "Launch retro",
     "launch launch launch: what went wrong with the go-live and the roll_out"},
    {"a3", "", "Café naïve résumé ÉCOLE Ærøskøbing straße"},
    {"a4", "Go-live checklist", "go live checklist; go-live owners; live go"},
    {"a5", "東京タワー", "東京タワー visit and 東京 trip with x² and Ωmega"},
    {"a6", "Budget", String.duplicate("budget forecast quarter ", 80) <> "launch"},
    {"a7", "Roll out", "roll out the roll_out plan, rolling rollout"},
    {"a8", "Meeting notes", "notes about the platform, nothing about launches"},
    {"a9", "Ops", "OPS ops Ops oPs runbook"},
    {"a10", "Empty", ""}
  ]

  @memories [
    {"m1", "Running the runners while they ran a run"},
    {"m2", "connection connected connecting connections"},
    {"m3", "the generous generalization of general generals"},
    {"m4", "happily happiness happy"},
    {"m5", "nothing in common here"}
  ]

  @queries [
    ~s("launch"),
    ~s("launch" OR "platform"),
    ~s("go-live" OR "checklist"),
    ~s("roll_out" OR "rollout"),
    ~s("platform" "launch"),
    ~s("cafe" OR "ecole" OR "strasse" OR "straße"),
    ~s("東京タワー" OR "東京"),
    ~s("ops"),
    ~s("budget" OR "launch" OR "notes"),
    ~s("go" "live"),
    ~s("laun"*),
    ~s("go" "liv"*),
    ~s("roll out"),
    ~s("nothingmatches"),
    ~s("")
  ]

  @memory_queries [
    ~s("running"),
    ~s("run" OR "connect"),
    ~s("generals" OR "happy"),
    ~s("connections" "connected")
  ]

  setup_all do
    schema = PostgresStore.unique_schema()

    start_supervised!(
      {PgStore, PostgresStore.options(schema, pool_size: 4, full_text_interval_ms: 0)}
    )

    on_exit(fn -> PostgresStore.drop_schema(schema) end)
    :ok
  end

  setup do
    :ok = PgStore.raw_execute("DELETE FROM contexts", [])
    :ok = PgStore.raw_execute("DELETE FROM memories", [])
    :ok = PgStore.refresh_full_text(["contexts_fts", "memories_fts"])
    :ok
  end

  defp insert_context(id, title, content, workspace \\ "default") do
    :ok =
      PgStore.raw_execute(
        "INSERT INTO contexts (id, uri, title, content, workspace_id) VALUES (?1, ?2, ?3, ?4, ?5)",
        [id, "optimal://test/#{id}", title, content, workspace]
      )
  end

  defp insert_memory(id, content) do
    :ok =
      PgStore.raw_execute(
        "INSERT INTO memories (id, tenant_id, workspace_id, content) VALUES (?1, 'default', 'default', ?2)",
        [id, content]
      )
  end

  # The same rows in an FTS5 table shaped like the store's.
  defp sqlite_index(ddl, rows) do
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")
    :ok = Exqlite.Sqlite3.execute(db, ddl)
    marks = Enum.map_join(1..length(hd(rows)), ", ", fn _ -> "?" end)
    {:ok, insert} = Exqlite.Sqlite3.prepare(db, "INSERT INTO t VALUES (#{marks})")

    for row <- rows do
      :ok = Exqlite.Sqlite3.bind(insert, row)
      :done = Exqlite.Sqlite3.step(db, insert)
      :ok = Exqlite.Sqlite3.reset(insert)
    end

    db
  end

  defp sqlite_scores(db, match) do
    {:ok, statement} =
      Exqlite.Sqlite3.prepare(db, "SELECT id, -bm25(t) FROM t WHERE t MATCH ?1 ORDER BY id")

    :ok = Exqlite.Sqlite3.bind(statement, [match])
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
    Map.new(rows, &List.to_tuple/1)
  end

  defp postgres_scores(index, match) do
    {:ok, param} = FullText.query_param(index, match)

    {:ok, rows} =
      PgStore.raw_query("SELECT doc_key, score FROM optimal_fts_match(?1, ?2)", [index, param])

    Map.new(rows, &List.to_tuple/1)
  end

  defp assert_same_scores(sqlite, postgres, query) do
    assert Map.keys(postgres) |> Enum.sort() == Map.keys(sqlite) |> Enum.sort(), query

    for {id, expected} <- sqlite do
      actual = Map.fetch!(postgres, id)

      assert abs(actual - expected) <= 1.0e-12 * max(1.0, abs(expected)),
             "#{query}: #{id} scored #{actual} on PostgreSQL and #{expected} on SQLite"
    end
  end

  test "contexts rank as contexts_fts ranks them, query for query" do
    for {id, title, content} <- @corpus, do: insert_context(id, title, content)

    db =
      sqlite_index(
        "CREATE VIRTUAL TABLE t USING fts5(id UNINDEXED, title, content, node UNINDEXED)",
        Enum.map(@corpus, fn {id, title, content} -> [id, title, content, "inbox"] end)
      )

    for query <- @queries do
      assert_same_scores(sqlite_scores(db, query), postgres_scores("contexts_fts", query), query)
    end

    # Not a corpus where nothing matches: most queries find several rows.
    assert map_size(postgres_scores("contexts_fts", ~s("launch" OR "platform"))) >= 4
  end

  test "memories rank as memories_fts ranks them, Porter stems included" do
    for {id, content} <- @memories, do: insert_memory(id, content)

    db =
      sqlite_index(
        "CREATE VIRTUAL TABLE t USING fts5(id UNINDEXED, content, tokenize='porter unicode61')",
        Enum.map(@memories, fn {id, content} -> [id, content] end)
      )

    for query <- @memory_queries do
      assert_same_scores(sqlite_scores(db, query), postgres_scores("memories_fts", query), query)
    end

    assert Map.keys(postgres_scores("memories_fts", ~s("running"))) == ["m1"]
  end

  test "the index follows inserts, updates, deletes and key changes" do
    insert_context("x1", "alpha", "first body")
    insert_context("x2", "beta", "second body")

    assert Map.keys(postgres_scores("contexts_fts", ~s("alpha"))) == ["x1"]

    :ok = PgStore.raw_execute("UPDATE contexts SET content = 'alpha again' WHERE id = 'x2'", [])
    assert Map.keys(postgres_scores("contexts_fts", ~s("alpha"))) |> Enum.sort() == ["x1", "x2"]

    :ok = PgStore.raw_execute("UPDATE contexts SET title = 'gamma' WHERE id = 'x1'", [])
    assert Map.keys(postgres_scores("contexts_fts", ~s("alpha"))) == ["x2"]

    :ok = PgStore.raw_execute("UPDATE contexts SET id = 'x3' WHERE id = 'x1'", [])
    assert Map.keys(postgres_scores("contexts_fts", ~s("gamma"))) == ["x3"]

    :ok = PgStore.raw_execute("DELETE FROM contexts WHERE id = 'x2'", [])
    assert postgres_scores("contexts_fts", ~s("alpha")) == %{}

    # A metadata-only update does not queue the row.
    {:ok, [[before]]} = PgStore.raw_query("SELECT COUNT(*) FROM optimal_fts_queue", [])
    :ok = PgStore.raw_execute("UPDATE contexts SET sn_ratio = 0.9 WHERE id = 'x3'", [])
    {:ok, [[later]]} = PgStore.raw_query("SELECT COUNT(*) FROM optimal_fts_queue", [])
    assert later == before

    # The totals are those of the rows left.
    {:ok, [[docs, tokens]]} =
      PgStore.raw_query(
        "SELECT docs, tokens FROM optimal_fts_totals WHERE index_name = 'contexts_fts'",
        []
      )

    assert docs == 1
    assert tokens == 3
  end

  test "a bulk delete takes every row it deletes out of the index" do
    for {id, title, content} <- @corpus, do: insert_context(id, title, content)
    insert_context("other", "launch", "kept", "other-workspace")

    :ok = PgStore.raw_execute("DELETE FROM contexts WHERE workspace_id = 'default'", [])
    assert {:ok, [[1]]} = PgStore.raw_query("SELECT COUNT(*) FROM contexts_fts", [])
    assert Map.keys(postgres_scores("contexts_fts", ~s("launch"))) == ["other"]
  end

  test "counting through the contexts_fts view reads an index brought up to date" do
    for {id, title, content} <- @corpus, do: insert_context(id, title, content)

    assert {:ok, [[10, 10, 10]]} =
             PgStore.raw_query(
               """
               SELECT (SELECT COUNT(*) FROM contexts), (SELECT COUNT(*) FROM contexts_fts),
                      (SELECT COUNT(DISTINCT id) FROM contexts_fts)
               """,
               []
             )
  end

  test "rebuilding an index gives the same scores" do
    for {id, title, content} <- @corpus, do: insert_context(id, title, content)
    before = postgres_scores("contexts_fts", ~s("launch" OR "platform"))
    :ok = PgStore.rebuild_full_text("contexts_fts")
    assert postgres_scores("contexts_fts", ~s("launch" OR "platform")) == before
  end

  test "rows written while refreshes run are all indexed in the end" do
    writer =
      Task.async(fn ->
        for n <- 1..150, do: insert_context("w#{n}", "written", "while refreshing #{n}")
      end)

    refresher =
      Task.async(fn ->
        for _ <- 1..30, do: :ok = PgStore.refresh_full_text(["contexts_fts"])
      end)

    Task.await(writer, 60_000)
    Task.await(refresher, 60_000)

    assert map_size(postgres_scores("contexts_fts", ~s("written"))) == 150

    assert {:ok, [[150, 150]]} =
             PgStore.raw_query(
               "SELECT (SELECT COUNT(*) FROM contexts), (SELECT COUNT(*) FROM contexts_fts)",
               []
             )
  end

  test "an index created at runtime ranks as an FTS5 external-content table, diacritics folded" do
    rows = [
      {1, "Crème brûlée recipe", "dessert"},
      {2, "creme brulee, the classic", "dessert classic"},
      {3, "Ǖber ǘmlaut ṏver", "accents stacked"},
      {4, "plain text row", "nothing"},
      {5, "recipe recipe recipe", "dessert"}
    ]

    {:ok, _} =
      PgStore.transaction(fn txn ->
        with {:ok, _} <-
               PgStore.txn_execute_native(
                 txn,
                 ~s[CREATE TABLE "fts_probe" ("_rowid" BIGINT PRIMARY KEY, "f_a" TEXT, "f_b" TEXT)]
               ),
             :ok <-
               OptimalEngine.Store.Postgres.FullText.create_index(txn, %{
                 name: "fts_probe_fts",
                 table: "fts_probe",
                 key: "_rowid",
                 key_type: "bigint",
                 columns: ["f_a", "f_b"],
                 tokenize: "unicode61 remove_diacritics 2"
               }) do
          {:ok, :created}
        end
      end)

    for {rowid, a, b} <- rows do
      :ok =
        PgStore.raw_execute(
          ~s[INSERT INTO "fts_probe" ("_rowid", "f_a", "f_b") VALUES (?1, ?2, ?3)],
          [
            rowid,
            a,
            b
          ]
        )
    end

    db =
      sqlite_index(
        "CREATE VIRTUAL TABLE t USING fts5(id UNINDEXED, a, b, tokenize='unicode61 remove_diacritics 2')",
        Enum.map(rows, fn {rowid, a, b} -> [Integer.to_string(rowid), a, b] end)
      )

    for query <- [
          ~s("creme"),
          ~s("brulee" OR "recipe"),
          ~s("uber" "umlaut"),
          ~s("des"*),
          ~s("over")
        ] do
      {:ok, param} = FullText.query_json("unicode61 remove_diacritics 2", query)

      {:ok, found} =
        PgStore.raw_query("SELECT doc_key, score FROM optimal_fts_match('fts_probe_fts', ?1)", [
          param
        ])

      assert_same_scores(sqlite_scores(db, query), Map.new(found, &List.to_tuple/1), query)
    end

    # Dropped with its table, it leaves nothing behind.
    {:ok, _} =
      PgStore.transaction(fn txn ->
        with :ok <-
               OptimalEngine.Store.Postgres.FullText.drop_index(txn, "fts_probe_fts", "fts_probe"),
             {:ok, _} <- PgStore.txn_execute_native(txn, ~s[DROP TABLE "fts_probe"]) do
          {:ok, :dropped}
        end
      end)

    assert {:ok, [[0]]} =
             PgStore.raw_query(
               "SELECT COUNT(*) FROM optimal_fts_postings WHERE index_name = 'fts_probe_fts'",
               []
             )
  end

  describe "query syntax" do
    test "the forms the engine builds parse" do
      assert {:ok, %{any: true, phrases: [%{text: "a"}, %{text: "b c"}]}} =
               FullText.parse(~s("a" OR "b c"))

      assert {:ok, %{any: false, phrases: [%{text: "a", prefix: false}, %{prefix: true}]}} =
               FullText.parse(~s("a" "b"*))

      assert {:ok, %{phrases: [%{text: ""}]}} = FullText.parse(~s(""))
    end

    test "anything else is refused by name" do
      for match <- [~s(a OR b), ~s("a" AND "b"), ~s("a" OR "b" "c"), ~s("a"* "b"), ~s[NEAR("a")]] do
        assert {:error, {:unsupported, "FTS5 query syntax"}} = FullText.parse(match), match
      end
    end
  end
end
