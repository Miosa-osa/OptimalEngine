#!/usr/bin/env bash
# Proves the Engine-only quickstart (docs/guides/quickstart.md) end to end on
# one machine, and the topology round trip from WO-41 item 4.
#
# It needs no account, no other product, and no network service: one Engine,
# one minted key, one workspace, one stored source, one search, one cited
# assembly, then import/export of a topology document.
#
# Usage: scripts/proof-engine-only.sh
# Exit: 0 only when every step passed and the whole run stayed under 15 minutes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-4211}"
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

export OPTIMAL_ENGINE_URL="$url"
export OPTIMAL_ENGINE_API_KEY="$key"
cli=apps/cli/optimal

echo "== step 4: a workspace"
"$cli" api POST /api/workspaces '{"slug":"personal","name":"Personal Brain"}' >/dev/null ||
  fail "creating the workspace"

echo "== step 5: store a source"
"$cli" capture "Renewal call with the supplier moved to the 14th; the contract review is still open." \
  personal --title "Supplier renewal call" >/dev/null || fail "capturing the source"

echo "== step 6: retrieve with citations"
"$cli" search "supplier renewal" personal >/dev/null || fail "searching"
"$cli" assemble "supplier renewal" personal >/dev/null || fail "assembling context"
"$cli" version >/dev/null || fail "version"

echo "== step 7: topology round trip"
cat >"$DATA/org.json" <<'JSON'
{
  "schema_version": 1,
  "organizations": [
    {
      "slug": "example-co",
      "name": "Example Co",
      "status": "active",
      "role": "Operating company",
      "workspaces": ["delivery", "sales"]
    }
  ],
  "people": [
    {
      "id": "user:jane",
      "kind": "user",
      "display_name": "Jane Example",
      "workspaces": ["sales"]
    }
  ]
}
JSON

curl -sf -X POST -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
  --data @"$DATA/org.json" "$url/api/topology/import" >"$DATA/import.json" ||
  fail "importing the topology"
curl -sf -H "Authorization: Bearer $key" "$url/api/topology/export" >"$DATA/export.json" ||
  fail "exporting the topology"

python3 - "$DATA/org.json" "$DATA/export.json" <<'PY' || fail "the exported topology differs from the imported one"
import json, sys

def clean(value):
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [clean(v) for v in value]
    return value

sent = clean(json.load(open(sys.argv[1])))
back = clean(json.load(open(sys.argv[2])))

if sent == back:
    print("TOPOLOGY_MATCH=true")
    sys.exit(0)

print("TOPOLOGY_MATCH=false")
print("sent:", json.dumps(sent, sort_keys=True))
print("back:", json.dumps(back, sort_keys=True))
sys.exit(1)
PY

echo "== step 8: authority requests (what the console proxies)"
code=$(curl -s -o "$DATA/authority.json" -w "%{http_code}" \
  -H "Authorization: Bearer $key" "$url/api/authority/requests?status=pending")
echo "AUTHORITY_STATUS=$code"
head -c 300 "$DATA/authority.json" || true
echo

elapsed=$(( $(date +%s) - started ))
echo "QUICKSTART_SECONDS=$elapsed"
[ "$elapsed" -lt 900 ] || fail "the quickstart took longer than 15 minutes"
echo "PASS engine-only quickstart"
