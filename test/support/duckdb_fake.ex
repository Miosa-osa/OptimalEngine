defmodule OptimalEngine.TestSupport.DuckDBFake do
  @moduledoc """
  A fake `duckdb` executable for tests: a shell script that answers the three
  statements the provider sends (`SELECT 1`, `COPY ... TO '<file>'`,
  `SELECT value FROM read_parquet('<file>')`) by writing and reading a plain
  file, printing JSON rows as the real CLI does with `-json`. Tests put its
  directory first on the PATH. No test here needs DuckDB installed.
  """

  @script ~S"""
  #!/usr/bin/env bash
  set -euo pipefail
  sql="${4:-}"
  case "$sql" in
    "SELECT 1 AS one") echo '[{"one":1}]' ;;
    COPY*)
      value=$(printf '%s' "$sql" | sed -E "s/.*SELECT '([^']*)' AS value.*/\1/")
      file=$(printf '%s' "$sql" | sed -E "s/.*TO '([^']*)'.*/\1/")
      printf '%s' "$value" > "$file"
      echo '[]' ;;
    *read_parquet*)
      file=$(printf '%s' "$sql" | sed -E "s/.*read_parquet\('([^']*)'\).*/\1/")
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
