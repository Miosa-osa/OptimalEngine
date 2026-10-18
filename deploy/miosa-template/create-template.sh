#!/usr/bin/env bash
# Create (or update) the `optimal-engine` sandbox template in one MIOSA organization.
#
#   MIOSA_API_KEY=msk_... ENGINE_IMAGE=registry/optimal-engine@sha256:<64 hex> \
#     deploy/miosa-template/create-template.sh [--dry-run]
#
# ENGINE_IMAGE must be digest-pinned: a tag can move under a running Memory.
# --dry-run renders and validates the spec with the platform and creates nothing.
# The key is read from the environment and never printed.
set -euo pipefail

API="${MIOSA_API_URL:-https://api.miosa.ai/api/v1}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

: "${MIOSA_API_KEY:?set MIOSA_API_KEY}"
: "${ENGINE_IMAGE:?set ENGINE_IMAGE to repo@sha256:<64 hex>}"

if ! [[ "$ENGINE_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
  echo "ENGINE_IMAGE must look like repo@sha256:<64 hex digits> (no tag)" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
body="$(sed "s|__ENGINE_IMAGE__|${ENGINE_IMAGE}|" "$here/build-spec.json.tmpl")"

call() { # method path [body]
  curl -sS -m 60 -X "$1" "$API$2" \
    -H "Authorization: Bearer ${MIOSA_API_KEY}" \
    -H "Content-Type: application/json" \
    ${3:+--data "$3"} -w '\n%{http_code}'
}

split() { out="$1"; code="${out##*$'\n'}"; text="${out%$'\n'*}"; }

split "$(call POST /sandbox-templates/validate "$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["build_spec"]))')")"
if [ "$code" != "200" ]; then
  echo "BuildSpec rejected ($code): $text" >&2
  exit 1
fi
echo "BuildSpec valid."
[ "$DRY" = 1 ] && exit 0

split "$(call POST /sandbox-templates "$body")"
case "$code" in
  201 | 200) echo "Template created; its first build was started. Watch it: miosa template builds optimal-engine" ;;
  *) echo "Create failed ($code): $text" >&2; exit 1 ;;
esac
