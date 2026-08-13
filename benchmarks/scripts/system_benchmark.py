#!/usr/bin/env python3
"""Reproducible latency, throughput, reliability, and SLO benchmark for Optimal Engine."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import platform
import statistics
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


def percentile(values: list[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(0, math.ceil(quantile * len(ordered)) - 1)
    return ordered[rank]


def load_profile(path: Path, name: str) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    for profile in data["profiles"]:
        if profile["name"] == name:
            return profile
    raise ValueError(f"unknown profile {name!r}")


def request_for(base_url: str, endpoint: str, query: str, workspace: str) -> urllib.request.Request:
    base = base_url.rstrip("/")
    if endpoint == "search":
        params = urllib.parse.urlencode({"q": query, "workspace": workspace, "limit": 10})
        return urllib.request.Request(f"{base}/api/search?{params}", method="GET")

    paths = {
        "rag": "/api/rag",
        "rag-fast": "/api/rag",
        "rag-governed-tiered": "/api/rag",
        "rag-governed-reconstructive": "/api/rag",
        "assemble": "/api/assemble",
        "reconstruct": "/api/reconstruct",
    }
    payload_data: dict[str, Any] = {
        "query": query,
        "topic": query,
        "workspace": workspace,
    }
    if endpoint == "rag-fast":
        payload_data.update({"skip_intent": True, "skip_wiki": True})
    elif endpoint == "rag-governed-tiered":
        payload_data.update({"context_package": True, "strategy": "tiered"})
    elif endpoint == "rag-governed-reconstructive":
        payload_data.update({"context_package": True, "strategy": "reconstructive"})
    payload = json.dumps(payload_data).encode("utf-8")
    return urllib.request.Request(
        base + paths[endpoint],
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )


def execute(base_url: str, endpoint: str, query: str, workspace: str, timeout: float) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        request = request_for(base_url, endpoint, query, workspace)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
            status = response.status
        return {
            "ok": 200 <= status < 300,
            "status": status,
            "latency_ms": (time.perf_counter() - started) * 1000,
            "bytes": len(body),
        }
    except urllib.error.HTTPError as error:
        body = error.read()
        return {
            "ok": False,
            "status": error.code,
            "latency_ms": (time.perf_counter() - started) * 1000,
            "bytes": len(body),
            "error": f"HTTPError: HTTP {error.code}",
        }
    except Exception as error:
        return {
            "ok": False,
            "status": None,
            "latency_ms": (time.perf_counter() - started) * 1000,
            "bytes": 0,
            "error": f"{type(error).__name__}: {error}",
        }


def summarize(rows: list[dict[str, Any]], elapsed: float, target: dict[str, Any]) -> dict[str, Any]:
    successful_latencies = [float(row["latency_ms"]) for row in rows if row["ok"]]
    all_latencies = [float(row["latency_ms"]) for row in rows]
    failures = sum(1 for row in rows if not row["ok"])
    error_rate = failures / len(rows) if rows else 1.0
    status_counts: dict[str, int] = {}
    for row in rows:
        key = str(row.get("status") or "transport_error")
        status_counts[key] = status_counts.get(key, 0) + 1
    metrics = {
        "requests": len(rows),
        "successes": len(rows) - failures,
        "failures": failures,
        "error_rate": error_rate,
        "attempted_rps": len(rows) / elapsed if elapsed else 0.0,
        "successful_rps": (len(rows) - failures) / elapsed if elapsed else 0.0,
        "rate_limited_requests": status_counts.get("429", 0),
        "status_counts": status_counts,
        "response_megabytes": sum(row["bytes"] for row in rows) / 1_000_000,
        "latency_ms": {
            "population": "successful requests only",
            "min": min(successful_latencies, default=0.0),
            "mean": statistics.mean(successful_latencies) if successful_latencies else 0.0,
            "p50": percentile(successful_latencies, 0.50),
            "p95": percentile(successful_latencies, 0.95),
            "p99": percentile(successful_latencies, 0.99),
            "max": max(successful_latencies, default=0.0),
        },
        "attempt_latency_ms": {
            "p95": percentile(all_latencies, 0.95),
            "max": max(all_latencies, default=0.0),
        },
    }
    gates = {
        "error_rate": error_rate <= float(target.get("error_rate", 1.0)),
        "p95_ms": metrics["latency_ms"]["p95"] <= float(target.get("p95_ms", math.inf)),
        "p99_ms": metrics["latency_ms"]["p99"] <= float(target.get("p99_ms", math.inf)),
    }
    metrics["gates"] = gates
    metrics["passed"] = all(gates.values())
    return metrics


def run_endpoint(args: argparse.Namespace, profile: dict[str, Any], endpoint: str) -> dict[str, Any]:
    requests = args.requests or int(profile["requests"])
    concurrency = args.concurrency or int(profile["concurrency"])
    warmup = args.warmup if args.warmup is not None else int(profile.get("warmup", 0))
    queries = profile["queries"]

    for index in range(warmup):
        execute(args.engine_url, endpoint, queries[index % len(queries)], args.workspace, args.timeout)

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = []
        next_submission = time.perf_counter()
        for index in range(requests):
            if args.request_rate:
                delay = next_submission - time.perf_counter()
                if delay > 0:
                    time.sleep(delay)
                next_submission += 1.0 / args.request_rate
            futures.append(pool.submit(
                execute,
                args.engine_url,
                endpoint,
                queries[index % len(queries)],
                args.workspace,
                args.timeout,
            ))
        rows = [future.result() for future in futures]
    elapsed = time.perf_counter() - started
    metrics = summarize(rows, elapsed, profile.get("targets", {}).get(endpoint, {}))
    metrics["endpoint"] = endpoint
    metrics["concurrency"] = concurrency
    metrics["warmup_requests"] = warmup
    metrics["requested_rate_rps"] = args.request_rate
    metrics["elapsed_seconds"] = elapsed
    metrics["errors"] = [row.get("error") for row in rows if row.get("error")][:10]
    return metrics


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="smoke")
    parser.add_argument("--profiles", default="benchmarks/configs/system_profiles.json")
    parser.add_argument("--engine-url", default="http://127.0.0.1:4200")
    parser.add_argument("--workspace", default="default:miosa")
    parser.add_argument("--endpoints", default="search,rag,assemble,reconstruct")
    parser.add_argument("--requests", type=int)
    parser.add_argument("--concurrency", type=int)
    parser.add_argument(
        "--warmup",
        type=int,
        help="override profile warmup; use 0 to measure cold-first-request behavior",
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--request-rate",
        type=float,
        help="pace submissions per endpoint; omit for an intentional saturation burst",
    )
    parser.add_argument("--out")
    args = parser.parse_args()

    profile = load_profile(Path(args.profiles), args.profile)
    endpoints = [value.strip() for value in args.endpoints.split(",") if value.strip()]
    valid = {
        "search",
        "rag",
        "rag-fast",
        "rag-governed-tiered",
        "rag-governed-reconstructive",
        "assemble",
        "reconstruct",
    }
    invalid = sorted(set(endpoints) - valid)
    if invalid:
        parser.error(f"unsupported endpoints: {', '.join(invalid)}")

    result = {
        "benchmark_version": "system-benchmark-v1",
        "profile": args.profile,
        "workspace": args.workspace,
        "engine_url": args.engine_url,
        "environment": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "cpu_count": os.cpu_count(),
        },
        "endpoints": [run_endpoint(args, profile, endpoint) for endpoint in endpoints],
    }
    result["passed"] = all(endpoint["passed"] for endpoint in result["endpoints"])
    output = json.dumps(result, indent=2, sort_keys=True)
    print(output)
    if args.out:
        path = Path(args.out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(output + "\n", encoding="utf-8")
    return 0 if result["passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
