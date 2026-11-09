defmodule OptimalEngine.TestSupport.DuckDBFake do
  @moduledoc """
  A fake `duckdb` executable for tests: a shell script that answers the three
  statements the provider sends (`SELECT 1`, `COPY ... TO '<file>'`,
  `SELECT value FROM read_parquet('<file>')`) by writing and reading a plain
  file, printing JSON rows as the real CLI does with `-json`. A quote doubled
  inside a path literal is read back as one, as SQL does. `SELECT 'hang'`
  writes its pid to `$DUCKDB_FAKE_PIDFILE` and never answers, as one process
  (`exec sleep`), for the timeout test. Tests put its
  directory first on the PATH. No test here needs DuckDB installed.

  The analytics statements (`OptimalEngine.Analytics`) start with the
  lockdown `SET`s. For them the fake appends every statement it is sent to
  `$DUCKDB_FAKE_LOG`, answers an export's `COPY (... read_json('<ndjson>') ...)
  TO '<parquet>'` by copying the NDJSON to the Parquet path, its
  `SELECT count(*) AS n` by counting that file's lines, and any other
  `read_parquet` query with the JSON in `$DUCKDB_FAKE_ROWS` (`[]` without it).
  `$DUCKDB_FAKE_FAIL` set makes every analytics statement fail.
  """

  @script ~S"""
  #!/usr/bin/env bash
  set -euo pipefail
  sql="${4:-}"
  if [ -n "${DUCKDB_FAKE_LOG:-}" ]; then printf '%s\n' "$sql" >> "$DUCKDB_FAKE_LOG"; fi
  case "$sql" in
    SET*)
      if [ -n "${DUCKDB_FAKE_FAIL:-}" ]; then echo "IO Error: fake failure" >&2; exit 1; fi
      case "$sql" in
        *read_json*)
          src=$(printf '%s' "$sql" | sed -E "s/.*read_json\('((''|[^'])*)'.*/\1/" | sed "s/''/'/g")
          dst=$(printf '%s' "$sql" | sed -E "s/.*\) TO '((''|[^'])*)'.*/\1/" | sed "s/''/'/g")
          cp "$src" "$dst"
          echo '[]' ;;
        *"count(*) AS n"*)
          file=$(printf '%s' "$sql" | sed -E "s/.*read_parquet\('((''|[^'])*)'\).*/\1/" | sed "s/''/'/g")
          printf '[{"n":%s}]\n' "$(grep -c . "$file" || true)" ;;
        *read_parquet*) printf '%s\n' "${DUCKDB_FAKE_ROWS:-[]}" ;;
        *) echo "Parser Error: fake duckdb does not know: $sql" >&2; exit 1 ;;
      esac ;;
    "SELECT 1 AS one") echo '[{"one":1}]' ;;
    "SELECT 'hang'")
      echo "$$" > "${DUCKDB_FAKE_PIDFILE:-/dev/null}"
      exec sleep 30 ;;
    COPY*)
      value=$(printf '%s' "$sql" | sed -E "s/.*SELECT '([^']*)' AS value.*/\1/")
      file=$(printf '%s' "$sql" | sed -E "s/.*TO '((''|[^'])*)'.*/\1/" | sed "s/''/'/g")
      printf '%s' "$value" > "$file"
      echo '[]' ;;
    *read_parquet*)
      file=$(printf '%s' "$sql" | sed -E "s/.*read_parquet\('((''|[^'])*)'\).*/\1/" | sed "s/''/'/g")
      printf '[{"value":"%s"}]\n' "$(cat "$file")" ;;
    *) echo "Parser Error: fake duckdb does not know: $sql" >&2; exit 1 ;;
  esac
  """

  @doc "Installs the fake in a fresh directory and puts it first on the PATH. Returns a restore function."
  @spec install() :: {String.t(), (-> :ok)}
  def install do
    dir = Path.join(System.tmp_dir!(), "duckdb-fake-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "duckdb")
    File.write!(path, @script)
    File.chmod!(path, 0o755)
    previous = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> previous)

    {dir,
     fn ->
       System.put_env("PATH", previous)
       File.rm_rf!(dir)
       :ok
     end}
  end
end
