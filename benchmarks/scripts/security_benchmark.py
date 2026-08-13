#!/usr/bin/env python3
"""Run the isolated authorization and governance regression benchmark."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import time
from pathlib import Path


DEFAULT_TESTS = [
    "test/api/workspace_authorization_test.exs",
    "test/memory_core/governed_recall_test.exs",
    "test/memory_reconstructor_test.exs",
]


def parse_counts(output: str) -> tuple[int | None, int | None]:
    matches = re.findall(r"(\d+) tests?, (\d+) failures?", output)
    if not matches:
        return None, None
    tests, failures = matches[-1]
    return int(tests), int(failures)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-dir", default=".")
    parser.add_argument("--out")
    parser.add_argument("--tests", nargs="+", default=DEFAULT_TESTS)
    args = parser.parse_args()

    command = ["mix", "test", "--no-color", *args.tests]
    environment = os.environ.copy()
    environment["MIX_ENV"] = "test"
    started = time.perf_counter()
    completed = subprocess.run(
        command,
        cwd=args.engine_dir,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed = time.perf_counter() - started
    combined = completed.stdout + completed.stderr
    tests, failures = parse_counts(combined)
    passed = completed.returncode == 0 and failures == 0 and tests is not None

    result = {
        "benchmark_version": "security-regression-v1",
        "passed": passed,
        "tests": tests,
        "failures": failures,
        "elapsed_seconds": round(elapsed, 3),
        "command": command,
        "test_files": args.tests,
        "environment": {
            "python": platform.python_version(),
            "platform": platform.platform(),
        },
        "checks": [
            "tenant isolation",
            "workspace isolation",
            "security-label isolation",
            "partition isolation",
            "unauthorized crowd-out",
            "temporal and supersession filtering",
            "governed reconstruction expansion",
        ],
        "summary": f"{tests} tests, {failures} failures" if tests is not None else "missing summary",
    }
    rendered = json.dumps(result, indent=2, sort_keys=True)
    print(rendered)
    if args.out:
        path = Path(args.out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered + "\n", encoding="utf-8")
    return 0 if passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
