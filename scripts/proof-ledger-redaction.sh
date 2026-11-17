#!/usr/bin/env bash
# Erased content leaves the replication ledger of both Engines of a pair
# (docs/guides/erasure-and-retention.md, "The replication ledger, peers and NATS").
#
# Starts Engine A and Engine B over HTTP, enables replication of the default
# workspace on both and pairs them. Two memories written on A reach B; then A
# forgets one and deletes the other. After one more cycle neither Engine's
# ledger (`sync_mutations`, `sync_capture`, `sync_conflicts`) holds either
# memory's text in any change (the memory's own, and those of the source
# package and claim writing a memory stages, which the forget erases with it),
# B holds the forgotten memory marked forgotten and no longer holds the deleted
# one, and A serves neither text.
#
# Usage:
#   scripts/proof-ledger-redaction.sh                       # SQLite stores
#   OPTIMAL_STORE=postgres OPTIMAL_POSTGRES_URL=postgres://... scripts/proof-ledger-redaction.sh
#
# On PostgreSQL the proof writes only to two schemas of its own,
# oe_proof_redact_{a,b}_<time>_<pid>, and drops them at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STORE="${OPTIMAL_STORE:-sqlite}"
if [ "$STORE" = postgres ]; then
  : "${OPTIMAL_POSTGRES_URL:?set OPTIMAL_POSTGRES_URL to a database the proof may write}"
fi
for tool in curl python3 openssl; do
  command -v "$tool" >/dev/null || { echo "the proof needs $tool" >&2; exit 2; }
done

STAMP="$(date +%s)_$$"
SCHEMA_A="oe_proof_redact_a_$STAMP"
SCHEMA_B="oe_proof_redact_b_$STAMP"
PORT_A="${PORT_A:-4271}"
PORT_B="${PORT_B:-4272}"
DATA="${DATA:-$(mktemp -d)}"
mkdir -p "$DATA"

export MIX_ENV="${MIX_ENV:-dev}"
export OPTIMAL_API_ENABLED=true
export OPTIMAL_AUTH_REQUIRED=true
export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"
export OPTIMAL_AUTHORITY_KEY="${OPTIMAL_AUTHORITY_KEY:-$(openssl rand -hex 32)}"
# The scheduler would run the peers on its own; the proof runs each cycle.
export OPTIMAL_SYNC_INTERVAL_MS="${OPTIMAL_SYNC_INTERVAL_MS:-3600000}"
if [ "$STORE" = postgres ]; then export OPTIMAL_STORE=postgres; else unset OPTIMAL_STORE; fi

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
  [ "$STORE" = postgres ] || return 0

  OPTIMAL_PROOF_SCHEMAS="$SCHEMA_A $SCHEMA_B" mix run --no-compile --no-start -e '
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, config} = OptimalEngine.Storage.Postgres.config()
    {:ok, conn} = config |> Map.take([:hostname, :port, :database, :username, :password, :ssl]) |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Postgrex.start_link()

    for schema <- String.split(System.fetch_env!("OPTIMAL_PROOF_SCHEMAS")) do
      unless schema =~ ~r/\Aoe_proof_redact_[ab]_[0-9_]+\z/, do: raise("refusing to drop schema #{schema}")
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

# ledger_hits ENGINE TEXT: changes of any table in the Engine's ledger,
# capture and conflicts that hold TEXT.
ledger_hits() {
  local name=$1 text=$2 port schema
  if [ "$name" = a ]; then port=$PORT_A schema=$SCHEMA_A; else port=$PORT_B schema=$SCHEMA_B; fi
  env $(engine_env "$name" "$port" "$schema") OPTIMAL_PROOF_TOKEN="$text" OPTIMAL_PROOF_TABLES="" \
    mix run --no-compile --no-start scripts/proof_ledger_grep.exs 2>>"$DATA/grep.log" | tail -1
}

# memory ENGINE_URL KEY ID: "<content>|<is_forgotten as JSON>" or "missing".
memory() {
  curl -s -H "Authorization: Bearer $2" "$1/api/memory/$3" |
    python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('missing'); sys.exit()
m=d.get('memory', d) if isinstance(d, dict) else {}
if not m.get('id'):
    print('missing')
else:
    print('%s|%s' % (m.get('content'), json.dumps(m.get('is_forgotten'))))"
}

echo "== build the engine ($STORE store)"
mix compile >"$DATA/compile.log" 2>&1 || fail "compile"

echo "== mint a key on each Engine"
KEY_A=$(mint a "$PORT_A" "$SCHEMA_A")
KEY_B=$(mint b "$PORT_B" "$SCHEMA_B")

echo "== start Engine A on :$PORT_A and Engine B on :$PORT_B"
start a "$PORT_A" "$SCHEMA_A"
start b "$PORT_B" "$SCHEMA_B"
A="http://127.0.0.1:$PORT_A"
B="http://127.0.0.1:$PORT_B"
wait_healthy "$A" "$KEY_A" || fail "Engine A did not answer /api/health"
wait_healthy "$B" "$KEY_B" || fail "Engine B did not answer /api/health"

echo "== enable replication of the default workspace on both, and pair them"
call POST "$A/api/sync/enable" "$KEY_A" '{"workspace":"default","label":"Engine A"}' >/dev/null || fail "enable on A"
call POST "$B/api/sync/enable" "$KEY_B" '{"workspace":"default","label":"Engine B"}' >/dev/null || fail "enable on B"
call POST "$A/api/sync/peers" "$KEY_A" \
  "{\"workspace\":\"default\",\"url\":\"$B\",\"api_key\":\"$KEY_B\",\"policy\":\"both\",\"max_class\":\"confidential\",\"label\":\"Engine B\"}" \
  >/dev/null || fail "registering B on A"
call POST "$B/api/sync/peers" "$KEY_B" \
  "{\"workspace\":\"default\",\"url\":\"$A\",\"api_key\":\"$KEY_A\",\"policy\":\"both\",\"max_class\":\"confidential\",\"label\":\"Engine A\"}" \
  >/dev/null || fail "registering A on B"

FORGET="forget-me-$STAMP"
DELETE="delete-me-$STAMP"

echo "== two memories written on A reach B"
id_f=$(call POST "$A/api/memory" "$KEY_A" "{\"workspace\":\"default\",\"content\":\"the vault code is $FORGET\"}" | json "d['id']") || fail "writing on A"
id_d=$(call POST "$A/api/memory" "$KEY_A" "{\"workspace\":\"default\",\"content\":\"the alarm code is $DELETE\"}" | json "d['id']") || fail "writing on A"
call POST "$B/api/sync/run" "$KEY_B" '{}' >"$DATA/run-b-1.json" || fail "sync run on B"
[[ "$(memory "$B" "$KEY_B" "$id_f")" == *"$FORGET"* ]] || fail "the first memory did not reach B: $(cat "$DATA/run-b-1.json")"
[[ "$(memory "$B" "$KEY_B" "$id_d")" == *"$DELETE"* ]] || fail "the second memory did not reach B"
for engine in a b; do
  for text in "$FORGET" "$DELETE"; do
    [ "$(ledger_hits "$engine" "$text")" -gt 0 ] || fail "Engine $engine's ledger did not hold $text before the erasure"
  done
done
echo "both ledgers hold both texts"

echo "== A forgets the first memory and deletes the second"
call POST "$A/api/memory/$id_f/forget" "$KEY_A" '{"reason":"asked"}' >/dev/null || fail "forget on A"
call DELETE "$A/api/memory/$id_d" "$KEY_A" >/dev/null || fail "delete on A"
for text in "$FORGET" "$DELETE"; do
  [ "$(ledger_hits a "$text")" = 0 ] || fail "A's ledger still holds $text after the erasure"
done
echo "A's ledger holds neither text"

echo "== one more cycle: B applies the redaction request and the delete"
call POST "$B/api/sync/run" "$KEY_B" '{}' >"$DATA/run-b-2.json" || fail "sync run on B"
for text in "$FORGET" "$DELETE"; do
  [ "$(ledger_hits b "$text")" = 0 ] || fail "B's ledger still holds $text: $(cat "$DATA/run-b-2.json")"
done
[[ "$(memory "$B" "$KEY_B" "$id_f")" == *"|1" || "$(memory "$B" "$KEY_B" "$id_f")" == *"|true" ]] || fail "B did not mark the forgotten memory: $(memory "$B" "$KEY_B" "$id_f")"
[ "$(memory "$B" "$KEY_B" "$id_d")" = missing ] || fail "B still holds the deleted memory"
echo "B's ledger holds neither text; its copy is forgotten and the other is gone"

echo "== A serves neither text to a peer that starts from the beginning"
call GET "$A/api/sync/changes?workspace=default&since=0&limit=2000" "$KEY_A" >"$DATA/changes-a.json" || fail "changes on A"
for text in "$FORGET" "$DELETE"; do
  python3 - "$DATA/changes-a.json" "$text" "$id_f" "$id_d" <<'PY' || fail "A serves $text"
import json, sys
page = json.load(open(sys.argv[1]))
text, ids = sys.argv[2], set(sys.argv[3:])
for m in page["mutations"]:
    if text in json.dumps(m):
        sys.exit(1)
PY
done

echo "== both Engines report healthy peers"
call GET "$A/api/sync/status?workspace=default" "$KEY_A" >"$DATA/status-a.json" || fail "status on A"
call GET "$B/api/sync/status?workspace=default" "$KEY_B" >"$DATA/status-b.json" || fail "status on B"
python3 - "$DATA/status-a.json" "$DATA/status-b.json" <<'PY' || fail "a peer is not healthy after the cycles"
import json, sys
for path in sys.argv[1:]:
    status = json.load(open(path))
    peers = status["peers"]
    print(status["label"], "ledger", status["ledger_sequence"],
          "peers", [(p["label"], p["status"]) for p in peers], "open conflicts", status["open_conflicts"])
    if not status["enabled"] or len(peers) != 1 or peers[0]["status"] != "active":
        sys.exit(1)
PY

echo "PASS erased memories leave the ledgers of both Engines ($STORE)"
