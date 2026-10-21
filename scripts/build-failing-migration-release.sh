#!/usr/bin/env bash
# Builds the test release of the upgrade rollback drill (WO-39).
#
# The release is the Engine at HEAD plus one migration that fails on purpose
# (OptimalEngine.Store.FailingMigration), and its version ends in
# -failing-migration. Staged as an upgrade target, it must make an upgrade roll
# back: the new release never answers because its store cannot open, and the
# previous release starts again on a store that kept its migration counter and
# its data. It cannot boot, so it can never pass conformance or be promoted.
#
# Usage: scripts/build-failing-migration-release.sh OUT_DIR [--channel beta] [--mix]
#
#   default   the release pipeline: deploy/Dockerfile.engine --target release
#   --mix     the local Mix toolchain (MIX_ENV=prod mix release) in a build
#             directory of its own, for a host without Docker; the archive then
#             carries no bundled shared libraries
#   --channel the release channel the manifest will name (default beta)
#
# Writes OUT_DIR/optimal-engine-<version>-<sha>.tgz, OUT_DIR/SHA256SUMS and
# OUT_DIR/identity.json: the identity the release itself reports, read with
# `bin/optimal eval` because it cannot start. Then prints the engine-release
# manifest command for staging (docs/guides/versioning-and-releases.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUFFIX=-failing-migration
OUT=
CHANNEL=beta
MODE=docker

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 64
}

while [ $# -gt 0 ]; do
  case $1 in
    --channel)
      [ $# -ge 2 ] || usage
      CHANNEL=$2
      shift 2
      ;;
    --mix)
      MODE=mix
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
case $CHANNEL in dev | stable | beta | pinned) ;; *) echo "unknown channel $CHANNEL" >&2 && exit 64 ;; esac

die() {
  echo "build-failing-migration-release: $*" >&2
  exit 1
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
    docker build --target release \
      --build-arg OPTIMAL_ENGINE_GIT_SHA="$SHA" \
      --build-arg OPTIMAL_ENGINE_BUILD_TIMESTAMP="$TS" \
      --build-arg OPTIMAL_RELEASE_CHANNEL="$CHANNEL" \
      --build-arg OPTIMAL_BUILD_FAILING_MIGRATION=1 \
      -f "$ROOT/deploy/Dockerfile.engine" \
      -o type=local,dest="$WORK/out" \
      "$ROOT"
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
      export MIX_ENV=prod MIX_BUILD_PATH="$WORK/build" OPTIMAL_BUILD_FAILING_MIGRATION=1 \
        OPTIMAL_ENGINE_GIT_SHA="$SHA" OPTIMAL_ENGINE_BUILD_TIMESTAMP="$TS" \
        OPTIMAL_RELEASE_CHANNEL="$CHANNEL"
      mix deps.get >/dev/null
      mix compile --force
      mix release optimal --overwrite --path "$WORK/pkg/optimal-engine"
    )
    # The start script of deploy/Dockerfile.engine's packager stage.
    printf '%s\n' '#!/bin/sh' \
      'ROOT="$(cd "$(dirname "$0")" && pwd)"' \
      'export LD_LIBRARY_PATH="$ROOT/libextra${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"' \
      'export RELEASE_COOKIE="${RELEASE_COOKIE:-optimal_engine_sandbox}"' \
      'export OPTIMAL_API_ENABLED="${OPTIMAL_API_ENABLED:-true}"' \
      'export OPTIMAL_API_INTERFACE="${OPTIMAL_API_INTERFACE:-0.0.0.0}"' \
      'export OPTIMAL_API_PORT="${OPTIMAL_API_PORT:-4200}"' \
      'export OPTIMAL_ENGINE_ROOT="${OPTIMAL_ENGINE_ROOT:-/data}"' \
      'export OPTIMAL_ENGINE_DB="${OPTIMAL_ENGINE_DB:-/data/.optimal/index.db}"' \
      'export OPTIMAL_ENGINE_CACHE="${OPTIMAL_ENGINE_CACHE:-/data/.optimal/cache}"' \
      'mkdir -p /data/.optimal' \
      'exec "$ROOT/bin/optimal" start' \
      >"$WORK/pkg/optimal-engine/start-engine"
    chmod +x "$WORK/pkg/optimal-engine/start-engine"
    tar czf "$ARTIFACT" -C "$WORK/pkg" optimal-engine
    ;;
esac

# The identity the artifact reports, from the release itself, after its native
# libraries load: the release must fail on its migration and on nothing else.
mkdir -p "$WORK/check"
tar xzf "$ARTIFACT" -C "$WORK/check"
IDENTITY=$(
  cd "$WORK/check"
  RELEASE_DISTRIBUTION=none OPTIMAL_RELEASE_CHANNEL="$CHANNEL" \
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
MIGRATION=$(field expected_migration)

(
  cd "$OUT"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$(basename "$ARTIFACT")"
  else
    shasum -a 256 "$(basename "$ARTIFACT")"
  fi
) >"$OUT/SHA256SUMS"

cat <<EOF
built     $ARTIFACT
identity  version $VERSION, commit $SHA, migration $MIGRATION, channel $CHANNEL
sha256    $(cut -d' ' -f1 "$OUT/SHA256SUMS")

Stage it like any release, in a directory of its own:
  engine-release manifest --artifact $ARTIFACT \\
    --version $VERSION --git-sha $SHA --build-timestamp $TS \\
    --expected-migration $MIGRATION --channel $CHANNEL --out $OUT/manifest.json
EOF
