#!/bin/sh
# Builds the client CLI release artifacts:
#   <out>/optimal-<version>-<os>-<arch>.tar.gz for linux-amd64, linux-arm64,
#   darwin-amd64 and darwin-arm64, plus <out>/SHA256SUMS.
# The client is one POSIX shell program, so every archive holds the same files;
# they are named per platform so installers and images fetch by platform.
# Usage: apps/cli/build.sh [out-dir]   (default: dist/cli)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/dist/cli}

version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$root/mix.exs")
cli_version=$(sed -n 's/^OPTIMAL_CLI_VERSION=\(.*\)$/\1/p' "$here/optimal")
[ -n "$version" ] || { echo "build: cannot read @version from mix.exs" >&2; exit 1; }
if [ "$version" != "$cli_version" ]; then
  echo "build: apps/cli/optimal says $cli_version but mix.exs says $version" >&2
  exit 1
fi

for shell in sh dash bash; do
  if command -v "$shell" >/dev/null 2>&1; then
    "$shell" -n "$here/optimal" || { echo "build: $shell rejects apps/cli/optimal" >&2; exit 1; }
  fi
done

if command -v sha256sum >/dev/null 2>&1; then
  sum() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  sum() { shasum -a 256 "$@"; }
else
  echo "build: need sha256sum or shasum" >&2
  exit 1
fi

mkdir -p "$out"
stage=$(mktemp -d "${TMPDIR:-/tmp}/optimal-cli-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT

for platform in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64; do
  name=optimal-$version-$platform
  mkdir -p "$stage/$name"
  cp "$here/optimal" "$here/install.sh" "$stage/$name/"
  cp "$root/LICENSE" "$stage/$name/LICENSE"
  chmod 0755 "$stage/$name/optimal" "$stage/$name/install.sh"
  ln -s optimal "$stage/$name/oe"
  printf '%s\n' "$version" >"$stage/$name/VERSION"
  tar -C "$stage" -czf "$out/$name.tar.gz" "$name"
done

(cd "$out" && sum optimal-"$version"-*.tar.gz >SHA256SUMS)
echo "built optimal $version into $out"
