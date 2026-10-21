#!/usr/bin/env bash
# Stage 3 acceptance for the PostgreSQL provider, with whole engines
# (docs/guides/postgres-provider.md).
#
# Builds the engine with the PostgreSQL store (OPTIMAL_STORE=postgres), boots
# two engine processes against one database, and has each write one
# workspace through OptimalEngine.Store at the same time for 50 rounds
# (test/support/postgres_writer.ex), while both publish policy packs for one
# scope. A third process then checks that nothing was lost, that every pack
# took its own version, that search and replication were refused by name, and
# that the embedded SQLite store, given the same writes, answers 20 queries
# exactly as PostgreSQL does.
#
# The proof writes only to a PostgreSQL schema of its own, oe_proof_<time>_<pid>,
# and drops it at the end. It never takes the schema from OPTIMAL_POSTGRES_SCHEMA,
# which names a real store's schema; OPTIMAL_PROOF_SCHEMA may name another one,
# and only a name that starts with oe_proof_ is accepted or dropped.
#
# Usage: OPTIMAL_POSTGRES_URL=postgres://... scripts/proof-postgres-two-engines.sh
#        scripts/proof-postgres-two-engines.sh --print-schema
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

proof_schema_name() {
  [[ "$1" =~ ^oe_proof_[a-z0-9_]+$ ]]
}

PROOF_SCHEMA="${OPTIMAL_PROOF_SCHEMA:-oe_proof_$(date +%s)_$$}"
if ! proof_schema_name "$PROOF_SCHEMA"; then
  echo "refusing schema $PROOF_SCHEMA: the proof only writes and drops a schema named oe_proof_..." >&2
  exit 2
fi

if [ "${1:-}" = "--print-schema" ]; then
  echo "$PROOF_SCHEMA"
  exit 0
fi

: "${OPTIMAL_POSTGRES_URL:?set OPTIMAL_POSTGRES_URL to a database the proof may write}"

DATA="${DATA:-$(mktemp -d)}"
mkdir -p "$DATA"
export MIX_ENV=dev
export OPTIMAL_STORE=postgres
# The engines the proof starts read their schema from here.
export OPTIMAL_POSTGRES_SCHEMA="$PROOF_SCHEMA"
export OPTIMAL_PROOF_WORKSPACE="pg-engines-$(date +%s)"
export OPTIMAL_PROOF_DIR="$DATA"
export OPTIMAL_AUTHORITY_KEY="${OPTIMAL_AUTHORITY_KEY:-$(openssl rand -hex 32)}"
export CONNECTOR_KEY="${CONNECTOR_KEY:-$(openssl rand -hex 32)}"

fail() {
  echo "FAIL $1"
  for log in "$DATA"/*.log; do
    [ -f "$log" ] && { echo "--- $log"; tail -20 "$log"; }
  done
  exit 1
}

engine_env() {
  local name=$1
  mkdir -p "$DATA/$name/cache"
  echo "OPTIMAL_ENGINE_ROOT=$DATA/$name OPTIMAL_ENGINE_DB=$DATA/$name/index.db OPTIMAL_ENGINE_CACHE=$DATA/$name/cache"
}

drop_schema() {
  if ! proof_schema_name "$PROOF_SCHEMA"; then
    echo "refusing to drop schema $PROOF_SCHEMA" >&2
    return 0
  fi

  env $(engine_env cleanup) OPTIMAL_PROOF_SCHEMA="$PROOF_SCHEMA" mix run --no-compile --no-start -e '
    schema = System.fetch_env!("OPTIMAL_PROOF_SCHEMA")
    unless schema =~ ~r/\Aoe_proof_[a-z0-9_]+\z/, do: raise("refusing to drop schema #{schema}")
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, config} = OptimalEngine.Storage.Postgres.config()
    {:ok, conn} = config |> Map.take([:hostname, :port, :database, :username, :password, :ssl]) |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Postgrex.start_link()
    Postgrex.query!(conn, ~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE), [])
  ' >/dev/null 2>&1 || true
}
trap drop_schema EXIT

echo "== build with the PostgreSQL store"
mix compile >"$DATA/compile.log" 2>&1 || fail "compile"

echo "== setup: schema $OPTIMAL_POSTGRES_SCHEMA, workspace $OPTIMAL_PROOF_WORKSPACE"
env $(engine_env setup) mix run --no-compile --no-start scripts/postgres_two_engines.exs setup 2>"$DATA/setup.log" ||
  fail "setup"

echo "== two engines write one workspace"
pids=()
for writer in 1 2; do
  env $(engine_env "engine-$writer") mix run --no-compile scripts/postgres_two_engines.exs writer "$writer" \
    >"$DATA/writer-$writer.out" 2>"$DATA/writer-$writer.log" &
  pids+=("$!")
done

for _ in $(seq 1 1200); do
  [ -f "$DATA/ready-1" ] && [ -f "$DATA/ready-2" ] && break
  sleep 0.1
done
[ -f "$DATA/ready-1" ] && [ -f "$DATA/ready-2" ] || fail "the engines did not boot"
touch "$DATA/go"

for pid in "${pids[@]}"; do wait "$pid" || fail "a writer engine failed"; done
grep -h "^engine " "$DATA/writer-1.out" "$DATA/writer-2.out" || true

echo "== check, and compare with the embedded SQLite copy"
env $(engine_env check) mix run --no-compile --no-start scripts/postgres_two_engines.exs check \
  2>"$DATA/check.log" | grep -E "^(PASS|FAIL|engine|mismatches)" || fail "check"

echo "PASS two engines on one PostgreSQL workspace"
