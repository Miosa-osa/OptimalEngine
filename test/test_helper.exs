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

ExUnit.configure(exclude: exclude)

# Authority keys are wrapped in tests exactly as in production.
if is_nil(System.get_env("OPTIMAL_AUTHORITY_KEY")) do
  System.put_env("OPTIMAL_AUTHORITY_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
end

ExUnit.start()

# OPTIMAL_SQL_CENSUS=<path> records the statements the suite runs on SQLite and
# reports which of them prepare on PostgreSQL (test/support/sql_census.ex).
if OptimalEngine.Test.SqlCensus.enabled?(), do: OptimalEngine.Test.SqlCensus.start()
