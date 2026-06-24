#!/usr/bin/env bash
# Always-on launcher for the Optimal Engine (launchd KeepAlive).
export PATH="/opt/homebrew/opt/erlang/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export OPTIMAL_API_ENABLED=true
export MIX_ENV=dev
cd /Users/rhl/code/OptimalEngine || exit 1
exec mix run --no-halt
