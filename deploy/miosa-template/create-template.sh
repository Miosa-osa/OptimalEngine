#!/usr/bin/env bash
# Create (or update) the `optimal-engine` sandbox template in one MIOSA organization.
#
#   MIOSA_API_KEY=msk_... RELEASE_URL=<presigned url> RELEASE_SHA256=<64 hex> \
#     deploy/miosa-template/create-template.sh [--dry-run]
#
# The template is the `miosa-sandbox` base plus build steps that download the Engine
# release tarball (stage-release.sh puts it in a MIOSA bucket and prints both values),
# check its sha256, and unpack it. No registry, no GitHub.
# --dry-run renders and validates the spec with the platform and creates nothing.
# The key is read from the environment and never printed.
set -euo pipefail

API="${MIOSA_API_URL:-https://api.miosa.ai/api/v1}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

: "${MIOSA_API_KEY:?set MIOSA_API_KEY}"
: "${RELEASE_URL:?set RELEASE_URL (from stage-release.sh)}"
: "${RELEASE_SHA256:?set RELEASE_SHA256 (from stage-release.sh)}"

if ! [[ "$RELEASE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "RELEASE_SHA256 must be 64 hex digits" >&2
  exit 2
fi
case "$RELEASE_URL" in
  https://*) ;;
  *) echo "RELEASE_URL must be https" >&2; exit 2 ;;
esac
case "$RELEASE_URL" in
  *"'"*) echo "RELEASE_URL must not contain a quote" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
body="$(python3 - "$here/build-spec.json.tmpl" "$RELEASE_URL" "$RELEASE_SHA256" <<'PY'
import sys
text = open(sys.argv[1]).read()
print(text.replace("__RELEASE_URL__", sys.argv[2]).replace("__RELEASE_SHA256__", sys.argv[3]))
PY
)"

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
