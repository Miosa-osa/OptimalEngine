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

# Workspaces root + topology - default under the engine's own working dir so a
# fresh install is self-contained, never a developer path.
config :optimal_engine,
  root_path:
    System.get_env("OPTIMAL_ENGINE_ROOT", Path.join(File.cwd!(), ".optimal/workspaces")),
  topology_full_path:
    System.get_env(
      "OPTIMAL_ENGINE_TOPOLOGY_FULL",
      Path.join(File.cwd!(), ".optimal/topology.yaml")
    )

# Local HTTP API - enabled on demand (the bundled engine turns it on; other
# contexts leave it off). Port is env-driven so it can dodge a busy :4200.
if System.get_env("OPTIMAL_API_ENABLED") == "true" do
  config :optimal_engine, :api,
    enabled: true,
    port: String.to_integer(System.get_env("OPTIMAL_API_PORT", "4200")),
    interface: System.get_env("OPTIMAL_API_INTERFACE", "127.0.0.1")
end
