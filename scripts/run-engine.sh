#!/usr/bin/env bash
# Always-on launcher for the Optimal Engine (launchd KeepAlive).
set -euo pipefail

export PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export OPTIMAL_API_ENABLED=true
export MIX_ENV=dev
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p .optimal

if [ -z "${CONNECTOR_KEY:-}" ]; then
  key_file=".optimal/connector_key"

  if [ ! -f "$key_file" ]; then
    umask 077
    openssl rand -hex 32 > "$key_file"
  fi

  chmod 600 "$key_file"
  CONNECTOR_KEY="$(tr -d '[:space:]' < "$key_file")"
  export CONNECTOR_KEY
fi

exec mix run --no-halt
