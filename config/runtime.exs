import Config

if config_env() == :prod do
  config :optimal_engine,
    root_path: System.get_env("OPTIMAL_ENGINE_ROOT", "/data"),
    db_path: System.get_env("OPTIMAL_ENGINE_DB", "/data/.optimal/index.db"),
    cache_path: System.get_env("OPTIMAL_ENGINE_CACHE", "/data/.optimal/cache"),
    topology_path: System.get_env("OPTIMAL_ENGINE_TOPOLOGY", "/data/.optimal/config.yaml"),
    topology_full_path: System.get_env("OPTIMAL_ENGINE_TOPOLOGY_FULL", "/data/topology.yaml")

  config :optimal_engine, :api,
    enabled: System.get_env("OPTIMAL_API_ENABLED", "true") == "true",
    port:
      System.get_env("OPTIMAL_API_PORT", "4200")
      |> String.to_integer(),
    interface: System.get_env("OPTIMAL_API_INTERFACE", "0.0.0.0")

  config :optimal_engine, :auth,
    auth_required: System.get_env("OPTIMAL_AUTH_REQUIRED", "false") == "true",
    bcrypt_cost:
      System.get_env("OPTIMAL_BCRYPT_COST", "12")
      |> String.to_integer()

  config :optimal_engine, :ollama,
    host: System.get_env("OLLAMA_HOST", "http://host.docker.internal:11434"),
    embed_model: System.get_env("OPTIMAL_EMBED_MODEL", "nomic-embed-text"),
    embed_vision_model: System.get_env("OPTIMAL_EMBED_VISION_MODEL", "nomic-embed-vision"),
    generate_model: System.get_env("OPTIMAL_GENERATE_MODEL", "qwen3:8b"),
    vlm_model: System.get_env("OPTIMAL_VLM_MODEL", "qwen2.5-vl")
end
