#!/usr/bin/env bash
# Create (or update) the `optimal-engine` sandbox template in one MIOSA organization.
#
#   MIOSA_API_KEY=msk_... RELEASE_URLS='<url> <url> ...' RELEASE_SHA256=<64 hex> \
#     deploy/miosa-template/create-template.sh [--dry-run]
#
# The template is the `miosa-sandbox` base plus build steps that download the Engine
# release tarball in parts (stage-release.sh puts it in a MIOSA bucket and prints both values),
# check its sha256, and unpack it. No registry, no GitHub.
# --dry-run renders and validates the spec with the platform and creates nothing.
# The key is read from the environment and never printed.
set -euo pipefail

API="${MIOSA_API_URL:-https://api.miosa.ai/api/v1}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

: "${MIOSA_API_KEY:?set MIOSA_API_KEY}"
: "${RELEASE_URLS:?set RELEASE_URLS, the part urls from stage-release.sh separated by spaces}"
: "${RELEASE_SHA256:?set RELEASE_SHA256 (from stage-release.sh)}"

if ! [[ "$RELEASE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "RELEASE_SHA256 must be 64 hex digits" >&2
  exit 2
fi
for u in $RELEASE_URLS; do
  case "$u" in
    https://*) ;;
    *) echo "every release url must be https" >&2; exit 2 ;;
  esac
  case "$u" in
    *"'"*) echo "a release url must not contain a quote" >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
body="$(python3 - "$here/build-spec.json.tmpl" "$RELEASE_SHA256" $RELEASE_URLS <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
sha, urls = sys.argv[2], sys.argv[3:]
# Bucket objects are capped in size, so the release is downloaded in parts and joined.
steps = [
    {"run": "curl -fsSL --retry 3 --retry-delay 2 -o /tmp/oe.part%02d '%s'" % (i, url), "timeout": 600}
    for i, url in enumerate(urls)
]
steps += [
    {"run": "cat /tmp/oe.part* > /tmp/optimal-engine.tgz && rm -f /tmp/oe.part*"},
    {"run": "echo '%s  /tmp/optimal-engine.tgz' | sha256sum -c -" % sha},
    {"run": "mkdir -p /opt /data/.optimal && tar xzf /tmp/optimal-engine.tgz -C /opt && rm -f /tmp/optimal-engine.tgz", "timeout": 300},
    {"run": "/opt/optimal-engine/bin/optimal version"},
]
spec["build_spec"]["steps"] = steps
print(json.dumps(spec))
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
