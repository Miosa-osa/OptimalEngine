#!/usr/bin/env bash
# WO-33 item 2: kill the Engine mid-write, restart it, and prove no partial
# transaction is visible.
#
# A transaction is all-or-nothing. The script sends one large transaction, kills
# the Engine while it is in flight, restarts it against the same data directory,
# and asserts the collection holds either every record of that transaction or
# none. It also writes one record after the restart, so a recovered store that
# only reads would not pass.
#
# Usage: scripts/proof-app-data-crash.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-4213}"
DATA="${DATA:-$(mktemp -d)}"
N="${N:-5000}"
KILL_AFTER="${KILL_AFTER:-0.08}"
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

start_engine() {
  mix run --no-halt >>"$DATA/server.log" 2>&1 &
  server=$!
  local healthy=0
  for _ in $(seq 1 90); do
    if curl -sf -H "Authorization: Bearer $key" "$url/api/health" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 1
  done
  if [ "$healthy" != 1 ]; then
    echo "--- last boot log ---"
    tail -20 "$DATA/server.log"
    fail "the Engine did not answer /api/health on port $port"
  fi
}

echo "== step 1: dependencies"
mix deps.get >/dev/null

echo "== step 2: mint the key"
mint_out=$(mix optimal.auth mint --name root --workspace '*' --json 2>/dev/null || true)
key=$(printf '%s' "$mint_out" |
  grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
  sed 's/.*"\([^"]*\)"$/\1/')
[ -n "$key" ] || fail "mint printed no key"

url="http://127.0.0.1:$PORT"
echo "== step 3: start the Engine"
start_engine
trap 'kill "$server" 2>/dev/null || true' EXIT

echo "== step 4: a collection"
code=$(curl -s -o "$DATA/collection.json" -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
  --data '{"name":"tasks","fields":[{"name":"title","type":"string","required":true},{"name":"owner","type":"string"}],"owner_field":"owner","indexes":[{"fields":["owner"]}]}' \
  "$url/api/data/collections?workspace=default:crash")
[ "$code" = "201" ] || { cat "$DATA/collection.json"; fail "creating the collection (HTTP $code)"; }

echo "== step 5: one transaction of $N creates"
python3 - "$N" "$DATA/txn.json" <<'PY'
import json, sys

count = int(sys.argv[1])
operations = [
    {"op": "create", "collection": "tasks", "id": "crash-%06d" % i,
     "data": {"title": "record %d" % i, "owner": "user-a"}}
    for i in range(count)
]
with open(sys.argv[2], "w") as handle:
    json.dump({"operations": operations}, handle)
PY

curl -s -o "$DATA/txn.out" -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
  --data @"$DATA/txn.json" "$url/api/data/transactions" >"$DATA/txn.code" 2>/dev/null &
curl_pid=$!
sleep "$KILL_AFTER"
kill -9 "$server" 2>/dev/null || true
wait "$curl_pid" 2>/dev/null || true
in_flight=$(cat "$DATA/txn.code" 2>/dev/null || echo "none")
echo "IN_FLIGHT_HTTP=$in_flight"
head -c 400 "$DATA/txn.out" 2>/dev/null || true
echo

echo "== step 6: restart on the same store"
sleep 1
start_engine

count=$(curl -sf -X POST -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
  --data '{"count":true,"limit":0}' "$url/api/data/collections/tasks/query" |
  grep -o '"count":[0-9]*' | head -1 | cut -d: -f2)
echo "RECORDS_AFTER_RESTART=${count:-unknown}"
[ -n "$count" ] || fail "the restarted Engine did not answer the query"
if [ "$count" != "0" ] && [ "$count" != "$N" ]; then
  fail "a partial transaction is visible: $count of $N records"
fi

echo "== step 7: the recovered store still writes"
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
  --data '{"id":"after-restart","data":{"title":"after restart","owner":"user-a"}}' \
  "$url/api/data/collections/tasks/records")
echo "WRITE_AFTER_RESTART=$code"
[ "$code" = "201" ] || fail "the recovered store refused a write"

echo "PASS app data crash recovery (no partial transaction)"
