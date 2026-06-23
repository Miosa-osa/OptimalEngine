import Config

# Default paths point at the current directory; override in dev.exs / prod.exs
# or via OPTIMAL_ENGINE_ROOT env var at runtime.
config :optimal_engine,
  root_path: System.get_env("OPTIMAL_ENGINE_ROOT", File.cwd!()),
  db_path: System.get_env("OPTIMAL_ENGINE_DB", Path.join(File.cwd!(), ".optimal/index.db")),
  cache_path: System.get_env("OPTIMAL_ENGINE_CACHE", Path.join(File.cwd!(), ".optimal/cache")),
  topology_path:
    System.get_env("OPTIMAL_ENGINE_TOPOLOGY", Path.join(File.cwd!(), ".optimal/config.yaml")),
  topology_full_path:
    System.get_env("OPTIMAL_ENGINE_TOPOLOGY_FULL", Path.join(File.cwd!(), "topology.yaml"))

# API key authentication.
# Set auth_required: true in production (or via OPTIMAL_AUTH_REQUIRED env var in runtime.exs).
# In dev and test, auth_required defaults to false so the API is open without a key.
config :optimal_engine, :auth,
  auth_required: false,
  bcrypt_cost: 12

config :optimal_engine, :ollama,
  host: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
  embed_model: "nomic-embed-text",
  embed_vision_model: "nomic-embed-vision",
  generate_model: "qwen3:8b",
  vlm_model: System.get_env("OPTIMAL_VLM_MODEL", "qwen2.5-vl"),
  vlm_timeout_ms: 60_000,
  timeout_ms: 30_000

# Memory Core: when true, CLI/API intake extracts a pending Claim from each
# accepted Signal (closing the Source -> Signal -> Claim break). Default ON.
config :optimal_engine, :memory, auto_extract_claims: true

config :optimal_engine, :video,
  max_keyframes: 10,
  scene_threshold: 0.3

config :optimal_engine, :hybrid_search,
  alpha: 0.6,
  vector_enabled: true

config :optimal_engine, :context_refresh_scheduler,
  enabled: true,
  boot_delay_ms: 5 * 60 * 1_000,
  interval_ms: 60 * 60 * 1_000,
  batch_limit: 50,
  workspace_limit: 100

config :logger, :console,
  format: "[$level] $message\n",
  metadata: [:module, :request_id]

import_config "#{config_env()}.exs"
