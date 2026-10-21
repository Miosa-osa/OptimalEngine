#!/bin/sh
# Builds the MCP server release artifact:
#   <out>/optimal-engine-mcp-<version>.tar.gz and its line in <out>/SHA256SUMS
#   (other lines, such as the CLI archives' from apps/cli/build.sh, are kept).
# The server is JavaScript, so one archive serves every platform; it needs Node.js 20
# or newer. The archive holds optimal-engine-mcp-<version>/ with dist/, the production
# node_modules/ from package-lock.json, package.json, LICENSE and VERSION.
# The build runs in a scratch copy, so the checkout's node_modules and dist are untouched.
# Usage: apps/mcp/build.sh [out-dir]   (default: dist/cli, beside the CLI archives)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=${1:-$root/dist/cli}

version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$root/mix.exs")
[ -n "$version" ] || { echo "build: cannot read @version from mix.exs" >&2; exit 1; }
package_version=$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$here/package.json" | head -1)
server_version=$(sed -n 's/^export const MCP_VERSION = "\(.*\)";$/\1/p' "$here/src/version.ts" | head -1)
if [ "$package_version" != "$version" ] || [ "$server_version" != "$version" ]; then
  echo "build: apps/mcp says $package_version (package.json) and $server_version (src/version.ts) but mix.exs says $version" >&2
  exit 1
fi

command -v npm >/dev/null 2>&1 || { echo "build: npm is required" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then
  sum() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  sum() { shasum -a 256 "$@"; }
else
  echo "build: need sha256sum or shasum" >&2
  exit 1
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/optimal-mcp-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT

work=$stage/work
mkdir -p "$work"
cp "$here/package.json" "$here/package-lock.json" "$here/tsconfig.json" "$work/"
cp -R "$here/src" "$work/src"
(
  cd "$work"
  npm ci --no-audit --no-fund --loglevel=error
  npm run build --silent
  npm prune --omit=dev --no-audit --no-fund --loglevel=error
)

name=optimal-engine-mcp-$version
mkdir -p "$stage/$name"
cp -R "$work/dist" "$work/node_modules" "$work/package.json" "$stage/$name/"
cp "$root/LICENSE" "$stage/$name/LICENSE"
printf '%s\n' "$version" >"$stage/$name/VERSION"
tar -C "$stage" -czf "$out/$name.tar.gz" "$name"

(
  cd "$out"
  {
    [ ! -f SHA256SUMS ] || grep -v "  optimal-engine-mcp-$version.tar.gz\$" SHA256SUMS || true
    sum "$name.tar.gz"
  } | sort -k 2 >SHA256SUMS.tmp
  mv SHA256SUMS.tmp SHA256SUMS
)
echo "built optimal-engine-mcp $version into $out"
