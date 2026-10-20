#!/usr/bin/env bash
# Proves the Engine as an app database: builds the TypeScript client, starts
# one Engine, and runs the reference to-do app against it.
#
# The app covers WO-33 items 1 and 3: a tasks collection with an owner field,
# 1,000 records, a cursor query for one owner sorted by due date, an update
# with a stale version (409 version_conflict), a two-write transaction whose
# second write fails (nothing committed), semantic search by title, and an
# end-user key that cannot read, or write, another owner's task.
#
# Usage: scripts/proof-app-data.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-4212}"
DATA="${DATA:-$(mktemp -d)}"
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

started=$(date +%s)

echo "== step 1: dependencies"
mix deps.get >/dev/null

echo "== step 2: mint the first key"
mint_out=$(mix optimal.auth mint --name root --workspace '*' --json 2>/dev/null || true)
key=$(printf '%s' "$mint_out" |
  grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
  sed 's/.*"\([^"]*\)"$/\1/')
if [ -z "$key" ]; then
  printf '%s\n' "$mint_out" | tail -8 |
    sed 's/"key"[[:space:]]*:[[:space:]]*"[^"]*"/"key":"REDACTED"/'
  fail "mint printed no key"
fi

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

echo "== step 4: build the TypeScript client"
cd sdks/typescript
npm install --no-audit --no-fund >/dev/null 2>&1 || fail "installing the TypeScript client"
npm run build >/dev/null 2>&1 || fail "building the TypeScript client"

echo "== step 5: the reference to-do app"
app_started=$(date +%s)
OPTIMAL_ENGINE_URL="$url" OPTIMAL_API_KEY="$key" OPTIMAL_WORKSPACE="default:todo-demo" \
  node examples/todo-app.ts >"$DATA/todo.log" 2>&1 || {
  tail -60 "$DATA/todo.log"
  fail "the reference app reported failures"
}
app_seconds=$(( $(date +%s) - app_started ))
grep -E "^(PASS|FAIL)" "$DATA/todo.log" | tail -20
grep -q "ALL CHECKS PASSED" "$DATA/todo.log" || {
  tail -60 "$DATA/todo.log"
  fail "the reference app did not print ALL CHECKS PASSED"
}

echo "APP_SECONDS=$app_seconds"
elapsed=$(( $(date +%s) - started ))
echo "APP_DATA_SECONDS=$elapsed"
echo "PASS app data reference app"
