defmodule OptimalEngine.Store.Postgres.SQLiteFunctionsParityTest do
  @moduledoc """
  SQLite's JSON, date and time, and text functions give the same rows on the
  PostgreSQL store (OptimalEngine.Store.Postgres.SQLiteFunctions, renamed to by
  OptimalEngine.Store.Dialect) as on SQLite: each statement runs on both, and
  the rows, NULLs and order included, must be equal.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store.Postgres, as: PgStore
  alias OptimalEngine.Test.PostgresStore

  @moduletag :postgres
  # Starts its own PostgreSQL store beside the embedded one, which a
  # PostgreSQL build already runs as OptimalEngine.Store.
  @moduletag :sqlite_store

  setup_all do
    schema = PostgresStore.unique_schema()

    start_supervised!(
      {PgStore, PostgresStore.options(schema, pool_size: 2, full_text_interval_ms: 0)}
    )

    {:ok, db} = Exqlite.Sqlite3.open(":memory:")
    on_exit(fn -> PostgresStore.drop_schema(schema) end)
    %{db: db}
  end

  defp sqlite(db, sql, params) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(statement, params)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
    :ok = Exqlite.Sqlite3.release(db, statement)
    rows
  end

  defp assert_parity(db, cases) do
    for {sql, params} <- cases do
      expected = sqlite(db, sql, params)
      assert PgStore.raw_query(sql, params) == {:ok, expected}, sql
    end
  end

  defp cases(statements),
    do:
      Enum.map(statements, fn
        {sql, params} -> {sql, params}
        sql -> {sql, []}
      end)

  test "json_set, json_insert, json_replace and json_remove", %{db: db} do
    assert_parity(
      db,
      cases([
        ~s/SELECT json_set('{"b":1}', '$.a', 2)/,
        ~s/SELECT json_set('{"b":1,"a":0}', '$.a', 'x', '$.c', json('[1,{"d":null}]'))/,
        ~s/SELECT json_set('{}', '$.a.b.c', 1.5)/,
        ~s/SELECT json_set('{"a":{"b":1}}', '$.a.c', json('true'))/,
        ~s/SELECT json_set('[1,2,3]', '$[1]', 9, '$[#]', 4)/,
        ~s/SELECT json_set(NULL, '$.a', 1)/,
        ~s/SELECT json_set('{"a":1}', '$.a', NULL)/,
        ~s/SELECT json_set('{"x" : [ 1 , 2 ] }', '$."y z"', '"quoted"')/,
        {~s/SELECT json_set(COALESCE(?1, '{}'), '$.who', ?2, '$.raw', json(?3))/,
         [nil, "agent", ~s({"k":[true,false]})]},
        ~s/SELECT json_set('{"a":1}', '$.b', json_extract('{"n":{"m":2}}', '$.n'))/,
        ~s/SELECT json_set('{"a":1}', '$.b', 1 = 1)/,
        ~s/SELECT json_insert('{"a":1}', '$.a', 2, '$.b', 3)/,
        ~s/SELECT json_replace('{"a":1}', '$.a', 2, '$.b', 3)/,
        ~s/SELECT json_remove('{"a":1,"b":2,"c":{"d":3}}', '$.b', '$.c.d')/,
        ~s/SELECT json_remove('[1,2,3]', '$[0]')/,
        ~s|SELECT json_remove('{"a":1}', '$.missing')|
      ])
    )
  end

  test "json, json_object, json_array, json_type, json_array_length, json_valid", %{db: db} do
    assert_parity(
      db,
      cases([
        ~s/SELECT json(' { "a" : [ 1, 2.50, "x" ] , "b":null } ')/,
        ~s/SELECT json_object('a', 1, 'b', 'x', 'c', json('[1,2]'), 'd', NULL)/,
        ~s/SELECT json_object()/,
        ~s/SELECT json_array(1, 'x', NULL, json('{"k":1}'))/,
        ~s|SELECT json_type('{"a":1}'), json_type('[1]'), json_type('1'), json_type('1.5'),
                  json_type('"s"'), json_type('true'), json_type('false'), json_type('null')|,
        ~s/SELECT json_type('{"a":{"b":[1]}}', '$.a.b'), json_type('{"a":1}', '$.missing')/,
        ~s|SELECT json_array_length('[1,2,3]'), json_array_length('{"a":1}'),
                  json_array_length('{"a":[1,2]}', '$.a'), json_array_length('{"a":1}', '$.b')|,
        ~s/SELECT json_valid('{"a":1}'), json_valid('nope'), json_valid(''), json_valid('[1,2')/,
        {~s/SELECT CASE WHEN json_valid(?1) THEN json_type(?1, '$.x') END/, [~s({"x":[1]})]}
      ])
    )
  end

  test "json_each over objects, arrays and scalars", %{db: db} do
    assert_parity(
      db,
      cases([
        ~s/SELECT key, CAST(value AS TEXT), type, CAST(atom AS TEXT) FROM json_each('{"s":"t","n":2,"r":1.5,"b":true,"f":false,"z":null,"o":{"k":1},"a":[1]}')/,
        ~s/SELECT CAST(key AS TEXT), CAST(value AS TEXT), type FROM json_each('["x",3,null]')/,
        ~s/SELECT value FROM json_each('{"a":{"b":["p","q"]}}', '$.a.b')/,
        ~s/SELECT key, value, type FROM json_each('"scalar"')/,
        ~s/SELECT COUNT(*) FROM json_each(NULL)/,
        {~s/SELECT EXISTS (SELECT 1 FROM json_each(?1) j WHERE j.type != 'text' OR trim(j.value) = '')/,
         [~s(["a", " "])]},
        {~s/SELECT (SELECT count(*) FROM json_each(?1) WHERE key = 'labels')/, [~s({"labels":[]})]}
      ])
    )
  end

  test "json_group_array and group_concat", %{db: db} do
    values =
      "(SELECT 'b' AS v, 1 AS n UNION ALL SELECT 'a', 2 UNION ALL SELECT 'b', 3 UNION ALL SELECT NULL, 4)"

    assert_parity(
      db,
      cases([
        "SELECT json_group_array(v) FROM #{values} t",
        "SELECT json_group_array(n) FROM #{values} t",
        "SELECT json_array_length(json_group_array(DISTINCT v)) FROM (SELECT v FROM #{values} t WHERE v IS NOT NULL) d",
        "SELECT json_group_array(v) FROM #{values} t WHERE n > 9",
        "SELECT group_concat(v) FROM #{values} t",
        "SELECT group_concat(v, '; ') FROM #{values} t",
        "SELECT group_concat(n) FROM #{values} t",
        "SELECT group_concat(v) FROM #{values} t WHERE n > 9"
      ])
    )
  end

  test "instr, char and GLOB", %{db: db} do
    assert_parity(
      db,
      cases([
        ~s/SELECT instr('hello', 'l'), instr('hello', 'z'), instr('héllo', 'l'), instr('a', NULL)/,
        ~s/SELECT char(65, 66), 'x' || char(9) || 'y'/,
        ~s/SELECT v GLOB 'a*', v GLOB 'A*', v GLOB 'a?c', v GLOB '[a-c]bc', v GLOB '[^a]*', v GLOB 'a.c' FROM (SELECT 'abc' AS v) t/,
        {~s/SELECT v GLOB ?1, v NOT GLOB ?1 FROM (SELECT 'exampleorg-1:secrets' AS v) t/,
         ["exampleorg-*:secrets"]},
        ~s|SELECT v GLOB '*[^!-~]*' FROM (SELECT 'ascii' AS v UNION ALL SELECT 'naïve') t|,
        # The text of a json_extract, as migration 72 matches an external id.
        ~s|SELECT json_extract(m, '$.id') GLOB '*[^!-~]*', NOT (json_extract(m, '$.id') GLOB 'x*') FROM (SELECT '{"id":"x-1"}' AS m UNION ALL SELECT '{"id":"naïve"}' UNION ALL SELECT '{"id":7}') t|
      ])
    )
  end

  test "date and time functions with modifiers", %{db: db} do
    assert_parity(
      db,
      cases([
        ~s/SELECT datetime('2026-01-31 10:20:30', '+1 month'), datetime('2026-03-31', '-1 month')/,
        ~s/SELECT datetime('2024-02-29', '+1 year'), datetime('2026-05-17 08:09:10', 'start of month')/,
        ~s/SELECT datetime('2026-05-17 08:09:10', 'start of year'), datetime('2026-05-17 08:09:10', 'start of day')/,
        ~s/SELECT datetime('2026-05-17 08:09:10', '+90 minutes'), datetime('2026-05-17 08:09:10', '-1.5 days')/,
        ~s/SELECT datetime('2026-05-17 08:09:10', '+2 hours', '-30 seconds')/,
        {~s/SELECT datetime('2026-05-17 08:09:10', '+' || ?1 || ' seconds')/, [30]},
        {~s/SELECT datetime('2026-05-17 08:09:10', '-' || ?1 || ' days')/, ["7"]},
        {~s/SELECT datetime('2026-05-17 08:09:10', ?1)/, ["+3 days"]},
        ~s/SELECT datetime('2026-03-01T12:00:00Z'), datetime('2026-03-01 12:00:00+02:00'), datetime('2026-03-01T12:00')/,
        ~s/SELECT datetime(1700000000, 'unixepoch'), datetime(2461100.5)/,
        ~s/SELECT datetime('garbage'), datetime(NULL), datetime('2026-13-01'), date('2026-03-01 23:59:59')/,
        ~s/SELECT time('2026-03-01 23:59:59.789'), datetime('2026-03-01 12:00:00.789', 'subsec'), time('10:20')/,
        ~s/SELECT julianday('2026-03-01 12:00:00'), julianday('2000-01-01'), julianday('2026-03-01 00:00:00.123')/,
        ~s/SELECT (julianday('2026-03-02 06:00:00') - julianday('2026-03-01')) * 24.0/,
        ~s/SELECT unixepoch('2026-03-01 00:00:00'), unixepoch('1970-01-01')/,
        ~s/SELECT strftime('%Y-%m-%d %H:%M:%S', '2026-03-01 01:02:03'), strftime('%s', '2026-03-01')/,
        ~s/SELECT strftime('%j %w %u %W %d %m %H %M', '2026-03-01 07:08:09'), strftime('%W', '2026-01-04')/,
        ~s/SELECT strftime('%f', '2026-03-01 00:00:01.250'), strftime('%Y-%m-%dT%H:%M:%fZ', '2026-03-01 00:00:01.25')/,
        ~s/SELECT datetime(v) FROM (SELECT '2026-03-01T10:00:00.000Z' AS v UNION ALL SELECT NULL) t/,
        ~s|SELECT datetime(v) >= datetime('2026-02-01') FROM (SELECT '2026-03-01 10:00:00' AS v) t|
      ])
    )
  end

  test "now is the statement's time, on both forms", %{db: _db} do
    assert {:ok, [[1, 1, 1]]} =
             PgStore.raw_query(
               """
               SELECT datetime('now') = datetime('now', '+0 seconds'),
                      abs(julianday('now') - julianday(datetime('now'))) < 0.00002,
                      strftime('%s', 'now') = CAST(unixepoch() AS TEXT)
               """,
               []
             )
  end

  test "a modifier the store does not have is an error, never a wrong time" do
    assert {:error, _} = PgStore.raw_query("SELECT datetime('2026-03-01', 'weekday 0')", [])
  end
end
