defmodule OptimalEngine.Store.DialectTest do
  @moduledoc """
  Stage 2 of the PostgreSQL provider: the mechanical rewrites are proven here,
  and every construct the module cannot translate is refused by name. The
  rows each rewrite returns are compared with SQLite's in
  `test/store/postgres/connection_test.exs`.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Store.Dialect

  @jsonb_kind "NULLIF((meta::jsonb #> '{kind}'), 'null'::jsonb)"

  describe "translated statements" do
    test "numbered placeholders become dollar placeholders" do
      assert {:ok, "SELECT * FROM t WHERE id = $1 AND kind = $2"} =
               Dialect.to_postgres("SELECT * FROM t WHERE id = ?1 AND kind = ?2")
    end

    test "positional placeholders are numbered in order" do
      assert {:ok, "SELECT * FROM t WHERE a = $1 AND b = $2"} =
               Dialect.to_postgres("SELECT * FROM t WHERE a = ? AND b = ?")
    end

    test "placeholders inside a literal are left alone" do
      assert {:ok, "SELECT '?1' AS literal, a FROM t WHERE b = $1", %{params: [2]}} =
               Dialect.translate("SELECT '?1' AS literal, a FROM t WHERE b = ?2")
    end

    test "a parameter the statement never names is left out, as SQLite ignores it" do
      assert {:ok, "SELECT a FROM t WHERE b = $1 AND c IN ($2, $1)", %{params: [2, 4]}} =
               Dialect.translate("SELECT a FROM t WHERE b = ?2 AND c IN (?4, ?2)")

      assert {:ok, "SELECT a FROM t WHERE b = $1", %{params: :all}} =
               Dialect.translate("SELECT a FROM t WHERE b = ?1")
    end

    test "datetime('now') is the statement's time in the stored ISO-8601 text format" do
      assert {:ok,
              "SELECT to_char((statement_timestamp() AT TIME ZONE 'utc'), 'YYYY-MM-DD HH24:MI:SS')"} =
               Dialect.to_postgres("SELECT datetime('now')")
    end

    test "datetime('now', '-90 days') subtracts the interval before formatting" do
      assert {:ok,
              "SELECT to_char((statement_timestamp() AT TIME ZONE 'utc') - interval '90 days', 'YYYY-MM-DD HH24:MI:SS')"} =
               Dialect.to_postgres("SELECT datetime('now', '-90 days')")
    end

    test "the measured strftime formats map to to_char" do
      assert {:ok,
              "SELECT to_char((statement_timestamp() AT TIME ZONE 'utc'), 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"} =
               Dialect.to_postgres("SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')")

      assert {:ok,
              "SELECT to_char((statement_timestamp() AT TIME ZONE 'utc'), 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')"} =
               Dialect.to_postgres("SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now')")
    end

    test "INSERT OR IGNORE becomes ON CONFLICT DO NOTHING" do
      assert {:ok, "INSERT INTO t (a, b) VALUES ($1, $2) ON CONFLICT DO NOTHING"} =
               Dialect.to_postgres("INSERT OR IGNORE INTO t (a, b) VALUES (?1, ?2)")
    end

    test "IS with a placeholder compares NULL as a value, as SQLite's IS does" do
      assert {:ok, "SELECT * FROM t WHERE a IS NOT DISTINCT FROM $1 AND b IS DISTINCT FROM $2"} =
               Dialect.to_postgres("SELECT * FROM t WHERE a IS ?1 AND b IS NOT ?2")

      assert {:ok,
              "SELECT * FROM t WHERE a IS DISTINCT FROM 'outbound' AND b IS NOT DISTINCT FROM 3 AND c IS NOT NULL AND d IS TRUE"} =
               Dialect.to_postgres(
                 "SELECT * FROM t WHERE a IS NOT 'outbound' AND b IS 3 AND c IS NOT NULL AND d IS TRUE"
               )
    end

    test "deferring foreign keys is SET CONSTRAINTS; every other PRAGMA is refused" do
      assert {:ok, "SET CONSTRAINTS ALL DEFERRED"} =
               Dialect.to_postgres("PRAGMA defer_foreign_keys = ON")

      assert {:ok, "SET CONSTRAINTS ALL IMMEDIATE"} =
               Dialect.to_postgres("PRAGMA defer_foreign_keys = OFF")

      assert {:error, {:unsupported, "PRAGMA"}} = Dialect.to_postgres("PRAGMA foreign_keys = OFF")
    end

    test "the part of a value before a separator, and instr anywhere else refused" do
      assert {:ok,
              "SELECT (CASE WHEN strpos($1, ':') > 0 THEN substr($1, 1, strpos($1, ':') - 1) WHEN strpos($1, ':') = 0 THEN '' END) FROM t WHERE w.id = $1"} =
               Dialect.to_postgres(
                 "SELECT substr(?1, 1, instr(?1, ':') - 1) FROM t WHERE w.id = ?1"
               )

      assert {:ok,
              "SELECT (CASE WHEN strpos(w.id, ':') > 0 THEN substr(w.id, 1, strpos(w.id, ':') - 1) WHEN strpos(w.id, ':') = 0 THEN '' END) FROM workspaces w"} =
               Dialect.to_postgres("SELECT substr(w.id, 1, instr(w.id, ':') - 1) FROM workspaces w")

      assert {:error, {:unsupported, "instr"}} = Dialect.to_postgres("SELECT instr(a, 'b') FROM t")

      assert {:error, {:unsupported, "instr"}} =
               Dialect.to_postgres("SELECT substr(?, 1, instr(?, ':') - 1) FROM t")
    end

    test "an UPDATE with a conflict clause is refused by name" do
      for clause <- ~w(REPLACE IGNORE ABORT FAIL ROLLBACK) do
        assert {:error, {:unsupported, "UPDATE with a conflict clause"}} =
                 Dialect.to_postgres("UPDATE OR #{clause} t SET a = ?1 WHERE id = ?2")
      end

      assert {:ok, _} = Dialect.to_postgres("UPDATE t SET last_update = ?1 WHERE a = 1 OR b = 2")
    end

    test "IFNULL, json_valid of a column and eight-byte casts" do
      assert {:ok,
              "SELECT COALESCE(a, 0), (meta IS JSON), CAST(n AS BIGINT), CAST(s AS DOUBLE PRECISION) FROM t"} =
               Dialect.to_postgres(
                 "SELECT IFNULL(a, 0), json_valid(meta), CAST(n AS INTEGER), CAST(s AS REAL) FROM t"
               )
    end

    test "a list bound as one JSON array parameter, and json_each anywhere else refused" do
      assert {:ok,
              "SELECT id FROM t WHERE a IN (SELECT value FROM jsonb_array_elements_text(CAST($2 AS text)::jsonb)) AND tenant_id = $1"} =
               Dialect.to_postgres(
                 "SELECT id FROM t WHERE a IN (SELECT value FROM json_each(?2)) AND tenant_id = ?1"
               )

      assert {:error, {:unsupported, "json_each"}} =
               Dialect.to_postgres("SELECT key FROM t, json_each(t.meta)")

      assert {:error, {:unsupported, "json_each"}} =
               Dialect.to_postgres(
                 "SELECT id FROM t WHERE a IN (SELECT value FROM json_each(t.meta))"
               )
    end
  end

  describe "ORDER BY" do
    test "every term keeps SQLite's NULL order" do
      assert {:ok, "SELECT a FROM t ORDER BY a NULLS FIRST, b DESC NULLS LAST LIMIT 5"} =
               Dialect.to_postgres("SELECT a FROM t ORDER BY a, b DESC LIMIT 5")
    end

    test "a window's ORDER BY ends at its parenthesis, and an explicit order is kept" do
      assert {:ok,
              "SELECT row_number() OVER (ORDER BY a NULLS FIRST) FROM t ORDER BY f(a, b) ASC NULLS FIRST, c NULLS LAST"} =
               Dialect.to_postgres(
                 "SELECT row_number() OVER (ORDER BY a) FROM t ORDER BY f(a, b) ASC, c NULLS LAST"
               )
    end
  end

  describe "LIKE" do
    test "becomes ILIKE in the C collation with no escape character, outside literals" do
      assert {:ok,
              "SELECT * FROM t WHERE a ILIKE ($1) COLLATE \"C\" ESCAPE '' AND b NOT ILIKE ('LIKE %') COLLATE \"C\" ESCAPE ''"} =
               Dialect.to_postgres("SELECT * FROM t WHERE a LIKE ?1 AND b NOT like 'LIKE %'")
    end

    test "a concatenated pattern is one operand, and an explicit ESCAPE is kept" do
      assert {:ok,
              "SELECT * FROM t WHERE a ILIKE ('%' || $1 || '%') COLLATE \"C\" ESCAPE '' AND b ILIKE ($2) COLLATE \"C\" ESCAPE '\\'"} =
               Dialect.to_postgres(
                 "SELECT * FROM t WHERE a LIKE '%' || ?1 || '%' AND b LIKE ?2 ESCAPE '\\'"
               )
    end

    test "a computed pattern is refused" do
      assert {:error, {:unsupported, "LIKE with a computed pattern"}} =
               Dialect.to_postgres("SELECT * FROM t WHERE a LIKE lower(?1)")
    end

    test "GLOB is refused" do
      assert {:error, {:unsupported, "GLOB"}} =
               Dialect.to_postgres("SELECT * FROM t WHERE a GLOB ?1")
    end
  end

  describe "json_extract" do
    test "selected or passed to a function, it is the value's text in the C collation" do
      assert {:ok, "SELECT ((metadata::jsonb #>> '{routing_review,state}') COLLATE \"C\") FROM t"} =
               Dialect.to_postgres("SELECT json_extract(metadata, '$.routing_review.state') FROM t")

      assert {:ok, "SELECT COALESCE(((meta::jsonb #>> '{kind}') COLLATE \"C\"), 'memory') FROM t"} =
               Dialect.to_postgres("SELECT COALESCE(json_extract(meta, '$.kind'), 'memory') FROM t")
    end

    test "compared to a placeholder, it compares JSON values and the placeholder must be text" do
      assert {:ok, "SELECT a FROM t WHERE #{@jsonb_kind} = to_jsonb($1::text)",
              %{text_params: [1], params: :all}} ==
               Dialect.translate("SELECT a FROM t WHERE json_extract(meta, '$.kind') = ?1")

      assert {:ok, "SELECT a FROM t WHERE #{@jsonb_kind} IS DISTINCT FROM to_jsonb($1::text)",
              %{text_params: [1], params: :all}} ==
               Dialect.translate("SELECT a FROM t WHERE json_extract(meta, '$.kind') IS NOT ?1")
    end

    test "compared to a literal, an IN list or NULL" do
      assert {:ok, "SELECT a FROM t WHERE #{@jsonb_kind} != to_jsonb('x'::text)"} ==
               Dialect.to_postgres("SELECT a FROM t WHERE json_extract(meta, '$.kind') != 'x'")

      assert {:ok,
              "SELECT a FROM t WHERE #{@jsonb_kind} IN (to_jsonb('review'::text), to_jsonb($1::text))",
              %{text_params: [1], params: [2]}} ==
               Dialect.translate(
                 "SELECT a FROM t WHERE json_extract(meta, '$.kind') IN ('review', ?2)"
               )

      assert {:ok, "SELECT a FROM t WHERE #{@jsonb_kind} IS NULL"} ==
               Dialect.to_postgres("SELECT a FROM t WHERE json_extract(meta, '$.kind') IS NULL")
    end

    test "compared to an integer, it matches the number, and 1 and 0 match true and false" do
      assert {:ok,
              "SELECT a FROM t WHERE NULLIF((meta::jsonb #> '{scheduled}'), 'null'::jsonb) IN ('1'::jsonb, 'true'::jsonb)"} ==
               Dialect.to_postgres("SELECT a FROM t WHERE json_extract(meta, '$.scheduled') = 1")

      assert {:ok,
              "SELECT a FROM t WHERE NOT (NULLIF((meta::jsonb #> '{n}'), 'null'::jsonb) IN ('7'::jsonb))"} ==
               Dialect.to_postgres("SELECT a FROM t WHERE json_extract(meta, '$.n') <> 7")
    end

    test "compared to a column, it compares text" do
      assert {:ok, "SELECT 1 FROM c, l WHERE ((c.meta::jsonb #>> '{ref}') COLLATE \"C\") = l.ref"} ==
               Dialect.to_postgres("SELECT 1 FROM c, l WHERE json_extract(c.meta, '$.ref') = l.ref")
    end

    test "a form that would compare or order by SQLite's types is refused" do
      for {sql, reason} <- [
            {"SELECT a FROM t WHERE json_extract(meta, '$.n') < ?1",
             "json_extract ordered comparison"},
            {"SELECT a FROM t WHERE json_extract(meta, '$.n') BETWEEN 1 AND 2",
             "json_extract ordered comparison"},
            {"SELECT a FROM t WHERE ?1 = json_extract(meta, '$.n')",
             "json_extract on the right of a comparison"},
            {"SELECT a FROM t WHERE json_extract(meta, '$.n') = ?1 || 'x'",
             "json_extract compared to an expression"},
            {"SELECT a FROM t WHERE json_extract(meta, '$.n') = lower(b)",
             "json_extract compared to an expression"},
            {"SELECT a FROM t ORDER BY json_extract(meta, '$.n')", "json_extract in ORDER BY"},
            {"SELECT json_extract(metadata, '$.a[0]') FROM t", "json_extract path"}
          ] do
        assert {:error, {:unsupported, ^reason}} = Dialect.to_postgres(sql), sql
      end
    end
  end

  describe "refused statements" do
    test "INSERT OR REPLACE is refused rather than guessed" do
      assert {:error, {:unsupported, "INSERT OR REPLACE"}} =
               Dialect.to_postgres("INSERT OR REPLACE INTO t (a) VALUES (?1)")

      assert {:error, {:unsupported, "REPLACE INTO"}} =
               Dialect.to_postgres("REPLACE INTO t (a) VALUES (?1)")
    end

    test "catalog and DDL constructs are refused" do
      assert {:error, {:unsupported, "PRAGMA"}} = Dialect.to_postgres("PRAGMA table_info(t)")

      assert {:error, {:unsupported, "AUTOINCREMENT"}} =
               Dialect.to_postgres("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT)")

      assert {:error, {:unsupported, "sqlite_master"}} =
               Dialect.to_postgres("SELECT name FROM sqlite_master WHERE type = 'table'")

      assert {:error, {:unsupported, "SQLite catalog function"}} =
               Dialect.to_postgres("SELECT name FROM pragma_table_info('t')")

      assert {:error, {:unsupported, "rowid"}} = Dialect.to_postgres("SELECT rowid FROM t")
    end

    test "full-text MATCH and last_insert_rowid are refused" do
      assert {:error, {:unsupported, "FTS5 MATCH"}} =
               Dialect.to_postgres("SELECT * FROM fts WHERE fts MATCH ?1")

      assert {:error, {:unsupported, "last_insert_rowid"}} =
               Dialect.to_postgres("SELECT last_insert_rowid()")
    end

    test "SQLite-only functions are refused by name" do
      for {sql, name} <- [
            {"SELECT value FROM json_each(?1)", "json_each"},
            {"UPDATE t SET meta = json_set(meta, '$.a', 1)", "json_set"},
            {"SELECT group_concat(name) FROM t", "group_concat"},
            {"SELECT typeof(a) FROM t", "typeof"},
            {"SELECT julianday(a) FROM t", "julianday"},
            {"SELECT date(created_at) FROM t", "date"},
            {"SELECT a FROM t WHERE json_valid(lower(a))", "json_valid of an expression"}
          ] do
        assert {:error, {:unsupported, ^name}} = Dialect.to_postgres(sql), sql
      end
    end

    test "an unmapped strftime format or datetime modifier is refused" do
      assert {:error, {:unsupported, "strftime format %s"}} =
               Dialect.to_postgres("SELECT strftime('%s', 'now')")

      assert {:error, {:unsupported, "unmapped date/time function"}} =
               Dialect.to_postgres("SELECT datetime('now', ?1)")

      assert {:error, {:unsupported, "unmapped date/time function"}} =
               Dialect.to_postgres("SELECT datetime(created_at) FROM t")
    end

    test "mixing numbered and positional placeholders is refused" do
      assert {:error, {:mixed_placeholders, _sql}} =
               Dialect.to_postgres("SELECT * FROM t WHERE a = ?1 AND b = ?")
    end

    test "every refusal is listed with a reason" do
      refusals = Dialect.refusals()
      assert {"INSERT OR REPLACE", reason} = List.keyfind(refusals, "INSERT OR REPLACE", 0)
      assert reason =~ "delete-and-insert"
      assert {"FTS5 MATCH", reason} = List.keyfind(refusals, "FTS5 MATCH", 0)
      assert reason =~ "full-text search is not available"
    end
  end
end
