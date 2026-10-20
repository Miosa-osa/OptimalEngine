#!/usr/bin/env python3
"""Measure the embedded Engine's app-data throughput.

Writes N records into one collection through the bulk endpoint (batched), then
runs Q indexed queries at the final size and reports writes per second and the
p95 query latency. This is WO-33 item 4: measured numbers, not an estimate.

Usage: bench-app-data.py <base-url> <api-key> <workspace> [records] [queries]
"""

import json
import sys
import time
import urllib.parse
import urllib.request

base, key, workspace = sys.argv[1], sys.argv[2], sys.argv[3]
records = int(sys.argv[4]) if len(sys.argv) > 4 else 100_000
queries = int(sys.argv[5]) if len(sys.argv) > 5 else 200
batch = 1_000
query = f"?workspace={urllib.parse.quote(workspace)}"


def call(method, path, body=None):
    payload = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(base + path + query, data=payload, method=method)
    request.add_header("Authorization", "Bearer " + key)
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read() or b"{}")


collection = {
    "name": "tasks",
    "fields": [
        {"name": "title", "type": "string", "required": True},
        {"name": "done", "type": "boolean", "default": False},
        {"name": "due", "type": "datetime"},
        {"name": "owner", "type": "string"},
    ],
    "owner_field": "owner",
    "indexes": [{"fields": ["owner", "done", "due"]}],
}

call("POST", "/api/data/collections", collection)

written = 0
started = time.perf_counter()
for offset in range(0, records, batch):
    rows = [
        {
            "id": "bench-%07d" % i,
            "data": {
                "title": "task %d" % i,
                "owner": "user-a" if i % 2 == 0 else "user-b",
                "done": i % 5 == 0,
                "due": "2026-11-%02dT%02d:00:00.000Z" % (1 + (i % 28), i % 24),
            },
        }
        for i in range(offset, min(offset + batch, records))
    ]
    written += call("POST", "/api/data/collections/tasks/records/bulk", {"records": rows})["count"]

elapsed = time.perf_counter() - started
rate = written / elapsed if elapsed else 0.0

body = {"where": {"owner": "user-a", "done": False}, "sort": ["due"], "limit": 25}
for _ in range(10):
    call("POST", "/api/data/collections/tasks/query", body)

latencies = []
for _ in range(queries):
    began = time.perf_counter()
    call("POST", "/api/data/collections/tasks/query", body)
    latencies.append((time.perf_counter() - began) * 1000)

latencies.sort()
p50 = latencies[len(latencies) // 2]
p95 = latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))]

total = call("POST", "/api/data/collections/tasks/query", {"count": True, "limit": 0})["count"]

print("BENCH_RECORDS=%d" % written)
print("BENCH_COUNTED=%d" % total)
print("BENCH_WRITE_SECONDS=%.2f" % elapsed)
print("BENCH_WRITES_PER_SECOND=%.0f" % rate)
print("BENCH_QUERIES=%d" % len(latencies))
print("BENCH_P50_MS=%.2f" % p50)
print("BENCH_P95_MS=%.2f" % p95)

if written != records or total != records:
    print("FAIL wrote %d of %d, counted %d" % (written, records, total))
    sys.exit(1)
