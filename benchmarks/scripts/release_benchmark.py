#!/usr/bin/env python3
"""Run all named Optimal Engine release benchmark families and render one scorecard."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import subprocess
import time
from pathlib import Path


def parse_metrics(output: str) -> dict:
    matches = re.findall(r"(\d+) tests?, (\d+) failures?", output)
    metrics = {}
    if matches:
        metrics["tests"], metrics["failures"] = map(int, matches[-1])
    try:
        start = output.rfind("\n{")
        value = json.loads(output[start + 1 :] if start >= 0 else output)
        for key in (
            "cases",
            "valid_cases",
            "mutations",
            "endpoints",
            "tests",
            "failures",
            "records",
            "insert_ms",
            "inserts_per_second",
            "lookup_p50_ms",
            "lookup_p95_ms",
            "lookup_p99_ms",
            "database_growth_bytes",
        ):
            if key in value:
                metrics[key] = value[key]
    except (ValueError, TypeError):
        pass
    return metrics


def run_suite(suite: dict, root: Path) -> dict:
    started = time.perf_counter()
    commands = suite.get("commands") or [suite["command"]]
    environment = os.environ.copy()
    environment.update(suite.get("env") or {})
    completed_runs = [
        subprocess.run(
            command,
            cwd=root,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        for command in commands
    ]
    elapsed = time.perf_counter() - started
    output = "\n".join(run.stdout + run.stderr for run in completed_runs)
    metrics = {}
    for run in completed_runs:
        metrics.update(parse_metrics(run.stdout + run.stderr))
    test_matches = re.findall(r"(\d+) tests?, (\d+) failures?", output)
    if test_matches:
        metrics["tests"] = sum(int(tests) for tests, _ in test_matches)
        metrics["failures"] = sum(int(failures) for _, failures in test_matches)
    return {
        "id": suite["id"],
        "name": suite["name"],
        "meaning": suite["meaning"],
        "passed": all(run.returncode == 0 for run in completed_runs),
        "elapsed_seconds": round(elapsed, 3),
        "metrics": metrics,
        "commands": commands,
        "qualification": suite.get("qualification", "executed_regression"),
        "limitation": suite.get("limitation"),
        "output_tail": output[-1200:] if all(run.returncode == 0 for run in completed_runs) else "",
    }


def markdown(report: dict) -> str:
    lines = [
        "# Optimal Engine Release Benchmark",
        "",
        f"Generated: {report['generated_at']}",
        "",
        f"Overall: **{'PASS' if report['passed'] else 'FAIL'}** ({report['passed_suites']}/{report['total_suites']} suites)",
        "",
        "| Suite | Status | Tests or cases | Qualification | Time | What it means |",
        "| --- | --- | ---: | --- | ---: | --- |",
    ]
    for suite in report["suites"]:
        metrics = suite["metrics"]
        count = metrics.get(
            "tests", metrics.get("cases", metrics.get("records", metrics.get("mutations", "-")))
        )
        status = "PASS" if suite["passed"] else "FAIL"
        lines.append(
            f"| {suite['name']} | {status} | {count} | {suite['qualification']} | {suite['elapsed_seconds']:.3f}s | {suite['meaning']} |"
        )
    limitations = [suite for suite in report["suites"] if suite.get("limitation")]
    if limitations:
        lines.extend(["", "## Qualification limits", ""])
        lines.extend(f"- **{suite['name']}:** {suite['limitation']}" for suite in limitations)
    lines.extend(
        [
            "",
            "A passing score means every listed gate completed successfully on the recorded environment.",
        "It does not make unmeasured workloads optimal.",
            "Suite qualification levels and limitations are recorded in the JSON report.",
            "",
        ]
    )
    return "\n".join(lines)


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_commit(root: Path) -> str | None:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, check=False
    )
    return completed.stdout.strip() if completed.returncode == 0 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="benchmarks/configs/release_suites.json")
    parser.add_argument("--only", help="comma-separated suite ids")
    parser.add_argument("--out", default="benchmarks/results/release-current.json")
    parser.add_argument("--markdown", default="benchmarks/results/RELEASE-CURRENT.md")
    parser.add_argument("--history", default="benchmarks/results/release-history.jsonl")
    parser.add_argument("--no-history", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    config = json.loads((root / args.config).read_text(encoding="utf-8"))
    selected = set(args.only.split(",")) if args.only else None
    suites = [suite for suite in config["suites"] if selected is None or suite["id"] in selected]
    results = [run_suite(suite, root) for suite in suites]
    datasets = sorted((root / "benchmarks/datasets").glob("**/*"))
    report = {
        "benchmark_version": config["version"],
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "environment": {"platform": platform.platform(), "python": platform.python_version()},
        "commit": git_commit(root),
        "dataset_hashes": {
            str(path.relative_to(root)): file_hash(path) for path in datasets if path.is_file()
        },
        "total_suites": len(results),
        "passed_suites": sum(result["passed"] for result in results),
        "passed": bool(results) and all(result["passed"] for result in results),
        "suites": results,
    }
    out = root / args.out
    card = root / args.markdown
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    card.write_text(markdown(report), encoding="utf-8")
    if not args.no_history:
        history = root / args.history
        history.parent.mkdir(parents=True, exist_ok=True)
        with history.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(report, sort_keys=True) + "\n")
    print(markdown(report))
    return 0 if report["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
