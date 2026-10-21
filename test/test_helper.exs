# Skip RocksDB backend tests unless the NIF is loadable
exclude = if Code.ensure_loaded?(:rocksdb), do: [], else: [:rocksdb]

# The 100 MB Notion import timing runs only when asked for (--only notion_scale).
ExUnit.configure(exclude: [:notion_scale | exclude])

# Authority keys are wrapped in tests exactly as in production.
if is_nil(System.get_env("OPTIMAL_AUTHORITY_KEY")) do
  System.put_env("OPTIMAL_AUTHORITY_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
end

ExUnit.start()
