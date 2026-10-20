#!/usr/bin/env bash
# WO-31: the offsite backup and restore drill on real object storage.
#
# Needs an S3 credential and bucket for this run, supplied at `.gate-secrets/engwo-s3.env`
# (an overlay for the gate machine; never committed). The file exports
# S3_ENDPOINT, S3_BUCKET, S3_REGION, S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY.
#
# Proves, in order: an online backup with PRAGMA integrity_check that ships an
# encrypted object and verifies its checksums; the object is listed back from
# the bucket; a restore of that object into a second data directory; 20-query
# parity between the source and the restored store; and the providers report.
#
# Usage: scripts/proof-offsite-backup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SECRETS="${SECRETS:-$ROOT/.gate-secrets/engwo-s3.env}"
[ -r "$SECRETS" ] || {
  echo "FAIL no S3 credentials at $SECRETS"
  exit 1
}
# shellcheck disable=SC1090
. "$SECRETS"

DATA="${DATA:-$(mktemp -d)}"
SOURCE_PORT="${SOURCE_PORT:-4216}"
RESTORED_PORT="${RESTORED_PORT:-4217}"
export MIX_ENV=dev
export OPTIMAL_API_ENABLED=true
export OPTIMAL_AUTH_REQUIRED=true
export OPTIMAL_ENGINE_ROOT="$DATA/root"
export OPTIMAL_ENGINE_DB="$DATA/root/index.db"
export OPTIMAL_ENGINE_CACHE="$DATA/root/cache"
export OPTIMAL_S3_ENDPOINT="$S3_ENDPOINT"
export OPTIMAL_S3_BUCKET="$S3_BUCKET"
export OPTIMAL_S3_REGION="${S3_REGION:-us-east-1}"
export OPTIMAL_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export OPTIMAL_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export OPTIMAL_S3_PREFIX="${S3_PREFIX:-engwo-1019/}"
export OPTIMAL_S3_TRACE="${OPTIMAL_S3_TRACE:-1}"
export OPTIMAL_BACKUP_KEY="${OPTIMAL_BACKUP_KEY:-$(openssl rand -hex 32)}"
export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"
export OPTIMAL_AUTHORITY_KEY="${OPTIMAL_AUTHORITY_KEY:-$(openssl rand -hex 32)}"

mkdir -p "$OPTIMAL_ENGINE_ROOT" "$OPTIMAL_ENGINE_CACHE"

fail() {
  echo "FAIL $1"
  if [ -f "$DATA/server.log" ]; then tail -30 "$DATA/server.log"; fi
  if [ -f "$DATA/restored.log" ]; then tail -20 "$DATA/restored.log"; fi
  exit 1
}

start_engine() { # port, log, root
  local port=$1 log=$2 root=${3:-$OPTIMAL_ENGINE_ROOT}
  OPTIMAL_ENGINE_ROOT="$root" OPTIMAL_ENGINE_DB="$root/index.db" \
    OPTIMAL_ENGINE_CACHE="$root/cache" OPTIMAL_API_PORT="$port" \
    mix run --no-halt >>"$log" 2>&1 &
  local pid=$!
  local healthy=0
  for _ in $(seq 1 90); do
    if curl -sf -H "Authorization: Bearer $key" "http://127.0.0.1:$port/api/health" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 1
  done
  [ "$healthy" = 1 ] || fail "the Engine on port $port did not answer /api/health"
  echo "$pid"
}

echo "== step 1: dependencies"
mix deps.get >/dev/null

echo "== step 2: mint the key"
mint_out=$(mix optimal.auth mint --name root --workspace '*' --json 2>/dev/null || true)
key=$(printf '%s' "$mint_out" |
  grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
  sed 's/.*"\([^"]*\)"$/\1/')
[ -n "$key" ] || fail "mint printed no key"

echo "== step 3: source Engine and one collection"
source_pid=$(start_engine "$SOURCE_PORT" "$DATA/server.log" "$OPTIMAL_ENGINE_ROOT")
trap 'kill "$source_pid" "${restored_pid:-}" 2>/dev/null || true' EXIT

source_url="http://127.0.0.1:$SOURCE_PORT"
ws="?workspace=default:drill"
curl -sf -X POST -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
  --data '{"name":"tasks","fields":[{"name":"title","type":"string","required":true},{"name":"owner","type":"string"},{"name":"n","type":"integer"}],"owner_field":"owner","indexes":[{"fields":["owner"]}]}' \
  "$source_url/api/data/collections$ws" >/dev/null || fail "creating the collection"

python3 - "$source_url" "$key" <<'PY' || fail "seeding records"
import json, sys, urllib.request

base, key = sys.argv[1], sys.argv[2]
rows = [{"id": "seed-%03d" % i, "data": {"title": "task %d" % i, "owner": "user-a", "n": i}} for i in range(60)]
request = urllib.request.Request(
    base + "/api/data/collections/tasks/records/bulk?workspace=default:drill",
    data=json.dumps({"records": rows}).encode(),
    method="POST",
)
request.add_header("Authorization", "Bearer " + key)
request.add_header("Content-Type", "application/json")
with urllib.request.urlopen(request, timeout=60) as response:
    print("seeded", json.loads(response.read())["count"])
PY

echo "== step 4: online backup, verified, shipped offsite"
mix optimal.backup "$DATA/snap.db" --verify --offsite >"$DATA/backup.log" 2>&1 ||
  { cat "$DATA/backup.log"; fail "the backup failed"; }
grep -q "integrity_check:  OK" "$DATA/backup.log" || { cat "$DATA/backup.log"; fail "integrity_check did not pass"; }
grep -q "offsite:" "$DATA/backup.log" || { cat "$DATA/backup.log"; fail "no offsite copy"; }
grep -q "checksums verified" "$DATA/backup.log" || { cat "$DATA/backup.log"; fail "offsite checksums were not verified"; }
sed -n '1,12p' "$DATA/backup.log"

echo "== step 5: the object is listed back from the bucket"
mix optimal.backup --list-offsite-objects >"$DATA/objects.log" 2>&1 ||
  { cat "$DATA/objects.log"; fail "listing the bucket failed"; }
objects=$(grep -c "s3://\|engwo-1019/" "$DATA/objects.log" || true)
echo "BUCKET_OBJECT_LINES=$objects"
[ "$objects" -ge 1 ] || { cat "$DATA/objects.log"; fail "the bucket lists no backup object"; }

echo "== step 6: restore the offsite copy into a second data directory"
backup_id=$(mix optimal.backup --list-offsite 2>/dev/null |
  grep -E '^  backup_[0-9a-f]{32}$' | head -1 | tr -d ' ' || true)
[ -n "$backup_id" ] || fail "no cataloged offsite backup id"
echo "BACKUP_ID=$backup_id"

mix optimal.restore --from-offsite "$backup_id" --data-dir "$DATA/restored" >"$DATA/restore.log" 2>&1 ||
  { cat "$DATA/restore.log"; fail "the offsite restore failed"; }
tail -8 "$DATA/restore.log"

echo "== step 7: 20-query parity between source and restore"
restored_pid=$(start_engine "$RESTORED_PORT" "$DATA/restored.log" "$DATA/restored")
trap 'kill "$source_pid" "$restored_pid" 2>/dev/null || true' EXIT

python3 - "$source_url" "http://127.0.0.1:$RESTORED_PORT" "$key" <<'PY' || fail "parity differed"
import json, sys, urllib.request

source, restored, key = sys.argv[1], sys.argv[2], sys.argv[3]
bodies = []
for limit in (1, 5, 10, 25):
    for owner in ("user-a", "user-b"):
        bodies.append({"where": {"owner": owner}, "sort": ["n"], "limit": limit})
        bodies.append({"where": {"owner": owner, "n": {"gte": 10}}, "sort": ["n"], "limit": limit})
        bodies.append({"where": {"owner": owner}, "count": True, "limit": 0})

def query(base, body):
    request = urllib.request.Request(
        base + "/api/data/collections/tasks/query?workspace=default:drill",
        data=json.dumps(body).encode(),
        method="POST",
    )
    request.add_header("Authorization", "Bearer " + key)
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read())

bodies = bodies[:20]
mismatched = 0
for index, body in enumerate(bodies):
    if query(source, body) != query(restored, body):
        mismatched += 1
        print("MISMATCH", index, json.dumps(body, sort_keys=True))
print("PARITY_QUERIES=%d MISMATCHES=%d" % (len(bodies), mismatched))
sys.exit(0 if mismatched == 0 else 1)
PY

echo "== step 8: providers"
curl -sf -H "Authorization: Bearer $key" "$source_url/api/storage/providers" >"$DATA/providers.json" ||
  fail "the providers route failed"
python3 - "$DATA/providers.json" <<'PY' || fail "the providers report is wrong"
import json, sys

body = json.load(open(sys.argv[1]))
providers = body.get("providers", body)
s3 = providers.get("s3", {})
postgres = providers.get("postgres", {})
print("S3_STATUS=%s POSTGRES_STATUS=%s" % (s3.get("status"), postgres.get("status")))
if s3.get("status") not in ("available", "ok"):
    sys.exit(1)
if postgres.get("status") != "not_configured":
    sys.exit(1)
PY

echo "PASS offsite backup and restore drill"
