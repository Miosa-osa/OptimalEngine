#!/usr/bin/env bash
# WO-39: the upgrade rollback drill, end to end, with real releases.
#
# Reproduces what a managed upgrade does to one data directory, with the same
# start script (deploy/miosa-template/start-engine) and environment a managed
# Engine boots with. The current release starts and gets data, then stops.
#
#   Case A: the failing-migration test release starts on that data twice, as a
#   supervisor restarting it would. Passes when it never answers and the store
#   keeps its migration counter, schema and data: the same `sqlite3 .dump` and
#   the same schema rows before and after.
#
#   Case B: with a backup taken first (VACUUM INTO, as a managed upgrade does),
#   the passing-then-failing test release starts twice. Passes when it never
#   answers, its passing migration (9000001) stays applied while the failing
#   one leaves nothing, the previous release opens that unrestored store and
#   its storage audit reports the migration drift, and restoring the backup
#   brings back the store: the same schema rows, the same .dump line by line,
#   and every full-text row joined to its base row.
#
# Every .dump keeps the hidden rowids (--preserve-rowids): contexts, memories
# and source_packages have text keys, and their full-text rows hang on the
# rowid. VACUUM INTO writes a virtual table's schema row after the ordinary
# tables, so a copy's .dump has the same lines in another order; the schema
# rows, compared exactly, catch what a line comparison cannot, such as a
# column moved between tables.
#
# Then the current release starts again, serves the record it had and finds
# the document it had. No crash dump may land in the data directory.
#
# Needs a clean commit (the test releases name it), Elixir, sqlite3, curl,
# python3 and openssl. Builds every release with MIX_ENV=prod and never touches a
# running Engine: it uses its own data directory and port, and removes the data
# directory when it finishes (KEEP_DATA=1 keeps it).
#
# Usage: scripts/proof-failing-migration.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -n "${DATA:-}" ]; then OWN_DATA=0; else OWN_DATA=1 DATA=$(mktemp -d); fi
PORT="${PORT:-4231}"
URL="http://127.0.0.1:$PORT"
KEY="oe_$(openssl rand -hex 12)_$(openssl rand -hex 20)"
DB="$DATA/data/.optimal/engine.db"
SENTINEL=failing-migration-sentinel
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
  if [ "$OWN_DATA" = 1 ] && [ "${KEEP_DATA:-0}" != 1 ]; then rm -rf "$DATA"; fi
}
trap cleanup EXIT

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}
pad() { printf '%03d' "$1"; }
sql() { sqlite3 "$DB" "$1"; }

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

api() { # method path [json]
  if [ $# -ge 3 ]; then
    curl -sf -X "$1" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" --data "$3" "$URL$2"
  else
    curl -sf -X "$1" -H "Authorization: Bearer $KEY" "$URL$2"
  fi
}

json() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

# A release runs from the data directory, as the managed unit does.
boot() { # release-dir log
  (cd "$DATA/data" && exec env "${ENGINE_ENV[@]}" "$1/start-engine") >>"$DATA/$2" 2>&1 &
}

start_current() { # log
  boot "$DATA/current" "$1"
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

# Boots a test release twice and requires each boot to exit non-zero without
# ever answering, failing on migration `failing` and rolling it back.
boot_test_release() { # release-dir name failing
  for attempt in 1 2; do
    boot "$1" "$2-$attempt.log"
    FAILING_PID=$!
    answered=0
    for _ in $(seq 1 180); do
      kill -0 "$FAILING_PID" 2>/dev/null || break
      code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/health" || true)
      case $code in 200 | 401) answered=1 ;; esac
      sleep 1
    done
    if kill -0 "$FAILING_PID" 2>/dev/null; then fail "$2 attempt $attempt is still running after 180 s"; fi
    rc=0
    wait "$FAILING_PID" || rc=$?
    FAILING_PID=
    [ "$answered" = 0 ] || fail "$2 attempt $attempt answered /api/health"
    [ "$rc" != 0 ] || fail "$2 attempt $attempt exited 0"
    grep -q "migration $(pad "$3") failed and was rolled back" "$DATA/$2-$attempt.log" ||
      fail "$2 attempt $attempt did not fail on migration $3 with a rollback"
    grep -q 'failing_migration_fails' "$DATA/$2-$attempt.log" ||
      fail "$2 attempt $attempt did not fail on the failing migration's statement"
    echo "$2 attempt $attempt: exit $rc, never answered, migration $(pad "$3") failed and was rolled back"
  done
}

# Writes a store's logical content to a file: its `sqlite3 .dump`, with the
# hidden rowids.
dump_to() { # db file
  sqlite3 "$1" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
  sqlite3 "$1" '.dump --preserve-rowids' >"$2"
}

# Takes a store's .dump and its schema rows as <name>.dump and <name>.schema.
snapshot() { # db name
  dump_to "$1" "$DATA/$2.dump"
  sqlite3 "$1" 'SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name' >"$DATA/$2.schema"
}

file_sha() { sha256 <"$1" | cut -d' ' -f1; }

# Fails, with the first differences, when two files differ; --any-order
# compares them line by line regardless of order.
same_lines() { # label before after [--any-order]
  local before=$2 after=$3
  if [ "${4:-}" = --any-order ]; then
    LC_ALL=C sort "$2" >"$2.sorted"
    LC_ALL=C sort "$3" >"$3.sorted"
    before=$2.sorted after=$3.sorted
  fi
  cmp -s "$before" "$after" && return 0
  echo "--- $1: differences (first 40 lines)" >&2
  diff "$before" "$after" | head -40 >&2 || true
  fail "$1 differ"
}

# The same schema rows exactly, and the same .dump (line by line with --any-order).
same_store() { # label before after [--any-order]
  same_lines "$1: the schema rows" "$DATA/$2.schema" "$DATA/$3.schema"
  same_lines "$1: the .dump lines" "$DATA/$2.dump" "$DATA/$3.dump" "${4:-}"
}

# No full-text row without its base row (by rowid, with the same id or
# content), and no base row without its full-text row.
fts_joined() { # label
  local unjoined
  unjoined=$(sql "SELECT
    (SELECT count(*) FROM contexts_fts f LEFT JOIN contexts c ON c.rowid = f.rowid
       WHERE c.rowid IS NULL OR c.id IS NOT f.id),
    (SELECT count(*) FROM contexts c LEFT JOIN contexts_fts f ON f.rowid = c.rowid WHERE f.rowid IS NULL),
    (SELECT count(*) FROM memories_fts f LEFT JOIN memories m ON m.rowid = f.rowid
       WHERE m.rowid IS NULL OR m.content IS NOT f.content),
    (SELECT count(*) FROM memories m LEFT JOIN memories_fts f ON f.rowid = m.rowid WHERE f.rowid IS NULL)")
  [ "$unjoined" = "0|0|0|0" ] ||
    fail "$1: unjoined full-text rows (contexts_fts, contexts, memories_fts, memories): $unjoined"
}

# The storage audit's migrations check: "ok", or its detail.
audit_migrations() {
  curl -s --max-time 120 -H "Authorization: Bearer $KEY" "$URL/api/stores/audit" |
    json 'next(("ok" if c["ok"] else c["detail"]) for c in d["checks"] if c["name"] == "migrations")'
}

# True when /api/search finds the seeded document, within 15 s.
search_finds() { # query document-id
  for _ in $(seq 1 15); do
    if api GET "/api/search?q=$1&workspace=default" >"$DATA/search.json" &&
      python3 -c '
import json, sys
results = json.load(open(sys.argv[1])).get("results") or []
text = lambda r: (r.get("title") or "") + " " + (r.get("content") or "")
sys.exit(0 if any(r.get("id") == sys.argv[3] or sys.argv[2] in text(r) for r in results) else 1)
' "$DATA/search.json" "$1" "$2"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

table_count() { sql "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '$1'"; }

SHA=$(git rev-parse HEAD)
mkdir -p "$DATA/data/.optimal"

echo "== step 1: the current release ($SHA)"
export MIX_ENV=prod
mix deps.get >/dev/null
env -u OPTIMAL_BUILD_FAILING_MIGRATION OPTIMAL_ENGINE_GIT_SHA="$SHA" mix compile --force \
  >"$DATA/build-current.log" 2>&1 || fail "building the current release"
env -u OPTIMAL_BUILD_FAILING_MIGRATION mix release optimal --overwrite --path "$DATA/current" \
  >>"$DATA/build-current.log" 2>&1 || fail "assembling the current release"
install -m 0755 deploy/miosa-template/start-engine "$DATA/current/start-engine"

echo "== step 2: the two test releases, built by their script"
for variant in failing passing-first; do
  flags=(--mix)
  [ "$variant" = passing-first ] && flags+=(--passing-first)
  scripts/build-failing-migration-release.sh "$DATA/$variant-out" "${flags[@]}" \
    >"$DATA/build-$variant.log" 2>&1 || fail "building the $variant test release"
  grep -E '^(built|identity|sha256) ' "$DATA/build-$variant.log"
  (cd "$DATA/$variant-out" && sha256 -c SHA256SUMS >/dev/null) || fail "the $variant archive does not match SHA256SUMS"
  mkdir -p "$DATA/$variant"
  tar xzf "$DATA/$variant-out"/optimal-engine-*-"$SHA".tgz -C "$DATA/$variant"
done

echo "== step 3: the current release serves data"
start_current current-1.log
current_version=$(api GET /api/version | json 'd["version"]')
current_migration=$(api GET /api/version | json 'd["expected_migration"]')
failing_version=$(json 'd["version"]' <"$DATA/failing-out/identity.json")
failing_migration=$(json 'd["expected_migration"]' <"$DATA/failing-out/identity.json")
passing_version=$(json 'd["version"]' <"$DATA/passing-first-out/identity.json")
passing_migration=$(json 'd["expected_migration"]' <"$DATA/passing-first-out/identity.json")
[ "$failing_version" = "$current_version-failing-migration" ] || fail "test release version $failing_version"
[ "$failing_migration" = 9000001 ] || fail "test release migration $failing_migration, not the reserved 9000001"
[ "$passing_version" = "$current_version-passing-then-failing-migration" ] || fail "test release version $passing_version"
[ "$passing_migration" = 9000002 ] || fail "test release migration $passing_migration, not the reserved 9000002"

memory=$(api POST /api/memory/remember \
  "{\"content\": \"Rollback drill record $SHA\", \"workspace\": \"default\", \"force\": true}")
memory_id=$(printf '%s' "$memory" | json '(d.get("memory") or {}).get("id")')
[ -n "$memory_id" ] && [ "$memory_id" != None ] || fail "remember returned no id: $memory"
api GET "/api/memory/$memory_id?workspace=default" | grep -q "Rollback drill record $SHA" ||
  fail "the record is not readable before the upgrade"
# A document, for the full-text rows of contexts and a search after the rollback.
marker="drilldoc$(printf '%s' "$SHA" | cut -c1-12)"
document=$(api POST /api/ingest \
  "{\"text\": \"Rollback drill document $marker, kept through the failed upgrade.\", \"title\": \"Rollback drill $marker\", \"workspace\": \"default\"}") ||
  fail "ingest failed"
document_id=$(printf '%s' "$document" | json 'd.get("signal_id")')
[ -n "$document_id" ] && [ "$document_id" != None ] || fail "ingest returned no id: $document"
search_finds "$marker" "$document_id" || fail "search does not find the document before the upgrade: $(cat "$DATA/search.json")"
stop_current

# The row the failing migration changes before it fails.
sql "INSERT INTO tenants (id, name) VALUES ('$SENTINEL', 'Sentinel')"
[ "$(sql 'SELECT max(version) FROM schema_migrations')" = "$current_migration" ] ||
  fail "the store is not at migration $current_migration"
[ "$(sql 'SELECT count(*) FROM contexts')" -ge 1 ] || fail "the store holds no context"
fts_joined "before the upgrade"
snapshot "$DB" before
dump_before=$(file_sha "$DATA/before.dump")

echo "== case A: the failing migration alone"
boot_test_release "$DATA/failing/optimal-engine" failing "$failing_migration"
a_counter=$(sql 'SELECT max(version) FROM schema_migrations')
snapshot "$DB" after-a
a_dump=$(file_sha "$DATA/after-a.dump")
[ "$a_counter" = "$current_migration" ] || fail "case A: the migration counter moved to $a_counter"
same_store "case A, the store after the boots" before after-a
[ "$(table_count failing_migration_probe)" = 0 ] || fail "case A: the failing migration's table survived"
[ "$(sql "SELECT name FROM tenants WHERE id = '$SENTINEL'")" = Sentinel ] || fail "case A: the sentinel changed"
[ "$(sql 'PRAGMA integrity_check')" = ok ] || fail "case A: integrity_check"

echo "== case B: a passing migration, then the failing one, with a backup first"
sql "VACUUM INTO '$DATA/pre-upgrade.db'"
snapshot "$DATA/pre-upgrade.db" backup
same_store "case B, the backup" before backup --any-order
boot_test_release "$DATA/passing-first/optimal-engine" passing-first "$passing_migration"
b_counter=$(sql 'SELECT max(version) FROM schema_migrations')
[ "$b_counter" = 9000001 ] ||
  fail "case B: the passing migration 9000001 should stay applied; the counter is $b_counter"
[ "$(sql 'SELECT count(*) FROM passing_migration_probe')" = 1 ] || fail "case B: the passing migration's row"
[ "$(table_count failing_migration_probe)" = 0 ] || fail "case B: the failing migration's table survived"
[ "$(sql "SELECT name FROM tenants WHERE id = '$SENTINEL'")" = Sentinel ] || fail "case B: the sentinel changed"
[ "$(sql 'PRAGMA integrity_check')" = ok ] || fail "case B: integrity_check"
# Without the restore, the previous release still opens the store, and its
# storage audit reports the passing migration's reserved number as drift.
start_current current-unrestored.log
b_unrestored_audit=$(audit_migrations) || b_unrestored_audit="no readable audit"
case $b_unrestored_audit in
  *migration_drift*) ;;
  *) fail "case B: the audit of the unrestored store reports $b_unrestored_audit, not migration_drift" ;;
esac
stop_current
# The rollback restores the pre-upgrade backup.
cp "$DATA/pre-upgrade.db" "$DB"
rm -f "$DB-wal" "$DB-shm"
b_restored_counter=$(sql 'SELECT max(version) FROM schema_migrations')
[ "$b_restored_counter" = "$current_migration" ] || fail "case B: the restored store is at $b_restored_counter"
snapshot "$DB" restored
b_restored_dump=$(file_sha "$DATA/restored.dump")
same_store "case B, the restored store" before restored --any-order
fts_joined "case B, the restored store"
[ "$(table_count passing_migration_probe)" = 0 ] || fail "case B: the restored store has the passing migration's table"

echo "== step 4: the current release starts again and serves the same data"
start_current current-2.log
[ "$(api GET /api/version | json 'd["version"]')" = "$current_version" ] || fail "the current release reports another version"
[ "$(api GET /api/version | json 'd["expected_migration"]')" = "$current_migration" ] ||
  fail "the current release expects another migration"
api GET "/api/memory/$memory_id?workspace=default" | grep -q "Rollback drill record $SHA" ||
  fail "the record is not readable after the rollback"
search_finds "$marker" "$document_id" || fail "search does not find the document after the rollback: $(cat "$DATA/search.json")"
restored_audit=$(audit_migrations) || restored_audit="no readable audit"
[ "$restored_audit" = ok ] || fail "the audit of the restored store reports $restored_audit"
stop_current

dumps=$(find "$DATA/data" -name 'erl_crash.dump*' | wc -l | tr -d ' ')
[ "$dumps" = 0 ] || fail "$dumps crash dump(s) in the data directory"

echo
echo "PROOF failing-migration rollback: PASS"
echo "  current release   $current_version, migration $current_migration, commit $SHA"
echo "  case A            $failing_version (migration $failing_migration): 2 boots, both exited non-zero, never answered"
echo "                    migration $current_migration before and $a_counter after; schema rows equal; .dump sha256 $dump_before before, $a_dump after"
echo "  case B            $passing_version (migrations 9000001 and $passing_migration): 2 boots, both exited non-zero, never answered"
echo "                    migration $b_counter after the boots (the passing one stays); unrestored, the audit reports $b_unrestored_audit"
echo "                    restored backup at $b_restored_counter: schema rows equal, .dump lines equal (sha256 $b_restored_dump, the same lines as $dump_before in another order), full-text rows joined"
echo "  record            $memory_id readable before and after"
echo "  document          $document_id found by /api/search before and after; the audit of the restored store reports $restored_audit"
echo "  crash dumps       none in the data directory"
