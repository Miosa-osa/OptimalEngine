#!/usr/bin/env python3
"""Append release scorecards and compare current suite status to a baseline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def compare(current: dict, baseline: dict) -> list[dict]:
    previous = {suite["id"]: suite for suite in baseline.get("suites", [])}
    regressions = []
    for suite in current.get("suites", []):
        old = previous.get(suite["id"])
        if old and old.get("passed") is True and suite.get("passed") is not True:
            regressions.append({"suite": suite["id"], "from": "pass", "to": "fail"})
    return regressions


def append_history(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as output:
        output.write(json.dumps(report, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current", required=True)
    parser.add_argument("--baseline")
    parser.add_argument("--history")
    args = parser.parse_args()
    current = json.loads(Path(args.current).read_text(encoding="utf-8"))
    baseline = json.loads(Path(args.baseline).read_text(encoding="utf-8")) if args.baseline else {}
    regressions = compare(current, baseline)
    if args.history:
        append_history(Path(args.history), current)
    print(json.dumps({"passed": not regressions, "regressions": regressions}, indent=2))
    return 0 if not regressions else 2


if __name__ == "__main__":
    raise SystemExit(main())
