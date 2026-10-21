#!/usr/bin/env bash
# WO-43 and WO-46: proves the Engine's relay client, a laptop Engine that syncs
# with a managed Engine through the MIOSA control-plane relay.
#
# It starts a laptop Engine on temporary data, registers the relay as its peer
# (`relay+<RELAY_BASE>`, the laptop is the only initiator), and checks:
#   1. a laptop capture reaches the cloud and a cloud capture reaches the
#      laptop, each within 60 s;
#   2. 100 writes made while the relay is unreachable arrive exactly once after
#      it returns, and pushing the same changes again applies nothing;
#   3. a note the cloud wrote and the laptop then edited is no conflict on
#      either side (with CLOUD_ENGINE_URL), a note passed back and forth three
#      times each way ends the same on both sides with no conflict, while a
#      note edited on both sides while apart is one conflict, on the laptop,
#      and nothing else is;
#   4. a workspace with sync policy none never leaves the laptop;
#   5. the relay refuses a push on another migration, and the laptop pauses
#      while the relay reports another migration and resumes when it matches.
# The laptop reaches the relay through a local gate (scripts/relay_proof.py)
# that forwards every request unchanged: stopping it makes the relay
# unreachable, and its request log is the evidence of what left the laptop.
#
# Usage:
#   RELAY_BASE=https://api.miosa.ai/api/v1/engines/<engine id>/sync \
#   MIOSA_API_KEY_FILE=<file with a key that has engine:sync> \
#   WORKSPACE=default scripts/proof-relay-client.sh
#
#   scripts/proof-relay-client.sh --stand-in
#     also starts a second Engine as the cloud, behind a local relay stand-in
#     that implements the relay contract, so it runs with no MIOSA account.
#
# Optional: CLOUD_ENGINE_URL with CLOUD_ENGINE_KEY or CLOUD_ENGINE_KEY_FILE, the
# managed Engine's own API (reachable from a sandbox attached to its
# workspace). With them the cloud side writes on the managed Engine itself and
# checks with its search; without them a second device writes through the
# relay and the checks read the cloud's ledger through the relay.
# SYNC_INTERVAL_MS (default 20000) is the laptop's sync interval, and
# ANALYSES_INTERVAL_MS (default 5000) when the Engines schedule their analyses.
#
# Run it on a disposable machine, never on a machine with a live user store.
# The managed Engine keeps the proof's writes (marked with the run id).
# Keys come from the environment or files and are never printed. The temporary
# data (the Engines' stores, their keys, the relay key sealed in the laptop's
# store) is removed on exit; KEEP_DATA=1 keeps it for debugging. DATA, when
# set, must name an empty or missing directory.
# Exit: 0 only when every check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mode=relay
case "${1:-}" in
  "") ;;
  --stand-in) mode=stand-in ;;
  -h | --help)
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "usage: $0 [--stand-in]   (see --help)" >&2
    exit 2
    ;;
esac

umask 077
if [ -n "${DATA:-}" ]; then
  if [ -e "$DATA" ] && [ -n "$(ls -A "$DATA")" ]; then
    echo "DATA must be an empty or missing directory: $DATA" >&2
    exit 2
  fi
  mkdir -p "$DATA"
else
  DATA="$(mktemp -d)"
fi

# The temporary data holds every key the run uses. main runs in a pipeline
# subshell that stops its Engines when it exits; this shell then removes it.
remove_data() {
  if [ "${KEEP_DATA:-}" = 1 ]; then
    echo "== temporary data kept at $DATA (KEEP_DATA=1); it holds keys, remove it when done" >&2
  else
    rm -rf "$DATA"
  fi
}
trap remove_data EXIT

SECRETS="$DATA/secrets"
: >"$SECRETS"
export DATA WORKSPACE="${WORKSPACE:-default}" SYNC_INTERVAL_MS="${SYNC_INTERVAL_MS:-20000}"
export LAPTOP_PORT="${LAPTOP_PORT:-4321}" CLOUD_PORT="${CLOUD_PORT:-4322}"
export RELAY_PORT="${RELAY_PORT:-4323}" GATE_PORT="${GATE_PORT:-4324}"
export MIX_ENV=dev

key_from() { # a value, or a file holding it
  if [ -n "${1:-}" ]; then printf '%s' "$1"; elif [ -n "${2:-}" ]; then tr -d '[:space:]' <"$2"; fi
}

if [ "$mode" = stand-in ]; then
  MIOSA_API_KEY="$(openssl rand -hex 24)"
  unset RELAY_BASE CLOUD_ENGINE_URL CLOUD_ENGINE_KEY
else
  MIOSA_API_KEY="$(key_from "${MIOSA_API_KEY:-}" "${MIOSA_API_KEY_FILE:-}")"
  CLOUD_ENGINE_KEY="$(key_from "${CLOUD_ENGINE_KEY:-}" "${CLOUD_ENGINE_KEY_FILE:-}")"
  [ -n "${RELAY_BASE:-}" ] || { echo "RELAY_BASE is required (or use --stand-in)" >&2; exit 2; }
  [ -n "$MIOSA_API_KEY" ] || { echo "MIOSA_API_KEY or MIOSA_API_KEY_FILE is required" >&2; exit 2; }
  export RELAY_BASE CLOUD_ENGINE_KEY
fi
export MIOSA_API_KEY

engine_env() { # name port; only ever called in the subshell that runs the Engine
  local dir="$DATA/$1"
  # The relay key reaches the laptop only through its peer registration.
  unset MIOSA_API_KEY MIOSA_API_KEY_FILE CLOUD_ENGINE_KEY CLOUD_ENGINE_KEY_FILE
  export OPTIMAL_API_ENABLED=true OPTIMAL_AUTH_REQUIRED=true OPTIMAL_API_PORT="$2"
  export OPTIMAL_API_INTERFACE=127.0.0.1
  export OPTIMAL_ENGINE_ROOT="$dir/root" OPTIMAL_ENGINE_DB="$dir/root/index.db"
  export OPTIMAL_ENGINE_CACHE="$dir/cache" OPTIMAL_BACKUP_DIR="$dir/backups"
  export OPTIMAL_KNOWLEDGE_ROCKSDB_PATH="$dir/rocksdb"
  export OPTIMAL_ENGINE_TOPOLOGY="$dir/topology.yaml" OPTIMAL_ENGINE_TOPOLOGY_FULL="$dir/topology-full.yaml"
  export OPTIMAL_SYNC_INTERVAL_MS="$SYNC_INTERVAL_MS"
  # Each Engine enqueues its daily analysis jobs 5 s after boot, as a managed
  # Engine does each day, so every run shows that the job queue stays home.
  export OPTIMAL_ANALYSES_INTERVAL_MS="${ANALYSES_INTERVAL_MS:-5000}"
  CONNECTOR_KEY="$(cat "$dir/connector_key")"
  OPTIMAL_AUTHORITY_KEY="$(cat "$dir/authority_key")"
  export CONNECTOR_KEY OPTIMAL_AUTHORITY_KEY
}

# Engines this run started; global so the EXIT trap still sees them after main returns.
pids=()
stop_engines() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
}

names=(laptop)
[ "$mode" = stand-in ] && names+=(cloud)

main() {

  fail() {
    echo "FAIL $1"
    for name in "${names[@]}"; do
      [ -f "$DATA/$name/server.log" ] && { echo "--- $name log"; tail -15 "$DATA/$name/server.log"; }
    done
    exit 1
  }

  echo "== relay client proof ($mode), workspace $WORKSPACE, temporary data $DATA"
  for tool in python3 curl openssl mix; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
  done

  echo "== compile"
  if ! { mix deps.get && mix compile; } >"$DATA/compile.log" 2>&1; then
    tail -20 "$DATA/compile.log"
    fail "mix compile"
  fi

  port_of() { if [ "$1" = laptop ]; then echo "$LAPTOP_PORT"; else echo "$CLOUD_PORT"; fi; }

  for name in "${names[@]}"; do
    mkdir -p "$DATA/$name/root" "$DATA/$name/cache"
    openssl rand -hex 32 >"$DATA/$name/connector_key"
    openssl rand -hex 32 >"$DATA/$name/authority_key"
    cat "$DATA/$name/connector_key" "$DATA/$name/authority_key" >>"$SECRETS"
    key=$( (engine_env "$name" "$(port_of "$name")" && mix optimal.auth mint --name "relay-proof-$name" --scope '*' --workspace '*' --json 2>/dev/null) |
      python3 scripts/relay_proof.py mint-key) || fail "minting the $name Engine's key"
    printf '%s\n' "$key" >>"$SECRETS"
    printf '%s' "$key" >"$DATA/$name/key"
    printf 'Authorization: Bearer %s\n' "$key" >"$DATA/$name/auth-header"
  done

  trap stop_engines EXIT
  for name in "${names[@]}"; do
    (engine_env "$name" "$(port_of "$name")" && exec mix run --no-halt --no-compile >"$DATA/$name/server.log" 2>&1) &
    pids+=($!)
  done

  for name in "${names[@]}"; do
    local url healthy=0
    url="http://127.0.0.1:$(port_of "$name")"
    for _ in $(seq 1 120); do
      if curl -sf -H @"$DATA/$name/auth-header" "$url/api/health" >/dev/null 2>&1; then
        healthy=1
        break
      fi
      sleep 1
    done
    [ "$healthy" = 1 ] || fail "the $name Engine did not answer /api/health on $url"
    echo "== $name Engine up at $url"
  done

  export LAPTOP_URL="http://127.0.0.1:$LAPTOP_PORT" LAPTOP_KEY
  LAPTOP_KEY="$(cat "$DATA/laptop/key")"
  local args=()
  if [ "$mode" = stand-in ]; then
    export CLOUD_ENGINE_URL="http://127.0.0.1:$CLOUD_PORT" CLOUD_ENGINE_KEY
    CLOUD_ENGINE_KEY="$(cat "$DATA/cloud/key")"
    args+=(--stand-in)
  fi

  echo "== checks (sync interval ${SYNC_INTERVAL_MS} ms)"
  python3 -u scripts/relay_proof.py run ${args[@]+"${args[@]}"}
}

# Every line goes through the redactor, which also knows the keys minted above.
set +e
main 2>&1 | python3 -u scripts/relay_proof.py redact "$SECRETS"
statuses=("${PIPESTATUS[@]}")
set -e
[ "${statuses[0]}" = 0 ] && [ "${statuses[1]}" = 0 ]
