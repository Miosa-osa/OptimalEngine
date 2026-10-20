#!/usr/bin/env bash
# Proves the operating layer (WO-41), the Engine side of the Engine without
# BusinessOS (WO-44), and Signal Theory and viability (WO-45) against a live
# Engine, one CHECK line per acceptance criterion. The checks themselves are
# in scripts/proof_operating_layer.py.
#
# Usage:
#   scripts/proof-operating-layer.sh
#       Starts its own Engine on temporary data with auth required, mints a
#       root key, and runs every check (full mode on a fresh store).
#   ENGINE_URL=https://... ENGINE_KEY_FILE=/path/admin.key scripts/proof-operating-layer.sh
#       Full mode against an existing Engine with an admin key (a managed QA
#       Engine). It creates uniquely named workspaces, principals and keys,
#       then revokes the keys and archives the workspaces (KEEP=1 keeps them).
#   ENGINE_URL=http://127.0.0.1:4200 [ENGINE_KEY_FILE=...] WORKSPACE=<id> \
#     scripts/proof-operating-layer.sh --read-only
#       Sends GET requests only and names the tenant and workspace it read;
#       everything else it prints is counts, dates, metric values and
#       booleans, never content, titles, names, emails or keys. For an
#       owner's private Engine. Boot is read only with BOOT=1, and then with
#       generate=false, so today's rhythm note is not written (an Engine
#       older than that option still writes it).
#       GET /api/signals/classification?plan=true reads every Signal of the
#       workspace (CLASSIFY_PLAN=0 skips that).
#
# The key is read from a file or minted here, passed to the checks in the
# environment, and never printed or put on a command line. A temporary store
# this script made is removed on exit unless KEEP_DATA=1.
# Exit: 0 when every check passed or was skipped, 1 when one failed, 2 when
# the Engine could not be reached or refused the key.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE=full
case "${1:-}" in
  --read-only) MODE=read-only ;;
  "") ;;
  *) echo "usage: $0 [--read-only]" >&2; exit 64 ;;
esac

LIMIT_SECONDS="${LIMIT_SECONDS:-900}"
started=$(date +%s)

key_from_file() {
  [ -r "$1" ] || { echo "UNREACHABLE cannot read ENGINE_KEY_FILE" >&2; exit 2; }
  tr -d '[:space:]' <"$1"
}

if [ -n "${ENGINE_URL:-}" ]; then
  PROOF_ENGINE_KEY=""
  if [ -n "${ENGINE_KEY_FILE:-}" ]; then PROOF_ENGINE_KEY="$(key_from_file "$ENGINE_KEY_FILE")"; fi
  if [ "$MODE" = full ] && [ -z "$PROOF_ENGINE_KEY" ]; then
    echo "full mode against an existing Engine needs ENGINE_KEY_FILE with an admin key" >&2
    exit 64
  fi
  export ENGINE_URL PROOF_ENGINE_KEY PROOF_FRESH=0
else
  [ "$MODE" = full ] || { echo "--read-only needs ENGINE_URL" >&2; exit 64; }

  PORT="${PORT:-4212}"
  own_data=0
  if [ -z "${DATA:-}" ]; then
    DATA="$(mktemp -d)"
    own_data=1
  fi
  export MIX_ENV=dev
  export OPTIMAL_API_ENABLED=true
  export OPTIMAL_AUTH_REQUIRED=true
  export OPTIMAL_API_PORT="$PORT"
  export OPTIMAL_ENGINE_ROOT="$DATA/root"
  export OPTIMAL_ENGINE_DB="$DATA/root/index.db"
  export OPTIMAL_ENGINE_CACHE="$DATA/root/cache"
  # The proof takes its own snapshots and runs no analyses, so the schedulers
  # cannot change the store while it reads it.
  export OPTIMAL_VIABILITY_INTERVAL_MS=0
  export OPTIMAL_ANALYSES_INTERVAL_MS=0
  export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"
  export OPTIMAL_AUTHORITY_KEY="${OPTIMAL_AUTHORITY_KEY:-$(openssl rand -hex 32)}"
  mkdir -p "$OPTIMAL_ENGINE_ROOT" "$OPTIMAL_ENGINE_CACHE"

  fail() {
    echo "FAIL $1"
    if [ -f "$DATA/server.log" ]; then tail -30 "$DATA/server.log"; fi
    exit 1
  }

  echo "== start an Engine on an empty store"
  mix deps.get >/dev/null
  mint_out=$(mix optimal.auth mint --name root --workspace '*' --json 2>"$DATA/mint.err" || true)
  PROOF_ENGINE_KEY=$(printf '%s' "$mint_out" |
    grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
    sed 's/.*"\([^"]*\)"$/\1/' || true)
  if [ -z "$PROOF_ENGINE_KEY" ]; then
    printf '%s\n' "$mint_out" | tail -8 |
      sed 's/"key"[[:space:]]*:[[:space:]]*"[^"]*"/"key":"REDACTED"/'
    tail -8 "$DATA/mint.err"
    fail "mint printed no key"
  fi

  mix run --no-halt >"$DATA/server.log" 2>&1 &
  server=$!

  cleanup() {
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
    if [ "$own_data" = 1 ] && [ "${KEEP_DATA:-}" != 1 ]; then rm -rf "$DATA"; fi
  }
  trap cleanup EXIT

  ENGINE_URL="http://127.0.0.1:$PORT"
  healthy=0
  for _ in $(seq 1 120); do
    code=$(printf 'Authorization: Bearer %s\n' "$PROOF_ENGINE_KEY" |
      curl -s -o /dev/null -w '%{http_code}' -H @- "$ENGINE_URL/api/health" || true)
    if [ "$code" = 200 ]; then
      healthy=1
      break
    fi
    sleep 1
  done
  [ "$healthy" = 1 ] || fail "the Engine did not answer /api/health"
  export ENGINE_URL PROOF_ENGINE_KEY PROOF_FRESH=1
fi

status=0
python3 "$ROOT/scripts/proof_operating_layer.py" "$MODE" || status=$?

elapsed=$(($(date +%s) - started))
echo "PROOF_SECONDS=$elapsed"
if [ "$status" = 0 ] && [ "$elapsed" -ge "$LIMIT_SECONDS" ]; then
  echo "FAIL the proof took longer than $LIMIT_SECONDS seconds"
  status=1
fi
exit "$status"
