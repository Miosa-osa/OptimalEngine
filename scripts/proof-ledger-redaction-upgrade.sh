#!/usr/bin/env bash
# The ledger redaction backfill on a database an older release left behind
# (docs/guides/erasure-and-retention.md, "Backfill for an Engine that erased before").
#
# 1. Checks out OLD_REF (default v0.3.14) in a worktree and, with that code,
#    seeds a SQLite database: replication of the default workspace on, two
#    memories and a context with its source package, claim and chunk written,
#    then one memory forgotten, the other deleted and the context erased, all
#    through the old code's own erasure paths. The ledger keeps every text.
# 2. With this checkout (the upgrade: its migrations run on the same file),
#    `mix optimal.ledger.redact --dry-run` reports counts only and changes
#    nothing, `mix optimal.ledger.redact` redacts, and a second run finds
#    nothing.
#
# The source package and claim that writing a memory stages keep its text as
# live rows until #245 erases them with the forget, so the memory texts are
# looked for in the changes of the memory tables; the context's text in every
# change.
#
# Usage: scripts/proof-ledger-redaction-upgrade.sh [OLD_REF]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OLD_REF="${1:-${OLD_REF:-v0.3.14}}"
STAMP="$(date +%s)_$$"
DATA="${DATA:-$(mktemp -d)}"
OLD="$DATA/old"
OLD_BUILD="${OLD_BUILD:-$DATA/old_build}"
mkdir -p "$DATA/engine/cache"

export MIX_ENV="${MIX_ENV:-dev}"
export OPTIMAL_API_ENABLED=false
export OPTIMAL_SYNC_INTERVAL_MS=3600000
export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"
export OPTIMAL_ENGINE_ROOT="$DATA/engine"
export OPTIMAL_ENGINE_DB="$DATA/engine/index.db"
export OPTIMAL_ENGINE_CACHE="$DATA/engine/cache"
unset OPTIMAL_STORE

fail() {
  echo "FAIL $1"
  for log in "$DATA"/*.log; do
    [ -f "$log" ] && { echo "--- $log"; tail -25 "$log"; }
  done
  exit 1
}

cleanup() { git -C "$ROOT" worktree remove --force "$OLD" >/dev/null 2>&1 || true; }
trap cleanup EXIT

FORGOT="proof-forgot-$STAMP"
DELETED="proof-deleted-$STAMP"
ERASED="proof-erased-$STAMP"
MEMORY_TABLES="memories,memory_embeddings,memory_relations,ledger_redactions"

hits() {
  OPTIMAL_PROOF_TOKEN="$1" OPTIMAL_PROOF_TABLES="${2:-}" \
    mix run --no-compile --no-start scripts/proof_ledger_grep.exs 2>>"$DATA/grep.log" | tail -1
}

echo "== check out $OLD_REF and build it"
git worktree add --detach "$OLD" "$OLD_REF" >"$DATA/worktree.log" 2>&1 || fail "worktree of $OLD_REF"
(cd "$OLD" && MIX_BUILD_PATH="$OLD_BUILD" mix deps.get >"$DATA/old-deps.log" 2>&1 &&
  MIX_BUILD_PATH="$OLD_BUILD" mix compile >"$DATA/old-compile.log" 2>&1) || fail "building $OLD_REF"

echo "== seed and erase with $OLD_REF"
(cd "$OLD" && FORGOT="$FORGOT" DELETED="$DELETED" ERASED="$ERASED" MIX_BUILD_PATH="$OLD_BUILD" \
  mix run --no-compile -e '
    alias OptimalEngine.{Memory, Store, Sync}
    alias OptimalEngine.Compliance.DerivedData
    alias OptimalEngine.Pipeline.Decomposer.Chunk

    ws = "default"
    {:ok, _} = Sync.enable("default", ws, "user:proof")
    {:ok, forgot} = Memory.create(%{content: "the vault code is " <> System.fetch_env!("FORGOT"), workspace_id: ws})
    {:ok, deleted} = Memory.create(%{content: "the alarm code is " <> System.fetch_env!("DELETED"), workspace_id: ws})

    text = "write to " <> System.fetch_env!("ERASED")
    ctx = "proof-ctx"

    {:ok, _} = Store.raw_query("INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, genre, node, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
      [ctx, "default", ws, "optimal://proof/" <> ctx, "t", text, "note", "person-operator", "2020-01-01T00:00:00Z"])
    {:ok, _} = Store.raw_query("INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text) VALUES (?1, ?2, ?3, ?4, ?5)",
      ["pkg-" <> ctx, "default", ws, "hash-" <> ctx, text])
    {:ok, _} = Store.raw_query("UPDATE contexts SET metadata = json_object(?1, ?2) WHERE id = ?3", ["source_package_id", "pkg-" <> ctx, ctx])
    {:ok, _} = Store.raw_query("INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["claim-" <> ctx, "default", ws, "pkg-" <> ctx, ctx, text])
    :ok = Store.insert_chunks([Chunk.new(id: ctx <> ":0", signal_id: ctx, tenant_id: "default", workspace_id: ws, text: text)])
    {:ok, _} = Sync.Capture.seal()

    :ok = Memory.forget(forgot.id)
    :ok = Memory.delete(deleted.id)
    {:ok, _} = DerivedData.erase_contexts("default", [ctx])
    {:ok, _} = Sync.Capture.seal()
    IO.puts("seeded")
  ' >"$DATA/seed.log" 2>&1) || fail "seeding with $OLD_REF"

echo "== build this checkout (the upgrade)"
mix compile >"$DATA/compile.log" 2>&1 || fail "compile"

before_forgot=$(hits "$FORGOT" "$MEMORY_TABLES")
before_deleted=$(hits "$DELETED" "$MEMORY_TABLES")
before_erased=$(hits "$ERASED")
echo "the ledger $OLD_REF left: forgotten memory $before_forgot, deleted memory $before_deleted, erased context $before_erased"
[ "$before_forgot" -gt 0 ] && [ "$before_deleted" -gt 0 ] && [ "$before_erased" -gt 0 ] ||
  fail "$OLD_REF did not leave the texts in its ledger"

echo "== dry run"
mix optimal.ledger.redact --dry-run 2>"$DATA/dry.log" | sed -n '/^{/,/^}/p' >"$DATA/dry.json" || fail "dry run"
cat "$DATA/dry.json"
for text in "$FORGOT" "$DELETED" "$ERASED" proof-ctx pkg-proof-ctx; do
  grep -q -- "$text" "$DATA/dry.json" && fail "the dry run report names $text"
done
python3 - "$DATA/dry.json" <<'PY' || fail "the dry run report is not what it should be"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["dry_run"] is True
assert r["sync_enabled_workspaces"] >= 1 and isinstance(r["registered_peers"], int)
for table in ("memories", "contexts", "source_packages", "claims", "chunks"):
    assert r["exposed"].get(table, {}).get("rows", 0) >= 1, table
PY
[ "$(hits "$ERASED")" = "$before_erased" ] || fail "the dry run changed the ledger"

echo "== backfill"
mix optimal.ledger.redact 2>"$DATA/run.log" | sed -n '/^{/,/^}/p' >"$DATA/run.json" || fail "backfill"
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print('redacted', r['ledger_rows_redacted'], 'peer requests', r['peer_requests'])" "$DATA/run.json"
[ "$(hits "$FORGOT" "$MEMORY_TABLES")" = 0 ] || fail "the forgotten memory's text is still in the ledger"
[ "$(hits "$DELETED" "$MEMORY_TABLES")" = 0 ] || fail "the deleted memory's text is still in the ledger"
[ "$(hits "$ERASED")" = 0 ] || fail "the erased context's text is still in the ledger"

echo "== a second run finds nothing"
mix optimal.ledger.redact 2>"$DATA/again.log" | sed -n '/^{/,/^}/p' >"$DATA/again.json" || fail "second run"
python3 - "$DATA/again.json" <<'PY' || fail "the second run redacted again"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["ledger_rows_redacted"] == 0 and r["peer_requests"] == 0 and r["exposed"] == {}, r
PY

echo "PASS the backfill redacts what $OLD_REF erased, reports counts only, and runs once"
