defmodule OptimalEngine.Store.DialectTest do
  @moduledoc """
  Stage 2 of the PostgreSQL provider: the mechanical rewrites are proven here,
  and every construct the module cannot translate is refused by name.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Store.Dialect

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
      assert {:ok, "SELECT '?1' AS literal, a FROM t WHERE b = $2"} =
               Dialect.to_postgres("SELECT '?1' AS literal, a FROM t WHERE b = ?2")
    end

    test "datetime('now') keeps the stored ISO-8601 text format" do
      assert {:ok, "SELECT to_char((now() AT TIME ZONE 'utc'), 'YYYY-MM-DD HH24:MI:SS')"} =
               Dialect.to_postgres("SELECT datetime('now')")
    end

    test "datetime('now', '-90 days') subtracts the interval before formatting" do
      assert {:ok,
              "SELECT to_char((now() AT TIME ZONE 'utc') - interval '90 days', 'YYYY-MM-DD HH24:MI:SS')"} =
               Dialect.to_postgres("SELECT datetime('now', '-90 days')")
    end

    test "the measured strftime formats map to to_char" do
      assert {:ok, "SELECT to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"} =
               Dialect.to_postgres("SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now')")

      assert {:ok, "SELECT to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"')"} =
               Dialect.to_postgres("SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now')")
    end

    test "json_extract becomes a jsonb path lookup" do
      assert {:ok, "SELECT (metadata::jsonb #>> '{routing_review,state}') FROM t"} =
               Dialect.to_postgres("SELECT json_extract(metadata, '$.routing_review.state') FROM t")
    end

    test "INSERT OR IGNORE becomes ON CONFLICT DO NOTHING" do
      assert {:ok, "INSERT INTO t (a, b) VALUES ($1, $2) ON CONFLICT DO NOTHING"} =
               Dialect.to_postgres("INSERT OR IGNORE INTO t (a, b) VALUES (?1, ?2)")
    end
  end

  describe "refused statements" do
    test "INSERT OR REPLACE is refused rather than guessed" do
      assert {:error, {:unsupported, "INSERT OR REPLACE"}} =
               Dialect.to_postgres("INSERT OR REPLACE INTO t (a) VALUES (?1)")
    end

    test "catalog and DDL constructs are refused" do
      assert {:error, {:unsupported, "PRAGMA"}} = Dialect.to_postgres("PRAGMA table_info(t)")

      assert {:error, {:unsupported, "AUTOINCREMENT"}} =
               Dialect.to_postgres("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT)")
    end

    test "full-text MATCH and last_insert_rowid are refused" do
      assert {:error, {:unsupported, "FTS5 MATCH"}} =
               Dialect.to_postgres("SELECT * FROM fts WHERE fts MATCH ?1")

      assert {:error, {:unsupported, "last_insert_rowid"}} =
               Dialect.to_postgres("SELECT last_insert_rowid()")
    end

    test "an unmapped strftime format is refused" do
      assert {:error, {:unsupported, "strftime format %s"}} =
               Dialect.to_postgres("SELECT strftime('%s', 'now')")
    end

    test "an unmapped json_extract path is refused" do
      assert {:error, {:unsupported, "unmapped json_extract"}} =
               Dialect.to_postgres("SELECT json_extract(metadata, '$.a[0]')")
    end

    test "mixing numbered and positional placeholders is refused" do
      assert {:error, {:mixed_placeholders, _sql}} =
               Dialect.to_postgres("SELECT * FROM t WHERE a = ?1 AND b = ?")
    end

    test "every refusal is listed with a reason" do
      refusals = Dialect.refusals()
      assert {"INSERT OR REPLACE", reason} = List.keyfind(refusals, "INSERT OR REPLACE", 0)
      assert reason =~ "delete-and-insert"
    end
  end
end
