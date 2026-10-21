#!/usr/bin/env bash
# WO-43: seed a replica from a workspace bundle and catch up from the
# replication ledger without a full resync.
#
# Two Engines run on temporary data directories on this machine. Engine A gets
# a synthetic workspace (documents, chunks, vectors, edges, files) written while
# sync is enabled, so its whole history is in the ledger. A exports a bundle,
# which records `ledger_sequence` and `bundle_sha256`, and Engine B imports it
# through the raw upload route. B then registers A as a pull peer starting from
# that sequence, A writes more changes, and B catches up.
#
# Proves: the bundle's mark covers every change written before the export,
# including changes captured but not yet sealed; B pulls exactly A's ledger
# entries after the mark and none before it; the new changes arrive; and the
# workspace's documents, chunks, vectors, edges, and memories match row for row
# with the same vector bytes.
#
# SEED_MB (default 50) is the generated content in MiB; SEED_MB=2048 is the
# 2 GB run. CHANGES (default 25) is the number of writes after the snapshot and
# LATE (default 10) the number written just before the export. The run exits 77
# (skipped) when the data directory's disk has less free space than it needs.
# Both Engines and every file live under DATA (a new temporary directory unless
# given), which is removed at the end unless KEEP_DATA=1.
#
# Usage: SEED_MB=50 scripts/proof-seed.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SEED_MB="${SEED_MB:-50}"
CHANGES="${CHANGES:-25}"
LATE="${LATE:-10}"
A_PORT="${A_PORT:-4231}"
B_PORT="${B_PORT:-4232}"
# A data directory this run creates is removed at the end (KEEP_DATA=1 keeps it).
created_data=0
if [ -z "${DATA:-}" ]; then
  DATA=$(mktemp -d)
  created_data=1
fi
A_URL="http://127.0.0.1:$A_PORT"
B_URL="http://127.0.0.1:$B_PORT"

export MIX_ENV=dev
export OPTIMAL_AUTH_REQUIRED=true
export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"
export OPTIMAL_AUTHORITY_KEY="${OPTIMAL_AUTHORITY_KEY:-$(openssl rand -hex 32)}"
# Sync cycles run only when this proof asks for one, so every count is exact.
export OPTIMAL_SYNC_INTERVAL_MS=86400000
# Bundle staging stays inside the run's data directory.
export TMPDIR="$DATA/tmp"
mkdir -p "$TMPDIR" "$DATA/a/cache" "$DATA/b/cache"

started=$(date +%s)

fail() {
  echo "FAIL $1"
  for name in a b; do
    if [ -s "$DATA/rss-$name.log" ]; then echo "ENGINE_${name}_PEAK_RSS_MB=$(peak_mb "$DATA/rss-$name.log")"; fi
  done
  free -m 2>/dev/null | head -2 || true
  for log in a.log b.log; do
    if [ -f "$DATA/$log" ]; then
      echo "-- $log"
      tail -40 "$DATA/$log"
    fi
  done
  exit 1
}

# Samples an Engine's resident memory every 2 s into a file until it stops
# (run in the background); peak_mb prints the largest sample in MiB.
sample_rss() { # pid file
  while kill -0 "$1" 2>/dev/null; do
    ps -o rss= -p "$1" >>"$2" 2>/dev/null || true
    sleep 2
  done
}

peak_mb() { # file
  sort -n "$1" | tail -1 | awk '{printf "%d", $1 / 1024}'
}

# Runs a command with the environment of Engine a or b.
engine() {
  local name=$1
  shift
  env OPTIMAL_ENGINE_ROOT="$DATA/$name" OPTIMAL_ENGINE_DB="$DATA/$name/index.db" \
    OPTIMAL_ENGINE_CACHE="$DATA/$name/cache" "$@"
}

mint_root_key() { # engine name
  engine "$1" env OPTIMAL_API_ENABLED=false mix optimal.auth mint --name root --workspace '*' --json 2>/dev/null |
    grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# Starts Engine a or b and prints its pid once it answers /api/health. The
# Engine is the background process itself (no shell function in between), so
# the pid stops it. Fails when the port is already taken or the Engine exits.
start_engine() { # name port key
  local name=$1 port=$2 key=$3
  if curl -s -o /dev/null "http://127.0.0.1:$port/api/health"; then
    return 1
  fi
  OPTIMAL_ENGINE_ROOT="$DATA/$name" OPTIMAL_ENGINE_DB="$DATA/$name/index.db" \
    OPTIMAL_ENGINE_CACHE="$DATA/$name/cache" OPTIMAL_API_ENABLED=true OPTIMAL_API_PORT="$port" \
    mix run --no-halt >>"$DATA/$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 120); do
    kill -0 "$pid" 2>/dev/null || return 1
    if curl -sf -H "Authorization: Bearer $key" "http://127.0.0.1:$port/api/health" >/dev/null 2>&1; then
      echo "$pid"
      return 0
    fi
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  return 1
}

# Stops an Engine and waits until it has exited and its port is closed.
stop_engine() { # pid port
  local pid=$1 port=$2
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do
    if ! kill -0 "$pid" 2>/dev/null && ! curl -s -o /dev/null "http://127.0.0.1:$port/api/health"; then
      return 0
    fi
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
}

cleanup() {
  stop_engine "${a_pid:-}" "$A_PORT"
  stop_engine "${b_pid:-}" "$B_PORT"
  if [ "$created_data" = 1 ] && [ "${KEEP_DATA:-0}" != 1 ]; then
    rm -rf "$DATA"
  fi
}
trap cleanup EXIT

db_bytes() { # engine name
  python3 -c 'import os, sys; p = sys.argv[1]; print(sum(os.path.getsize(f) for f in (p, p + "-wal") if os.path.exists(f)))' \
    "$DATA/$1/index.db"
}

# One small HTTP client for every step: JSON in, JSON out, keys never printed.
cat >"$DATA/proofhttp.py" <<'PY'
import json, urllib.error, urllib.parse, urllib.request


def call(base, key, method, path, body=None, params=None, headers=None, timeout=3600):
    url = base + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Bearer " + key)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors="replace")[:500]


def ok(result, what, expected=(200, 201)):
    status, body = result
    if status not in expected:
        raise SystemExit("%s returned %s: %s" % (what, status, body))
    return body


def changes(base, key, workspace, since, until=None):
    """Every ledger entry after `since` (up to `until`), read the way a peer reads them."""
    entries = []
    while True:
        page = ok(
            call(base, key, "GET", "/api/sync/changes",
                 params={"workspace": workspace, "since": since, "limit": 2000},
                 headers={"x-optimal-replica": "proof-reader"}),
            "GET /api/sync/changes",
        )
        for mutation in page["mutations"]:
            if until is None or mutation["sequence"] <= until:
                entries.append(mutation)
        if not page["more"] or (until is not None and page["cursor"] >= until):
            return entries
        since = page["cursor"]
PY

echo "== step 1: room for the run"
avail_mb=$(df -Pm "$DATA" | awk 'NR == 2 {print $4}')
# Measured at SEED_MB=50: the source store is about 4.4 times the generated
# content (rows, indexes, and the ledger, whose payloads carry vectors as hex),
# the bundle 0.75 times, the replica 2 times, and the bundle unpacked for the
# import about 1.3 times. The import is the peak: 8.5 times, plus a margin.
need_mb=$((SEED_MB * 17 / 2 + 1024))
echo "SEED_MB=$SEED_MB FREE_MB=$avail_mb NEED_MB=$need_mb"
if [ "$avail_mb" -lt "$need_mb" ]; then
  echo "SKIP the disk holding $DATA has $avail_mb MiB free and this run needs about $need_mb MiB"
  exit 77
fi

echo "== step 2: keys"
a_key=$(mint_root_key a)
[ -n "$a_key" ] || fail "minting a key on Engine A printed no key"
b_key=$(mint_root_key b)
[ -n "$b_key" ] || fail "minting a key on Engine B printed no key"

echo "== step 3: Engine A, the workspace, sync enabled, a replica key"
a_pid=$(start_engine a "$A_PORT" "$a_key") || fail "Engine A did not answer /api/health"

python3 - "$DATA" "$A_URL" "$a_key" <<'PY' || fail "preparing the workspace on Engine A"
import json, sys
sys.path.insert(0, sys.argv[1])
from proofhttp import call, ok

data, base, key = sys.argv[1:4]
workspace = ok(call(base, key, "POST", "/api/workspaces", {"slug": "seed", "name": "Seed proof"}),
               "POST /api/workspaces")["id"]
ok(call(base, key, "POST", "/api/sync/enable", {"workspace": workspace}), "POST /api/sync/enable")
replica = ok(call(base, key, "POST", "/api/auth/keys",
                  {"name": "replica", "scopes": ["sync", "read"], "workspace_scope": [workspace]}),
             "POST /api/auth/keys")
with open(data + "/workspace", "w") as handle:
    handle.write(workspace)
with open(data + "/replica.key", "w") as handle:
    handle.write(replica["key"])
print("WORKSPACE=%s" % workspace)
PY
workspace=$(cat "$DATA/workspace")
stop_engine "$a_pid" "$A_PORT"

echo "== step 4: synthetic workspace on Engine A (stopped), captured and sealed"
engine a env OPTIMAL_API_ENABLED=false SEED_WORKSPACE="$workspace" SEED_MB="$SEED_MB" \
  mix run scripts/proof_seed_generate.exs >"$DATA/seed.out" 2>>"$DATA/a.log" ||
  { cat "$DATA/seed.out"; fail "generating the synthetic workspace"; }
grep '^SEED_' "$DATA/seed.out"
echo "A_DB_BYTES=$(db_bytes a)"

echo "== step 5: Engine A again; changes just before the export; the export"
a_pid=$(start_engine a "$A_PORT" "$a_key") || fail "Engine A did not answer /api/health after the seed"
sample_rss "$a_pid" "$DATA/rss-a.log" &
python3 - "$DATA" "$A_URL" "$a_key" "$workspace" "$LATE" <<'PY' || fail "exporting the bundle"
import json, sys, time, urllib.parse
sys.path.insert(0, sys.argv[1])
from proofhttp import call, changes, ok

data, base, key, workspace, late = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])

# Written right before the export: captured, not yet sealed into the ledger.
late_ids = []
for i in range(late):
    memory = ok(call(base, key, "POST", "/api/memory",
                     {"content": "Late change %d before the snapshot" % i, "workspace": workspace}),
                "POST /api/memory")
    late_ids.append(memory["id"])

started = time.time()
try:
    bundle = ok(call(base, key, "POST", "/api/workspaces/%s/bundle" % urllib.parse.quote(workspace, safe=""), {}),
                "POST /api/workspaces/:id/bundle")
except OSError as error:
    raise SystemExit("the export failed after %.0f s: %r" % (time.time() - started, error))
seconds = time.time() - started
mark = bundle["ledger_sequence"]
print("EXPORT_SECONDS=%.1f" % seconds)
print("BUNDLE_SHA256=%s" % bundle["bundle_sha256"])
print("BUNDLE_LEDGER_SEQUENCE=%d BUNDLE_TABLES=%d BUNDLE_ROWS=%d BUNDLE_FILES=%d"
      % (mark, bundle["tables"], bundle["rows"], bundle["files"]))

# Everything written before the export is at or below the mark: none of the
# late changes may be among the ledger entries after it.
after = changes(base, key, workspace, mark)
late_after = [m for m in after if m["entity_type"] == "memories" and m["entity_id"] in late_ids]
print("LATE_WRITES=%d LATE_ENTRIES_AFTER_MARK=%d" % (len(late_ids), len(late_after)))
json.dump({"bundle": bundle, "late_ids": late_ids}, open(data + "/export.json", "w"))
if late_after:
    raise SystemExit("the bundle's mark misses %d ledger entries written before the export" % len(late_after))
PY
echo "ENGINE_A_PEAK_RSS_MB=$(peak_mb "$DATA/rss-a.log")"
bundle=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["bundle"]["bundle"])' "$DATA/export.json")
mark=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["bundle"]["ledger_sequence"])' "$DATA/export.json")

echo "== step 6: download the bundle and import it on Engine B"
t0=$(date +%s.%N)
code=$(curl -sS -o "$DATA/bundle.tar.gz" -w '%{http_code}' -H "Authorization: Bearer $a_key" \
  "$A_URL/api/bundles/$bundle") || fail "downloading the bundle"
[ "$code" = 200 ] || fail "downloading the bundle returned $code"
t1=$(date +%s.%N)
bundle_bytes=$(wc -c <"$DATA/bundle.tar.gz" | tr -d ' ')
echo "BUNDLE_BYTES=$bundle_bytes"
# The source's copy is not needed again; removing it keeps the run's disk use down.
rm -f "$DATA/a/backups/bundles/$bundle"
python3 -c 'import sys; print("DOWNLOAD_SECONDS=%.1f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$t0" "$t1"

b_pid=$(start_engine b "$B_PORT" "$b_key") || fail "Engine B did not answer /api/health"
sample_rss "$b_pid" "$DATA/rss-b.log" &
t0=$(date +%s.%N)
code=$(curl -sS -X POST -T "$DATA/bundle.tar.gz" -H "Content-Type: application/gzip" -H "Expect:" \
  -H "Authorization: Bearer $b_key" -o "$DATA/import.json" -w '%{http_code}' \
  "$B_URL/api/bundles/import") || fail "uploading the bundle to Engine B"
t1=$(date +%s.%N)
[ "$code" = 201 ] || { head -c 600 "$DATA/import.json"; fail "the import returned $code"; }
python3 -c 'import sys; print("IMPORT_SECONDS=%.1f" % (float(sys.argv[2]) - float(sys.argv[1])))' "$t0" "$t1"
echo "ENGINE_B_PEAK_RSS_MB=$(peak_mb "$DATA/rss-b.log")"
echo "B_DB_BYTES_AFTER_IMPORT=$(db_bytes b)"
rm -f "$DATA/bundle.tar.gz"

python3 - "$DATA" "$B_URL" "$b_key" <<'PY' || fail "the import does not match the export"
import json, sys
sys.path.insert(0, sys.argv[1])
from proofhttp import call

data, base, key = sys.argv[1:4]
exported = json.load(open(data + "/export.json"))
bundle = exported["bundle"]
summary = json.load(open(data + "/import.json"))
rows = sum(summary["rows"].values())
print("IMPORT_ROWS=%d IMPORT_TABLES=%d IMPORT_FILES=%d" % (rows, len(summary["rows"]), summary["files"]))
problems = []
if summary["bundle_sha256"] != bundle["bundle_sha256"]:
    problems.append("bundle_sha256 differs")
if rows != bundle["rows"]:
    problems.append("rows %d != exported %d" % (rows, bundle["rows"]))
if summary["files"] != bundle["files"]:
    problems.append("files %d != exported %d" % (summary["files"], bundle["files"]))
present = sum(1 for memory_id in exported["late_ids"]
              if call(base, key, "GET", "/api/memory/" + memory_id)[0] == 200)
print("LATE_WRITES_ON_B_AFTER_IMPORT=%d" % present)
if present != len(exported["late_ids"]):
    problems.append("the late changes are not all in the imported workspace")
if problems:
    raise SystemExit("; ".join(problems))
PY

echo "== step 7: $CHANGES changes on Engine A after the snapshot"
python3 - "$DATA" "$A_URL" "$a_key" "$workspace" "$CHANGES" <<'PY' || fail "writing changes on Engine A"
import json, sys
sys.path.insert(0, sys.argv[1])
from proofhttp import call, ok

data, base, key, workspace, count = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
written = {}
for i in range(count):
    content = "Change %d after the snapshot" % i
    memory = ok(call(base, key, "POST", "/api/memory", {"content": content, "workspace": workspace}),
                "POST /api/memory")
    written[memory["id"]] = content
status = ok(call(base, key, "GET", "/api/sync/status", params={"workspace": workspace}), "GET /api/sync/status")
json.dump({"written": written, "ledger_sequence": status["ledger_sequence"]}, open(data + "/changes.json", "w"))
print("CHANGES_WRITTEN=%d A_LEDGER_SEQUENCE=%d" % (len(written), status["ledger_sequence"]))
PY

echo "== step 8: Engine B pulls from Engine A, starting at the bundle's mark"
python3 - "$DATA" "$A_URL" "$B_URL" "$b_key" "$workspace" "$mark" <<'PY' || fail "catching up"
import json, sys, time
sys.path.insert(0, sys.argv[1])
from proofhttp import call, ok

data, a_url, b_url, key, workspace, mark = sys.argv[1:7]
mark = int(mark)
replica_key = open(data + "/replica.key").read().strip()
target = json.load(open(data + "/changes.json"))["ledger_sequence"]

ok(call(b_url, key, "POST", "/api/sync/peers",
        {"workspace": workspace, "url": a_url, "api_key": replica_key, "policy": "pull", "since": mark}),
   "POST /api/sync/peers")

started = time.time()
applied, failed, conflicts, cycles, cursor, skipped = 0, 0, 0, 0, mark, {}
while cursor < target and cycles < 100:
    results = ok(call(b_url, key, "POST", "/api/sync/run", {}), "POST /api/sync/run")["results"]
    cycles += 1
    pulled = [r for r in results if r.get("workspace_id") == workspace]
    if not pulled or "ok" not in pulled[0]["pull"]:
        raise SystemExit("the pull failed: %s" % json.dumps(pulled)[:600])
    page = pulled[0]["pull"]["ok"]
    applied += page["applied"]
    failed += len(page["failed"])
    conflicts += page["conflicts"]
    for reason, n in page["skipped"].items():
        skipped[reason] = skipped.get(reason, 0) + n
    if page["cursor"] == cursor and page["applied"] == 0:
        break
    cursor = page["cursor"]
seconds = time.time() - started
print("CATCHUP_SECONDS=%.1f CATCHUP_CYCLES=%d" % (seconds, cycles))
print("PULLED_APPLIED=%d PULLED_SKIPPED=%s PULLED_FAILED=%d PULLED_CONFLICTS=%d CURSOR=%d A_TARGET=%d"
      % (applied, json.dumps(skipped, sort_keys=True), failed, conflicts, cursor, target))
json.dump({"applied": applied, "failed": failed, "conflicts": conflicts, "cursor": cursor,
           "skipped": skipped, "seconds": seconds},
          open(data + "/catchup.json", "w"))
if cursor < target:
    raise SystemExit("Engine B stopped at %d before Engine A's %d" % (cursor, target))
PY

echo "== step 9: exactly the changes after the mark, nothing before it, same rows"
python3 - "$DATA" "$A_URL" "$B_URL" "$a_key" "$b_key" "$workspace" "$mark" <<'PY' || fail "the replica differs"
import hashlib, json, sqlite3, sys
sys.path.insert(0, sys.argv[1])
from proofhttp import call, changes, ok

data, a_url, b_url, a_key, b_key, workspace, mark = sys.argv[1:8]
mark = int(mark)
catchup = json.load(open(data + "/catchup.json"))
written = json.load(open(data + "/changes.json"))["written"]
problems = []

a_replica = ok(call(a_url, a_key, "GET", "/api/sync/status", params={"workspace": workspace}),
               "GET /api/sync/status")["replica_id"]
expected = changes(a_url, a_key, workspace, mark, catchup["cursor"])
on_b = changes(b_url, b_key, workspace, 0)
expected_ids = {m["id"] for m in expected}
b_ids = {m["id"] for m in on_b if m["device_id"] == a_replica}
print("EXPECTED_ENTRIES=%d B_LEDGER_ENTRIES_FROM_A=%d B_OWN_ENTRIES=%d"
      % (len(expected_ids), len(b_ids), len(on_b) - len(b_ids)))
if expected_ids != b_ids:
    problems.append("B's ledger differs from A's entries after the mark: %d missing, %d extra"
                    % (len(expected_ids - b_ids), len(b_ids - expected_ids)))
if catchup["applied"] != len(expected_ids):
    problems.append("applied %d, expected %d" % (catchup["applied"], len(expected_ids)))
if catchup["failed"] or catchup["conflicts"]:
    problems.append("%d failed and %d conflicts" % (catchup["failed"], catchup["conflicts"]))

memories = {m["entity_id"] for m in expected if m["entity_type"] == "memories"}
missing = [i for i in written if i not in memories]
if missing:
    problems.append("%d changes are not in A's ledger after the mark" % len(missing))
arrived = 0
for memory_id, content in written.items():
    status, body = call(b_url, b_key, "GET", "/api/memory/" + memory_id)
    if status == 200 and body.get("content") == content:
        arrived += 1
print("CHANGES_ON_B=%d of %d" % (arrived, len(written)))
if arrived != len(written):
    problems.append("only %d of %d changes arrived on B" % (arrived, len(written)))

def connect(name):
    return sqlite3.connect("file:%s/%s/index.db?mode=ro" % (data, name), uri=True)

a_db, b_db = connect("a"), connect("b")
(before_mark,) = a_db.execute(
    "SELECT COUNT(*) FROM sync_mutations WHERE workspace_id = ? AND sequence <= ?", (workspace, mark)).fetchone()
print("A_LEDGER_ENTRIES_AT_MARK=%d PULLED=%d" % (before_mark, len(b_ids)))
if before_mark <= len(b_ids):
    problems.append("the seed's ledger (%d) is not larger than what was pulled (%d)" % (before_mark, len(b_ids)))

digests = {
    "contexts": "SELECT id, title, content FROM contexts WHERE workspace_id = ? ORDER BY id",
    "chunks": "SELECT id, text FROM chunks WHERE workspace_id = ? ORDER BY id",
    "chunk_embeddings": "SELECT chunk_id, vector FROM chunk_embeddings WHERE workspace_id = ? ORDER BY chunk_id",
    "vectors": "SELECT context_id, embedding FROM vectors WHERE workspace_id = ? ORDER BY context_id",
    "edges": "SELECT source_id, target_id, relation, weight FROM edges WHERE workspace_id = ? ORDER BY source_id, target_id, relation",
    "memories": "SELECT id, content FROM memories WHERE workspace_id = ? ORDER BY id",
}
for table, sql in digests.items():
    summary = []
    for db in (a_db, b_db):
        digest, count = hashlib.sha256(), 0
        for row in db.execute(sql, (workspace,)):
            count += 1
            for value in row:
                digest.update(value if isinstance(value, bytes) else repr(value).encode())
                digest.update(b"\x00")
        summary.append((count, digest.hexdigest()))
    same = summary[0] == summary[1]
    print("PARITY %s A=%d B=%d %s" % (table, summary[0][0], summary[1][0], "same" if same else "DIFFERENT"))
    if not same:
        problems.append("%s differs" % table)

if problems:
    raise SystemExit("; ".join(problems))
PY

echo "B_DB_BYTES=$(db_bytes b)"
echo "TOTAL_SECONDS=$(($(date +%s) - started))"
echo "PASS seed a replica from a bundle and catch up from its ledger mark"
