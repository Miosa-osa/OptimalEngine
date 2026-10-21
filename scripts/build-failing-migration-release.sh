#!/usr/bin/env bash
# Builds a test release of the upgrade rollback drill (WO-39).
#
# The release is the Engine at HEAD plus migrations that fail on purpose
# (OptimalEngine.Store.FailingMigration), and its version says so. Staged as an
# upgrade target, it must make an upgrade roll back: it never answers, because
# its store cannot open. It cannot boot, so it can never pass conformance or be
# promoted, and scripts/check_release_version.exs refuses to release it.
#
# Usage: scripts/build-failing-migration-release.sh OUT_DIR [--passing-first] [--mix]
#
#   default          migration 9000001 fails: the store keeps its counter and data
#                    (version <v>-failing-migration)
#   --passing-first  migration 9000001 passes, then 9000002 fails: the store is
#                    left between releases, and only the pre-boot backup restores it
#                    (version <v>-passing-then-failing-migration)
#   --mix            build with the local Mix toolchain (MIX_ENV=prod mix release)
#                    in a build directory of its own, for a host without Docker; the
#                    archive then carries no bundled shared libraries
#
# The release channel is always dev: a test release serves no channel.
# The default build is the release pipeline's: deploy/Dockerfile.engine --target
# release (BUILDER_IMAGE names a builder image, as for build-release.sh). Writes
# OUT_DIR/optimal-engine-<version>-<sha>.tgz, OUT_DIR/SHA256SUMS and
# OUT_DIR/identity.json: the identity the release itself reports, read with
# `bin/optimal eval` because it cannot start. Then prints how to stage it for
# the drill (docs/guides/versioning-and-releases.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=
CHANNEL=dev
MODE=docker
VARIANT=1
SUFFIX=-failing-migration
# OptimalEngine.Store.FailingMigration.reserved_base/0 plus the variant's migrations.
EXPECTED_MIGRATION=9000001

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case $1 in
    --mix)
      MODE=mix
      shift
      ;;
    --passing-first)
      VARIANT=2
      SUFFIX=-passing-then-failing-migration
      EXPECTED_MIGRATION=9000002
      shift
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [ -z "$OUT" ] || usage
      OUT=$1
      shift
      ;;
  esac
done
[ -n "$OUT" ] || usage

die() {
  echo "build-failing-migration-release: $*" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# The artifact names its commit, so it must be exactly that commit.
[ -z "$(git -C "$ROOT" status --porcelain)" ] ||
  die "the checkout has uncommitted changes; build from a clean commit"

BASE_VERSION=$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$ROOT/mix.exs")
case $BASE_VERSION in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "cannot read @version from mix.exs" ;;
esac
case $BASE_VERSION in *-*) die "mix.exs version $BASE_VERSION already has a suffix" ;; esac
VERSION=$BASE_VERSION$SUFFIX
SHA=$(git -C "$ROOT" rev-parse HEAD)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ARTIFACT=$OUT/optimal-engine-$VERSION-$SHA.tgz

echo "== building $VERSION at $SHA ($MODE)"

case $MODE in
  docker)
    args=(
      --build-arg "OPTIMAL_ENGINE_GIT_SHA=$SHA"
      --build-arg "OPTIMAL_ENGINE_BUILD_TIMESTAMP=$TS"
      --build-arg "OPTIMAL_RELEASE_CHANNEL=$CHANNEL"
      --build-arg "OPTIMAL_BUILD_FAILING_MIGRATION=$VARIANT"
    )
    [ -n "${BUILDER_IMAGE:-}" ] && args+=(--build-arg "BUILDER_IMAGE=$BUILDER_IMAGE")
    docker build --target release "${args[@]}" \
      -f "$ROOT/deploy/Dockerfile.engine" -o "type=local,dest=$WORK/out" "$ROOT"
    mv "$WORK/out/optimal-engine.tgz" "$ARTIFACT"
    ;;
  mix)
    # A build directory of its own: the flag is read at compile time, and a
    # shared _build must never keep a module compiled with it. Seeded from
    # _build/prod so dependencies are not rebuilt; Mix links each priv
    # directory relatively, so the copy follows the links.
    if [ -d "$ROOT/_build/prod" ]; then cp -R -L -p "$ROOT/_build/prod" "$WORK/build"; fi
    (
      cd "$ROOT"
      export MIX_ENV=prod MIX_BUILD_PATH="$WORK/build" OPTIMAL_BUILD_FAILING_MIGRATION="$VARIANT" \
        OPTIMAL_ENGINE_GIT_SHA="$SHA" OPTIMAL_ENGINE_BUILD_TIMESTAMP="$TS" \
        OPTIMAL_RELEASE_CHANNEL="$CHANNEL"
      mix deps.get >/dev/null
      mix compile --force
      mix release optimal --overwrite --path "$WORK/pkg/optimal-engine"
    )
    install -m 0755 "$ROOT/deploy/miosa-template/start-engine" "$WORK/pkg/optimal-engine/start-engine"
    tar czf "$ARTIFACT" -C "$WORK/pkg" optimal-engine
    ;;
esac

# The identity the artifact reports, from the release itself, after its native
# libraries load: the release must fail on its migration and on nothing else.
mkdir -p "$WORK/check"
tar xzf "$ARTIFACT" -C "$WORK/check"
cmp -s "$WORK/check/optimal-engine/start-engine" "$ROOT/deploy/miosa-template/start-engine" ||
  die "the archive's start-engine is not deploy/miosa-template/start-engine"
IDENTITY=$(
  cd "$WORK/check"
  RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP_SECONDS=0 \
    LD_LIBRARY_PATH="$WORK/check/optimal-engine/libextra" \
    optimal-engine/bin/optimal eval '
      Application.load(:optimal_engine)
      {:module, _} = Code.ensure_loaded(:rocksdb)
      {:module, _} = Code.ensure_loaded(Exqlite.Sqlite3NIF)
      info = OptimalEngine.Version.info()
      fields = [:version, :git_sha, :build_timestamp, :expected_migration, :release_channel]
      IO.puts(Jason.encode!(Map.take(info, fields)))
    ' | grep '^{' | tail -1
) || die "the release did not report its identity or its native libraries did not load"
[ -n "$IDENTITY" ] || die "the release did not report its identity or its native libraries did not load"
printf '%s\n' "$IDENTITY" >"$OUT/identity.json"

field() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$OUT/identity.json" "$1"
}
[ "$(field version)" = "$VERSION" ] || die "the release reports version $(field version), not $VERSION"
[ "$(field git_sha)" = "$SHA" ] || die "the release reports commit $(field git_sha), not $SHA"
[ "$(field build_timestamp)" = "$TS" ] || die "the release reports build time $(field build_timestamp), not $TS"
[ "$(field release_channel)" = "$CHANNEL" ] || die "the release reports channel $(field release_channel), not $CHANNEL"
MIGRATION=$(field expected_migration)
[ "$MIGRATION" = "$EXPECTED_MIGRATION" ] ||
  die "the release expects migration $MIGRATION, not the reserved $EXPECTED_MIGRATION"

(cd "$OUT" && sha256 "$(basename "$ARTIFACT")") >"$OUT/SHA256SUMS"

cat <<EOF
built     $ARTIFACT
identity  version $VERSION, commit $SHA, migration $MIGRATION, channel $CHANNEL
sha256    $(cut -d' ' -f1 "$OUT/SHA256SUMS")

Stage it for the drill only: on the QA host, under a staging root of its own
(MIOSA_OPTIMAL_ENGINE_STAGING_ROOT), never the fleet's, where a new Engine
would be created on it. engine-release refuses to write a manifest for a
-failing-migration version; see "Stage it" in docs/guides/versioning-and-releases.md.
EOF
