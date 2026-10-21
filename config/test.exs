import Config

# Use bcrypt cost 4 in tests — functionally identical, ~80x faster than cost 12.
config :optimal_engine, :auth,
  auth_required: false,
  bcrypt_cost: 4

# Integration tests exercise many API endpoints in one run. Keep rate limits high
# so the suite validates behavior rather than hitting infra guardrails.
config :optimal_engine,
  api_rate_limit_capacity: 10_000,
  api_rate_limit_per_minute: 10_000

# Test data lives inside this checkout (mix.exs `test_store_dir/0`), so two
# checkouts, or two users on one shared machine, never share a database, a
# cache or a root. A fixed /tmp path made one user's leftover database block
# another user's run.
test_dir = Path.expand("../_build/test_store", __DIR__)
test_root = Path.join(test_dir, "optimal_engine_test_root")

config :optimal_engine,
  root_path: test_root,
  db_path:
    Path.join(test_dir, "optimal_engine_test_#{System.get_env("MIX_TEST_PARTITION", "0")}.db"),
  cache_path: Path.join(test_dir, "optimal_engine_test_cache"),
  topology_path: Path.join(test_root, ".optimal/config.yaml"),
  topology_full_path: Path.join(test_root, "topology.yaml")

config :optimal_engine, :api_rate_limit,
  default_capacity: 10_000,
  default_per_minute: 10_000

# Viability passes and analyses run on demand in tests.
config :optimal_engine, :viability_interval_ms, 0

# Bundle jobs are run by the tests themselves (BundleJobs.drain/1), at once.
config :optimal_engine, bundle_jobs_interval_ms: 0, bundle_job_start_delay_s: 0
config :optimal_engine, :analyses_interval_ms, 0
config :optimal_engine, :reindex_interval_ms, 0
config :optimal_engine, :imports_interval_ms, 0
config :optimal_engine, :maintenance_interval_ms, 0
config :optimal_engine, :embedding_sweep_interval_ms, 0

config :optimal_engine, :metric_history, enabled: false
config :optimal_engine, :session, llm_summary: false, llm_extraction: false

# The connector pull loop runs on demand in tests: a live loop would pull
# every test's connector rows in the background.
config :optimal_engine, :pull_scheduler, enabled: false

# The credential broker the connector tests stand up behind the HTTP mock.
config :optimal_engine, :credential_broker_hosts, ["connect.example.com", "api.miosa.ai"]

config :optimal_engine,
       :credential_broker_paths,
       ["/api/credentials", "/api/v1/connect/broker/"]

config :optimal_engine, :context_refresh_scheduler,
  enabled: false,
  boot_delay_ms: 1_000,
  interval_ms: 60_000,
  batch_limit: 50,
  workspace_limit: 100

# Unit and integration tests must not depend on a developer's local Ollama.
# Dedicated model integration tests call the adapters explicitly.
# Ollama points at a closed port, so no test can load a model on the host
# (a developer machine behaves like CI, which has no Ollama); tests that need
# a model server start a stub and set the host themselves.
config :optimal_engine, :ollama, host: "http://127.0.0.1:9"
config :optimal_engine, :hybrid_search, vector_enabled: false
config :optimal_engine, :memory_embeddings, auto_index: false
config :optimal_engine, :embed, on_ingest: false
config :optimal_engine, :semantic_processing, enabled: false
config :optimal_engine, :app_data, semantic_indexing: :off
