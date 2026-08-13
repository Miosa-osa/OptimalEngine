#!/usr/bin/env python3
"""Fail unless a recorded benchmark artifact declares every gate passed."""

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", required=True)
    args = parser.parse_args()
    artifact = json.loads(Path(args.artifact).read_text(encoding="utf-8"))
    result = {
        "benchmark_version": "artifact-gate-v1",
        "artifact": args.artifact,
        "passed": artifact.get("passed") is True,
        "profile": artifact.get("profile"),
        "endpoints": len(artifact.get("endpoints") or []),
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
