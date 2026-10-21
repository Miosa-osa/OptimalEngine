defmodule OptimalEngine.Store.Postgres.JsonExtractParityTest do
  @moduledoc """
  Every `json_extract` call site of the engine, run on SQLite and on
  PostgreSQL over the same rows.

  Each case names its call site and a fragment of the statement there; the
  fragment must still be in that file, so a changed call site fails here until
  its case is updated. A statement the PostgreSQL store refuses must be refused
  by name. Rows a statement returns are compared after decoding JSON text,
  because PostgreSQL writes an object's JSON with its own spacing and key
  order.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Store.Postgres.{Connection, Schema}
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres

  @intake "default:knowledge-intake"

  setup_all do
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")
    capture_log(fn -> :ok = OptimalEngine.Store.SQLite.migrate(db) end)

    schema = PostgresStore.unique_schema()
    pool = start_supervised!({Connection, PostgresStore.options(schema)})
    {:ok, _} = Schema.sync(pool, schema: schema)
    {:ok, plan} = Schema.derive()

    on_exit(fn ->
      Exqlite.Sqlite3.close(db)
      PostgresStore.drop_schema(schema)
    end)

    for {table, row} <- fixtures(), do: insert!(db, pool, plan, table, row)
    %{db: db, pool: pool}
  end

  defp fixtures do
    review = fn state, proposed ->
      Jason.encode!(%{
        "routing_review" => %{"state" => state, "proposed_workspace_id" => proposed}
      })
    end

    [
      {"workspaces",
       %{
         "id" => @intake,
         "tenant_id" => "default",
         "slug" => "knowledge-intake",
         "name" => "Intake"
       }},
      {"contexts",
       %{
         "id" => "c1",
         "workspace_id" => @intake,
         "type" => "signal",
         "title" => "one",
         "path" => "intake/signals/c1.md",
         "modified_at" => "2026-10-01T10:00:00Z",
         "metadata" => review.("review", "default:alpha")
       }},
      {"contexts",
       %{
         "id" => "c2",
         "workspace_id" => @intake,
         "type" => "resource",
         "title" => "two",
         "modified_at" => "2026-10-02T10:00:00Z",
         "metadata" => review.("unresolved", nil)
       }},
      {"contexts",
       %{
         "id" => "c3",
         "workspace_id" => @intake,
         "title" => "three",
         "modified_at" => "2026-10-03T10:00:00Z",
         "metadata" => review.("accepted", "default:beta")
       }},
      {"contexts",
       %{"id" => "c4", "workspace_id" => @intake, "title" => "four", "metadata" => "{}"}},
      {"contexts",
       %{
         "id" => "c5",
         "workspace_id" => "default",
         "type" => "signal",
         "node" => "ops",
         "sn_ratio" => 0.8,
         "path" => "default/signals/c5.md",
         "created_at" => "2026-10-05T09:00:00Z",
         "metadata" =>
           Jason.encode!(%{
             "cross_ref_from" => "c1",
             "outward" => "pricing",
             "direction" => "outbound",
             "thread_ref" => "thread-1",
             "tag" => "seed-a"
           })
       }},
      {"contexts",
       %{
         "id" => "c6",
         "workspace_id" => "default",
         "type" => "signal",
         "node" => "ops",
         "sn_ratio" => 0.4,
         "path" => "default/signals/c6.md",
         "created_at" => "2026-10-06T09:00:00Z",
         "metadata" =>
           Jason.encode!(%{
             "outward" => nil,
             "direction" => "inbound",
             "agent_action" => %{"kind" => "x"}
           })
       }},
      {"contexts",
       %{
         "id" => "c7",
         "workspace_id" => "default",
         "type" => "signal",
         "node" => "sales",
         "sn_ratio" => 0.6,
         "path" => "default/notes/c7.md",
         "created_at" => "2026-10-07T09:00:00Z",
         "metadata" => Jason.encode!(%{"outward" => "pricing", "tag" => "seed-b"})
       }},
      {"sessions",
       %{
         "id" => "s1",
         "tenant_id" => "default",
         "workspace_id" => "default",
         "metadata" => Jason.encode!(%{"kind" => "chat", "correlation_id" => "corr-1"})
       }},
      {"sessions",
       %{
         "id" => "s2",
         "tenant_id" => "default",
         "workspace_id" => "default",
         "metadata" => Jason.encode!(%{"kind" => "chat", "correlation_id" => "corr-2"})
       }},
      {"sessions",
       %{
         "id" => "s3",
         "tenant_id" => "default",
         "workspace_id" => "default",
         "metadata" => Jason.encode!(%{"kind" => "other"})
       }},
      {"memories",
       %{
         "id" => "m1",
         "content" => "a fact",
         "created_at" => "2026-10-01 10:00:00",
         "metadata" => Jason.encode!(%{"kind" => "fact"})
       }},
      {"memories", %{"id" => "m2", "content" => "plain", "created_at" => "2026-10-02 10:00:00"}},
      {"memories",
       %{
         "id" => "m3",
         "content" => "another fact",
         "created_at" => "2026-10-03 10:00:00",
         "metadata" => Jason.encode!(%{"kind" => "fact"})
       }},
      {"api_keys",
       %{
         "id" => "k1",
         "tenant_id" => "default",
         "hashed_secret" => "h1",
         "prefix" => "p1",
         "name" => "cli",
         "metadata" => Jason.encode!(%{"source" => "cli"})
       }},
      {"api_keys",
       %{
         "id" => "k2",
         "tenant_id" => "default",
         "hashed_secret" => "h2",
         "prefix" => "p2",
         "name" => "cli two",
         "metadata" => Jason.encode!(%{"source" => "cli"})
       }},
      {"api_keys",
       %{
         "id" => "k3",
         "tenant_id" => "default",
         "hashed_secret" => "h3",
         "prefix" => "p3",
         "name" => "web",
         "metadata" => Jason.encode!(%{"source" => "web"})
       }},
      {"authority_action_steps",
       %{
         "id" => "st1",
         "tenant_id" => "default",
         "workspace_id" => "default",
         "correlation_id" => "chain-1",
         "seq" => 1,
         "stage" => "request",
         "occurred_at" => "2026-10-01T10:00:00Z",
         "detail" => Jason.encode!(%{"jti" => "grant-1"})
       }},
      {"authority_action_steps",
       %{
         "id" => "st2",
         "tenant_id" => "default",
         "workspace_id" => "default",
         "correlation_id" => "chain-2",
         "seq" => 1,
         "stage" => "request",
         "occurred_at" => "2026-10-02T10:00:00Z",
         "detail" => Jason.encode!(%{"request_id" => "req-2"})
       }},
      {"authority_evidence",
       %{
         "id" => "ev1",
         "tenant_id" => "default",
         "tenant_seq" => 1,
         "kind" => "request.created",
         "jti" => "grant-9",
         "detail" => Jason.encode!(%{"request_id" => "req-2"}),
         "prev_hash" => "0",
         "hash" => "a",
         "kid" => "k",
         "signature" => "s",
         "recorded_at" => "2026-10-02T10:00:00Z"
       }},
      {"authority_evidence",
       %{
         "id" => "ev2",
         "tenant_id" => "default",
         "tenant_seq" => 2,
         "kind" => "grant.issued",
         "jti" => "grant-1",
         "detail" => Jason.encode!(%{"approval" => "req-2"}),
         "prev_hash" => "a",
         "hash" => "b",
         "kid" => "k",
         "signature" => "s",
         "recorded_at" => "2026-10-03T10:00:00Z"
       }},
      {"open_loops",
       %{
         "id" => "l1",
         "tenant_id" => "default",
         "workspace_id" => "default",
         "kind" => "owed_reply",
         "title" => "reply",
         "fingerprint" => "f1",
         "thread_ref" => "thread-1",
         "created_at" => "2026-10-01T00:00:00Z"
       }},
      {"signal_events",
       %{
         "id" => "e1",
         "tenant_id" => "default",
         "workspace_id" => "default",
         "kind" => "outward",
         "topic" => "pricing",
         "occurred_at" => "2026-10-04T00:00:00Z"
       }}
    ]
  end

  # {call site, fragment of its statement, statement, parameters, expectation}
  defp cases do
    [
      {"lib/optimal_engine/context_health.ex",
       "json_extract(metadata, '$.routing_review.state') IN ('review', 'unresolved')",
       "SELECT COUNT(*) FROM contexts WHERE archived_at IS NULL AND workspace_id = 'default:knowledge-intake' AND json_extract(metadata, '$.routing_review.state') IN ('review', 'unresolved')",
       [], :rows},
      {"lib/optimal_engine/corpus_organizer.ex",
       "SET metadata = json_set(COALESCE(metadata, '{}'), '$.routing_review', json(?1))",
       """
       UPDATE contexts SET metadata = json_set(COALESCE(metadata, '{}'), '$.routing_review', json(?1))
       WHERE id = ?2 AND workspace_id = ?3 AND archived_at IS NULL
         AND (json_extract(metadata, '$.routing_review.state') IS NOT ?4
              OR json_extract(metadata, '$.routing_review.proposed_workspace_id') IS NOT ?5)
       """, ["{}", "c1", @intake, "review", "default:alpha"], {:refused, "json_set"}},
      {"lib/optimal_engine/corpus_organizer.ex", "'$.routing_placement', json(?1)",
       "UPDATE contexts SET metadata = json_set(COALESCE(metadata, '{}'), '$.routing_placement', json(?1)) WHERE id = ?2",
       ["{}", "c1"], {:refused, "json_set"}},
      {"lib/optimal_engine/chat_session.ex", "AND json_extract(metadata, '$.correlation_id') = ?3",
       "SELECT COUNT(*) FROM sessions WHERE tenant_id = ?1 AND workspace_id = ?2 AND json_extract(metadata, '$.kind') = 'chat' AND json_extract(metadata, '$.correlation_id') = ?3",
       ["default", "default", "corr-1"], :rows},
      {"lib/optimal_engine/chat_session.ex",
       "AND json_extract(metadata, '$.kind') = '\#{@record_kind}'",
       "SELECT id FROM sessions WHERE tenant_id = ?1 AND workspace_id = ?2 AND json_extract(metadata, '$.kind') = 'chat' ORDER BY id",
       ["default", "default"], :ordered},
      {"lib/optimal_engine/chat_session.ex", "AND json_extract(metadata, '$.kind') = ?4",
       "SELECT id, metadata FROM sessions WHERE id = ?1 AND tenant_id = ?2 AND workspace_id = ?3 AND json_extract(metadata, '$.kind') = ?4",
       ["s1", "default", "default", "chat"], :rows},
      {"lib/optimal_engine/review_queue.ex",
       "SELECT id, title, l0_abstract, json_extract(metadata, '$.routing_review')",
       """
       SELECT id, title, l0_abstract, json_extract(metadata, '$.routing_review')
       FROM contexts
       WHERE workspace_id = 'default:knowledge-intake' AND archived_at IS NULL
         AND json_extract(metadata, '$.routing_review.state') = ?1
       ORDER BY modified_at DESC LIMIT ?2
       """, ["review", 25], :ordered},
      {"lib/optimal_engine/viability.ex",
       "AND (CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.cross_ref_from') END) IS NULL",
       """
       SELECT id, path FROM contexts
       WHERE type = 'signal' AND path LIKE '%/signals/%'
         AND (CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.cross_ref_from') END) IS NULL
       """, [], :rows},
      {"lib/optimal_engine/data_steward.ex",
       "json_extract(metadata, '$.routing_review.state') IN ('review','unresolved')",
       """
       SELECT id, title, json_extract(metadata, '$.routing_review.state'),
              json_extract(metadata, '$.routing_review.proposed_workspace_id')
       FROM contexts
       WHERE tenant_id=?1 AND workspace_id=?2 AND archived_at IS NULL
         AND json_extract(metadata, '$.routing_review.state') IN ('review','unresolved')
       ORDER BY modified_at DESC LIMIT ?3
       """, ["default", "default:knowledge-intake", 10], :ordered},
      {"lib/optimal_engine/memory/versioned/store.ex",
       "AND (CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.kind') END) = ?3",
       """
       SELECT id, content FROM memories
       WHERE tenant_id = ?1 AND workspace_id = ?2 AND is_latest = 1 AND is_forgotten = 0
         AND (CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.kind') END) = ?3
       ORDER BY created_at ASC, id ASC
       LIMIT ?4
       """, ["default", "default", "fact", 10], :ordered},
      {"lib/optimal_engine/auth/api_key.ex", "AND json_extract(metadata, '$.source') = ?3",
       """
       UPDATE api_keys SET revoked_at = datetime('now')
       WHERE tenant_id = ?1 AND revoked_at IS NULL AND id != ?2
         AND json_extract(metadata, '$.source') = ?3
       """, ["default", "k1", "cli"], :changes},
      {"lib/optimal_engine/viability/systems.ex",
       "SELECT (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) AS topic FROM contexts c",
       """
       SELECT topic, COUNT(*) FROM (
         SELECT (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) AS topic FROM contexts c
         WHERE c.workspace_id IN (?2) AND c.archived_at IS NULL
           AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) IS NOT NULL
           AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) >= ?3
         UNION ALL
         SELECT topic FROM signal_events
         WHERE tenant_id = ?1 AND workspace_id IN (?2) AND kind = 'outward'
           AND substr(occurred_at, 1, 10) >= ?3
       ) GROUP BY topic ORDER BY 2 DESC
       """, ["default", "default", "2026-01-01"], :rows},
      {"lib/optimal_engine/viability/systems.ex",
       "SELECT COALESCE(c.created_at, c.indexed_at) AS at FROM contexts c",
       """
       SELECT MAX(at) FROM (
         SELECT COALESCE(c.created_at, c.indexed_at) AS at FROM contexts c
         WHERE c.workspace_id IN (?2)
           AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) IS NOT NULL
         UNION ALL
         SELECT occurred_at FROM signal_events
         WHERE tenant_id = ?1 AND workspace_id IN (?2) AND kind = 'outward'
       )
       """, ["default", "default"], :rows},
      {"lib/optimal_engine/viability/trajectory.ex",
       "SUM(CASE WHEN (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) IS NOT NULL THEN 1 ELSE 0 END)",
       """
       SELECT CASE WHEN substr(COALESCE(c.created_at, c.indexed_at), 1, 10) >= ?4 THEN 1 ELSE 0 END AS period,
         c.node, COUNT(*), AVG(c.sn_ratio),
         SUM(CASE WHEN (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) IS NOT NULL THEN 1 ELSE 0 END)
       FROM contexts c
       WHERE c.workspace_id IN (?2) AND c.type = 'signal' AND c.archived_at IS NULL
         AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) >= ?3
         AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) < ?5
       GROUP BY 1, 2
       """, ["default", "default", "2026-10-01", "2026-10-06", "2026-11-01"], :rows},
      {"lib/optimal_engine/viability/metrics.ex",
       "(CASE WHEN json_valid(\#{a}.metadata) THEN json_extract(\#{a}.metadata, '\#{path}') END)",
       """
       SELECT COUNT(*) FROM contexts c
       WHERE c.workspace_id = ?1
         AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.direction') END) = 'outbound'
       """, ["default"], :rows},
      {"lib/optimal_engine/viability/audit.ex",
       "(\#{direction} IS NOT 'outbound' AND NOT \#{produced})",
       """
       SELECT c.id FROM contexts c
       WHERE c.workspace_id = ?1 AND c.type = 'signal' AND c.archived_at IS NULL
         AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.agent_action') END) IS NULL
         AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.cross_ref_from') END) IS NULL
         AND ((CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.direction') END) IS NOT 'outbound'
              AND NOT EXISTS (SELECT 1 FROM signal_events e WHERE e.context_id = c.id AND e.kind = 'produced'))
         AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) >= ?2
         AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) < ?3
       ORDER BY c.id
       """, ["default", "2026-10-01", "2026-11-01"], :ordered},
      {"lib/optimal_engine/retrieval/l0_cache.ex",
       "SELECT COALESCE(json_extract(metadata, '$.kind'), 'memory') AS kind, COUNT(*) as cnt",
       """
       SELECT COALESCE(json_extract(metadata, '$.kind'), 'memory') AS kind, COUNT(*) as cnt
       FROM memories
       WHERE is_latest = 1 AND is_forgotten = 0
       GROUP BY kind
       ORDER BY cnt DESC
       """, [], :ordered},
      {"lib/optimal_engine/memory_core/reconstruction_learning.ex",
       "COALESCE(AVG(json_array_length(r.citations)), 0)",
       "SELECT COALESCE(AVG(json_array_length(r.citations)), 0) FROM memory_reconstruction_runs r WHERE json_extract(r.metadata, '$.engine_version') = ?1",
       ["1"], {:refused, "json_array_length"}},
      {"lib/optimal_engine/backup/schedule.ex",
       "AND json_extract(metadata, '$.schedule_job_id') = ?1",
       """
       SELECT id, storage_uri, offsite, integrity_status FROM backup_records
       WHERE status = 'completed' AND json_extract(metadata, '$.schedule_job_id') = ?1
       ORDER BY created_at DESC, rowid DESC LIMIT 1
       """, ["job-1"], {:refused, "rowid"}},
      {"lib/optimal_engine/backup/schedule.ex",
       "AND json_extract(metadata, '$.offsite_shipped_at') IS NOT NULL",
       """
       SELECT id, created_at, metadata FROM backup_records
       WHERE json_extract(metadata, '$.scheduled') = 1
         AND json_extract(metadata, '$.offsite_shipped_at') IS NOT NULL
       ORDER BY created_at DESC, rowid DESC LIMIT 1
       """, [], {:refused, "rowid"}},
      {"lib/optimal_engine/authority/action_chain.ex",
       ~S|(#{detail_field("jti")} = ?2 OR #{detail_field("request_id")} = ?2)|,
       """
       SELECT correlation_id FROM authority_action_steps
       WHERE tenant_id = ?1 AND (CASE WHEN json_valid(detail) THEN json_extract(detail, '$.jti') END = ?2 OR CASE WHEN json_valid(detail) THEN json_extract(detail, '$.request_id') END = ?2)
       ORDER BY occurred_at LIMIT 1
       """, ["default", "req-2"], :ordered},
      {"lib/optimal_engine/authority/action_chain.ex",
       ~S|(#{detail_field("request_id")} IN (#{marks}) OR #{detail_field("approval")} IN (#{marks}) OR jti IN (#{marks}))|,
       """
       SELECT id, kind FROM authority_evidence
       WHERE tenant_id = ?1 AND (kind <> 'agent_action.step' AND (CASE WHEN json_valid(detail) THEN json_extract(detail, '$.request_id') END IN (?2, ?3) OR CASE WHEN json_valid(detail) THEN json_extract(detail, '$.approval') END IN (?2, ?3) OR jti IN (?2, ?3)))
       ORDER BY tenant_seq ASC LIMIT 1000
       """, ["default", "req-2", "grant-1"], :ordered},
      {"lib/optimal_engine/operating/loops.ex",
       "AND json_extract(c.metadata, '$.thread_ref') = l.thread_ref",
       """
       SELECT l.id, c.id FROM open_loops l
       JOIN contexts c ON c.tenant_id = l.tenant_id AND c.workspace_id = l.workspace_id
         AND json_extract(c.metadata, '$.thread_ref') = l.thread_ref
         AND COALESCE(c.created_at, c.modified_at) > l.created_at
         AND c.id != COALESCE(l.source_context_id, '')
       WHERE l.tenant_id = ?1 AND l.workspace_id = ?2 AND l.state = 'open' AND l.thread_ref IS NOT NULL
       """, ["default", "default"], :rows},
      {"lib/mix/tasks/optimal.seed.ex", "AND json_extract(metadata, '$.tag') = ?2",
       "SELECT id FROM contexts WHERE tenant_id = ?1 AND json_extract(metadata, '$.tag') = ?2",
       ["default", "seed-a"], :rows},
      {"lib/mix/tasks/optimal.seed.ex",
       "DELETE FROM contexts WHERE tenant_id = ?1 AND json_extract(metadata, '$.tag') = ?2",
       "DELETE FROM contexts WHERE tenant_id = ?1 AND json_extract(metadata, '$.tag') = ?2",
       ["default", "seed-b"], :changes},
      {"lib/mix/tasks/optimal.ingest_workspace.ex",
       "json_extract(metadata, '$.tag') = 'workspace-ingest'",
       "DELETE FROM nodes WHERE tenant_id = ?1 AND workspace_id = ?2 AND json_extract(metadata, '$.tag') = 'workspace-ingest'",
       ["default", "default"], :changes}
    ]
  end

  test "every call site's statement is still at its call site" do
    for {site, fragment, _sql, _params, _expect} <- cases() do
      assert String.contains?(squash(File.read!(site)), squash(fragment)),
             "#{site} no longer has: #{fragment}"
    end
  end

  test "every call site answers on PostgreSQL as on SQLite, or is refused by name",
       %{db: db, pool: pool} do
    for {site, _fragment, sql, params, expect} <- cases() do
      case expect do
        {:refused, name} ->
          assert {:error, {:unsupported, ^name}} = Connection.query(pool, sql, params), site

        :changes ->
          assert pg_changes(pool, sql, params) == sqlite_changes(db, sql, params), site

        :ordered ->
          assert decoded(pg_rows(pool, sql, params)) == decoded(sqlite_rows(db, sql, params)),
                 site

        :rows ->
          assert Enum.sort(decoded(pg_rows(pool, sql, params))) ==
                   Enum.sort(decoded(sqlite_rows(db, sql, params))),
                 site
      end
    end
  end

  test "the fixtures exercise every answered case", %{db: db} do
    answered =
      for {site, _f, sql, params, expect} <- cases(),
          expect in [:rows, :ordered],
          do: {site, sql, params}

    empty =
      for {site, sql, params} <- answered,
          sqlite_rows(db, sql, params) in [[], [[0]], [[nil]]],
          do: site

    assert empty == []
  end

  # ---------------------------------------------------------------------------
  # Both databases
  # ---------------------------------------------------------------------------

  # A row with every column the table requires: the fixture's values, the
  # column default, or a filler of the column's type.
  defp insert!(db, pool, plan, table, values) do
    columns = Enum.find(plan.tables, &(&1.name == table)).columns

    row =
      for column <- columns,
          Map.has_key?(values, column.name) or
            (column.not_null and is_nil(column.default) and not column.identity) do
        {column.name, Map.get_lazy(values, column.name, fn -> filler(column) end)}
      end

    names = Enum.map_join(row, ", ", &elem(&1, 0))
    marks = Enum.map_join(1..length(row), ", ", &"?#{&1}")
    sql = "INSERT INTO #{table} (#{names}) VALUES (#{marks})"
    params = Enum.map(row, &elem(&1, 1))

    sqlite_execute!(db, sql, params)
    {:ok, _} = Connection.query(pool, sql, params)
  end

  defp filler(%{type: "BIGINT"}), do: 0
  defp filler(%{type: "DOUBLE PRECISION"}), do: 0.0
  defp filler(%{type: "BYTEA"}), do: {:blob, <<>>}
  defp filler(%{name: name}), do: "#{name}-#{System.unique_integer([:positive])}"

  defp sqlite_rows(db, sql, params) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(statement, params)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
    Exqlite.Sqlite3.release(db, statement)
    rows
  end

  defp sqlite_execute!(db, sql, params), do: sqlite_rows(db, sql, params)

  # A write runs and is rolled back, so the next case sees the same rows.
  defp sqlite_changes(db, sql, params) do
    :ok = Exqlite.Sqlite3.execute(db, "SAVEPOINT parity")
    sqlite_rows(db, sql, params)
    {:ok, changes} = Exqlite.Sqlite3.changes(db)
    :ok = Exqlite.Sqlite3.execute(db, "ROLLBACK TO parity")
    :ok = Exqlite.Sqlite3.execute(db, "RELEASE parity")
    changes
  end

  defp pg_rows(pool, sql, params) do
    {:ok, %{rows: rows}} = Connection.query(pool, sql, params)
    rows
  end

  defp pg_changes(pool, sql, params) do
    {:error, {:changes, changes}} =
      Connection.transaction(
        pool,
        fn txn ->
          {:ok, %{num_rows: changes}} = Connection.txn_query(txn, sql, params)
          {:error, {:changes, changes}}
        end,
        5_000
      )

    changes
  end

  defp decoded(rows), do: Enum.map(rows, fn row -> Enum.map(row, &json_value/1) end)

  defp json_value("{" <> _ = text), do: decode(text)
  defp json_value("[" <> _ = text), do: decode(text)
  defp json_value(value), do: value

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:json, value}
      {:error, _} -> text
    end
  end

  defp squash(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
