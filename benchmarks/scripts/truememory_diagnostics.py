#!/usr/bin/env python3
"""Run dependency-free lexical baselines, oracle diagnostics, and retrieval ablations."""

from __future__ import annotations

import argparse
import json
import math
import re
import time
from collections import Counter
from pathlib import Path
from typing import Any

from truememory_compat import percentile, sha256, wilson


def tokens(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", text.lower())


def bm25_rank(messages: list[dict[str, Any]], query: str, top_k: int) -> list[dict[str, Any]]:
    documents = [tokens(message["content"]) for message in messages]
    average_length = sum(map(len, documents)) / max(len(documents), 1)
    frequencies = Counter(token for document in map(set, documents) for token in document)
    query_tokens = tokens(query)
    scores = []
    for index, document in enumerate(documents):
        counts = Counter(document)
        score = 0.0
        for token in query_tokens:
            document_frequency = frequencies[token]
            inverse_frequency = math.log(1 + (len(documents) - document_frequency + 0.5) / (document_frequency + 0.5))
            frequency = counts[token]
            denominator = frequency + 1.5 * (1 - 0.75 + 0.75 * len(document) / max(average_length, 1))
            score += inverse_frequency * frequency * 2.5 / max(denominator, 1e-9)
        scores.append((score, index))
    return [messages[index] for score, index in sorted(scores, reverse=True)[:top_k] if score > 0]


def evidence_recall(question: dict[str, Any], messages: list[dict[str, Any]]) -> tuple[int, int]:
    expected = set(question.get("evidence", []))
    returned = {message.get("evidence_tag") for message in messages}
    return len(expected & returned), len(expected)


def evaluate(prepared: Path, top_ks: list[int]) -> dict[str, Any]:
    conversations = [json.loads(line) for line in prepared.read_text(encoding="utf-8").splitlines() if line]
    results = []
    oracle_counts = {"questions": 0, "evidence_addresses": 0, "missing_addresses": 0, "missing": []}
    for top_k in top_ks:
        found = total = hit = questions = 0
        latencies = []
        for conversation in conversations:
            available = {message.get("evidence_tag") for message in conversation["messages"]}
            for question in conversation["questions"]:
                evidence = question.get("evidence", [])
                if top_k == top_ks[0]:
                    oracle_counts["questions"] += int(bool(evidence))
                    oracle_counts["evidence_addresses"] += len(evidence)
                    missing = [item for item in evidence if item not in available]
                    oracle_counts["missing_addresses"] += len(missing)
                    oracle_counts["missing"].extend(
                        {"conversation_id": conversation["conversation_id"], "question_id": question["id"], "address": item}
                        for item in missing
                    )
                started = time.perf_counter()
                ranked = bm25_rank(conversation["messages"], question["question"], top_k)
                latencies.append(time.perf_counter() - started)
                item_found, item_total = evidence_recall(question, ranked)
                found += item_found
                total += item_total
                hit += int(item_found > 0)
                questions += int(item_total > 0)
        results.append({
            "strategy": "bm25", "top_k": top_k, "questions": questions,
            "question_recall": round(hit / questions * 100, 3) if questions else None,
            "evidence_recall": round(found / total * 100, 3) if total else None,
            "evidence_found": found, "evidence_total": total,
            "wilson_95": wilson(hit, questions),
            "latency_p50_ms": round(percentile(latencies, 0.50) * 1000, 3),
            "latency_p95_ms": round(percentile(latencies, 0.95) * 1000, 3),
            "latency_p99_ms": round(percentile(latencies, 0.99) * 1000, 3),
        })
    return {
        "version": "truememory-diagnostics-v1", "prepared_sha256": sha256(prepared),
        "oracle": {
            **oracle_counts,
            "resolvable_addresses": oracle_counts["evidence_addresses"] - oracle_counts["missing_addresses"],
            "address_integrity": "PASS" if not oracle_counts["missing_addresses"] else "UPSTREAM_ANNOTATION_GAPS",
        },
        "ablations": results,
    }


def compare_strict_oracle(strict: Path, oracle: Path) -> dict[str, Any]:
    strict_rows = {row["conversation_id"]: row for row in load_jsonl(strict)}
    oracle_rows = {row["conversation_id"]: row for row in load_jsonl(oracle)}
    common = sorted(strict_rows.keys() & oracle_rows.keys())
    diagnostics = []
    for question_id in common:
        strict_count = len(strict_rows[question_id]["messages"])
        oracle_count = len(oracle_rows[question_id]["messages"])
        diagnostics.append({
            "question_id": question_id, "strict_messages": strict_count, "oracle_messages": oracle_count,
            "reduction_percent": round((1 - oracle_count / strict_count) * 100, 3) if strict_count else 0.0,
        })
    reductions = [item["reduction_percent"] for item in diagnostics]
    return {
        "version": "longmemeval-strict-oracle-diagnostic-v1",
        "strict_sha256": sha256(strict), "oracle_sha256": sha256(oracle),
        "strict_cases": len(strict_rows), "oracle_cases": len(oracle_rows), "matched_question_ids": len(common),
        "missing_from_oracle": sorted(strict_rows.keys() - oracle_rows.keys()),
        "missing_from_strict": sorted(oracle_rows.keys() - strict_rows.keys()),
        "strict_messages": sum(len(row["messages"]) for row in strict_rows.values()),
        "oracle_messages": sum(len(row["messages"]) for row in oracle_rows.values()),
        "message_reduction_percent": round(
            (1 - sum(len(row["messages"]) for row in oracle_rows.values()) /
             sum(len(row["messages"]) for row in strict_rows.values())) * 100, 3
        ),
        "per_case_reduction_p50": percentile(reductions, 0.50),
        "per_case_reduction_p95": percentile(reductions, 0.95),
    }


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", required=True)
    parser.add_argument("--oracle-prepared")
    parser.add_argument("--top-k", type=int, nargs="+", default=[1, 5, 10, 25, 50, 100])
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    result = (
        compare_strict_oracle(Path(args.prepared), Path(args.oracle_prepared))
        if args.oracle_prepared else evaluate(Path(args.prepared), args.top_k)
    )
    output = Path(args.out)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
