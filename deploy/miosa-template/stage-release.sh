#!/usr/bin/env bash
# Put the release tarball in a MIOSA bucket and print download URLs for the template build.
#
#   MIOSA_API_KEY=<key or session token> BUCKET_ID=<uuid> deploy/miosa-template/stage-release.sh out/optimal-engine.tgz
#
# Bucket objects are capped in size (a few MB per request), so the tarball goes up in
# 4 MB parts. Prints RELEASE_URLS (presigned GETs, valid 24 hours, space separated) and
# RELEASE_SHA256 (of the whole tarball) for create-template.sh.
# The key is read from the environment and never printed. The bucket access policy must be
# `signed`, not `private`. Everything stays on MIOSA's own storage.
set -euo pipefail

file="${1:?path to optimal-engine.tgz}"
: "${MIOSA_API_KEY:?set MIOSA_API_KEY}"
: "${BUCKET_ID:?set BUCKET_ID (a MIOSA storage bucket of the organization that builds the template)}"
API="${MIOSA_API_URL:-https://api.miosa.ai/api/v1}"
prefix="${RELEASE_PREFIX:-releases/optimal-engine/$(date -u +%Y%m%dT%H%M%SZ)}"

sha="$(sha256sum "$file" | cut -d' ' -f1)"
work="$(mktemp -d)"
trap 'find "$work" -mindepth 1 -delete; rmdir "$work"' EXIT
split -b 4m -d -a 3 "$file" "$work/part."

urls=()
for part in "$work"/part.*; do
  key="$prefix/$(basename "$part")"
  code="$(curl -sS -m 300 -o /dev/null -w '%{http_code}' -X PUT "$API/storage/buckets/$BUCKET_ID/objects/$key" \
    -H "Authorization: Bearer $MIOSA_API_KEY" -H "Content-Type: application/octet-stream" --data-binary "@$part")"
  [ "$code" = "200" ] || { echo "upload of $key failed ($code)" >&2; exit 1; }
  resp="$(curl -sS -m 60 -X POST "$API/storage/buckets/$BUCKET_ID/presign" \
    -H "Authorization: Bearer $MIOSA_API_KEY" -H "Content-Type: application/json" \
    --data "{\"key\":\"$key\",\"method\":\"GET\",\"expires_in\":86400}")"
  url="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))')"
  [ -n "$url" ] || { echo "presign of $key failed" >&2; exit 1; }
  urls+=("$url")
done

echo "RELEASE_URLS=${urls[*]}"
echo "RELEASE_SHA256=$sha"
