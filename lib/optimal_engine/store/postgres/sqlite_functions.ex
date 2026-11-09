defmodule OptimalEngine.Store.Postgres.SQLiteFunctions do
  @moduledoc """
  SQLite's JSON, date and time, and text functions as PostgreSQL functions, so
  the engine's statements that use them run on the PostgreSQL store with
  SQLite's results.

  `OptimalEngine.Store.Dialect` renames each SQLite call to its function here
  (`json_set` to `sqlite_json_set`, `datetime` to `sqlite_datetime`, ...), so
  no name collides with PostgreSQL's own `json_object`, `json_array`, `date`
  or `time`, and passes every argument as text, as SQLite reads it. The
  schema sync (`OptimalEngine.Store.Postgres.Schema.sync/2`) creates them,
  before any index or view, every time it runs.

  ## JSON

  JSON stays text. Documents are read as PostgreSQL `json`, which keeps the
  order of an object's members as written, and the result is minified with no
  space, as SQLite writes it: `json_set('{"b":1}', '$.a', 2)` is
  `{"b":1,"a":2}` on both stores. A path is `$`, then `.key`, `."key"`, `[N]`,
  `[#]` or `[#-N]`. A value is JSON when it is the result of another JSON
  function and otherwise the SQL value: text is a JSON string, a number a
  JSON number, NULL `null`. A parameter is bound as text, so a value bound to
  a parameter is a JSON string; bind JSON with `json(?)`.

  `sqlite_json_each` returns SQLite's columns (`key`, `value`, `type`, `atom`,
  `id`, `parent`, `fullkey`, `path`) as text, with a scalar's value as SQLite
  gives it (a string unquoted, `true` as 1, `null` as NULL) and a container's
  as minified JSON.

  ## Dates and times

  A time value is SQLite's: `now` (the statement's start, to the
  millisecond), `YYYY-MM-DD`, with `HH:MM`, `HH:MM:SS` or `HH:MM:SS.SSS`
  after a space or `T`, an optional `Z` or `+HH:MM`, `HH:MM[:SS]` alone, or a
  Julian day number (seconds since 1970 after `unixepoch`). It is held as
  SQLite holds it, milliseconds since the Julian epoch, and the modifiers
  move it as SQLite's do: `±N days|hours|minutes|seconds|months|years`
  (months and years by the calendar fields, so January 31 plus one month is
  March 2 or 3), `start of day|month|year`, `unixepoch`, `subsec`, and `utc`
  and `localtime`, which leave a UTC time as it is. A value that does not
  parse is NULL, as on SQLite; a modifier SQLite has and this does not raises.
  """

  @doc false
  def ddl, do: json_functions() ++ time_functions()

  defp json_functions do
    [
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_min(j json) RETURNS text
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        t text := json_typeof(j);
        out text;
      BEGIN
        IF j IS NULL THEN RETURN NULL; END IF;
        IF t = 'object' THEN
          SELECT '{' || COALESCE(string_agg(to_json(e.key)::text || ':' || sqlite_json_min(e.value), ',' ORDER BY e.n), '') || '}'
            INTO out FROM json_each(j) WITH ORDINALITY AS e(key, value, n);
          RETURN out;
        ELSIF t = 'array' THEN
          SELECT '[' || COALESCE(string_agg(sqlite_json_min(e.value), ',' ORDER BY e.n), '') || ']'
            INTO out FROM json_array_elements(j) WITH ORDINALITY AS e(value, n);
          RETURN out;
        ELSE
          RETURN btrim(j::text, E' \t\n\r');
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json(t text) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT sqlite_json_min(t::json) $fn$
      """,
      # A value as JSON text: a number stays a number, a boolean is 1 or 0 as
      # SQLite has it, NULL is null, and anything else is a JSON string.
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_value(v anyelement) RETURNS text
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        t regtype := pg_typeof(v);
      BEGIN
        IF v IS NULL THEN RETURN 'null'; END IF;
        IF t IN ('bigint'::regtype, 'integer'::regtype, 'smallint'::regtype) THEN RETURN v::text; END IF;
        IF t IN ('double precision'::regtype, 'real'::regtype, 'numeric'::regtype) THEN
          RETURN to_json(v)::text;
        END IF;
        IF t = 'boolean'::regtype THEN RETURN CASE WHEN v::text = 'true' THEN '1' ELSE '0' END; END IF;
        RETURN to_json(v::text)::text;
      END
      $fn$
      """,
      # A path as keys: 'k:<key>' for a member, 'i:<n>' for an element, 'i:#'
      # and 'i:#-<n>' for SQLite's end-of-array forms.
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_path(p text) RETURNS text[]
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        rest text;
        keys text[] := '{}';
        m text[];
      BEGIN
        IF p IS NULL OR left(p, 1) <> '$' THEN
          RAISE EXCEPTION 'bad JSON path: %', p USING ERRCODE = '22023';
        END IF;
        rest := substr(p, 2);
        WHILE rest <> '' LOOP
          m := regexp_match(rest, '^\."((?:[^"]|"")*)"');
          IF m IS NOT NULL THEN
            keys := keys || ('k:' || m[1]);
            rest := substr(rest, length(m[1]) + 4);
            CONTINUE;
          END IF;
          m := regexp_match(rest, '^\.([^.\[]+)');
          IF m IS NOT NULL THEN
            keys := keys || ('k:' || m[1]);
            rest := substr(rest, length(m[1]) + 2);
            CONTINUE;
          END IF;
          m := regexp_match(rest, '^\[(\d+|#|#-\d+)\]');
          IF m IS NOT NULL THEN
            keys := keys || ('i:' || m[1]);
            rest := substr(rest, length(m[1]) + 3);
            CONTINUE;
          END IF;
          RAISE EXCEPTION 'bad JSON path: %', p USING ERRCODE = '22023';
        END LOOP;
        RETURN keys;
      END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_index(k text, len int) RETURNS int
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT CASE WHEN k = 'i:#' THEN len
                    WHEN k LIKE 'i:#-%' THEN len - substr(k, 5)::int
                    ELSE substr(k, 3)::int END
      $fn$
      """,
      # The value at keys, or NULL when the path is not in the document.
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_at(doc json, keys text[]) RETURNS json
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        k text;
        found json;
        i int;
      BEGIN
        FOREACH k IN ARRAY keys LOOP
          IF doc IS NULL THEN RETURN NULL; END IF;
          IF left(k, 2) = 'k:' THEN
            IF json_typeof(doc) <> 'object' THEN RETURN NULL; END IF;
            SELECT e.value INTO found FROM json_each(doc) WITH ORDINALITY AS e(key, value, n)
              WHERE e.key = substr(k, 3) ORDER BY e.n LIMIT 1;
            doc := found;
            found := NULL;
          ELSE
            IF json_typeof(doc) <> 'array' THEN RETURN NULL; END IF;
            i := sqlite_json_index(k, json_array_length(doc));
            IF i < 0 OR i >= json_array_length(doc) THEN RETURN NULL; END IF;
            doc := doc -> i;
          END IF;
        END LOOP;
        RETURN doc;
      END
      $fn$
      """,
      # SQLite's json_set ('set'), json_insert ('insert'), json_replace
      # ('replace') and json_remove ('remove') at one path. A missing member
      # on the way is created for set and insert, as SQLite does.
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_put(doc json, keys text[], val json, mode text) RETURNS json
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        k text := keys[1];
        rest text[] := keys[2:];
        parts text[] := '{}';
        hit boolean := false;
        e record;
        i int;
        len int;
        child json;
      BEGIN
        IF k IS NULL THEN
          IF mode IN ('set', 'replace') THEN RETURN val; END IF;
          IF mode = 'remove' THEN RETURN NULL; END IF;
          RETURN doc;
        END IF;

        IF left(k, 2) = 'k:' THEN
          IF json_typeof(doc) IS DISTINCT FROM 'object' THEN RETURN doc; END IF;
          FOR e IN SELECT x.key, x.value FROM json_each(doc) WITH ORDINALITY AS x(key, value, n) ORDER BY x.n LOOP
            IF NOT hit AND e.key = substr(k, 3) THEN
              hit := true;
              IF rest = '{}' THEN
                IF mode = 'remove' THEN CONTINUE; END IF;
                child := CASE WHEN mode = 'insert' THEN e.value ELSE val END;
              ELSE
                child := sqlite_json_put(e.value, rest, val, mode);
              END IF;
              parts := parts || (to_json(e.key)::text || ':' || child::text);
            ELSE
              parts := parts || (to_json(e.key)::text || ':' || e.value::text);
            END IF;
          END LOOP;
          IF NOT hit AND mode IN ('set', 'insert') THEN
            IF rest = '{}' THEN
              child := val;
            ELSE
              child := sqlite_json_put(CASE WHEN left(rest[1], 2) = 'i:' THEN '[]'::json ELSE '{}'::json END, rest, val, mode);
            END IF;
            IF child IS NOT NULL THEN parts := parts || (to_json(substr(k, 3))::text || ':' || child::text); END IF;
          END IF;
          RETURN ('{' || array_to_string(parts, ',') || '}')::json;
        END IF;

        IF json_typeof(doc) IS DISTINCT FROM 'array' THEN RETURN doc; END IF;
        len := json_array_length(doc);
        i := sqlite_json_index(k, len);
        FOR e IN SELECT x.value, x.n - 1 AS idx FROM json_array_elements(doc) WITH ORDINALITY AS x(value, n) ORDER BY x.n LOOP
          IF e.idx = i THEN
            hit := true;
            IF rest = '{}' THEN
              IF mode = 'remove' THEN CONTINUE; END IF;
              child := CASE WHEN mode = 'insert' THEN e.value ELSE val END;
            ELSE
              child := sqlite_json_put(e.value, rest, val, mode);
            END IF;
            parts := parts || child::text;
          ELSE
            parts := parts || e.value::text;
          END IF;
        END LOOP;
        IF NOT hit AND i = len AND mode IN ('set', 'insert') THEN
          IF rest = '{}' THEN
            child := val;
          ELSE
            child := sqlite_json_put(CASE WHEN left(rest[1], 2) = 'i:' THEN '[]'::json ELSE '{}'::json END, rest, val, mode);
          END IF;
          IF child IS NOT NULL THEN parts := parts || child::text; END IF;
        END IF;
        RETURN ('[' || array_to_string(parts, ',') || ']')::json;
      END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_edit(mode text, doc text, pv text[]) RETURNS text
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        d json;
        i int := 1;
      BEGIN
        IF doc IS NULL THEN RETURN NULL; END IF;
        d := doc::json;
        WHILE i <= COALESCE(array_length(pv, 1), 0) LOOP
          IF pv[i] IS NULL THEN RETURN NULL; END IF;
          IF mode = 'remove' THEN
            d := sqlite_json_put(d, sqlite_json_path(pv[i]), NULL, mode);
            i := i + 1;
          ELSE
            d := sqlite_json_put(d, sqlite_json_path(pv[i]), pv[i + 1]::json, mode);
            i := i + 2;
          END IF;
          IF d IS NULL THEN RETURN NULL; END IF;
        END LOOP;
        RETURN sqlite_json_min(d);
      END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_set(doc text, VARIADIC pv text[]) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT sqlite_json_edit('set', doc, pv) $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_insert(doc text, VARIADIC pv text[]) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT sqlite_json_edit('insert', doc, pv) $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_replace(doc text, VARIADIC pv text[]) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT sqlite_json_edit('replace', doc, pv) $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_remove(doc text, VARIADIC paths text[]) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT sqlite_json_edit('remove', doc, paths) $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_object(VARIADIC kv text[]) RETURNS text
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        parts text[] := '{}';
        i int := 1;
      BEGIN
        WHILE i <= COALESCE(array_length(kv, 1), 0) LOOP
          IF kv[i] IS NULL THEN RAISE EXCEPTION 'json_object() labels must be TEXT' USING ERRCODE = '22023'; END IF;
          parts := parts || (to_json(kv[i])::text || ':' || sqlite_json_min(kv[i + 1]::json));
          i := i + 2;
        END LOOP;
        RETURN '{' || array_to_string(parts, ',') || '}';
      END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_array(VARIADIC vs text[]) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT '[' || COALESCE(string_agg(sqlite_json_min(v::json), ',' ORDER BY n), '') || ']'
        FROM unnest(vs) WITH ORDINALITY AS u(v, n)
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_kind(j json) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT CASE json_typeof(j)
          WHEN 'object' THEN 'object' WHEN 'array' THEN 'array' WHEN 'string' THEN 'text'
          WHEN 'boolean' THEN CASE WHEN j::text = 'true' THEN 'true' ELSE 'false' END
          WHEN 'null' THEN 'null'
          WHEN 'number' THEN CASE WHEN j::text ~ '[.eE]' THEN 'real' ELSE 'integer' END
        END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_type(doc text, p text DEFAULT '$') RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT sqlite_json_kind(sqlite_json_at(doc::json, sqlite_json_path(p))) $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_array_length(doc text, p text DEFAULT '$') RETURNS bigint
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT CASE WHEN j IS NULL THEN NULL WHEN json_typeof(j) = 'array' THEN json_array_length(j) ELSE 0 END
        FROM (SELECT sqlite_json_at(doc::json, sqlite_json_path(p)) AS j) s
      $fn$
      """,
      # The JSON of the value at a path, for a JSON argument of another JSON
      # function (SQLite passes json_extract's result on as JSON).
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_extract_json(doc text, p text) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT COALESCE(sqlite_json_min(sqlite_json_at(doc::json, sqlite_json_path(p))), 'null') $fn$
      """,
      # A scalar as SQLite's json_each and json_extract give it.
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_sql(j json) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$
        SELECT CASE json_typeof(j)
          WHEN 'string' THEN j #>> '{}'
          WHEN 'number' THEN btrim(j::text, E' \t\n\r')
          WHEN 'boolean' THEN CASE WHEN j::text = 'true' THEN '1' ELSE '0' END
          WHEN 'null' THEN NULL
          ELSE sqlite_json_min(j)
        END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_each(doc text, p text DEFAULT '$')
      RETURNS TABLE (key text, value text, type text, atom text, id bigint, parent bigint, fullkey text, path text)
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        root json;
      BEGIN
        IF doc IS NULL THEN RETURN; END IF;
        root := sqlite_json_at(doc::json, sqlite_json_path(p));
        IF root IS NULL THEN RETURN; END IF;
        IF json_typeof(root) = 'object' THEN
          RETURN QUERY
            SELECT e.key, sqlite_json_sql(e.value), sqlite_json_kind(e.value),
                   CASE WHEN json_typeof(e.value) IN ('object', 'array') THEN NULL ELSE sqlite_json_sql(e.value) END,
                   e.n, NULL::bigint, p || '.' || e.key, p
            FROM json_each(root) WITH ORDINALITY AS e(key, value, n) ORDER BY e.n;
        ELSIF json_typeof(root) = 'array' THEN
          RETURN QUERY
            SELECT (e.n - 1)::text, sqlite_json_sql(e.value), sqlite_json_kind(e.value),
                   CASE WHEN json_typeof(e.value) IN ('object', 'array') THEN NULL ELSE sqlite_json_sql(e.value) END,
                   e.n, NULL::bigint, p || '[' || (e.n - 1) || ']', p
            FROM json_array_elements(root) WITH ORDINALITY AS e(value, n) ORDER BY e.n;
        ELSE
          RETURN QUERY SELECT NULL::text, sqlite_json_sql(root), sqlite_json_kind(root), sqlite_json_sql(root),
                              0::bigint, NULL::bigint, p, p;
        END IF;
      END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_group_step(acc text[], v text) RETURNS text[]
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT acc || sqlite_json_min(v::json) $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_json_group_final(acc text[]) RETURNS text
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT '[' || array_to_string(acc, ',') || ']' $fn$
      """,
      "DROP AGGREGATE IF EXISTS sqlite_json_group_array(text)",
      """
      CREATE AGGREGATE sqlite_json_group_array(text) (
        SFUNC = sqlite_json_group_step, STYPE = text[], FINALFUNC = sqlite_json_group_final, INITCOND = '{}'
      )
      """
    ]
  end

  defp time_functions do
    [
      # SQLite's GLOB pattern as an anchored regular expression.
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_glob_regex(p text) RETURNS text
      LANGUAGE plpgsql IMMUTABLE AS $fn$
      DECLARE
        out text := '^';
        i int := 1;
        c text;
        j int;
      BEGIN
        IF p IS NULL THEN RETURN NULL; END IF;
        WHILE i <= length(p) LOOP
          c := substr(p, i, 1);
          IF c = '*' THEN
            out := out || '.*';
          ELSIF c = '?' THEN
            out := out || '.';
          ELSIF c = '[' AND strpos(substr(p, i + 2), ']') > 0 THEN
            j := i + 1 + strpos(substr(p, i + 2), ']');
            out := out || '[' || replace(replace(substr(p, i + 1, j - i - 1), '\', '\\'), '[', '\[') || ']';
            i := j;
          ELSE
            out := out || regexp_replace(c, '([.^$|()\[\]{}*+?\\])', '\\\1');
          END IF;
          i := i + 1;
        END LOOP;
        RETURN out || '$';
      END
      $fn$
      """,
      # Milliseconds since the Julian epoch of a time value after its
      # modifiers, as SQLite's DateTime.iJD, and whether subsec was asked for.
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_time_value(args text[], OUT ijd bigint, OUT subsec boolean)
      LANGUAGE plpgsql STABLE AS $fn$
      DECLARE
        v text := btrim(args[1]);
        m text[];
        y int; mo int; d int; h int := 0; mi int := 0; s double precision := 0; tz int := 0;
        a int; b int; x1 int; x2 int;
        r double precision;
        rounder double precision;
        modifier text;
        n int := 2;
        ts timestamp;
        months int;
        whole double precision;
      BEGIN
        subsec := false;
        IF v IS NULL THEN ijd := NULL; RETURN; END IF;

        m := regexp_match(v, '^(-?\d{4})-(\d\d)-(\d\d)(?:(?:\s+|T)(\d\d):(\d\d)(?::(\d\d(?:\.\d*)?))?)?\s*(Z|[+-]\d\d:?\d\d)?$', 'i');
        IF lower(v) = 'now' THEN
          ijd := floor(extract(epoch FROM statement_timestamp()) * 1000)::bigint + 210866760000000;
        ELSIF m IS NOT NULL THEN
          y := m[1]::int; mo := m[2]::int; d := m[3]::int;
          IF m[4] IS NOT NULL THEN h := m[4]::int; mi := m[5]::int; s := COALESCE(m[6]::double precision, 0); END IF;
          IF mo < 1 OR mo > 12 OR d < 1 OR d > 31 OR h > 24 OR mi > 59 OR s >= 60 THEN ijd := NULL; RETURN; END IF;
          IF m[7] IS NOT NULL AND upper(m[7]) <> 'Z' THEN
            tz := (substr(m[7], 2, 2)::int * 60 + right(m[7], 2)::int) * CASE WHEN left(m[7], 1) = '-' THEN -1 ELSE 1 END;
          END IF;
          IF mo <= 2 THEN y := y - 1; mo := mo + 12; END IF;
          a := y / 100; b := 2 - a + a / 4;
          x1 := 36525 * (y + 4716) / 100; x2 := 30601 * (mo + 1) / 1000;
          ijd := trunc((x1 + x2 + d + b - 1524.5::double precision) * 86400000)::bigint;
          ijd := ijd + h * 3600000 + mi * 60000 + trunc(s * 1000 + 0.5)::bigint - tz * 60000;
        ELSIF regexp_match(v, '^(\d\d):(\d\d)(?::(\d\d(?:\.\d*)?))?$') IS NOT NULL THEN
          m := regexp_match(v, '^(\d\d):(\d\d)(?::(\d\d(?:\.\d*)?))?$');
          ijd := 211813444800000 + m[1]::int * 3600000 + m[2]::int * 60000
                 + trunc(COALESCE(m[3]::double precision, 0) * 1000 + 0.5)::bigint;
        ELSIF v ~ '^[-+]?\d+(\.\d+)?$' THEN
          r := v::double precision;
          IF lower(btrim(COALESCE(args[2], ''))) = 'unixepoch' THEN
            ijd := trunc(r * 1000 + CASE WHEN r < 0 THEN -0.5 ELSE 0.5 END)::bigint + 210866760000000;
            n := 3;
          ELSE
            ijd := trunc(r * 86400000.0 + 0.5)::bigint;
          END IF;
        ELSE
          ijd := NULL; RETURN;
        END IF;

        WHILE n <= COALESCE(array_length(args, 1), 0) LOOP
          IF args[n] IS NULL THEN ijd := NULL; RETURN; END IF;
          modifier := lower(btrim(args[n]));
          n := n + 1;
          ts := timestamp '1970-01-01' + (ijd - 210866760000000) * interval '1 millisecond';

          IF modifier IN ('utc', 'localtime', 'auto') THEN
            CONTINUE;
          ELSIF modifier IN ('subsec', 'subsecond') THEN
            subsec := true;
          ELSIF modifier IN ('start of day', 'start of month', 'start of year') THEN
            ts := date_trunc(substr(modifier, 10), ts);
            ijd := (extract(epoch FROM ts) * 1000)::bigint + 210866760000000;
          ELSIF regexp_match(modifier, '^([+-]?\d+(?:\.\d*)?|[+-]?\.\d+)\s+(day|hour|minute|second|month|year)s?$') IS NOT NULL THEN
            m := regexp_match(modifier, '^([+-]?\d+(?:\.\d*)?|[+-]?\.\d+)\s+(day|hour|minute|second|month|year)s?$');
            r := m[1]::double precision;
            rounder := CASE WHEN r < 0 THEN -0.5 ELSE 0.5 END;
            IF m[2] IN ('month', 'year') THEN
              whole := trunc(r);
              months := whole::int * CASE WHEN m[2] = 'year' THEN 12 ELSE 1 END;
              y := extract(year FROM ts)::int; mo := extract(month FROM ts)::int; d := extract(day FROM ts)::int;
              mo := mo - 1 + months;
              y := y + floor(mo / 12.0)::int;
              mo := mo - floor(mo / 12.0)::int * 12 + 1;
              ts := make_timestamp(y, mo, 1, 0, 0, 0) + (d - 1) * interval '1 day' + (ts - date_trunc('day', ts));
              ijd := (extract(epoch FROM ts) * 1000)::bigint + 210866760000000;
              IF r <> whole THEN
                ijd := ijd + trunc((r - whole) * CASE WHEN m[2] = 'year' THEN 365.0 ELSE 30.0 END * 86400000.0 + rounder)::bigint;
              END IF;
            ELSE
              ijd := ijd + trunc(r * CASE m[2] WHEN 'day' THEN 86400000.0 WHEN 'hour' THEN 3600000.0
                                             WHEN 'minute' THEN 60000.0 ELSE 1000.0 END + rounder)::bigint;
            END IF;
          ELSE
            RAISE EXCEPTION 'SQLite date modifier % is not supported on PostgreSQL', modifier USING ERRCODE = '0A000';
          END IF;
        END LOOP;
      END
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_time_ts(ijd bigint) RETURNS timestamp
      LANGUAGE sql IMMUTABLE AS $fn$ SELECT timestamp '1970-01-01' + (ijd - 210866760000000) * interval '1 millisecond' $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_datetime(VARIADIC args text[]) RETURNS text
      LANGUAGE sql STABLE AS $fn$
        SELECT to_char(sqlite_time_ts(t.ijd), CASE WHEN t.subsec THEN 'YYYY-MM-DD HH24:MI:SS.MS' ELSE 'YYYY-MM-DD HH24:MI:SS' END)
        FROM sqlite_time_value(args) t
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_date(VARIADIC args text[]) RETURNS text
      LANGUAGE sql STABLE AS $fn$ SELECT to_char(sqlite_time_ts(t.ijd), 'YYYY-MM-DD') FROM sqlite_time_value(args) t $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_time(VARIADIC args text[]) RETURNS text
      LANGUAGE sql STABLE AS $fn$
        SELECT to_char(sqlite_time_ts(t.ijd), CASE WHEN t.subsec THEN 'HH24:MI:SS.MS' ELSE 'HH24:MI:SS' END)
        FROM sqlite_time_value(args) t
      $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_julianday(VARIADIC args text[]) RETURNS double precision
      LANGUAGE sql STABLE AS $fn$ SELECT t.ijd / 86400000.0::double precision FROM sqlite_time_value(args) t $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_unixepoch(VARIADIC args text[]) RETURNS bigint
      LANGUAGE sql STABLE AS $fn$ SELECT t.ijd / 1000 - 210866760000 FROM sqlite_time_value(args) t $fn$
      """,
      ~S"""
      CREATE OR REPLACE FUNCTION sqlite_strftime(fmt text, VARIADIC args text[]) RETURNS text
      LANGUAGE plpgsql STABLE AS $fn$
      DECLARE
        t record;
        ts timestamp;
        out text := '';
        i int := 1;
        c text;
        yday int;
        wd int;
      BEGIN
        SELECT * INTO t FROM sqlite_time_value(args);
        IF fmt IS NULL OR t.ijd IS NULL THEN RETURN NULL; END IF;
        ts := sqlite_time_ts(t.ijd);
        WHILE i <= length(fmt) LOOP
          c := substr(fmt, i, 1);
          IF c <> '%' THEN out := out || c; i := i + 1; CONTINUE; END IF;
          c := substr(fmt, i + 1, 1);
          i := i + 2;
          yday := extract(doy FROM ts)::int;
          wd := ((t.ijd + 43200000) / 86400000 % 7)::int;
          out := out || CASE c
            WHEN 'd' THEN to_char(ts, 'DD')
            WHEN 'e' THEN lpad(extract(day FROM ts)::int::text, 2)
            WHEN 'f' THEN to_char(ts, 'SS.MS')
            WHEN 'F' THEN to_char(ts, 'YYYY-MM-DD')
            WHEN 'H' THEN to_char(ts, 'HH24')
            WHEN 'k' THEN lpad(extract(hour FROM ts)::int::text, 2)
            WHEN 'j' THEN lpad(yday::text, 3, '0')
            WHEN 'J' THEN (t.ijd / 86400000.0::double precision)::text
            WHEN 'm' THEN to_char(ts, 'MM')
            WHEN 'M' THEN to_char(ts, 'MI')
            WHEN 's' THEN (t.ijd / 1000 - 210866760000)::text
            WHEN 'S' THEN to_char(ts, 'SS')
            WHEN 'T' THEN to_char(ts, 'HH24:MI:SS')
            WHEN 'R' THEN to_char(ts, 'HH24:MI')
            WHEN 'u' THEN (wd + 1)::text
            WHEN 'w' THEN ((wd + 1) % 7)::text
            WHEN 'W' THEN lpad(((yday - 1 + 7 - wd) / 7)::text, 2, '0')
            WHEN 'Y' THEN to_char(ts, 'YYYY')
            WHEN '%' THEN '%'
            ELSE NULL
          END;
          IF out IS NULL THEN
            RAISE EXCEPTION 'strftime format %% % is not supported on PostgreSQL', c USING ERRCODE = '0A000';
          END IF;
        END LOOP;
        RETURN out;
      END
      $fn$
      """
    ]
  end
end
