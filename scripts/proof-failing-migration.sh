#!/usr/bin/env bash
# WO-39: the upgrade rollback drill, end to end, with real releases.
#
# Reproduces what a managed upgrade does to one data directory, with the same
# environment a managed Engine boots with: the current release starts and gets
# data; it stops; the failing-migration test release starts on the same data
# (twice, as a supervisor restarting it would); then the current release starts
# again. Passes only when the test release never answers, the store keeps its
# migration counter, schema and data byte for byte (sqlite3 .dump), and the
# current release serves the data it had.
#
# Needs a clean commit (the test release names it), Elixir, sqlite3, curl,
# python3 and openssl. Builds both releases with MIX_ENV=prod and never touches
# a running Engine: it uses its own data directory and port.
#
# Usage: scripts/proof-failing-migration.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DATA="${DATA:-$(mktemp -d)}"
PORT="${PORT:-4231}"
URL="http://127.0.0.1:$PORT"
KEY="oe_$(openssl rand -hex 12)_$(openssl rand -hex 20)"
DB="$DATA/data/.optimal/engine.db"
# The Engine processes still running, and only those: a pid is cleared once its
# process has exited, so the exit trap never signals a pid another job reused.
CURRENT_PID=
FAILING_PID=

fail() {
  echo "FAIL $1"
  for log in "$DATA"/*.log; do
    [ -f "$log" ] && { echo "--- $log"; tail -25 "$log"; }
  done
  exit 1
}
cleanup() {
  for pid in "$CURRENT_PID" "$FAILING_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

# The managed Engine's environment (its boot script writes the same variables).
# Filled in once the keys exist; a release is started with `exec env`, so the
# recorded pid is the Engine itself.
ENGINE_ENV=()

api() { # method path [json]
  if [ $# -ge 3 ]; then
    curl -sf -X "$1" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" --data "$3" "$URL$2"
  else
    curl -sf -X "$1" -H "Authorization: Bearer $KEY" "$URL$2"
  fi
}

json() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

start_current() { # log
  (cd "$DATA/data" && exec env "${ENGINE_ENV[@]}" "$DATA/current/bin/optimal" start) >>"$DATA/$1" 2>&1 &
  CURRENT_PID=$!
  for _ in $(seq 1 120); do
    api GET /api/health >/dev/null 2>&1 && return 0
    if ! kill -0 "$CURRENT_PID" 2>/dev/null; then
      CURRENT_PID=
      fail "the current release exited during boot ($1)"
    fi
    sleep 1
  done
  fail "the current release did not answer /api/health within 120 s ($1)"
}

stop_current() {
  kill -TERM "$CURRENT_PID"
  for _ in $(seq 1 60); do
    if ! kill -0 "$CURRENT_PID" 2>/dev/null; then
      CURRENT_PID=
      return 0
    fi
    sleep 1
  done
  fail "the current release did not stop within 60 s"
}

dump_sha() {
  sqlite3 "$DB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
  sqlite3 "$DB" .dump | sha256sum | cut -d' ' -f1
}

ENGINE_ENV=(
  RELEASE_DISTRIBUTION=none
  OPTIMAL_API_ENABLED=true OPTIMAL_API_INTERFACE=127.0.0.1 OPTIMAL_API_PORT="$PORT"
  OPTIMAL_AUTH_REQUIRED=true OPTIMAL_RELEASE_CHANNEL=beta
  OPTIMAL_ENGINE_ROOT="$DATA/data" OPTIMAL_ENGINE_DB="$DB"
  OPTIMAL_ENGINE_CACHE="$DATA/data/.optimal/cache"
  OPTIMAL_KNOWLEDGE_ROCKSDB_PATH="$DATA/data/.optimal/knowledge-rocksdb"
  OPTIMAL_BACKUP_DIR="$DATA/data/.optimal/backups"
  OPTIMAL_BOOTSTRAP_KEY="$KEY" OPTIMAL_BOOTSTRAP_SCOPES='*'
  OPTIMAL_AUTHORITY_KEY="$(openssl rand -hex 32)" CONNECTOR_KEY="$(openssl rand -hex 32)"
)
SHA=$(git rev-parse HEAD)
mkdir -p "$DATA/data/.optimal"

echo "== step 1: the current release ($SHA)"
export MIX_ENV=prod
mix deps.get >/dev/null
OPTIMAL_ENGINE_GIT_SHA="$SHA" mix compile --force >"$DATA/build-current.log" 2>&1 ||
  fail "building the current release"
mix release optimal --overwrite --path "$DATA/current" >>"$DATA/build-current.log" 2>&1 ||
  fail "assembling the current release"

echo "== step 2: the failing-migration test release, built by its script"
scripts/build-failing-migration-release.sh "$DATA/failing-out" --mix >"$DATA/build-failing.log" 2>&1 ||
  fail "building the test release"
grep -E '^(built|identity|sha256) ' "$DATA/build-failing.log"
mkdir -p "$DATA/failing"
tar xzf "$DATA"/failing-out/optimal-engine-*-failing-migration-"$SHA".tgz -C "$DATA/failing"
(cd "$DATA/failing-out" && sha256sum -c SHA256SUMS) || fail "the archive does not match SHA256SUMS"

echo "== step 3: the current release serves data"
start_current current-1.log
current_version=$(api GET /api/version | json 'd["version"]')
current_migration=$(api GET /api/version | json 'd["expected_migration"]')
test_version=$(json 'd["version"]' <"$DATA/failing-out/identity.json")
test_migration=$(json 'd["expected_migration"]' <"$DATA/failing-out/identity.json")
[ "$test_version" = "$current_version-failing-migration" ] || fail "test release version $test_version"
[ "$test_migration" = "$((current_migration + 1))" ] || fail "test release migration $test_migration"

memory=$(api POST /api/memory/remember \
  "{\"content\": \"Rollback drill record $SHA\", \"workspace\": \"default\", \"force\": true}")
memory_id=$(printf '%s' "$memory" | json '(d.get("memory") or {}).get("id")')
[ -n "$memory_id" ] && [ "$memory_id" != None ] || fail "remember returned no id: $memory"
api GET "/api/memory/$memory_id?workspace=default" | grep -q "Rollback drill record $SHA" ||
  fail "the record is not readable before the upgrade"
stop_current

stored_before=$(sqlite3 "$DB" 'SELECT max(version) FROM schema_migrations')
[ "$stored_before" = "$current_migration" ] || fail "the store is at $stored_before, not $current_migration"
dump_before=$(dump_sha)

echo "== step 4: the test release starts on the same data, twice"
for attempt in 1 2; do
  (cd "$DATA/data" && exec env "${ENGINE_ENV[@]}" "$DATA/failing/optimal-engine/start-engine") \
    >"$DATA/failing-$attempt.log" 2>&1 &
  FAILING_PID=$!
  answered=0
  for _ in $(seq 1 180); do
    kill -0 "$FAILING_PID" 2>/dev/null || break
    code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/health" || true)
    case $code in 200 | 401) answered=1 ;; esac
    sleep 1
  done
  if kill -0 "$FAILING_PID" 2>/dev/null; then fail "attempt $attempt is still running after 180 s"; fi
  rc=0
  wait "$FAILING_PID" || rc=$?
  FAILING_PID=
  [ "$answered" = 0 ] || fail "attempt $attempt answered /api/health"
  [ "$rc" != 0 ] || fail "attempt $attempt exited 0"
  grep -q 'failing_migration_fails failed' "$DATA/failing-$attempt.log" ||
    fail "attempt $attempt did not fail on the failing migration"
  grep -q 'failed and was rolled back' "$DATA/failing-$attempt.log" ||
    fail "attempt $attempt did not roll the migration back"
  echo "attempt $attempt: exit $rc, never answered, failed on migration $test_migration and rolled it back"
done

echo "== step 5: the store is as it was"
stored_after=$(sqlite3 "$DB" 'SELECT max(version) FROM schema_migrations')
dump_after=$(dump_sha)
probe=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE name = 'failing_migration_probe'")
integrity=$(sqlite3 "$DB" 'PRAGMA integrity_check')
[ "$stored_after" = "$stored_before" ] || fail "the migration counter moved to $stored_after"
[ "$dump_after" = "$dump_before" ] || fail "the store changed: dump $dump_before became $dump_after"
[ "$probe" = 0 ] || fail "the failing migration's table survived"
[ "$integrity" = ok ] || fail "integrity_check: $integrity"

echo "== step 6: the current release starts again and serves the same data"
start_current current-2.log
[ "$(api GET /api/version | json 'd["version"]')" = "$current_version" ] || fail "the current release reports another version"
[ "$(api GET /api/version | json 'd["expected_migration"]')" = "$current_migration" ] ||
  fail "the current release expects another migration"
api GET "/api/memory/$memory_id?workspace=default" | grep -q "Rollback drill record $SHA" ||
  fail "the record is not readable after the rollback"
stop_current

crash_dumps=$(find "$DATA/data" -maxdepth 1 -name 'erl_crash.dump' | wc -l | tr -d ' ')

echo
echo "PROOF failing-migration rollback: PASS"
echo "  current release  $current_version, migration $current_migration, commit $SHA"
echo "  test release     $test_version, migration $test_migration: 2 boots, both exited non-zero, never answered"
echo "  store            migration $stored_before before and $stored_after after"
echo "  store dump       sha256 $dump_before before, $dump_after after"
echo "  probe table      absent; integrity_check $integrity"
echo "  record           $memory_id readable before and after"
echo "  residue          $crash_dumps erl_crash.dump in the working directory (the failed boots)"
