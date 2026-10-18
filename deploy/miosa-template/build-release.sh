#!/usr/bin/env bash
# Build the Engine release tarball on an x86_64 Docker host. No registry, no push.
#
#   deploy/miosa-template/build-release.sh [OUT_DIR]     # default ./out
#
# BUILDER_IMAGE (optional) names a bookworm-based Elixir image the host already has.
# Writes OUT_DIR/optimal-engine.tgz and prints its sha256. Run it on a MIOSA build
# host (x86_64), not on a laptop: the rocksdb compile takes 30 to 60 minutes.
# Then stage-release.sh puts the tarball in a MIOSA bucket and create-template.sh
# turns it into the `optimal-engine` sandbox template.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-$root/out}"
mkdir -p "$out"

if [ "$(uname -m)" != "x86_64" ] && [ "${ALLOW_NON_X86:-0}" != "1" ]; then
  echo "refusing to build on $(uname -m): the MIOSA hosts are x86_64 (set ALLOW_NON_X86=1 for a smoke build)" >&2
  exit 2
fi

args=()
[ -n "${BUILDER_IMAGE:-}" ] && args+=(--build-arg "BUILDER_IMAGE=$BUILDER_IMAGE")
docker build --target release "${args[@]}" -f "$root/deploy/Dockerfile.engine" -o "type=local,dest=$out" "$root"
test -s "$out/optimal-engine.tgz"
sha="$(sha256sum "$out/optimal-engine.tgz" | cut -d' ' -f1)"
echo
echo "Built $out/optimal-engine.tgz ($(du -h "$out/optimal-engine.tgz" | cut -f1))"
echo "RELEASE_SHA256=$sha"
