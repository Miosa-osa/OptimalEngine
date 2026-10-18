#!/usr/bin/env bash
# Build the Engine image for the MIOSA hosts and push it to a private GHCR package.
#
#   GHCR_USER=<github user> GHCR_TOKEN=<token with write:packages> \
#     deploy/miosa-template/publish-image.sh [--dry-run]
#
# Prints the digest-pinned reference to use as ENGINE_IMAGE in create-template.sh.
# Run it from a trusted machine or from CI; it is never run by the template script.
#
# The token is read from the environment and given to docker on stdin, never on a
# command line and never printed. --dry-run builds the image and stops before the
# login and the push.
#
# The package is created private by default under the Miosa-osa organization. Check
# Package settings once: visibility must stay Private, and the builder host that pulls
# the image needs `docker login ghcr.io` with a read:packages token.
set -euo pipefail

IMAGE="${ENGINE_IMAGE_NAME:-ghcr.io/miosa-osa/optimal-engine}"
PLATFORM="${ENGINE_PLATFORM:-linux/amd64}" # the MIOSA hosts are x86_64
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sha="$(git -C "$root" rev-parse --short=12 HEAD)"
if [ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]; then
  echo "refusing to publish a dirty tree: commit first so the image names a real commit" >&2
  exit 2
fi
tag="$IMAGE:$sha"

docker buildx build --platform "$PLATFORM" -f "$root/deploy/Dockerfile.engine" -t "$tag" \
  --label "org.opencontainers.image.revision=$(git -C "$root" rev-parse HEAD)" \
  --label "org.opencontainers.image.source=https://github.com/Miosa-osa/OptimalEngine" \
  --load "$root"
echo "Built $tag"
[ "$DRY" = 1 ] && { echo "dry run: not pushed"; exit 0; }

: "${GHCR_USER:?set GHCR_USER}"
: "${GHCR_TOKEN:?set GHCR_TOKEN (write:packages)}"
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null

docker push "$tag" >/dev/null
digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$tag")"
case "$digest" in
  "$IMAGE"@sha256:*) ;;
  *) echo "could not read the pushed digest (got: $digest)" >&2; exit 1 ;;
esac
echo
echo "Published. Use this reference, digest-pinned:"
echo "  ENGINE_IMAGE=$digest"
