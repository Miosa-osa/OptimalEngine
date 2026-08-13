#!/usr/bin/env python3
"""Validate a governed Optimal Engine Gold Set before execution."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REQUIRED = {
    "id",
    "workspace",
    "question",
    "required_terms",
    "forbidden_terms",
    "expected_object_links",
    "forbidden_object_links",
    "authorization",
    "as_of",
    "expected_abstention",
    "review",
}


def validate_case(case: dict[str, Any]) -> list[str]:
    errors = [f"missing {key}" for key in sorted(REQUIRED - case.keys())]
    authorization = case.get("authorization") or {}
    for key in ("tenant_id", "allowed_security_labels", "allowed_partitions"):
        if key not in authorization:
            errors.append(f"authorization missing {key}")
    review = case.get("review") or {}
    for key in ("reviewer", "reviewed_at"):
        if not review.get(key):
            errors.append(f"review missing {key}")
    if not case.get("question"):
        errors.append("question is blank")
    if case.get("expected_abstention") and case.get("expected_object_links"):
        errors.append("abstention case cannot require object links")
    return errors


def load(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()
    cases = load(Path(args.dataset))
    failures = []
    for case in cases:
        for error in validate_case(case):
            failures.append({"id": case.get("id"), "error": error})
    result = {
        "benchmark_version": "governed-gold-set-v1",
        "cases": len(cases),
        "valid_cases": len(cases) - len({failure["id"] for failure in failures}),
        "failures": failures,
        "passed": bool(cases) and not failures,
        "note": "Schema validation only. A private reviewed dataset is required for production quality scoring.",
    }
    rendered = json.dumps(result, indent=2, sort_keys=True)
    print(rendered)
    if args.out:
        Path(args.out).write_text(rendered + "\n", encoding="utf-8")
    return 0 if result["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
