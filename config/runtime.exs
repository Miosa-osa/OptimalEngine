import Config

# BusinessOS runtime config for the BUNDLED OptimalEngine.
#
# This replaces the OptimalOS-private overlay (which hardcoded one operator's personal
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
root_path =
  Application.get_env(
    :optimal_engine,
    :root_path,
    Path.join(File.cwd!(), ".optimal/workspaces")
  )

db_path =
  Application.get_env(:optimal_engine, :db_path, Path.join(File.cwd!(), ".optimal/index.db"))

cache_path =
  Application.get_env(:optimal_engine, :cache_path, Path.join(File.cwd!(), ".optimal/cache"))

topology_path =
  Application.get_env(
    :optimal_engine,
    :topology_path,
    Path.join(File.cwd!(), ".optimal/config.yaml")
  )

topology_full_path =
  Application.get_env(
    :optimal_engine,
    :topology_full_path,
    Path.join(File.cwd!(), ".optimal/topology.yaml")
  )

resolved_db_path = System.get_env("OPTIMAL_ENGINE_DB", db_path)

backup_dir =
  Application.get_env(
    :optimal_engine,
    :backup_dir,
    Path.join(Path.dirname(resolved_db_path), "backups")
  )

config :optimal_engine,
  root_path: System.get_env("OPTIMAL_ENGINE_ROOT", root_path),
  db_path: resolved_db_path,
  backup_dir: System.get_env("OPTIMAL_BACKUP_DIR", backup_dir),
  cache_path: System.get_env("OPTIMAL_ENGINE_CACHE", cache_path),
  topology_path: System.get_env("OPTIMAL_ENGINE_TOPOLOGY", topology_path),
  topology_full_path: System.get_env("OPTIMAL_ENGINE_TOPOLOGY_FULL", topology_full_path)

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
         host:
           System.get_env(
             "OLLAMA_HOST",
             Keyword.get(ollama_config, :host, "http://localhost:11434")
           ),
         embed_model:
           System.get_env(
             "OPTIMAL_EMBED_MODEL",
             Keyword.get(ollama_config, :embed_model, "nomic-embed-text")
           ),
         generate_model:
           System.get_env(
             "OPTIMAL_GENERATE_MODEL",
             Keyword.get(ollama_config, :generate_model, "qwen3:1.7b")
           ),
         vlm_model:
           System.get_env(
             "OPTIMAL_VLM_MODEL",
             Keyword.get(ollama_config, :vlm_model, "qwen2.5-vl")
           )
       )

# Authentication is an explicit deployment choice. Preserve configured defaults
# when absent; reject typos instead of silently exposing an anonymous service.
auth_config = Application.get_env(:optimal_engine, :auth, [])

auth_required =
  case System.get_env("OPTIMAL_AUTH_REQUIRED") do
    nil -> Keyword.get(auth_config, :auth_required, false)
    "true" -> true
    "false" -> false
    _ -> raise ArgumentError, "OPTIMAL_AUTH_REQUIRED must be true or false"
  end

config :optimal_engine, :auth, Keyword.put(auth_config, :auth_required, auth_required)

# Who an anonymous local request acts as (auth not required, no key). Keyed
# requests always act as their key's principal (OptimalEngine.API.Actor).
if operator = System.get_env("OPTIMAL_LOCAL_OPERATOR") do
  config :optimal_engine, :local_operator_id, operator
end

# Access lists: what ACL.can?/4 answers for a resource with no ACL rows.
# Defaults to deny whenever authentication is required; set
# OPTIMAL_ACL_ABSENT=allow|deny to choose explicitly.
acl_absent =
  case System.get_env("OPTIMAL_ACL_ABSENT") do
    nil -> if auth_required, do: :deny, else: :allow
    "allow" -> :allow
    "deny" -> :deny
    _ -> raise ArgumentError, "OPTIMAL_ACL_ABSENT must be allow or deny"
  end

config :optimal_engine, :acl_absent, acl_absent

# Release channel: which release stream this Engine serves. Reported by
# /api/version so an operator or update controller can compare the running
# build with the channel it intended. Absent means an unversioned local build.
case System.get_env("OPTIMAL_RELEASE_CHANNEL") do
  nil ->
    :ok

  channel when channel in ~w(dev stable beta pinned) ->
    config :optimal_engine, :release_channel, channel

  _ ->
    raise ArgumentError, "OPTIMAL_RELEASE_CHANNEL must be dev, stable, beta, or pinned"
end

# Corpus routing rules (CorpusOrganizer) are deployment data: a YAML or JSON
# file mapping target workspaces to weighted markers.
if corpus_rules = System.get_env("OPTIMAL_CORPUS_RULES") do
  config :optimal_engine, :corpus_routing_rules_path, corpus_rules
end

# Engine scope: "org" (default, every workspace a walled section) or
# "workspace" (serves only OPTIMAL_ENGINE_WORKSPACE).
case System.get_env("OPTIMAL_ENGINE_SCOPE") do
  nil ->
    :ok

  "org" ->
    config :optimal_engine, :engine_scope, %{mode: "org"}

  "workspace" ->
    workspace =
      System.get_env("OPTIMAL_ENGINE_WORKSPACE") ||
        raise ArgumentError, "OPTIMAL_ENGINE_SCOPE=workspace needs OPTIMAL_ENGINE_WORKSPACE"

    config :optimal_engine, :engine_scope, %{mode: "workspace", workspace_id: workspace}

  _ ->
    raise ArgumentError, "OPTIMAL_ENGINE_SCOPE must be org or workspace"
end

# Replication: how often the sync scheduler seals changes and runs peers.
if interval = System.get_env("OPTIMAL_SYNC_INTERVAL_MS") do
  config :optimal_engine, :sync_interval_ms, String.to_integer(interval)
end

# Size profile: agent, workspace, business, platform, or scale (OptimalEngine.Sizing).
if profile = System.get_env("OPTIMAL_SIZE_PROFILE") do
  unless profile in ~w(agent workspace business platform scale) do
    raise "OPTIMAL_SIZE_PROFILE must be agent, workspace, business, platform, or scale"
  end

  config :optimal_engine, :size_profile, profile
end

# Extra directories POST /api/assets may import server files from (an admin
# key is required; the Engine root is always allowed), separated by ':'.
if roots = System.get_env("OPTIMAL_ASSET_IMPORT_ROOTS") do
  config :optimal_engine, :asset_import_roots, String.split(roots, ":", trim: true)
end

# Analyses: how often the day's analysis jobs are scheduled and drained.
if interval = System.get_env("OPTIMAL_ANALYSES_INTERVAL_MS") do
  config :optimal_engine, :analyses_interval_ms, String.to_integer(interval)
end

# Viability: how often snapshots and the weekly audit are brought up to date.
if interval = System.get_env("OPTIMAL_VIABILITY_INTERVAL_MS") do
  config :optimal_engine, :viability_interval_ms, String.to_integer(interval)
end

# Optimal Authority. OPTIMAL_AUTHORITY_KEY (64 hex characters) wraps the
# signing keys and is read directly by OptimalEngine.Authority.Keys.
authority_mode = System.get_env("OPTIMAL_AUTHORITY_MODE")

if authority_mode do
  unless authority_mode in ~w(off observe enforce),
    do: raise(ArgumentError, "OPTIMAL_AUTHORITY_MODE must be off, observe, or enforce")

  config :optimal_engine, :authority_mode, authority_mode
end

if issuer = System.get_env("OPTIMAL_AUTHORITY_ISSUER") do
  config :optimal_engine, :authority_issuer, issuer
end

if audience = System.get_env("OPTIMAL_AUTHORITY_AUDIENCE") do
  config :optimal_engine, :authority_audience, audience
end

if max_ttl = System.get_env("OPTIMAL_AUTHORITY_MAX_TTL_SECONDS") do
  config :optimal_engine, :authority_max_ttl_seconds, String.to_integer(max_ttl)
end

# Local HTTP API - enabled on demand (the bundled engine turns it on; other
# contexts leave it off). Port is env-driven so it can dodge a busy :4200.
if System.get_env("OPTIMAL_API_ENABLED") == "true" do
  config :optimal_engine, :api,
    enabled: true,
    port: String.to_integer(System.get_env("OPTIMAL_API_PORT", "4200")),
    interface: System.get_env("OPTIMAL_API_INTERFACE", "127.0.0.1")
end
