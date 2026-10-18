#!/usr/bin/env bash
# Put the release tarball in a MIOSA bucket and print a download URL for the template build.
#
#   MIOSA_API_KEY=msk_... BUCKET_ID=<uuid> deploy/miosa-template/stage-release.sh out/optimal-engine.tgz
#
# Prints RELEASE_URL (a presigned GET, valid 24 hours) and RELEASE_SHA256 for create-template.sh.
# The key is read from the environment and never printed. The bucket must not be `private`:
# a presigned link needs access policy `signed`. Everything stays on MIOSA's own storage.
set -euo pipefail

file="${1:?path to optimal-engine.tgz}"
: "${MIOSA_API_KEY:?set MIOSA_API_KEY}"
: "${BUCKET_ID:?set BUCKET_ID (a MIOSA storage bucket of the organization that builds the template)}"
API="${MIOSA_API_URL:-https://api.miosa.ai/api/v1}"
key="${RELEASE_KEY:-releases/optimal-engine/$(date -u +%Y%m%dT%H%M%SZ).tgz}"

sha="$(sha256sum "$file" | cut -d' ' -f1)"

code="$(curl -sS -m 600 -o /dev/null -w '%{http_code}' -X PUT "$API/storage/buckets/$BUCKET_ID/objects/$key" \
  -H "Authorization: Bearer $MIOSA_API_KEY" -H "Content-Type: application/gzip" --data-binary "@$file")"
[ "$code" = "200" ] || { echo "upload failed ($code)" >&2; exit 1; }

resp="$(curl -sS -m 60 -X POST "$API/storage/buckets/$BUCKET_ID/presign" \
  -H "Authorization: Bearer $MIOSA_API_KEY" -H "Content-Type: application/json" \
  --data "{\"key\":\"$key\",\"method\":\"GET\",\"expires_in\":86400}")"
url="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))')"
[ -n "$url" ] || { echo "presign failed: $resp" >&2; exit 1; }

echo "RELEASE_URL=$url"
echo "RELEASE_SHA256=$sha"
