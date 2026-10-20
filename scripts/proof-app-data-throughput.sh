#!/usr/bin/env bash
# WO-33 item 4: publish measured embedded throughput.
#
# Starts one Engine on a local store and measures writes per second for 100,000
# records through the bulk endpoint, then the p50 and p95 latency of an indexed
# query over that collection.
#
# Usage: scripts/proof-app-data-throughput.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-4214}"
DATA="${DATA:-$(mktemp -d)}"
RECORDS="${RECORDS:-100000}"
QUERIES="${QUERIES:-200}"
export MIX_ENV=dev
export OPTIMAL_API_ENABLED=true
export OPTIMAL_AUTH_REQUIRED=true
export OPTIMAL_API_PORT="$PORT"
export OPTIMAL_ENGINE_ROOT="$DATA/root"
export OPTIMAL_ENGINE_DB="$DATA/root/index.db"
export OPTIMAL_ENGINE_CACHE="$DATA/root/cache"
export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"
export OPTIMAL_AUTHORITY_KEY="${OPTIMAL_AUTHORITY_KEY:-$(openssl rand -hex 32)}"

mkdir -p "$OPTIMAL_ENGINE_ROOT" "$OPTIMAL_ENGINE_CACHE"

fail() {
  echo "FAIL $1"
  if [ -f "$DATA/server.log" ]; then tail -30 "$DATA/server.log"; fi
  exit 1
}

echo "== step 1: dependencies"
mix deps.get >/dev/null

echo "== step 2: mint the key"
mint_out=$(mix optimal.auth mint --name root --workspace '*' --json 2>/dev/null || true)
key=$(printf '%s' "$mint_out" |
  grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
  sed 's/.*"\([^"]*\)"$/\1/')
[ -n "$key" ] || fail "mint printed no key"

echo "== step 3: start the Engine"
mix run --no-halt >"$DATA/server.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT

url="http://127.0.0.1:$PORT"
healthy=0
for _ in $(seq 1 90); do
  if curl -sf -H "Authorization: Bearer $key" "$url/api/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 1
done
[ "$healthy" = 1 ] || fail "the Engine did not answer /api/health"

echo "== step 4: measure $RECORDS records and $QUERIES queries"
python3 scripts/bench-app-data.py "$url" "$key" "default:bench" "$RECORDS" "$QUERIES" ||
  fail "the benchmark failed"

echo "PASS app data throughput"
