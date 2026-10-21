#!/usr/bin/env bash
# Proves what upgrading an Engine from 0.3.7 does to its knowledge graph.
#
# 0.3.7 wrote graph edges to the legacy `edges` table, whose key is
# UNIQUE(source_id, target_id, relation): an entity pair that two workspaces
# share kept only the first workspace's edge. Migration 76 copies `edges` into
# `graph_edges` (keyed by tenant and workspace); `Graph.backfill/1` writes the
# edges the old key dropped. This script runs the real upgrade and prints every
# number, so a report such as "backfill_needed is true and /api/graph shows no
# edges after the upgrade" can be read against data instead of the code.
#
# Steps (the lettering is the work order's):
#   (a) build OLD_REF (default v0.3.7), start it on a temp store, bootstrap key
#   (b) ingest 32 documents naming shared people and companies into the default
#       workspace and three more (default:alpha, default:beta, default:gamma;
#       gamma names only people the Engine does not know), plus three
#       documents in a second tenant's workspace (acme:qa) when it can be made,
#       three the second tenant's key writes to an unregistered bare id
#       (qabatch) and three to an unregistered prefixed id (acme:late)
#   (c) record the legacy edges per workspace, the contexts' workspace and
#       tenant labels, and what the API answers on OLD_REF
#   (d) stop, copy the store, boot UPGRADE_REF (default v0.3.8) on the copy so
#       migrations 74 to 82 run
#   (e) record graph_edges per tenant and workspace, GET /api/maintenance/graph
#       (backfill_status), GET /api/graph and the graph analysis reads
#   (f) stop, run OptimalEngine.Release.graph_backfill() (the one write path on
#       0.3.8), boot again, record the same numbers
#   (g) the same from MAIN_REF (default origin/main) on a second copy of the
#       0.3.7 store, backfilling with POST /api/maintenance/graph/backfill
#       while it runs
#
# The "expected" column is an independent oracle: the edge set the intake
# rules produce from each context's own entities, node, routed_to and
# supersedes (the same rules as Graph.backfill/1), keyed by tenant and
# workspace. "missing" is expected minus graph_edges, "extra" the reverse.
#
# Keys are written to files under DATA and never printed.
#
# Usage: scripts/proof-upgrade-graph.sh
#   OLD_REF, UPGRADE_REF, MAIN_REF   refs to compare (tags or origin/main)
#   REPO_URL                         where the refs are cloned from
#   PORT                             API port (default: a free one)
#   DATA                             work directory (default: a new temp dir)
#   KEEP_DATA=1                      keep DATA at the end
# It does not touch port 4200 or any Engine outside DATA.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${REPO_URL:-https://github.com/Miosa-osa/OptimalEngine}"
OLD_REF="${OLD_REF:-v0.3.7}"
UPGRADE_REF="${UPGRADE_REF:-v0.3.8}"
MAIN_REF="${MAIN_REF:-origin/main}"

command -v python3 >/dev/null 2>&1 || { echo "FAIL python3 is required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "FAIL curl is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL git is required"; exit 1; }
command -v mix >/dev/null 2>&1 || { echo "FAIL mix is required"; exit 1; }

own_data=0
if [ -z "${DATA:-}" ]; then
  DATA="$(mktemp -d)"
  own_data=1
fi
PORT="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')}"
case "$PORT" in 4200) echo "FAIL port 4200 belongs to the live Engine"; exit 1 ;; esac
BASE="http://127.0.0.1:$PORT"
SRC="$DATA/src"
STORES="$DATA/stores"
mkdir -p "$SRC" "$STORES" "$DATA/keys" "$DATA/tmp"
chmod 700 "$DATA/keys"
export TMPDIR="$DATA/tmp"

# One bootstrap key for the default tenant: the same token on every version, so
# the same key reads the store before and after each upgrade.
KEY="$(python3 -c 'import secrets; print("oe_" + secrets.token_hex(12) + "_" + secrets.token_hex(20))')"
(umask 077 && printf '%s' "$KEY" >"$DATA/keys/root")
AUTHORITY_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
CONNECTOR_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"

ENGINE_PID=""
BUILD_PIDS=()

cleanup() {
  if [ -n "$ENGINE_PID" ]; then kill "$ENGINE_PID" 2>/dev/null || true; fi
  for pid in "${BUILD_PIDS[@]:-}"; do
    if [ -n "$pid" ]; then
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    fi
  done
  if [ "$own_data" = 1 ] && [ "${KEEP_DATA:-0}" != 1 ]; then rm -rf "$DATA"; fi
}
trap cleanup EXIT

started=$(date +%s)

fail() {
  echo "FAIL $*"
  for log in "$DATA"/*.log; do
    if [ -f "$log" ]; then
      echo "-- $(basename "$log")"
      tail -25 "$log" | sed -E 's/oe_[0-9a-f]{24}_[0-9a-f]+/oe_REDACTED/g'
    fi
  done
  exit 1
}

# The environment of one Engine run on a store. Auth is on; the bootstrap key
# is the default tenant's root key; no embedder or model host is reachable.
store_env() { # store
  STORE_ENV=(
    MIX_ENV=dev
    OPTIMAL_ENGINE_ROOT="$1" OPTIMAL_ENGINE_DB="$1/index.db" OPTIMAL_ENGINE_CACHE="$1/cache"
    OPTIMAL_KNOWLEDGE_ROCKSDB_PATH="$1/knowledge-rocksdb" OPTIMAL_BACKUP_DIR="$1/backups"
    OPTIMAL_API_INTERFACE=127.0.0.1 OPTIMAL_API_PORT="$PORT"
    OPTIMAL_AUTH_REQUIRED=true OPTIMAL_BOOTSTRAP_KEY="$KEY" OPTIMAL_BOOTSTRAP_SCOPES='*'
    OPTIMAL_AUTHORITY_KEY="$AUTHORITY_KEY" CONNECTOR_KEY="$CONNECTOR_KEY"
    OLLAMA_HOST=http://127.0.0.1:9 OPTIMAL_SYNC_INTERVAL_MS=86400000
  )
}

# A command with the Engine's environment, API off (mix tasks, release calls).
cli() { # src store cmd...
  local src=$1 store=$2
  shift 2
  store_env "$store"
  (cd "$src" && env "${STORE_ENV[@]}" OPTIMAL_API_ENABLED=false "$@")
}

# Starts the Engine as the background process itself (no shell function in
# between), so ENGINE_PID stops it. Returns 1 when it exits or never answers.
start_engine() { # label src store
  local label=$1 src=$2 store=$3
  store_env "$store"
  (cd "$src" && exec env "${STORE_ENV[@]}" OPTIMAL_API_ENABLED=true mix run --no-halt) \
    >>"$DATA/$label.log" 2>&1 &
  ENGINE_PID=$!
  for _ in $(seq 1 240); do
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
      ENGINE_PID=""
      return 1
    fi
    if curl -sf --max-time 5 -o /dev/null -H "Authorization: Bearer $KEY" "$BASE/api/health"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

stop_engine() {
  local pid=$ENGINE_PID
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 90); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true
  ENGINE_PID=""
}

# The migrations a boot applied, from its log.
boot_migrations() { # label
  local applied
  applied=$(grep -a -o '\[Migrations\] Applying [0-9]*' "$DATA/$1.log" | awk '{print $3}' | tr '\n' ' ')
  echo "MIGRATIONS_APPLIED $1: ${applied:-none}"
  grep -a -E '\[Migrations\].*(rows changed|failed|error)' "$DATA/$1.log" | tail -10 || true
}

build_tree() { # name
  local t0
  t0=$(date +%s)
  (cd "$SRC/$1" && MIX_ENV=dev mix deps.get && MIX_ENV=dev mix compile) >"$DATA/build-$1.log" 2>&1 || return 1
  echo "BUILD $1 ok in $(( $(date +%s) - t0 )) s"
}

# Waits for a background build to finish; prints its line, returns its status.
await_build() { # name
  local status="$DATA/build-$1.status"
  for _ in $(seq 1 3600); do
    [ -f "$status" ] && break
    sleep 2
  done
  [ "$(cat "$status" 2>/dev/null)" = 0 ] || return 1
  cat "$DATA/build-$1.out"
}

py() { PROOF_DATA="$DATA" PROOF_BASE="$BASE" python3 "$DATA/driver.py" "$@"; }

write_driver() {
  cat >"$DATA/driver.py" <<'PY'
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DATA = os.environ["PROOF_DATA"]
BASE = os.environ.get("PROOF_BASE", "")
RESULTS = os.path.join(DATA, "results.jsonl")
WORKSPACES = os.path.join(DATA, "workspaces.json")

PEOPLE = ["Priya Natarajan", "Marcus Oyelaran", "Helena Voss", "Dmitri Kallas", "Sofia Brandt", "Tobias Wren"]
COMPANIES = ["Acme Robotics", "Northwind Freight", "Halcyon Labs", "Quill Analytics"]
# Named in documents but never added as topology nodes, so intake finds no
# entity in them: the shape of a store whose documents name nobody the Engine
# knows. Workspace gamma holds only such documents.
UNKNOWN = ["Ingrid Solheim", "Kenji Arata", "Oakridge Partners"]
ALL = PEOPLE + COMPANIES + UNKNOWN

# (workspace name, node, title, indexes into ALL). The first three are filed in
# the default workspace before the gazetteer knows any name, so they carry no
# entities: the shape of a store whose documents name nobody the Engine knows.
COLD = [
    ("default", "operations", "Supplier review", [0, 1, 6]),
    ("default", "operations", "Freight terms", [0, 6, 7]),
    ("default", "sales", "Lab pilot", [3, 8]),
]
WARM = [
    ("default", "operations", "Quarterly account", [0, 1, 6]),
    ("default", "operations", "Renewal call", [1, 6]),
    ("default", "sales", "Pilot scoping", [3, 8]),
    ("alpha", "engineering", "Integration plan", [0, 1, 6]),
    ("alpha", "operations", "Freight rollout", [0, 6, 7]),
    ("alpha", "engineering", "Capacity review", [1, 2, 6]),
    ("alpha", "sales", "Board prep", [0, 1, 2]),
    ("alpha", "operations", "Carrier audit", [2, 7]),
    ("alpha", "sales", "Pricing sync", [0, 6]),
    ("beta", "engineering", "Integration plan", [0, 1, 6]),
    ("beta", "operations", "Freight rollout", [0, 6, 7]),
    ("beta", "sales", "Lab pilot", [3, 8]),
    ("beta", "engineering", "Capacity review", [1, 2, 6]),
    ("beta", "sales", "Analytics scoping", [3, 4, 8]),
    ("beta", "operations", "Staffing", [0, 1]),
    ("gamma", "operations", "Site visit", [10, 11, 12]),
    ("gamma", "sales", "Contract terms", [10, 12]),
    ("gamma", "operations", "Handover", [11, 12]),
    ("gamma", "engineering", "Audit findings", [10, 11]),
    ("gamma", "sales", "Renewal", [10, 11, 12]),
    ("acme", "operations", "Integration plan", [0, 1, 6]),
    ("acme", "sales", "Pricing sync", [0, 6]),
    ("acme", "sales", "Lab pilot", [3, 8]),
    ("acmebare", "operations", "Integration plan", [0, 1, 6]),
    ("acmebare", "sales", "Pricing sync", [0, 6]),
    ("acmebare", "sales", "Lab pilot", [3, 8]),
    ("acmelate", "operations", "Integration plan", [0, 1, 6]),
    ("acmelate", "sales", "Pricing sync", [0, 6]),
    ("acmelate", "sales", "Lab pilot", [3, 8]),
]


def key(name):
    with open(os.path.join(DATA, "keys", name)) as handle:
        return handle.read().strip()


def call(method, path, key_name, body=None, timeout=180):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + key(key_name))
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw, status = response.read(), response.status
    except urllib.error.HTTPError as error:
        raw, status = error.read(), error.code
    except Exception as error:  # connection refused, timeout
        return 0, {"error": repr(error)}
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, {"raw": raw[:200].decode("utf-8", "replace")}


def record(row):
    with open(RESULTS, "a") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")


def compact(value, limit=300):
    text = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return text if len(text) <= limit else text[:limit] + "..."


def doc_text(number, title, names):
    lead = names[0]
    follow = names[1] if len(names) > 1 else lead
    last = names[-1]
    return (
        f"# {title}\n\n"
        f"Account review {number:02d}. Present: {', '.join(names)}.\n\n"
        f"Decision: {lead} approved the revised delivery plan and set the review date for the "
        f"first week of next month. {follow} owns the follow-up and will report progress to "
        f"{last} every Friday.\n\n"
        f"Risks: supplier lead time, budget approval, and integration testing. Action items: "
        f"{lead} sends the updated scope; {follow} confirms pricing; {last} signs off on the "
        f"schedule.\n"
    )


def ingest_group(docs, workspaces, number):
    """Files documents; returns the next document number."""
    summary = {}
    for name, node, title, idx in docs:
        info = workspaces[name]
        names = [ALL[i] for i in idx]
        status, body = call(
            "POST",
            "/api/ingest",
            info["key"],
            {
                "text": doc_text(number, title, names),
                "workspace": info["id"],
                "node": node,
                "title": f"{title} {number:02d}",
            },
        )
        found = len(body.get("entities") or []) if isinstance(body, dict) else 0
        row = summary.setdefault(name, {"ok": 0, "failed": 0, "entities": []})
        if status == 200 and isinstance(body, dict) and body.get("ok"):
            row["ok"] += 1
            row["entities"].append(found)
        else:
            row["failed"] += 1
            print(f"INGEST_FAILED ws={name} n={number} status={status} body={compact(body, 200)}")
        number += 1
    for name, row in summary.items():
        print(f"INGEST {name}: ok={row['ok']} failed={row['failed']} entities_per_doc={row['entities']}")
    return number


def seed():
    workspaces = {"default": {"id": "default", "key": "root"}}
    number = 1
    print("-- documents before the gazetteer knows any name")
    number = ingest_group(COLD, workspaces, number)

    print("-- gazetteer: the people and companies as topology nodes")
    for name in PEOPLE:
        status, body = call("POST", "/api/nodes", "root", {"name": name, "kind": "person", "workspace": "default"})
        if status != 200:
            print(f"NODE_FAILED {name} status={status} body={compact(body, 200)}")
    for name in COMPANIES:
        status, body = call("POST", "/api/nodes", "root", {"name": name, "kind": "entity", "workspace": "default"})
        if status != 200:
            print(f"NODE_FAILED {name} status={status} body={compact(body, 200)}")

    print("-- workspaces")
    for slug, title in (("alpha", "Alpha"), ("beta", "Beta"), ("gamma", "Gamma")):
        status, body = call("POST", "/api/workspaces", "root", {"slug": slug, "name": title})
        if status in (200, 201) and body.get("id"):
            workspaces[slug] = {"id": body["id"], "key": "root"}
        else:
            sys.exit(f"FAIL creating workspace {slug}: status={status} body={compact(body, 200)}")
    if os.path.exists(os.path.join(DATA, "keys", "acme")):
        status, body = call(
            "POST", "/api/organizations", "acme", {"slug": "acme-org", "name": "Acme Org", "tenant": "acme"}
        )
        org = body.get("id") if status in (200, 201) and isinstance(body, dict) else None
        print(f"ACME_ORGANIZATION status={status} id={org}")
        payload = {"slug": "qa", "name": "Acme QA", "tenant": "acme"}
        if org:
            payload["organization"] = org
        for key_name in ("acme", "root"):
            status, body = call("POST", "/api/workspaces", key_name, payload)
            if status in (200, 201) and body.get("id"):
                workspaces["acme"] = {"id": body["id"], "key": "acme"}
                break
            print(f"ACME_WORKSPACE_FAILED key={key_name} status={status} body={compact(body, 200)}")
        # The second tenant's key also writes to a bare id no workspace row registers
        # (unregistered ids without a tenant prefix are accepted): the rows are
        # labelled with the default tenant, not the key's.
        workspaces["acmebare"] = {"id": "qabatch", "key": "acme"}
        # And to a prefixed id no row registers: the prefix names a tenant that
        # exists, which is what migration 76 reads to relabel such rows.
        workspaces["acmelate"] = {"id": "acme:late", "key": "acme"}
    else:
        print("ACME_SKIPPED no second-tenant key")
    for name, info in workspaces.items():
        print(f"WORKSPACE {name} id={info['id']}")

    docs = [doc for doc in WARM if doc[0] in workspaces]
    print("-- documents")
    ingest_group(docs, workspaces, number)
    with open(WORKSPACES, "w") as handle:
        json.dump(workspaces, handle)
    time.sleep(8)


def jlist(value):
    try:
        parsed = json.loads(value) if isinstance(value, str) else value
    except ValueError:
        return []
    return parsed if isinstance(parsed, list) else []


def dbsnap(db, phase):
    con = sqlite3.connect(db, timeout=30)
    con.execute("PRAGMA query_only = ON")

    def rows(sql, args=()):
        try:
            return con.execute(sql, args).fetchall()
        except sqlite3.Error:
            return None

    def has(table):
        return bool(rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)))

    print(f"## DB {phase}")
    migration = rows("SELECT MAX(version), COUNT(*) FROM schema_migrations")
    print(f"schema_migrations: max={migration[0][0]} count={migration[0][1]}")
    ws_rows = rows("SELECT id, tenant_id FROM workspaces ORDER BY id") or []
    ws_tenant = dict(ws_rows)
    tenants = {row[0] for row in rows("SELECT id FROM tenants") or []}
    print("workspaces: " + ", ".join(f"{i}->{t}" for i, t in ws_rows))

    def tenant_of(workspace):
        if workspace in ws_tenant:
            return ws_tenant[workspace]
        prefix = workspace.split(":", 1)[0] if ":" in workspace else None
        return prefix if prefix in tenants else "default"

    contexts = rows(
        "SELECT id, node, entities, routed_to, supersedes, workspace_id, tenant_id FROM contexts"
    ) or []
    by_label = {}
    for row in contexts:
        label = (row[5] or "default", row[6] or "default")
        by_label[label] = by_label.get(label, 0) + 1
    print("contexts (workspace, tenant): " + ", ".join(f"{w}/{t}={n}" for (w, t), n in sorted(by_label.items())))
    wrong = sum(1 for row in contexts if (row[6] or "default") != tenant_of(row[5] or "default"))
    print(f"contexts whose tenant label differs from their workspace's tenant: {wrong}")

    for table in ("source_packages", "claims"):
        labels = rows(f"SELECT workspace_id, tenant_id, COUNT(*) FROM {table} GROUP BY 1, 2 ORDER BY 1, 2")
        if labels is not None:
            print(f"{table} (workspace/tenant=n): " + ", ".join(f"{w}/{t}={n}" for w, t, n in labels))

    entities = rows("SELECT workspace_id, COUNT(*), COUNT(DISTINCT name) FROM entities GROUP BY 1 ORDER BY 1")
    print("entities rows (workspace: rows/distinct): " + ", ".join(f"{w}: {n}/{d}" for w, n, d in entities or []))
    with_entities = {}
    for row in contexts:
        w = row[5] or "default"
        with_entities[w] = with_entities.get(w, 0) + (1 if jlist(row[2]) else 0)
    print("contexts that name an entity: " + ", ".join(f"{w}={n}" for w, n in sorted(with_entities.items())))

    legacy_keys = set()
    legacy = rows("SELECT workspace_id, source_id, target_id, relation, tenant_id FROM edges") or []
    legacy_by_ws = {}
    legacy_by_rel = {}
    for w, s, t, r, tenant in legacy:
        legacy_keys.add((tenant_of(w), w, s, t, r))
        legacy_by_ws[w] = legacy_by_ws.get(w, 0) + 1
        legacy_by_rel[(w, r)] = legacy_by_rel.get((w, r), 0) + 1
    print("legacy edges per workspace: " + ", ".join(f"{w}={n}" for w, n in sorted(legacy_by_ws.items())))
    print(
        "legacy edges per workspace and relation: "
        + ", ".join(f"{w}/{r}={n}" for (w, r), n in sorted(legacy_by_rel.items()))
    )
    print("legacy edges tenant_id column values: " + compact(sorted({row[4] for row in legacy})))

    graph_keys = set()
    graph_rows = rows("SELECT tenant_id, workspace_id, source_id, target_id, relation FROM graph_edges") if has("graph_edges") else None
    graph_counts = {}
    if graph_rows is None:
        print("graph_edges: table absent")
    else:
        for tenant, w, s, t, r in graph_rows:
            graph_keys.add((tenant, w, s, t, r))
            graph_counts[(tenant, w)] = graph_counts.get((tenant, w), 0) + 1
        print("graph_edges per tenant/workspace: " + ", ".join(f"{t}/{w}={n}" for (t, w), n in sorted(graph_counts.items())))
        mislabeled = sum(1 for tenant, w, *_ in graph_rows if tenant != tenant_of(w))
        print(f"graph_edges whose tenant differs from their workspace's tenant: {mislabeled}")
        if has("graph_backfills"):
            runs = rows("SELECT tenant_id, workspace_id, contexts, claims, edges_before, edges_after FROM graph_backfills")
            print(f"graph_backfills rows: {len(runs)} {compact(runs)}")

    expected = set()
    for cid, node, entities_json, routed_json, supersedes, w, _tenant in contexts:
        w = w or "default"
        tenant = tenant_of(w)
        names = []
        for e in jlist(entities_json):
            if isinstance(e, str) and e and e not in names:
                names.append(e)
        for e in names:
            expected.add((tenant, w, e, cid, "mentioned_in"))
            expected.add((tenant, w, cid, e, "mentions"))
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                for rel in ("co_occurs", "co_occurs_with"):
                    expected.add((tenant, w, a, b, rel))
                    expected.add((tenant, w, b, a, rel))
        if isinstance(node, str) and node:
            expected.add((tenant, w, cid, node, "lives_in"))
        for dest in jlist(routed_json):
            if isinstance(dest, str) and dest and dest != node:
                expected.add((tenant, w, cid, dest, "cross_ref"))
        if isinstance(supersedes, str) and supersedes:
            expected.add((tenant, w, cid, supersedes, "supersedes"))
    if has("claims"):
        claims = rows(
            "SELECT cl.id, c.entities, cl.workspace_id FROM claims cl JOIN contexts c ON c.id = cl.signal_id "
            "WHERE cl.signal_id IS NOT NULL"
        )
        for claim_id, entities_json, w in claims or []:
            w = w or "default"
            for e in {e for e in jlist(entities_json) if isinstance(e, str) and e}:
                expected.add((tenant_of(w), w, claim_id, e, "about"))
        print(f"claims with a source context: {len(claims or [])}")

    print("")
    header = f"{'workspace':<16}{'tenant':<10}{'contexts':>9}{'expected':>9}{'legacy':>8}{'graph_edges':>12}{'missing':>9}{'extra':>7}  missing by relation"
    print(header)
    labels = sorted({(k[0], k[1]) for k in expected | legacy_keys | graph_keys} | {(tenant_of(w), w) for w in ws_tenant})
    context_counts = {}
    for row in contexts:
        w = row[5] or "default"
        context_counts[w] = context_counts.get(w, 0) + 1
    totals = [0, 0, 0, 0, 0, 0]
    for tenant, w in labels:
        exp = {k for k in expected if (k[0], k[1]) == (tenant, w)}
        leg = {k for k in legacy_keys if (k[0], k[1]) == (tenant, w)}
        got = {k for k in graph_keys if (k[0], k[1]) == (tenant, w)}
        missing = exp - got
        extra = got - exp
        rels = {}
        for k in missing:
            rels[k[4]] = rels.get(k[4], 0) + 1
        rel_text = ", ".join(f"{r}={n}" for r, n in sorted(rels.items())) or "-"
        if graph_rows is None:
            rel_text = "-"
        graph_text = str(len(got)) if graph_rows is not None else "n/a"
        print(f"{w:<16}{tenant:<10}{context_counts.get(w, 0):>9}{len(exp):>9}{len(leg):>8}{graph_text:>12}{len(missing) if graph_rows is not None else 'n/a':>9}{len(extra) if graph_rows is not None else 'n/a':>7}  {rel_text}")
        record(
            {
                "kind": "db",
                "phase": phase,
                "ws": w,
                "tenant": tenant,
                "contexts": context_counts.get(w, 0),
                "expected": len(exp),
                "legacy": len(leg),
                "graph_edges": len(got) if graph_rows is not None else None,
                "missing": len(missing) if graph_rows is not None else None,
                "extra": len(extra) if graph_rows is not None else None,
                "max_migration": migration[0][0],
            }
        )
        for i, value in enumerate((context_counts.get(w, 0), len(exp), len(leg), len(got), len(missing), len(extra))):
            totals[i] += value
    print(f"{'TOTAL':<26}{totals[0]:>9}{totals[1]:>9}{totals[2]:>8}{totals[3] if graph_rows is not None else 'n/a':>12}{totals[4] if graph_rows is not None else 'n/a':>9}{totals[5] if graph_rows is not None else 'n/a':>7}")

    if has("jobs"):
        jobs = rows("SELECT kind, workspace_id, status, attempts FROM jobs WHERE kind LIKE 'maintenance.graph%' ORDER BY workspace_id")
        if jobs:
            print("graph backfill jobs: " + "; ".join(f"{w}={s}/{a}" for _k, w, s, a in jobs))
    con.close()


def apisnap(phase):
    with open(WORKSPACES) as handle:
        workspaces = json.load(handle)
    for name, info in workspaces.items():
        ws = urllib.parse.quote(info["id"], safe="")
        gs, graph = call("GET", f"/api/graph?workspace={ws}", info["key"])
        ms, maint = call("GET", f"/api/maintenance/graph?workspace={ws}", info["key"])
        hs, hubs = call("GET", f"/api/graph/hubs?workspace={ws}", info["key"])
        os_, optimal = call("GET", f"/api/optimal/graph?workspace={ws}", info["key"])
        stats = graph.get("stats", {}) if isinstance(graph, dict) else {}
        relations = {}
        for edge in (graph.get("edges") or []) if isinstance(graph, dict) else []:
            relations[edge.get("relation")] = relations.get(edge.get("relation"), 0) + 1
        legacy_stats = maint.get("edges", {}) if isinstance(maint, dict) else {}
        status = (maint.get("graph_edges") or {}) if isinstance(maint, dict) else {}
        row = {
            "kind": "api",
            "phase": phase,
            "ws": info["id"],
            "graph_status": gs,
            "graph_contexts": stats.get("context_count"),
            "graph_edge_count": stats.get("edge_count"),
            "graph_entities": stats.get("entity_count"),
            "graph_edge_relations": relations,
            "maint_status": ms,
            "maint_total_edges": legacy_stats.get("total_edges"),
            "backfill_needed": status.get("backfill_needed"),
            "legacy_edges": status.get("legacy_edges"),
            "maint_graph_edges": status.get("edges"),
            "hubs_status": hs,
            "hubs": len(hubs.get("hubs") or []) if isinstance(hubs, dict) else None,
            "optimal_status": os_,
            "optimal_edge_count": (optimal.get("stats") or {}).get("edge_count") if isinstance(optimal, dict) else None,
        }
        record(row)
        print(
            f"API {phase} {name} ws={info['id']} key={info['key']}: "
            f"/api/graph st={gs} contexts={row['graph_contexts']} edge_count={row['graph_edge_count']} "
            f"entities={row['graph_entities']} by_relation={compact(relations, 80)} | "
            f"/api/maintenance/graph st={ms} total_edges={row['maint_total_edges']} "
            f"backfill_needed={row['backfill_needed']} legacy_edges={row['legacy_edges']} graph_edges={row['maint_graph_edges']} | "
            f"hubs st={hs} n={row['hubs']} | /api/optimal/graph st={os_} edge_count={row['optimal_edge_count']}"
        )
        if gs != 200 or ms != 200:
            print(f"  graph body: {compact(graph, 200)}")
            print(f"  maintenance body: {compact(maint, 200)}")


def backfill_api():
    with open(WORKSPACES) as handle:
        workspaces = json.load(handle)
    queued = set()
    for name, info in workspaces.items():
        status, body = call("POST", "/api/maintenance/graph/backfill", info["key"], {"workspace": info["id"]})
        print(f"BACKFILL_API {name} POST status={status} body={compact(body, 200)}")
        if status == 202:
            queued.add(name)
    started = time.time()
    pending = set(queued)
    while pending and time.time() - started < 300:
        for name in sorted(pending):
            info = workspaces[name]
            ws = urllib.parse.quote(info["id"], safe="")
            status, maint = call("GET", f"/api/maintenance/graph?workspace={ws}", info["key"])
            state = (maint.get("graph_edges") or {}) if isinstance(maint, dict) else {}
            if status == 200 and state.get("backfill_needed") is False:
                pending.discard(name)
                print(f"BACKFILL_API {name} done after {int(time.time() - started)} s: graph_edges={state.get('edges')}")
        if pending:
            time.sleep(2)
    for name in sorted(pending):
        print(f"BACKFILL_API {name} still backfill_needed after 300 s")
    time.sleep(5)


def summary():
    rows = [json.loads(line) for line in open(RESULTS)]
    dbs = {}
    apis = {}
    for row in rows:
        if row["kind"] == "db":
            dbs[(row["phase"], row["ws"])] = row
        else:
            apis[(row["phase"], row["ws"])] = row
    phases = []
    for row in rows:
        if row["phase"] not in phases:
            phases.append(row["phase"])
    print(f"{'phase':<16}{'workspace':<16}{'contexts':>9}{'legacy':>8}{'graph_edges':>12}{'expected':>9}{'missing':>9}"
          f"{'api edge_count':>16}{'needed':>8}{'maint total':>13}{'hubs':>6}")
    for phase in phases:
        names = sorted({ws for (p, ws) in list(dbs) + list(apis) if p == phase})
        for ws in names:
            d = dbs.get((phase, ws), {})
            a = apis.get((phase, ws), {})
            print(
                f"{phase:<16}{ws:<16}{str(d.get('contexts', '-')):>9}{str(d.get('legacy', '-')):>8}"
                f"{str(d.get('graph_edges', '-')):>12}{str(d.get('expected', '-')):>9}{str(d.get('missing', '-')):>9}"
                f"{str(a.get('graph_edge_count', '-')):>16}{str(a.get('backfill_needed', '-')):>8}"
                f"{str(a.get('maint_total_edges', '-')):>13}{str(a.get('hubs', '-')):>6}"
            )

    def check(name, ok):
        print(f"CHECK {name}: {'not run' if ok is None else 'yes' if ok else 'NO'}")

    def differing(phase_a, phase_b, field, source):
        return [
            f"{ws} ({row.get(field)} -> {source[(phase_b, ws)].get(field)})"
            for (p, ws), row in sorted(source.items())
            if p == phase_a and (phase_b, ws) in source and source[(phase_b, ws)].get(field) != row.get(field)
        ]

    up_dbs = [r for (p, _), r in dbs.items() if p == "up-boot"]
    check("migration copy complete on the upgrade boot (graph_edges equals legacy edges, per workspace)",
          all(r["graph_edges"] == r["legacy"] for r in up_dbs) if up_dbs else None)
    check("legacy edges fall short of the expected edges before any backfill (the old key dropped some)",
          any(r["legacy"] < r["expected"] for r in up_dbs))
    for field in ("graph_contexts", "graph_edge_count", "graph_entities"):
        changed = differing("old", "up-boot", field, apis)
        check(f"/api/graph {field} is the same before and after the upgrade" + (f": {', '.join(changed)}" if changed else ""),
              not changed)
    for phase in ("up-backfill", "main-backfill"):
        group = [r for (p, _), r in dbs.items() if p == phase]
        check(f"{phase}: graph_edges holds every expected edge (missing 0, extra 0)",
              all(r["missing"] == 0 and r["extra"] == 0 for r in group) if group else None)
        flags = [r for (p, _), r in apis.items() if p == phase]
        check(f"{phase}: backfill_needed is false in every workspace",
              all(r["backfill_needed"] is False for r in flags) if flags else None)


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "seed":
        seed()
    elif command == "dbsnap":
        dbsnap(sys.argv[2], sys.argv[3])
    elif command == "apisnap":
        apisnap(sys.argv[2])
    elif command == "backfill-api":
        backfill_api()
    elif command == "summary":
        summary()
    else:
        sys.exit(f"unknown command {command}")
PY
}

# A second tenant with a key and, later, one workspace: the copy derives each
# edge's tenant from its workspace row, so a workspace outside the default
# tenant is the case where a wrong tenant label would show. Best effort.
acme_setup() { # src store
  local src=$1 store=$2 out key
  out=$(cli "$src" "$store" mix run -e 'IO.inspect(OptimalEngine.Tenancy.Tenant.create(%{id: "acme", name: "Acme QA"}) |> elem(0))' 2>&1) || true
  echo "ACME_TENANT create: $(printf '%s' "$out" | grep -a -E '^(:ok|:error|\{)' | tail -1)"
  out=$(cli "$src" "$store" mix optimal.auth mint --tenant acme --name acme-qa --workspace '*' --json 2>/dev/null) || true
  key=$(printf '%s' "$out" | grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  if [ -n "$key" ]; then
    (umask 077 && printf '%s' "$key" >"$DATA/keys/acme")
    echo "ACME_KEY minted"
  else
    echo "ACME_KEY not minted: the second-tenant case is skipped"
  fi
}

echo "== environment"
echo "ELIXIR $(elixir --version 2>/dev/null | tail -1)"
echo "PORT $PORT  DATA $DATA"

echo "== sources"
if ! git clone --quiet --no-checkout "$REPO_URL" "$DATA/repo" 2>"$DATA/clone.log"; then
  echo "clone of $REPO_URL failed; taking the refs from the checkout this script ships in"
  git clone --quiet --no-checkout "$ROOT" "$DATA/repo" || fail "no repository to take the refs from"
fi
for pair in "old:$OLD_REF" "up:$UPGRADE_REF" "main:$MAIN_REF"; do
  name=${pair%%:*}
  ref=${pair#*:}
  sha=$(git -C "$DATA/repo" rev-parse --verify --quiet "$ref^{commit}") || fail "ref $ref not found"
  git -C "$DATA/repo" worktree add --quiet --detach "$SRC/$name" "$sha" >/dev/null 2>&1 || fail "checking out $ref"
  echo "REF $name $ref $sha"
done
write_driver

echo "== build $OLD_REF"
build_tree old || fail "building $OLD_REF"
# The other two trees build in the background, one after the other (a RocksDB
# compile is memory-heavy), while $OLD_REF runs.
(
  build_tree up >"$DATA/build-up.out" 2>&1
  echo $? >"$DATA/build-up.status"
  build_tree main >"$DATA/build-main.out" 2>&1
  echo $? >"$DATA/build-main.status"
) &
BUILD_PIDS+=("$!")

STORE_OLD="$STORES/old"
STORE_UP="$STORES/up"
STORE_MAIN="$STORES/main"
mkdir -p "$STORE_OLD"

echo "== (a) $OLD_REF: fresh store"
acme_setup "$SRC/old" "$STORE_OLD"
start_engine old "$SRC/old" "$STORE_OLD" || fail "$OLD_REF did not start"
boot_migrations old

echo "== (b) ingest"
py seed || fail "seeding $OLD_REF"

echo "== (c) $OLD_REF numbers"
py apisnap old
stop_engine
py dbsnap "$STORE_OLD/index.db" old
cp -a "$STORE_OLD" "$STORE_UP" || fail "copying the store"
cp -a "$STORE_OLD" "$STORE_MAIN" || fail "copying the store"

echo "== (d) $UPGRADE_REF boots on the $OLD_REF store"
await_build up || fail "building $UPGRADE_REF"
start_engine up "$SRC/up" "$STORE_UP" || fail "$UPGRADE_REF did not start"
boot_migrations up

echo "== (e) $UPGRADE_REF after the migrations, before any backfill"
py apisnap up-boot
py dbsnap "$STORE_UP/index.db" up-boot
stop_engine

echo "== (f) $UPGRADE_REF: OptimalEngine.Release.graph_backfill() with the service stopped"
cli "$SRC/up" "$STORE_UP" mix run -e 'OptimalEngine.Release.graph_backfill()' >"$DATA/up-backfill-run.log" 2>&1
rc=$?
echo "RELEASE_BACKFILL exit=$rc $(grep -a -E 'Release\] graph backfill' "$DATA/up-backfill-run.log" | tail -2 | sed -E 's/^.*\[Release\]/[Release]/' | tr '\n' ' ')"
py dbsnap "$STORE_UP/index.db" up-backfill
start_engine up-after "$SRC/up" "$STORE_UP" || fail "$UPGRADE_REF did not restart"
py apisnap up-backfill
stop_engine

echo "== (g) $MAIN_REF boots on a second copy of the $OLD_REF store"
await_build main || fail "building $MAIN_REF"
start_engine main "$SRC/main" "$STORE_MAIN" || fail "$MAIN_REF did not start"
boot_migrations main
py apisnap main-boot
py dbsnap "$STORE_MAIN/index.db" main-boot
echo "-- POST /api/maintenance/graph/backfill, workspace by workspace"
py backfill-api
py apisnap main-backfill
stop_engine
py dbsnap "$STORE_MAIN/index.db" main-backfill

echo "== summary"
py summary
echo "PROOF_UPGRADE_GRAPH_SECONDS=$(( $(date +%s) - started ))"
echo "DONE"
