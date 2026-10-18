#!/bin/sh
# Installs the optimal client CLI and its oe alias.
# Usage: ./install.sh [prefix]
#   prefix defaults to $PREFIX, else /usr/local when writable, else ~/.local.
#   The programs go to <prefix>/bin.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix=${1:-${PREFIX:-}}
if [ -z "$prefix" ]; then
  if [ -w /usr/local/bin ]; then prefix=/usr/local; else prefix=${HOME:?}/.local; fi
fi
bin=$prefix/bin

command -v curl >/dev/null 2>&1 || echo "install: warning: curl is not installed; optimal needs curl 7.55 or newer" >&2

mkdir -p "$bin"
cp "$here/optimal" "$bin/optimal.tmp.$$"
chmod 0755 "$bin/optimal.tmp.$$"
mv -f "$bin/optimal.tmp.$$" "$bin/optimal"
ln -sf optimal "$bin/oe"

echo "installed $("$bin/optimal" --version) to $bin (oe is an alias)"
case :${PATH:-}: in
  *:"$bin":*) ;;
  *) echo "add $bin to PATH to run optimal and oe" ;;
esac
