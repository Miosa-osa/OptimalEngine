#!/usr/bin/env python3
"""Seed a generated benchmark corpus into Optimal Engine.

Each corpus row is inserted as a versioned memory and optionally promoted to a
wiki page. Promotion is useful because the current RAG path is wiki-first for
stable institutional-memory answers.
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


def post_json(url: str, payload: dict[str, Any], retries: int = 8) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")

    for attempt in range(retries + 1):
        request = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                raw = response.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if error.code == 429 and attempt < retries:
                try:
                    retry_ms = int(json.loads(detail).get("retry_after_ms", 500))
                except (ValueError, TypeError, json.JSONDecodeError):
                    retry_ms = 500
                time.sleep(max(retry_ms, 100) / 1000)
                continue
            raise RuntimeError(f"HTTP {error.code} from {url}: {detail}") from error

    raise RuntimeError(f"exhausted retries for {url}")


def get_json(url: str, params: dict[str, Any], retries: int = 8) -> dict[str, Any]:
    request_url = f"{url}?{urllib.parse.urlencode(params)}"
    for attempt in range(retries + 1):
        request = urllib.request.Request(request_url, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                raw = response.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if error.code == 429 and attempt < retries:
                try:
                    retry_ms = int(json.loads(detail).get("retry_after_ms", 500))
                except (ValueError, TypeError, json.JSONDecodeError):
                    retry_ms = 500
                time.sleep(max(retry_ms, 100) / 1000)
                continue
            raise RuntimeError(f"HTTP {error.code} from {request_url}: {detail}") from error

    raise RuntimeError(f"exhausted retries for {request_url}")


def pending_claim_id(args: argparse.Namespace, workspace: str, memory_id: str) -> str | None:
    response = get_json(
        f"{args.engine_url.rstrip('/')}/api/memory-core/claims",
        {"workspace": workspace, "kind": "memory_candidate", "limit": 100},
    )
    for claim in response.get("claims") or []:
        metadata = claim.get("metadata") or {}
        if metadata.get("versioned_memory_id") == memory_id:
            return claim.get("id")
    return None


def load_jsonl(path: Path, limit: int | None) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped:
                rows.append(json.loads(stripped))
                if limit and len(rows) >= limit:
                    break
    return rows


def seed_row(
    args: argparse.Namespace,
    row: dict[str, Any],
    latest_by_conversation: dict[str, str],
    latest_fact_by_conversation: dict[str, str],
) -> dict[str, Any]:
    workspace = row.get("workspace") or args.workspace
    metadata = {
        "benchmark": args.benchmark,
        "conversation_id": row["conversation_id"],
        "sequence": row.get("sequence", 1),
        "project": row["project"],
        "domain": row["domain"],
        "source": "benchmark_generator",
    }

    payload = {
        "workspace": workspace,
        "audience": args.audience,
        "content": row["content"],
        "metadata": metadata,
    }
    operation = row.get("operation", "create")
    previous_id = latest_by_conversation.get(row["conversation_id"])

    if operation == "update":
        if not previous_id:
            raise ValueError(
                f"update row has no prior memory for {row['conversation_id']}"
            )
        memory = post_json(
            f"{args.engine_url.rstrip('/')}/api/memory/{previous_id}/update",
            payload,
        )
    elif operation == "create":
        memory = post_json(f"{args.engine_url.rstrip('/')}/api/memory", payload)
    else:
        raise ValueError(f"unsupported corpus operation {operation!r}")

    memory_id = memory["id"]
    latest_by_conversation[row["conversation_id"]] = memory_id
    governed = None

    if args.promote_governed:
        claim_id = (memory.get("metadata") or {}).get("memory_core_pending_claim_id")
        claim_id = claim_id or pending_claim_id(args, workspace, memory_id)
        if not claim_id:
            raise ValueError(f"memory {memory_id} has no pending governed claim")
        promotion = {
            "workspace": workspace,
            "actor_id": args.reviewer,
            "verifier_id": args.reviewer,
            "fact_text": row["content"],
            "summary": row["content"],
            "memory_type": "benchmark_fixture",
            "aggregate_confidence": 1.0,
            "aggregate_precision": 1.0,
            "fact_metadata": metadata,
            "memory_metadata": metadata,
        }
        previous_fact_id = latest_fact_by_conversation.get(row["conversation_id"])
        if operation == "update" and previous_fact_id:
            promotion["supersedes_fact_id"] = previous_fact_id
            promotion["supersession_reason"] = "benchmark_version_update"
        governed = post_json(
            f"{args.engine_url.rstrip('/')}/api/memory-core/claims/{claim_id}/promote",
            promotion,
        )
        latest_fact_by_conversation[row["conversation_id"]] = governed["fact"]["id"]
    promoted = None

    if args.promote:
        promoted = post_json(
            f"{args.engine_url.rstrip('/')}/api/memory/{memory_id}/promote",
            {
                "workspace": workspace,
                "audience": args.audience,
                "slug": row["slug"],
            },
        )

    return {
        "conversation_id": row["conversation_id"],
        "sequence": row.get("sequence", 1),
        "workspace": workspace,
        "memory_id": memory_id,
        "operation": operation,
        "previous_memory_id": previous_id,
        "claim_id": governed["claim"]["id"] if governed else None,
        "fact_id": (governed or {}).get("fact", {}).get("id"),
        "memory_object_id": (governed or {}).get("memory_object", {}).get("id"),
        "slug": row["slug"],
        "promoted": bool(promoted),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--engine-url", default="http://127.0.0.1:4200")
    parser.add_argument("--workspace", default="bench-large")
    parser.add_argument("--audience", default="default")
    parser.add_argument("--benchmark", default="synthetic")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--promote", action="store_true")
    parser.add_argument("--promote-governed", action="store_true")
    parser.add_argument("--reviewer", default="benchmark:reviewer")
    parser.add_argument("--sleep-ms", type=int, default=0)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()

    rows = load_jsonl(Path(args.corpus), args.limit)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    latest_by_conversation: dict[str, str] = {}
    latest_fact_by_conversation: dict[str, str] = {}
    completed: set[tuple[str, int]] = set()
    if args.resume and out_path.exists():
        legacy_sequence_counts: dict[str, int] = {}
        for seeded in load_jsonl(out_path, None):
            conversation_id = seeded["conversation_id"]
            legacy_sequence_counts[conversation_id] = legacy_sequence_counts.get(conversation_id, 0) + 1
            sequence = seeded.get("sequence") or legacy_sequence_counts[conversation_id]
            completed.add((conversation_id, int(sequence)))
            latest_by_conversation[conversation_id] = seeded["memory_id"]
            if seeded.get("fact_id"):
                latest_fact_by_conversation[conversation_id] = seeded["fact_id"]

    mode = "a" if args.resume else "w"
    with out_path.open(mode, encoding="utf-8") as output:
        for index, row in enumerate(rows, start=1):
            key = (row["conversation_id"], int(row.get("sequence", 1)))
            if key in completed:
                print(f"[{index}/{len(rows)}] {row['conversation_id']} -> already seeded")
                continue
            seeded = seed_row(
                args,
                row,
                latest_by_conversation,
                latest_fact_by_conversation,
            )
            output.write(json.dumps(seeded, ensure_ascii=False) + "\n")
            output.flush()
            print(f"[{index}/{len(rows)}] {seeded['conversation_id']} -> {seeded['memory_id']}")
            if args.sleep_ms > 0:
                time.sleep(args.sleep_ms / 1000)

    print(
        json.dumps(
            {"rows": len(rows), "already_seeded": len(completed), "out": str(out_path)},
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
