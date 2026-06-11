#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCAN_PATHS=(
  README.md
  docs
  apps
  site
  skills
  sample-workspace
)

BLOCKED_PATTERN='Malu|gbrain|leafwiki|HydraDB|MemOS|Mem0|competitor|Oscar|Atlas|Lunivate|AI Masters|Agency Accelerants|OpenViking|Letta|Zep|Dust|Glean|Pinecone|Weaviate|Qdrant|ByteDance|SignalTheory-Internal-Bundle|Roberto H Luna|Signal Theory Research'

if rg -n "$BLOCKED_PATTERN" "${SCAN_PATHS[@]}" --glob '!**/node_modules/**'; then
  echo "Public audit failed: blocked private/comparison term found." >&2
  exit 1
fi

echo "Public audit passed."
