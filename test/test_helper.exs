# Skip RocksDB backend tests unless the NIF is loadable
exclude = if Code.ensure_loaded?(:rocksdb), do: [], else: [:rocksdb]

# PostgreSQL store tests run against OPTIMAL_TEST_POSTGRES_URL and are skipped
# without it (test/support/postgres_store.ex).
exclude =
  if OptimalEngine.Test.PostgresStore.available?() do
    exclude
  else
    IO.puts(
      "PostgreSQL store tests skipped: set #{OptimalEngine.Test.PostgresStore.env_name()} to run them."
    )

    [:postgres | exclude]
  end

# The Valkey integration test runs against OPTIMAL_TEST_VALKEY_URL and is
# skipped without it (test/storage/valkey_integration_test.exs).
exclude =
  if System.get_env("OPTIMAL_TEST_VALKEY_URL") in [nil, ""],
    do: [:valkey | exclude],
    else: exclude

# A forgotten memory's text is still in the replication ledger until the
# ledger redaction lands; the assertion that it is not is tagged
# :ledger_redaction (test/memory/memory_forget_erasure_test.exs) and enabled
# with it.
exclude = [:ledger_redaction | exclude]

# With OPTIMAL_STORE=postgres the Engine runs on PostgreSQL;
# tests that need the embedded SQLite store as the Engine's store, or start a
# PostgreSQL store of their own beside it, are tagged :sqlite_store.
# and tests of how the Engine behaves on PostgreSQL itself (concurrent
# writers, sequences drawn before commit) are tagged :postgres_store and run
# only there.
exclude =
  if OptimalEngine.Store.selected?(OptimalEngine.Store.Postgres),
    do: [:sqlite_store | exclude],
    else: [:postgres_store | exclude]

# Tests of what the Engine does on its PostgreSQL store only (the posting
# lists it refreshes after a commit) are tagged :postgres_engine.
exclude =
  if OptimalEngine.Store.selected?(OptimalEngine.Store.Postgres),
    do: exclude,
    else: [:postgres_engine | exclude]

# Analytics against a real DuckDB run with OPTIMAL_TEST_DUCKDB naming the
# `duckdb` executable (test/analytics/analytics_duckdb_test.exs). CI sets it
# (.github/workflows/ci.yml), so a value naming nothing that runs stops the
# suite instead of quietly skipping the lockdown tests.
exclude =
  case System.get_env("OPTIMAL_TEST_DUCKDB") do
    path when is_binary(path) and path != "" ->
      case System.cmd(path, ["--version"], stderr_to_stdout: true) do
        {version, 0} ->
          IO.puts("DuckDB analytics tests run against duckdb #{String.trim(version)}.")
          exclude

        {output, status} ->
          raise "OPTIMAL_TEST_DUCKDB=#{path} did not run (exit #{status}): #{output}"
      end

    _ ->
      IO.puts("DuckDB analytics tests skipped: set OPTIMAL_TEST_DUCKDB to a duckdb executable.")
      [:duckdb | exclude]
  end

# The Qdrant integration tests run against a real server at
# OPTIMAL_TEST_QDRANT_URL (docker run -p 6333:6333 qdrant/qdrant) and are
# skipped without it; every other Qdrant test uses the local stub.
exclude =
  case System.get_env("OPTIMAL_TEST_QDRANT_URL") do
    url when is_binary(url) and url != "" -> exclude
    _ -> [:qdrant_integration | exclude]
  end

# The 100 MB Notion import timing runs only when asked for (--only notion_scale).
ExUnit.configure(exclude: [:notion_scale | exclude])

# Authority keys are wrapped in tests exactly as in production.
if is_nil(System.get_env("OPTIMAL_AUTHORITY_KEY")) do
  System.put_env("OPTIMAL_AUTHORITY_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
end

ExUnit.start()

# OPTIMAL_SQL_CENSUS=<path> records the statements the suite runs on SQLite and
# reports which of them prepare on PostgreSQL (test/support/sql_census.ex).
if OptimalEngine.Test.SqlCensus.enabled?(), do: OptimalEngine.Test.SqlCensus.start()
