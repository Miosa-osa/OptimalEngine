defmodule OptimalEngine.Store.Postgres.SqliteJson do
  @moduledoc """
  SQL functions on the PostgreSQL store that read JSON text as SQLite's JSON
  functions read it, for the statements that must decide exactly what SQLite
  decides (the replication gate, `OptimalEngine.Sync.Gate`, and
  `OptimalEngine.Sync.Lineage`).

  PostgreSQL's `json` type keeps an object's members in order and keeps a key
  that appears twice, as SQLite's JSON text does, so these functions read
  `json`, never `jsonb`.

  | Function | SQLite |
  | --- | --- |
  | `oe_json_valid(t)` | `json_valid(t)`, as a boolean |
  | `oe_json_type(t)`, `oe_json_type(t, '$.key')` | `json_type`: `null`, `true`, `false`, `integer`, `real`, `text`, `array`, `object` |
  | `oe_json_extract(t, '$.key')` | `json_extract`: a string unquoted, `true`/`false` as `1`/`0`, JSON `null` as NULL, anything else as JSON text; the first member of a key that appears twice |
  | `oe_json_raw(t, '$.key')` | the member as `json`, for building an object (`json_object` keeps a JSON value's subtype) |
  | `oe_json_each(t)`, `oe_json_each(t, '$.key')` | `json_each`: `key`, `value` and `type` of an object's members, an array's elements (keyed by index), or a scalar itself |

  Paths are `'$.key'` with one plain key, the only form the callers use.
  Booleans are returned as PostgreSQL booleans where SQLite returns 1 or 0 to a
  condition; the callers use `TRUE` and `FALSE` there on PostgreSQL.

  `ensure/1` creates them each time the store starts.
  """

  alias OptimalEngine.Store.Postgres.Connection

  @doc "Creates or replaces the functions."
  @spec ensure(GenServer.server()) :: :ok | {:error, term()}
  def ensure(pool) do
    result =
      Connection.transaction(
        pool,
        fn txn ->
          Enum.reduce_while(
            ["SELECT pg_advisory_xact_lock(hashtext('optimal_engine.sqlite_json'))" | ddl()],
            {:ok, :ensured},
            fn sql, ok ->
              case Connection.txn_query(txn, sql, [], dialect: :postgres) do
                {:ok, _} -> {:cont, ok}
                {:error, _} = error -> {:halt, error}
              end
            end
          )
        end,
        60_000
      )

    with {:ok, _} <- result, do: :ok
  end

  @doc false
  def ddl do
    [
      """
      CREATE OR REPLACE FUNCTION oe_json_valid(t text) RETURNS boolean
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT t IS JSON $fn$
      """,
      """
      CREATE OR REPLACE FUNCTION oe_json_kind(v json) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT CASE json_typeof(v)
          WHEN 'string' THEN 'text'
          WHEN 'boolean' THEN btrim(v::text)
          WHEN 'number' THEN CASE WHEN v::text ~ '[.eE]' THEN 'real' ELSE 'integer' END
          ELSE json_typeof(v) END
      $fn$
      """,
      """
      CREATE OR REPLACE FUNCTION oe_json_value(v json) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT CASE oe_json_kind(v)
          WHEN 'text' THEN v #>> '{}'
          WHEN 'null' THEN NULL
          WHEN 'true' THEN '1'
          WHEN 'false' THEN '0'
          ELSE btrim(v::text) END
      $fn$
      """,
      # The first member named `key` of an object, as SQLite's json_extract
      # reads a key that appears twice.
      """
      CREATE OR REPLACE FUNCTION oe_json_raw(t text, path text) RETURNS json
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT CASE WHEN t IS JSON AND json_typeof(t::json) = 'object' THEN
          (SELECT e.value FROM json_each(t::json) WITH ORDINALITY AS e(key, value, n)
           WHERE e.key = substr(path, 3) ORDER BY e.n LIMIT 1)
        END
      $fn$
      """,
      """
      CREATE OR REPLACE FUNCTION oe_json_type(t text) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT CASE WHEN t IS JSON THEN oe_json_kind(t::json) END $fn$
      """,
      """
      CREATE OR REPLACE FUNCTION oe_json_type(t text, path text) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT oe_json_kind(oe_json_raw(t, path)) $fn$
      """,
      """
      CREATE OR REPLACE FUNCTION oe_json_extract(t text, path text) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT oe_json_value(oe_json_raw(t, path)) $fn$
      """,
      """
      CREATE OR REPLACE FUNCTION oe_json_each(t text)
      RETURNS TABLE (key text, value text, type text)
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT e.key, oe_json_value(e.value), oe_json_kind(e.value)
        FROM json_each(CASE WHEN json_typeof(t::json) = 'object' THEN t::json END) WITH ORDINALITY AS e(key, value, n)
        UNION ALL
        SELECT (a.n - 1)::text, oe_json_value(a.value), oe_json_kind(a.value)
        FROM json_array_elements(CASE WHEN json_typeof(t::json) = 'array' THEN t::json END) WITH ORDINALITY AS a(value, n)
        UNION ALL
        SELECT NULL, oe_json_value(t::json), oe_json_kind(t::json)
        WHERE json_typeof(t::json) NOT IN ('object', 'array')
      $fn$
      """,
      """
      CREATE OR REPLACE FUNCTION oe_json_each(t text, path text)
      RETURNS TABLE (key text, value text, type text)
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT * FROM oe_json_each(oe_json_raw(t, path)::text)
      $fn$
      """
    ]
  end
end
