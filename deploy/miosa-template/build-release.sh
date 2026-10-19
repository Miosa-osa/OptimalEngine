#!/usr/bin/env bash
# Build the Engine release tarball on an x86_64 Docker host. No registry, no push.
#
#   deploy/miosa-template/build-release.sh [OUT_DIR]     # default ./out
#
# BUILDER_IMAGE (optional) names a bookworm-based Elixir image the host already has.
# Writes OUT_DIR/optimal-engine.tgz (the name create-template.sh expects) plus a
# versioned hardlink OUT_DIR/optimal-engine-<version>-<sha>.tgz and SHA256SUMS.
# Run it on a MIOSA build host (x86_64), not on a laptop: the rocksdb compile
# takes 30 to 60 minutes.
#
# The release identity is compiled into the artifact, so the three values below
# must be passed rather than left to a Docker cache:
#   OPTIMAL_ENGINE_GIT_SHA          default: the checkout's HEAD
#   OPTIMAL_ENGINE_BUILD_TIMESTAMP  default: now, UTC
#   OPTIMAL_RELEASE_CHANNEL         default: dev; a release passes beta or stable
# DRY_RUN=1 prints the docker command (and the identity) without building.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-$root/out}"
mkdir -p "$out"

if [ "$(uname -m)" != "x86_64" ] && [ "${ALLOW_NON_X86:-0}" != "1" ]; then
  echo "refusing to build on $(uname -m): the MIOSA hosts are x86_64 (set ALLOW_NON_X86=1 for a smoke build)" >&2
  exit 2
fi

git_sha="${OPTIMAL_ENGINE_GIT_SHA:-$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)}"
build_timestamp="${OPTIMAL_ENGINE_BUILD_TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
release_channel="${OPTIMAL_RELEASE_CHANNEL:-dev}"

args=(
  --build-arg "OPTIMAL_ENGINE_GIT_SHA=$git_sha"
  --build-arg "OPTIMAL_ENGINE_BUILD_TIMESTAMP=$build_timestamp"
  --build-arg "OPTIMAL_RELEASE_CHANNEL=$release_channel"
)
[ -n "${BUILDER_IMAGE:-}" ] && args+=(--build-arg "BUILDER_IMAGE=$BUILDER_IMAGE")

if [ "${DRY_RUN:-0}" = "1" ]; then
  printf 'docker build --target release'
  printf ' %q' "${args[@]}"
  printf ' -f %q -o type=local,dest=%q %q\n' "$root/deploy/Dockerfile.engine" "$out" "$root"
  printf 'RELEASE_GIT_SHA=%s\nRELEASE_BUILD_TIMESTAMP=%s\nRELEASE_CHANNEL=%s\n' \
    "$git_sha" "$build_timestamp" "$release_channel"
  exit 0
fi

docker build --target release "${args[@]}" -f "$root/deploy/Dockerfile.engine" -o "type=local,dest=$out" "$root"
test -s "$out/optimal-engine.tgz"

version="$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$root/mix.exs")"
[ -n "$version" ] || { echo "build: cannot read @version from mix.exs" >&2; exit 1; }
versioned="optimal-engine-$version-$git_sha.tgz"
ln -f "$out/optimal-engine.tgz" "$out/$versioned" 2>/dev/null || cp "$out/optimal-engine.tgz" "$out/$versioned"

sha="$(sha256sum "$out/$versioned" | cut -d' ' -f1)"
(cd "$out" && sha256sum "$versioned" >SHA256SUMS)

echo
echo "Built $out/$versioned ($(du -h "$out/optimal-engine.tgz" | cut -f1))"
echo "RELEASE_ARTIFACT=$out/$versioned"
echo "RELEASE_VERSION=$version"
echo "RELEASE_GIT_SHA=$git_sha"
echo "RELEASE_BUILD_TIMESTAMP=$build_timestamp"
echo "RELEASE_CHANNEL=$release_channel"
echo "RELEASE_SHA256=$sha"
