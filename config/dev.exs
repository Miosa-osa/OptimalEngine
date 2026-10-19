import Config

# The HTTP API is off unless asked for (OPTIMAL_API_ENABLED=true, see
# config/runtime.exs). Every launcher sets it (scripts/run-engine.sh, the
# release image, docker-compose), so a bare `mix run` in a checkout never
# binds a port another Engine on this machine may be serving.
