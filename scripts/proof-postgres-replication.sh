#!/usr/bin/env bash
# Replication between two running Engines, each on a PostgreSQL store of its
# own (docs/guides/replication.md, docs/guides/postgres-provider.md).
#
# Starts Engine A and Engine B over HTTP, each with OPTIMAL_STORE=postgres and
# its own schema in one database, enables replication of the default
# workspace on both, and registers each as the other's peer. A memory written
# on A reaches B in one sync cycle, a memory written on B reaches A, and both
# Engines then report healthy peers and no open conflicts.
#
# The proof writes only to two schemas of its own, oe_proof_repl_{a,b}_<time>_<pid>,
# and drops them at the end.
#
# Usage: OPTIMAL_POSTGRES_URL=postgres://... scripts/proof-postgres-replication.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${OPTIMAL_POSTGRES_URL:?set OPTIMAL_POSTGRES_URL to a database the proof may write}"
for tool in curl python3 openssl; do
  command -v "$tool" >/dev/null || { echo "the proof needs $tool" >&2; exit 2; }
done

STAMP="$(date +%s)_$$"
SCHEMA_A="oe_proof_repl_a_$STAMP"
SCHEMA_B="oe_proof_repl_b_$STAMP"
PORT_A="${PORT_A:-4231}"
PORT_B="${PORT_B:-4232}"
DATA="${DATA:-$(mktemp -d)}"
mkdir -p "$DATA"

export MIX_ENV=dev
export OPTIMAL_STORE=postgres
export OPTIMAL_API_ENABLED=true
export OPTIMAL_AUTH_REQUIRED=true
export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"
export OPTIMAL_AUTHORITY_KEY="${OPTIMAL_AUTHORITY_KEY:-$(openssl rand -hex 32)}"
# The scheduler would run the peers on its own; the proof runs each cycle.
export OPTIMAL_SYNC_INTERVAL_MS="${OPTIMAL_SYNC_INTERVAL_MS:-3600000}"

pids=()

fail() {
  echo "FAIL $1"
  for log in "$DATA"/*.log; do
    [ -f "$log" ] && { echo "--- $log"; tail -25 "$log"; }
  done
  exit 1
}

engine_env() {
  local name=$1 port=$2 schema=$3
  mkdir -p "$DATA/$name/cache"
  echo "OPTIMAL_ENGINE_ROOT=$DATA/$name OPTIMAL_ENGINE_DB=$DATA/$name/index.db" \
    "OPTIMAL_ENGINE_CACHE=$DATA/$name/cache OPTIMAL_API_PORT=$port OPTIMAL_POSTGRES_SCHEMA=$schema"
}

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true

  OPTIMAL_PROOF_SCHEMAS="$SCHEMA_A $SCHEMA_B" mix run --no-compile --no-start -e '
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, config} = OptimalEngine.Storage.Postgres.config()
    {:ok, conn} = config |> Map.take([:hostname, :port, :database, :username, :password, :ssl]) |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Postgrex.start_link()

    for schema <- String.split(System.fetch_env!("OPTIMAL_PROOF_SCHEMAS")) do
      unless schema =~ ~r/\Aoe_proof_repl_[ab]_[0-9_]+\z/, do: raise("refusing to drop schema #{schema}")
      Postgrex.query!(conn, ~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE), [])
    end
  ' >/dev/null 2>&1 || true
}
trap cleanup EXIT

mint() {
  local name=$1 port=$2 schema=$3 out key
  out=$(env $(engine_env "$name" "$port" "$schema") mix optimal.auth mint --name "proof-$name" --workspace '*' --json 2>"$DATA/mint-$name.log" || true)
  key=$(printf '%s' "$out" | grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  [ -n "$key" ] || fail "minting a key on Engine $name"
  printf '%s' "$key"
}

start() {
  local name=$1 port=$2 schema=$3
  env $(engine_env "$name" "$port" "$schema") mix run --no-compile --no-halt >"$DATA/engine-$name.log" 2>&1 &
  pids+=("$!")
}

wait_healthy() {
  local url=$1 key=$2 code=
  for _ in $(seq 1 120); do
    code=$(curl -s -o "$DATA/health.json" -w '%{http_code}' -H "Authorization: Bearer $key" "$url/api/health" 2>/dev/null || true)
    [ "$code" = 200 ] && return 0
    sleep 1
  done
  echo "last /api/health answer: $code $(head -c 400 "$DATA/health.json" 2>/dev/null)"
  return 1
}

# call METHOD URL KEY [JSON]: the response body; fails the proof on an HTTP error.
call() {
  local method=$1 url=$2 key=$3 body=${4:-}
  if [ -n "$body" ]; then
    curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" --data "$body" "$url"
  else
    curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer $key" "$url"
  fi
}

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

echo "== build the engine (OPTIMAL_STORE=postgres)"
mix compile >"$DATA/compile.log" 2>&1 || fail "compile"

echo "== mint a key on each Engine (schemas $SCHEMA_A, $SCHEMA_B)"
KEY_A=$(mint a "$PORT_A" "$SCHEMA_A")
KEY_B=$(mint b "$PORT_B" "$SCHEMA_B")

echo "== start Engine A on :$PORT_A and Engine B on :$PORT_B"
start a "$PORT_A" "$SCHEMA_A"
start b "$PORT_B" "$SCHEMA_B"
A="http://127.0.0.1:$PORT_A"
B="http://127.0.0.1:$PORT_B"
wait_healthy "$A" "$KEY_A" || fail "Engine A did not answer /api/health"
wait_healthy "$B" "$KEY_B" || fail "Engine B did not answer /api/health"

store_a=$(call GET "$A/api/storage/providers" "$KEY_A" | json "[p['selected'] for p in d.get('providers', d.get('data', [])) if p.get('id') == 'postgres']")
store_b=$(call GET "$B/api/storage/providers" "$KEY_B" | json "[p['selected'] for p in d.get('providers', d.get('data', [])) if p.get('id') == 'postgres']")
[ "$store_a" = "[True]" ] && [ "$store_b" = "[True]" ] || fail "an Engine is not on the PostgreSQL store (A $store_a, B $store_b)"
echo "both Engines run the PostgreSQL store"

echo "== enable replication of the default workspace on both, and pair them"
call POST "$A/api/sync/enable" "$KEY_A" '{"workspace":"default","label":"Engine A"}' >"$DATA/enable-a.json" || fail "enable on A"
call POST "$B/api/sync/enable" "$KEY_B" '{"workspace":"default","label":"Engine B"}' >"$DATA/enable-b.json" || fail "enable on B"
call POST "$A/api/sync/peers" "$KEY_A" \
  "{\"workspace\":\"default\",\"url\":\"$B\",\"api_key\":\"$KEY_B\",\"policy\":\"both\",\"max_class\":\"confidential\",\"label\":\"Engine B\"}" \
  >/dev/null || fail "registering B on A"
call POST "$B/api/sync/peers" "$KEY_B" \
  "{\"workspace\":\"default\",\"url\":\"$A\",\"api_key\":\"$KEY_A\",\"policy\":\"both\",\"max_class\":\"confidential\",\"label\":\"Engine A\"}" \
  >/dev/null || fail "registering A on B"

# has ENGINE_URL KEY TEXT: whether the Engine holds a memory with that content.
has() {
  call GET "$1/api/memory?workspace=default&limit=200" "$2" |
    python3 -c "import json,sys; d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get('memories', d.get('data', [])); print(any(r.get('content') == sys.argv[1] for r in rows))" "$3"
}

echo "== a memory written on A reaches B"
from_a="written on Engine A $STAMP"
id_a=$(call POST "$A/api/memory" "$KEY_A" "{\"workspace\":\"default\",\"content\":\"$from_a\"}" | json "d['id']") || fail "writing on A"
[ "$(has "$B" "$KEY_B" "$from_a")" = "False" ] || fail "B held A's memory before any sync"
call POST "$B/api/sync/run" "$KEY_B" '{}' >"$DATA/run-b-1.json" || fail "sync run on B"
[ "$(has "$B" "$KEY_B" "$from_a")" = "True" ] || fail "A's memory did not reach B: $(cat "$DATA/run-b-1.json")"
echo "B pulled A's memory $id_a"

echo "== a memory written on B reaches A"
from_b="written on Engine B $STAMP"
id_b=$(call POST "$B/api/memory" "$KEY_B" "{\"workspace\":\"default\",\"content\":\"$from_b\"}" | json "d['id']") || fail "writing on B"
call POST "$A/api/sync/run" "$KEY_A" '{}' >"$DATA/run-a-1.json" || fail "sync run on A"
[ "$(has "$A" "$KEY_A" "$from_b")" = "True" ] || fail "B's memory did not reach A: $(cat "$DATA/run-a-1.json")"
echo "A pulled B's memory $id_b"

echo "== both Engines report healthy peers and no conflicts"
call GET "$A/api/sync/status?workspace=default" "$KEY_A" >"$DATA/status-a.json" || fail "status on A"
call GET "$B/api/sync/status?workspace=default" "$KEY_B" >"$DATA/status-b.json" || fail "status on B"
python3 - "$DATA/status-a.json" "$DATA/status-b.json" <<'PY' || fail "a peer is not healthy after the cycles"
import json, sys
for path in sys.argv[1:]:
    status = json.load(open(path))
    peers = status["peers"]
    print(status["label"], "ledger", status["ledger_sequence"],
          "peers", [(p["label"], p["status"], "pulled", p["last_pulled_seq"], "pushed", p["last_pushed_seq"],
                     "pending", p["pending_push"]) for p in peers],
          "open conflicts", status["open_conflicts"])
    if not status["enabled"] or len(peers) != 1 or peers[0]["status"] != "active" or status["open_conflicts"]:
        sys.exit(1)
PY

echo "PASS replication between two Engines on PostgreSQL stores"
