import Config

# BusinessOS runtime config for the BUNDLED OptimalEngine.
#
# This replaces the OptimalOS-private overlay (which hardcoded Roberto's personal
# workspace path). Everything here is env-driven so the desktop EngineManager can
# point the bundled engine at a per-user data directory and a free port, and so a
# downloaded user gets their OWN fresh config from these templated defaults -
# never a developer-machine path.
#
# The EngineManager sets:
#   OPTIMAL_API_ENABLED=true         - turn on the local HTTP API
#   OPTIMAL_API_PORT=<free port>     - avoid colliding with any other engine
#   OPTIMAL_ENGINE_ROOT=<user data>  - where governed workspaces live
#   OPTIMAL_ENGINE_DB / _CACHE       - per-user SQLite + cache (see config.exs)

# Runtime paths must be read here, not only in config.exs. Release builds evaluate
# config.exs at compile time, while downloaded apps supply per-user paths when the
# packaged engine starts.
config :optimal_engine,
  root_path: System.get_env("OPTIMAL_ENGINE_ROOT", Path.join(File.cwd!(), ".optimal/workspaces")),
  db_path: System.get_env("OPTIMAL_ENGINE_DB", Path.join(File.cwd!(), ".optimal/index.db")),
  cache_path: System.get_env("OPTIMAL_ENGINE_CACHE", Path.join(File.cwd!(), ".optimal/cache")),
  topology_path:
    System.get_env(
      "OPTIMAL_ENGINE_TOPOLOGY",
      Path.join(File.cwd!(), ".optimal/config.yaml")
    ),
  topology_full_path:
    System.get_env(
      "OPTIMAL_ENGINE_TOPOLOGY_FULL",
      Path.join(File.cwd!(), ".optimal/topology.yaml")
    )

knowledge_config = Application.get_env(:optimal_engine, :knowledge, [])
knowledge_backend = Keyword.get(knowledge_config, :backend, "ets") |> to_string()

config :optimal_engine,
       :knowledge,
       Keyword.merge(knowledge_config,
         backend: System.get_env("OPTIMAL_KNOWLEDGE_BACKEND", knowledge_backend),
         rocksdb_path:
           System.get_env(
             "OPTIMAL_KNOWLEDGE_ROCKSDB_PATH",
             Keyword.get(
               knowledge_config,
               :rocksdb_path,
               Path.join(File.cwd!(), ".optimal/knowledge-rocksdb")
             )
           )
       )

ollama_config = Application.get_env(:optimal_engine, :ollama, [])

config :optimal_engine,
       :ollama,
       Keyword.merge(ollama_config,
         host: System.get_env("OLLAMA_HOST", "http://localhost:11434"),
         embed_model: System.get_env("OPTIMAL_EMBED_MODEL", "nomic-embed-text"),
         generate_model: System.get_env("OPTIMAL_GENERATE_MODEL", "qwen3:8b"),
         vlm_model: System.get_env("OPTIMAL_VLM_MODEL", "qwen2.5-vl")
       )

# Local HTTP API - enabled on demand (the bundled engine turns it on; other
# contexts leave it off). Port is env-driven so it can dodge a busy :4200.
if System.get_env("OPTIMAL_API_ENABLED") == "true" do
  config :optimal_engine, :api,
    enabled: true,
    port: String.to_integer(System.get_env("OPTIMAL_API_PORT", "4200")),
    interface: System.get_env("OPTIMAL_API_INTERFACE", "127.0.0.1")
end
