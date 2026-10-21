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

# The PostgreSQL store of an OPTIMAL_STORE=postgres build keeps its tables in
# the schema OPTIMAL_POSTGRES_SCHEMA names (default public); the connection is
# OPTIMAL_POSTGRES_URL, read when the store starts.
postgres_store_config = Application.get_env(:optimal_engine, :postgres_store, [])

config :optimal_engine,
       :postgres_store,
       Keyword.put(
         postgres_store_config,
         :schema,
         System.get_env(
           "OPTIMAL_POSTGRES_SCHEMA",
           Keyword.get(postgres_store_config, :schema, "public")
         )
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

# Text embeddings come from Ollama at OLLAMA_HOST unless OPTIMAL_EMBED_URL names
# another endpoint, such as a shared, metered gateway (OptimalEngine.Embed.Text).
# An empty value counts as unset. The key is read from OPTIMAL_EMBED_API_KEY or
# the file in OPTIMAL_EMBED_API_KEY_FILE when a request is made, so it never
# enters the application environment.
text_embedding_config = Application.get_env(:optimal_engine, :text_embedding, [])

embed_url =
  case System.get_env("OPTIMAL_EMBED_URL") do
    blank when blank in [nil, ""] ->
      Keyword.get(text_embedding_config, :url)

    url ->
      url = String.trim(url)
      uri = URI.parse(url)

      if uri.scheme in ["http", "https"] and uri.host not in [nil, ""] do
        url
      else
        raise ArgumentError, "OPTIMAL_EMBED_URL must be an http or https URL"
      end
  end

embed_dialect =
  case System.get_env("OPTIMAL_EMBED_DIALECT") do
    blank when blank in [nil, ""] -> Keyword.get(text_embedding_config, :dialect)
    "openai" -> :openai
    "ollama" -> :ollama
    _ -> raise ArgumentError, "OPTIMAL_EMBED_DIALECT must be openai or ollama"
  end

embed_dimensions =
  case System.get_env("OPTIMAL_EMBED_DIMENSIONS") do
    blank when blank in [nil, ""] ->
      Keyword.get(text_embedding_config, :dimensions)

    value ->
      case Integer.parse(String.trim(value)) do
        {dimensions, ""} when dimensions > 0 -> dimensions
        _ -> raise ArgumentError, "OPTIMAL_EMBED_DIMENSIONS must be a positive whole number"
      end
  end

# How long a cached embedding is kept, in days; 0 keeps it until its workspace is
# purged. Unset keeps the configured value, or the default of 30.
embed_cache_max_age_days =
  case System.get_env("OPTIMAL_EMBED_CACHE_MAX_AGE_DAYS") do
    blank when blank in [nil, ""] ->
      Keyword.get(text_embedding_config, :cache_max_age_days, 30)

    value ->
      case Integer.parse(String.trim(value)) do
        {days, ""} when days >= 0 ->
          days

        _ ->
          raise ArgumentError, "OPTIMAL_EMBED_CACHE_MAX_AGE_DAYS must be a whole number of days"
      end
  end

config :optimal_engine,
       :text_embedding,
       Keyword.merge(text_embedding_config,
         url: embed_url,
         dialect: embed_dialect,
         dimensions: embed_dimensions,
         cache_max_age_days: embed_cache_max_age_days,
         api_key_file:
           System.get_env(
             "OPTIMAL_EMBED_API_KEY_FILE",
             Keyword.get(text_embedding_config, :api_key_file)
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

# Workspace bundles: the largest raw upload POST /api/bundles/import accepts,
# in bytes (default 5 GiB); a larger one is refused with 413.
if max_bytes = System.get_env("OPTIMAL_BUNDLE_MAX_BYTES") do
  case Integer.parse(String.trim(max_bytes)) do
    {bytes, ""} when bytes > 0 -> config :optimal_engine, :bundle_max_bytes, bytes
    _ -> raise ArgumentError, "OPTIMAL_BUNDLE_MAX_BYTES must be a positive number of bytes"
  end
end

# Replication: how long one peer's cycle keeps paging before it stops and
# resumes on the next cycle.
if budget = System.get_env("OPTIMAL_SYNC_CYCLE_BUDGET_MS") do
  config :optimal_engine, :sync_cycle_budget_ms, String.to_integer(budget)
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

# The credential brokers connectors may ask for short-lived credentials
# (`credential_source: "broker"`): https hosts, separated by ','. With none
# named, no broker is called.
if hosts = System.get_env("OPTIMAL_CREDENTIAL_BROKER_HOSTS") do
  hosts = hosts |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  config :optimal_engine, :credential_broker_hosts, hosts
end

# The paths a broker URL may sit under, separated by ','. The default is
# /api/v1/connect/broker/.
if paths = System.get_env("OPTIMAL_CREDENTIAL_BROKER_PATHS") do
  paths = paths |> String.split(",") |> Enum.map(&String.trim/1)

  # An empty entry, `/` (everything), a `;` or a `..` would widen the allowlist
  # past what was meant, so a bad list stops the Engine instead.
  Enum.each(paths, fn path ->
    unless Regex.match?(~r|\A/[A-Za-z0-9._~!$&'()*+,=:@/-]+\z|, path) and
             not String.contains?(path, ["..", "//"]) do
      raise ArgumentError,
            "OPTIMAL_CREDENTIAL_BROKER_PATHS must list path prefixes like /api/v1/connect/broker/, got: #{inspect(path)}"
    end
  end)

  config :optimal_engine, :credential_broker_paths, paths
end

# Imports: how often queued import jobs are drained (0 disables), the largest
# upload or download an import accepts, and where imports are staged
# (default: an imports folder next to the database). OPTIMAL_IMPORT_URL_HOSTS
# (comma-separated) is the list of hosts a source URL may name, internal ones
# included, and OPTIMAL_IMPORT_CA_FILE a PEM file of extra CAs to trust; both
# are read when a URL is checked.
if interval = System.get_env("OPTIMAL_IMPORTS_INTERVAL_MS") do
  config :optimal_engine, :imports_interval_ms, String.to_integer(interval)
end

if max_bytes = System.get_env("OPTIMAL_IMPORT_MAX_BYTES") do
  config :optimal_engine, :import_max_bytes, String.to_integer(max_bytes)
end

if imports_dir = System.get_env("OPTIMAL_IMPORTS_DIR") do
  config :optimal_engine, :imports_dir, imports_dir
end

# Analyses: how often the day's analysis jobs are scheduled and drained.
if interval = System.get_env("OPTIMAL_ANALYSES_INTERVAL_MS") do
  config :optimal_engine, :analyses_interval_ms, String.to_integer(interval)
end

# Offsite backups: how often a verified backup is taken, encrypted with
# OPTIMAL_BACKUP_KEY, and shipped to the object store (0 or unset disables),
# and how many scheduled copies are kept offsite and locally.
offsite_interval = String.trim(System.get_env("OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS", ""))

if offsite_interval != "" do
  interval = String.to_integer(offsite_interval)

  unless interval == 0 or interval >= 60_000,
    do:
      raise(
        ArgumentError,
        "OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS must be 0 (off) or at least 60000"
      )

  config :optimal_engine, :offsite_backup_interval_ms, interval
end

offsite_keep = String.trim(System.get_env("OPTIMAL_OFFSITE_BACKUP_KEEP", ""))

if offsite_keep != "" do
  keep = String.to_integer(offsite_keep)

  unless keep >= 1,
    do: raise(ArgumentError, "OPTIMAL_OFFSITE_BACKUP_KEEP must be at least 1")

  config :optimal_engine, :offsite_backup_keep, keep
end

offsite_keep_local = String.trim(System.get_env("OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL", ""))

if offsite_keep_local != "" do
  keep_local = String.to_integer(offsite_keep_local)

  unless keep_local >= 0,
    do: raise(ArgumentError, "OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL must be 0 or more")

  config :optimal_engine, :offsite_backup_keep_local, keep_local
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

# Claim promotion. By default (auto_threshold) the Engine promotes Claims
# whose confidence meets the workspace threshold on its own; manual and
# agent_review leave every Claim to a reviewer holding claims:review.
claim_promotion_mode = System.get_env("OPTIMAL_CLAIM_PROMOTION_MODE")

if claim_promotion_mode do
  unless claim_promotion_mode in ~w(auto_threshold manual agent_review),
    do:
      raise(
        ArgumentError,
        "OPTIMAL_CLAIM_PROMOTION_MODE must be auto_threshold, manual, or agent_review"
      )

  config :optimal_engine,
         :memory,
         Keyword.put(
           Application.get_env(:optimal_engine, :memory, []),
           :claim_promotion_mode,
           String.to_atom(claim_promotion_mode)
         )
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

# An API listening beyond loopback with authentication off is logged as an
# error at boot and every 10 minutes, and warned in /api/health
# (OptimalEngine.API.Exposure). OPTIMAL_REFUSE_OPEN_NETWORK=1 refuses to start
# instead; it is off by default in this release and the default in the next.
case System.get_env("OPTIMAL_REFUSE_OPEN_NETWORK") do
  nil -> :ok
  value when value in ["1", "true"] -> config :optimal_engine, :refuse_open_network, true
  value when value in ["0", "false", ""] -> config :optimal_engine, :refuse_open_network, false
  _ -> raise ArgumentError, "OPTIMAL_REFUSE_OPEN_NETWORK must be 1 or 0"
end

# Local HTTP API - enabled on demand (the bundled engine turns it on; other
# contexts leave it off). Port is env-driven so it can dodge a busy :4200.
if System.get_env("OPTIMAL_API_ENABLED") == "true" do
  config :optimal_engine, :api,
    enabled: true,
    port: String.to_integer(System.get_env("OPTIMAL_API_PORT", "4200")),
    interface: System.get_env("OPTIMAL_API_INTERFACE", "127.0.0.1")
end
