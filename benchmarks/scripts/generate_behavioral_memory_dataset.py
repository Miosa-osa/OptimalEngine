#!/usr/bin/env python3
"""Generate licensed, deterministic GoodAI-LTM-shaped behavioral memory cases."""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Any


TASKS = (
    "delayed_recall",
    "knowledge_update",
    "conflict_resolution",
    "prospective_memory",
    "trigger_response",
    "spatial_reasoning",
    "abstention",
)


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def filler(rng: random.Random, tokens: int) -> str:
    vocabulary = ["context", "review", "source", "project", "meeting", "evidence", "policy", "workflow"]
    return " ".join(rng.choice(vocabulary) for _ in range(tokens))


def build_case(index: int, task: str, span: int, rng: random.Random) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    case_id = f"behavior-{span}-{index:04d}-{task}"
    workspace = f"bench-behavior-{span}"
    project = f"Northstar-{task}-{index:04d}"
    code = f"NOVA-{index:04d}"
    noise = filler(rng, span)
    corpus: list[dict[str, Any]] = []
    required: list[str] = []
    forbidden: list[str] = []
    expected_abstention = False

    if task == "delayed_recall":
        content = f"The verified launch code for Project {project} is {code}. {noise}"
        question = f"What is the verified launch code for Project {project}?"
        required = [code]
    elif task == "knowledge_update":
        corpus.append({"content": f"Project {project} owner was Alice. This record is superseded.", "sequence": 1})
        content = f"Project {project} owner changed to Priya. Priya is current. {noise}"
        question = f"Who is the current owner of Project {project}?"
        required, forbidden = ["Priya"], ["Alice"]
    elif task == "conflict_resolution":
        corpus.append({"content": "An unreviewed rumor says the budget is $900.", "sequence": 1})
        content = f"Reviewed financial decision: Project {project} budget is $2400. {noise}"
        question = f"What is the reviewed Project {project} budget?"
        required, forbidden = ["$2400"], ["$900"]
    elif task == "prospective_memory":
        content = f"When Roberto says ORBIT, remind him to verify the backup checksum before deployment. {noise}"
        question = "ORBIT. What must Roberto be reminded to do?"
        required = ["verify", "backup checksum"]
    elif task == "trigger_response":
        content = f"Trigger rule: when the phrase BLUE COMET appears, respond with ESCALATE-SECURITY. {noise}"
        question = "BLUE COMET"
        required = ["ESCALATE-SECURITY"]
    elif task == "spatial_reasoning":
        content = f"The red key is inside the lockbox. The lockbox is inside the west cabinet. {noise}"
        question = "Which cabinet contains the red key?"
        required = ["west cabinet"]
    else:
        content = f"Project {project} records describe launch timing and ownership only. {noise}"
        question = f"What is Project {project}'s favorite restaurant?"
        expected_abstention = True

    corpus.append({"content": content, "sequence": len(corpus) + 1})
    corpus_rows = [
        {
            "conversation_id": case_id,
            "workspace": workspace,
            "slug": f"{case_id}-{row['sequence']}",
            "project": project,
            "domain": task,
            "content": row["content"],
            "sequence": row["sequence"],
        }
        for row in corpus
    ]
    question_row = {
        "id": case_id,
        "workspace": workspace,
        "question": question,
        "gold": "; ".join(required) if required else "ABSTAIN",
        "category": task,
        "required_terms": required,
        "forbidden_terms": forbidden,
        "expected_abstention": expected_abstention,
        "memory_span_tokens": span,
    }
    return corpus_rows, question_row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="benchmarks/generated/behavioral")
    parser.add_argument("--cases-per-task", type=int, default=10)
    parser.add_argument("--spans", default="100,1000,10000")
    parser.add_argument("--seed", type=int, default=20260813)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    corpus: list[dict[str, Any]] = []
    questions: list[dict[str, Any]] = []

    for span in [int(value) for value in args.spans.split(",")]:
        for task in TASKS:
            for offset in range(args.cases_per_task):
                rows, question = build_case(offset, task, span, rng)
                corpus.extend(rows)
                questions.append(question)

    out = Path(args.out)
    write_jsonl(out / "corpus.jsonl", corpus)
    write_jsonl(out / "questions.jsonl", questions)
    manifest = {
        "benchmark": "optimal-behavioral-memory-v1",
        "inspiration": "GoodAI LTM Benchmark task taxonomy",
        "license": "Original deterministic Optimal Engine fixtures",
        "seed": args.seed,
        "tasks": list(TASKS),
        "spans": [int(value) for value in args.spans.split(",")],
        "question_count": len(questions),
        "corpus_record_count": len(corpus),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
