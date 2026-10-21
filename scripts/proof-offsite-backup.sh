#!/usr/bin/env bash
# WO-31: the offsite backup and restore drill on real object storage.
#
# Needs an S3 credential and bucket for this run, supplied at `.gate-secrets/s3-proof.env`
# or the file SECRETS names (an overlay for the gate machine; `.gate-secrets/` is
# ignored by git). The file exports
# S3_ENDPOINT, S3_BUCKET, S3_REGION, S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY.
#
# Proves, in order: an online backup with PRAGMA integrity_check that ships an
# encrypted object and verifies its checksums; the object is listed back from
# the bucket; a restore of that object into a second data directory; 20-query
# parity between the source and the restored store; and the providers report.
#
# Then the fallback: the source Engine restarts with its S3 endpoint on a dead
# port and assets set to S3. An asset written then lands on the local disk with
# its fallback reason recorded and raises an alert (an error log line and the
# `optimal_engine.storage.asset_fallback` counter), and a probed providers
# report shows s3 unreachable. With the endpoint restored, s3 probes healthy
# and the next asset lands in the bucket.
#
# Usage: scripts/proof-offsite-backup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SECRETS="${SECRETS:-$ROOT/.gate-secrets/s3-proof.env}"
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
# The mix tasks run without the HTTP API; only start_engine serves one, on its own port.
export OPTIMAL_API_ENABLED=false
export OPTIMAL_AUTH_REQUIRED=true
export OPTIMAL_ENGINE_ROOT="$DATA/root"
export OPTIMAL_ENGINE_DB="$DATA/root/index.db"
export OPTIMAL_ENGINE_CACHE="$DATA/root/cache"
export OPTIMAL_S3_ENDPOINT="$S3_ENDPOINT"
export OPTIMAL_S3_BUCKET="$S3_BUCKET"
export OPTIMAL_S3_REGION="${S3_REGION:-us-east-1}"
export OPTIMAL_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export OPTIMAL_S3_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export OPTIMAL_S3_PREFIX="${S3_PREFIX:-offsite-proof/}"
# A trace logs every signed request's endpoint, bucket, canonical request and
# signature to the server log, which a failure tails; turn it on only to debug
# a rejected signature.
export OPTIMAL_S3_TRACE="${OPTIMAL_S3_TRACE:-0}"
export OPTIMAL_BACKUP_KEY="${OPTIMAL_BACKUP_KEY:-$(openssl rand -hex 32)}"
export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"
export OPTIMAL_AUTHORITY_KEY="${OPTIMAL_AUTHORITY_KEY:-$(openssl rand -hex 32)}"

mkdir -p "$OPTIMAL_ENGINE_ROOT" "$OPTIMAL_ENGINE_CACHE"

fail() {
  echo "FAIL $1"
  if [ -f "$DATA/server.log" ]; then tail -30 "$DATA/server.log"; fi
  if [ -f "$DATA/restored.log" ]; then tail -20 "$DATA/restored.log"; fi
  for log in outage.log recovered.log; do
    if [ -f "$DATA/$log" ]; then tail -20 "$DATA/$log"; fi
  done
  exit 1
}

# Stops an Engine and waits until it has exited and its port is closed.
stop_engine() { # pid port
  local pid=$1 port=$2
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do
    if ! kill -0 "$pid" 2>/dev/null && ! curl -s -o /dev/null "http://127.0.0.1:$port/api/health"; then
      return 0
    fi
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
}

start_engine() { # port, log, root
  local port=$1 log=$2 root=${3:-$OPTIMAL_ENGINE_ROOT}
  OPTIMAL_ENGINE_ROOT="$root" OPTIMAL_ENGINE_DB="$root/index.db" \
    OPTIMAL_ENGINE_CACHE="$root/cache" OPTIMAL_API_ENABLED=true OPTIMAL_API_PORT="$port" \
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
objects=$(grep -cF "${OPTIMAL_S3_PREFIX}backups/" "$DATA/objects.log" || true)
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
by_id = {provider.get("id"): provider for provider in body.get("providers", [])}
s3 = by_id.get("s3", {})
postgres = by_id.get("postgres", {})
print(
    "S3_CONFIGURED=%s S3_HEALTH=%s POSTGRES_HEALTH=%s"
    % (s3.get("configured"), s3.get("health"), postgres.get("health"))
)
if s3.get("configured") is not True or s3.get("health") not in ("healthy", "configured"):
    sys.exit(1)
if postgres.get("health") != "not_configured":
    sys.exit(1)
PY

echo "== step 9: the S3 endpoint goes dead; the next asset falls back and raises an alert"
stop_engine "$source_pid" "$SOURCE_PORT"
dead_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
echo "DEAD_ENDPOINT_PORT=$dead_port"
real_endpoint="$OPTIMAL_S3_ENDPOINT"
export OPTIMAL_ASSET_STORAGE=s3
# The Engine tries to place assets kept on disk every two seconds (step 11).
export OPTIMAL_ASSET_RECONCILE_INTERVAL_MS=2000
export OPTIMAL_S3_ENDPOINT="http://127.0.0.1:$dead_port"
source_pid=$(start_engine "$SOURCE_PORT" "$DATA/outage.log" "$OPTIMAL_ENGINE_ROOT") ||
  fail "the Engine did not start with the dead endpoint"

python3 - "$source_url" "$key" "$DATA/outage-asset.json" <<'PY' || fail "the outage write did not fall back with an alert"
import base64, hashlib, json, os, sys, urllib.request

base, key, out = sys.argv[1], sys.argv[2], sys.argv[3]

def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(base + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + key)
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.status, json.loads(response.read())

payload = b"asset written while the object store is unreachable\n" * 64
digest = hashlib.sha256(payload).hexdigest()
status, body = call("POST", "/api/assets", {
    "filename": "outage.txt",
    "content_base64": base64.b64encode(payload).decode(),
    "workspace": "default",
})
asset = body["asset"]
metadata = asset.get("metadata") or {}
path = asset.get("storage_path") or ""
on_disk = os.path.isfile(path) and hashlib.sha256(open(path, "rb").read()).hexdigest() == digest
print("OUTAGE_WRITE_STATUS=%d STORAGE_BACKEND=%s FALLBACK_REASON=%s LOCAL_COPY_MATCHES=%s"
      % (status, metadata.get("storage_backend"), metadata.get("storage_fallback_reason"), on_disk))

_, metrics = call("GET", "/api/metrics")
fallbacks = metrics.get("counters", {}).get("optimal_engine.storage.asset_fallback")
pending = metrics.get("gauges", {}).get("optimal_engine_storage_assets_pending_placement")
print("ALERT_COUNTER=%s PENDING_PLACEMENT=%s" % (fallbacks, pending))

_, probed = call("GET", "/api/storage/providers?probe=1")
s3 = {p["id"]: p for p in probed["providers"]}["s3"]
_, listed = call("GET", "/api/storage/providers")
unprobed = {p["id"]: p for p in listed["providers"]}["s3"]
print("S3_PROBED_HEALTH=%s S3_PROBED_STATE=%s S3_UNPROBED_HEALTH=%s"
      % (s3.get("health"), s3.get("lifecycle_state"), unprobed.get("health")))

json.dump({"path": path, "sha256": digest}, open(out, "w"))
checks = [
    status == 201,
    not path.startswith("s3://"),
    on_disk,
    metadata.get("storage_backend") == "filesystem",
    metadata.get("storage_fallback_reason") == "s3_upload_failed",
    fallbacks == 1,
    pending == 1,
    s3.get("health") == "unreachable",
]
sys.exit(0 if all(checks) else 1)
PY

alerts=$(grep -c "asset storage alert" "$DATA/outage.log" || true)
echo "ALERT_LOG_LINES=$alerts"
[ "$alerts" -ge 1 ] || fail "no asset storage alert in the Engine log"
grep -m1 "asset storage alert" "$DATA/outage.log" | sed 's/key=[^ ]*/key=<object key>/'

echo "== step 10: the endpoint is back; s3 probes healthy and the next asset lands in the bucket"
stop_engine "$source_pid" "$SOURCE_PORT"
export OPTIMAL_S3_ENDPOINT="$real_endpoint"
source_pid=$(start_engine "$SOURCE_PORT" "$DATA/recovered.log" "$OPTIMAL_ENGINE_ROOT") ||
  fail "the Engine did not start with the endpoint restored"

python3 - "$source_url" "$key" "$DATA/outage-asset.json" <<'PY' || fail "the Engine did not recover"
import base64, hashlib, json, os, sys, urllib.request

base, key, previous = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))

def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(base + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + key)
    request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.status, json.loads(response.read())

_, probed = call("GET", "/api/storage/providers?probe=1")
s3 = {p["id"]: p for p in probed["providers"]}["s3"]
print("S3_PROBED_HEALTH=%s S3_PROBED_STATE=%s" % (s3.get("health"), s3.get("lifecycle_state")))

payload = b"asset written after the object store came back\n" * 64
status, body = call("POST", "/api/assets", {
    "filename": "recovered.txt",
    "content_base64": base64.b64encode(payload).decode(),
    "workspace": "default",
})
asset = body["asset"]
metadata = asset.get("metadata") or {}
in_bucket = str(asset.get("storage_path", "")).startswith("s3://")
checksum_matches = metadata.get("object_checksum_sha256") == hashlib.sha256(payload).hexdigest()
kept = (os.path.isfile(previous["path"]) and
        hashlib.sha256(open(previous["path"], "rb").read()).hexdigest() == previous["sha256"])
print("RECOVERED_WRITE_STATUS=%d STORAGE_BACKEND=%s IN_BUCKET=%s OBJECT_CHECKSUM_MATCHES=%s FALLBACK_REASON=%s"
      % (status, metadata.get("storage_backend"), in_bucket, checksum_matches,
         metadata.get("storage_fallback_reason")))
print("OUTAGE_ASSET_KEPT_LOCALLY=%s" % kept)
checks = [
    s3.get("health") == "healthy",
    status == 201,
    metadata.get("storage_backend") == "s3",
    in_bucket,
    checksum_matches,
    "storage_fallback_reason" not in metadata,
    kept,
]
sys.exit(0 if all(checks) else 1)
PY

echo "== step 11: the asset kept on disk during the outage is placed in the bucket"
python3 - "$source_url" "$key" <<'PY' || fail "the outage asset was not placed"
import json, sys, time, urllib.request

base, key = sys.argv[1], sys.argv[2]

def pending():
    request = urllib.request.Request(base + "/api/metrics")
    request.add_header("Authorization", "Bearer " + key)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read()).get("gauges", {}).get("optimal_engine_storage_assets_pending_placement")

started = time.time()
left = pending()
while left != 0 and time.time() - started < 120:
    time.sleep(2)
    left = pending()
print("PENDING_PLACEMENT_AFTER_RECOVERY=%s PLACED_WITHIN_SECONDS=%.0f" % (left, time.time() - started))
sys.exit(0 if left == 0 else 1)
PY
stop_engine "$source_pid" "$SOURCE_PORT"
# Every object under the Engine's prefix, assets included (the backup listing
# above covers backups/ only).
mix run -e '{:ok, listing} = OptimalEngine.Storage.S3.list_objects(nil, max_pages: 20); Enum.each(listing.keys, &IO.puts/1)' \
  >"$DATA/objects-after.log" 2>&1 ||
  { cat "$DATA/objects-after.log"; fail "listing the bucket failed"; }
outage_sha=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["sha256"])' "$DATA/outage-asset.json")
in_bucket=$(grep -c "$outage_sha" "$DATA/objects-after.log" || true)
echo "OUTAGE_ASSET_IN_BUCKET=$([ "$in_bucket" -ge 1 ] && echo True || echo False)"
[ "$in_bucket" -ge 1 ] || fail "the bucket holds no object for the outage asset"
grep -c "placed in the object store" "$DATA/recovered.log" | sed 's/^/PLACED_LOG_LINES=/'

echo "PASS offsite backup and restore drill, S3 fallback, recovery and placement of the outage asset"
