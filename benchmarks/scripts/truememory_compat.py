#!/usr/bin/env python3
"""Prepare, validate, run, and aggregate TrueMemory-compatible evaluations."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PROTOCOL = ROOT / "benchmarks/truememory/protocol.json"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_sha256(path: Path) -> str:
    if path.is_file():
        return sha256(path)
    digest = hashlib.sha256()
    for child in sorted(path.glob("*.parquet")):
        digest.update(bytes.fromhex(sha256(child)))
    return digest.hexdigest()


def load_protocol(path: Path = DEFAULT_PROTOCOL) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def sync_upstream(protocol: dict[str, Any], destination: Path) -> dict[str, Any]:
    upstream = protocol["upstream"]
    if destination.exists():
        shutil.rmtree(destination)
    subprocess.run(
        ["git", "clone", "--quiet", upstream["repository"], str(destination)], check=True
    )
    subprocess.run(
        ["git", "checkout", "--quiet", upstream["commit"]], cwd=destination, check=True
    )
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=destination, text=True).strip()
    if commit != upstream["commit"]:
        raise RuntimeError(f"upstream commit mismatch: {commit}")
    return {"repository": upstream["repository"], "commit": commit, "license": upstream["license"]}


def protocol_constants(script: Path) -> dict[str, Any]:
    tree = ast.parse(script.read_text(encoding="utf-8"))
    wanted = {
        "ANSWER_MODEL",
        "ANSWER_MAX_TOKENS",
        "ANSWER_TEMPERATURE",
        "JUDGE_MODEL",
        "JUDGE_MAX_TOKENS",
        "JUDGE_TEMPERATURE",
        "NUM_JUDGE_RUNS",
        "TOP_K",
    }
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in wanted:
                try:
                    values[target.id] = ast.literal_eval(node.value)
                except (ValueError, TypeError):
                    pass
    return values


def protocol_prompts(script: Path) -> dict[str, str]:
    """Read upstream prompt literals at runtime without vendoring AGPL source text."""
    tree = ast.parse(script.read_text(encoding="utf-8"))
    wanted = {"ANSWER_PROMPT", "JUDGE_SYS", "JUDGE_USR", "JUDGE_PROMPT"}
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in wanted:
                try:
                    value = ast.literal_eval(node.value)
                except (ValueError, TypeError):
                    continue
                if isinstance(value, str):
                    values[target.id] = value
    if "ANSWER_PROMPT" not in values or not ({"JUDGE_USR", "JUDGE_PROMPT"} & values.keys()):
        raise RuntimeError(f"required prompts missing from {script}")
    return values


def verify_protocol(protocol: dict[str, Any], upstream: Path) -> dict[str, Any]:
    provider = protocol["provider"]
    checks = []
    for benchmark, config in protocol["benchmarks"].items():
        script = upstream / config["upstream_script"]
        constants = protocol_constants(script)
        expected = {
            "ANSWER_MODEL": provider["answer_model"],
            "ANSWER_MAX_TOKENS": config["answer_max_tokens"],
            "ANSWER_TEMPERATURE": provider["answer_temperature"],
            "JUDGE_MODEL": provider["judge_model"],
            "JUDGE_MAX_TOKENS": config["judge_max_tokens"],
            "JUDGE_TEMPERATURE": provider["judge_temperature"],
        }
        if "NUM_JUDGE_RUNS" in constants:
            expected["NUM_JUDGE_RUNS"] = provider["judge_runs"]
        if "TOP_K" in constants:
            expected["TOP_K"] = config["top_k"]
        mismatches = {
            key: {"expected": value, "upstream": constants.get(key)}
            for key, value in expected.items()
            if constants.get(key) != value
        }
        checks.append(
            {
                "benchmark": benchmark,
                "script": config["upstream_script"],
                "script_sha256": sha256(script),
                "constants": constants,
                "mismatches": mismatches,
                "passed": not mismatches,
            }
        )
    return {"passed": all(check["passed"] for check in checks), "checks": checks}


def parse_datetime(value: str) -> datetime | None:
    for pattern in ("%I:%M %p on %d %B, %Y", "%I:%M %p on %d %B %Y"):
        try:
            return datetime.strptime(value.strip(), pattern)
        except ValueError:
            pass
    return None


def resolve_relative_time(text: str, date_string: str) -> str:
    current = parse_datetime(date_string)
    if not current:
        return text
    replacements = [
        (r"\byesterday\b", 1),
        (r"\blast week\b", 7),
        (r"\blast month\b", 30),
        (r"\blast year\b", 365),
        (r"\btwo years ago\b", 730),
        (r"\ba year ago\b", 365),
        (r"\ba month ago\b", 30),
        (r"\ba week ago\b", 7),
        (r"\brecently\b", 7),
    ]
    for pattern, days in replacements:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            absolute = (current - timedelta(days=days)).strftime("%B %d, %Y")
            text = text[: match.start()] + f"{match.group(0)} (approximately {absolute})" + text[match.end() :]
    return text


def normalize_locomo_evidence(values: list[str]) -> list[str]:
    """Normalize known delimiter and formatting inconsistencies in LoCoMo annotations."""
    normalized = []
    for value in values:
        for match in re.finditer(r"D:?([0-9]+):([0-9]+)", value):
            normalized.append(f"D{int(match.group(1))}:{int(match.group(2))}")
    return list(dict.fromkeys(normalized))


def load_locomo(path: Path) -> list[dict[str, Any]]:
    conversations = json.loads(path.read_text(encoding="utf-8"))
    prepared = []
    for conversation in conversations:
        source = conversation["conversation"]
        speakers = (source["speaker_a"], source["speaker_b"])
        messages = []
        sessions = sorted(
            [key for key in source if key.startswith("session_") and not key.endswith("_date_time")],
            key=lambda key: int(key.split("_")[1]),
        )
        for session in sessions:
            date_string = source.get(f"{session}_date_time", "")
            session_time = parse_datetime(date_string)
            for index, turn in enumerate(source[session]):
                speaker = turn["speaker"]
                timestamp = (
                    (session_time + timedelta(seconds=30 * index)).isoformat()
                    if session_time
                    else date_string
                )
                messages.append(
                    {
                        "content": resolve_relative_time(turn["text"], date_string),
                        "speaker": speaker,
                        "recipient": speakers[1] if speaker == speakers[0] else speakers[0],
                        "timestamp": timestamp,
                        "session": session,
                        "evidence_tag": f"D{int(session.split('_')[-1])}:{index + 1}",
                    }
                )
        questions = [
            {
                "id": f"{conversation['sample_id']}:{index}",
                "question": item["question"],
                "gold": item["answer"],
                "category": item["category"],
                "evidence": normalize_locomo_evidence(item.get("evidence", [])),
                "evidence_raw": item.get("evidence", []),
            }
            for index, item in enumerate(conversation["qa"])
            if item["category"] != 5
        ]
        prepared.append(
            {"conversation_id": conversation["sample_id"], "messages": messages, "questions": questions}
        )
    return prepared


def load_longmemeval(path: Path) -> list[dict[str, Any]]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    prepared = []
    for row in rows:
        messages = []
        dates = row.get("haystack_dates", [])
        for session_index, session in enumerate(row.get("haystack_sessions", [])):
            timestamp = dates[session_index] if session_index < len(dates) else ""
            for turn in session:
                role = turn.get("role", "user")
                messages.append(
                    {
                        "content": turn.get("content", ""),
                        "speaker": role,
                        "recipient": "assistant" if role == "user" else "user",
                        "timestamp": timestamp,
                        "session": f"session_{session_index}",
                    }
                )
        prepared.append(
            {
                "conversation_id": row["question_id"],
                "messages": messages,
                "questions": [
                    {
                        "id": row["question_id"],
                        "question": row["question"],
                        "gold": row["answer"],
                        "category": row["question_type"],
                        "question_date": row.get("question_date", ""),
                        "expected_abstention": row["question_id"].endswith("_abs"),
                    }
                ],
            }
        )
    return prepared


def parse_beam_questions(value: str) -> list[dict[str, Any]]:
    groups = ast.literal_eval(value)
    questions = []
    for category, items in groups.items():
        for index, item in enumerate(items):
            gold = (
                item.get("ideal_response")
                or item.get("ideal_answer")
                or item.get("answer")
                or item.get("ideal_summary")
                or item.get("expected_compliance")
                or ""
            )
            questions.append(
                {
                    "id": f"{category}:{index}",
                    "question": item.get("question", ""),
                    "gold": gold,
                    "category": category,
                    "difficulty": item.get("difficulty", ""),
                    "rubric": item.get("rubric", ""),
                }
            )
    return questions


def load_beam(path: Path) -> list[dict[str, Any]]:
    if path.suffix == ".parquet" or path.is_dir():
        try:
            import pyarrow.parquet as parquet
        except ImportError as error:
            raise RuntimeError("BEAM parquet input requires optional pyarrow") from error
        files = sorted(path.glob("*.parquet")) if path.is_dir() else [path]
        rows = []
        for file in files:
            rows.extend(parquet.read_table(file).to_pylist())
    else:
        rows = json.loads(path.read_text(encoding="utf-8"))
    prepared = []
    for row_index, row in enumerate(rows):
        messages = []
        for session_index, session in enumerate(row["chat"]):
            turns = []
            if isinstance(session, list):
                turns = [turn for turn in session if isinstance(turn, dict)]
            elif isinstance(session, dict):
                keys = sorted(
                    session,
                    key=lambda key: int(key.split("-")[1])
                    if "-" in key and key.split("-")[1].isdigit() else 0,
                )
                for key in keys:
                    plan = session[key]
                    if not isinstance(plan, list):
                        continue
                    for batch in plan:
                        if not isinstance(batch, dict):
                            continue
                        for turn_group in batch.get("turns", []):
                            turns.extend(turn for turn in turn_group if isinstance(turn, dict))
            for turn in turns:
                role = turn.get("role", "user")
                messages.append(
                    {
                        "content": turn.get("content", ""),
                        "speaker": role,
                        "recipient": "assistant" if role == "user" else "user",
                        "timestamp": turn.get("time_anchor", ""),
                        "session": f"session_{session_index}",
                    }
                )
        prepared.append(
            {
                "conversation_id": row.get("conversation_id", row_index),
                "messages": messages,
                "questions": parse_beam_questions(row["probing_questions"]),
            }
        )
    return prepared


def prepare_dataset(name: str, source: Path, destination: Path) -> dict[str, Any]:
    if name == "locomo":
        conversations = load_locomo(source)
    elif name.startswith("longmemeval"):
        conversations = load_longmemeval(source)
    elif name.startswith("beam_"):
        conversations = load_beam(source)
    else:
        raise ValueError(f"unsupported benchmark: {name}")
    expected_hash = load_protocol()["benchmarks"][name].get("source_sha256")
    actual_source_hash = source_sha256(source)
    if expected_hash and actual_source_hash != expected_hash:
        raise RuntimeError(f"dataset hash mismatch for {name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8") as output:
        for conversation in conversations:
            output.write(json.dumps(conversation, ensure_ascii=False) + "\n")
    result = {
        "benchmark": name,
        "source": str(source),
        "source_sha256": actual_source_hash,
        "output": str(destination),
        "output_sha256": sha256(destination),
        "conversations": len(conversations),
        "messages": sum(len(item["messages"]) for item in conversations),
        "questions": sum(len(item["questions"]) for item in conversations),
    }
    return result


def wilson(correct: int, total: int, z: float = 1.959963984540054) -> list[float]:
    if total == 0:
        return [0.0, 0.0]
    proportion = correct / total
    denominator = 1 + z * z / total
    center = (proportion + z * z / (2 * total)) / denominator
    margin = z * math.sqrt(proportion * (1 - proportion) / total + z * z / (4 * total * total)) / denominator
    return [round((center - margin) * 100, 2), round((center + margin) * 100, 2)]


def percentile(values: list[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[max(math.ceil(len(ordered) * quantile) - 1, 0)]


def category_breakdown(details: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    result = {}
    for detail in details:
        category = str(detail.get("category", "unknown"))
        bucket = result.setdefault(category, {"correct": 0, "total": 0})
        bucket["total"] += 1
        bucket["correct"] += int(bool(detail.get("correct")))
    for bucket in result.values():
        bucket["accuracy"] = round(bucket["correct"] / bucket["total"] * 100, 3)
        bucket["wilson_95"] = wilson(bucket["correct"], bucket["total"])
    return dict(sorted(result.items()))


def validate_runs(runs: list[dict[str, Any]], protocol: dict[str, Any]) -> None:
    if not runs:
        raise ValueError("no runs supplied")
    benchmark = runs[0].get("benchmark")
    config = protocol["benchmarks"].get(benchmark)
    if not config:
        raise ValueError(f"unknown benchmark: {benchmark}")
    expected_runs = set(range(1, config["runs"] + 1))
    actual_runs = {run.get("run") for run in runs}
    if len(runs) != config["runs"] or actual_runs != expected_runs:
        raise ValueError(f"requires distinct complete runs {sorted(expected_runs)}")
    source_hashes = {run.get("source_sha256") for run in runs}
    strategies = {run.get("retrieval_strategy") for run in runs}
    for run in runs:
        if run.get("benchmark") != benchmark or run.get("protocol") != protocol["version"]:
            raise ValueError("mixed benchmark or protocol")
        if run.get("mode") != "matched_answer_judge" or run.get("answer_evaluation_state") != "COMPLETE":
            raise ValueError("only completed matched answer/judge runs may be aggregated")
        if run.get("total_questions") != config["questions"] or len(run.get("details", [])) != config["questions"]:
            raise ValueError("partial runs cannot be aggregated")
        ids = [detail.get("id") for detail in run["details"]]
        if len(ids) != len(set(ids)) or None in ids:
            raise ValueError("run contains missing or duplicate question IDs")
    if len(source_hashes) != 1:
        raise ValueError("runs use different prepared datasets")
    if len(strategies) != 1:
        raise ValueError("runs use different retrieval strategies")


def aggregate(paths: list[Path], protocol: dict[str, Any] | None = None) -> dict[str, Any]:
    runs = [json.loads(path.read_text(encoding="utf-8")) for path in paths]
    protocol = protocol or load_protocol()
    validate_runs(runs, protocol)
    scores = []
    for run in runs:
        total = int(run.get("total_questions", len(run.get("details", []))))
        correct = int(run.get("total_correct", sum(bool(item.get("correct")) for item in run.get("details", []))))
        scores.append(correct / total * 100 if total else 0.0)
    details = [item for run in runs for item in run.get("details", [])]
    latencies = [
        float(item[key])
        for item in details
        for key in ("retrieval_latency_s", "answer_latency_s", "judge_latency_s")
        if isinstance(item.get(key), (int, float))
    ]
    first_total = int(runs[0].get("total_questions", len(runs[0].get("details", [])))) if runs else 0
    mean_score = sum(scores) / len(scores) if scores else 0.0
    mean_correct = round(mean_score / 100 * first_total)
    return {
        "benchmark_version": "truememory-compatible-aggregate-v1",
        "runs": len(runs),
        "scores": [round(score, 3) for score in scores],
        "mean_accuracy": round(mean_score, 3),
        "standard_deviation": round((sum((score - mean_score) ** 2 for score in scores) / len(scores)) ** 0.5, 3) if scores else 0.0,
        "total_questions_per_run": first_total,
        "mean_correct": mean_correct,
        "wilson_95": wilson(mean_correct, first_total),
        "by_category": category_breakdown(details),
        "model_usage": {
            key: sum(int(run.get("model_usage", {}).get(key, 0)) for run in runs)
            for key in ("prompt_tokens", "completion_tokens", "total_tokens")
        },
        "estimated_cost_usd": (
            round(sum(float(run["estimated_cost_usd"]) for run in runs), 6)
            if all(run.get("estimated_cost_usd") is not None for run in runs) else None
        ),
        "latency_p50_s": round(percentile(latencies, 0.50), 3),
        "latency_p95_s": round(percentile(latencies, 0.95), 3),
        "latency_p99_s": round(percentile(latencies, 0.99), 3),
        "source_files": [{"path": str(path), "sha256": sha256(path)} for path in paths],
    }


def status(protocol: dict[str, Any], results_dir: Path) -> dict[str, Any]:
    benchmarks = []
    for name, config in protocol["benchmarks"].items():
        paths = sorted(results_dir.glob(f"optimal_engine_{name}_run[1-3].json"))
        required = config["runs"]
        complete = False
        if len(paths) == required:
            try:
                validate_runs([json.loads(path.read_text(encoding="utf-8")) for path in paths], protocol)
                complete = True
            except (ValueError, KeyError, json.JSONDecodeError):
                pass
        benchmarks.append(
            {
                "benchmark": name,
                "required_runs": required,
                "completed_runs": len(paths),
                "state": "COMPLETE" if complete else "NOT RUN" if not paths else "PARTIAL",
                "results": [str(path) for path in paths],
            }
        )
    return {"compatible_protocol": protocol["version"], "benchmarks": benchmarks}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", default=str(DEFAULT_PROTOCOL))
    subparsers = parser.add_subparsers(dest="command", required=True)
    sync = subparsers.add_parser("sync")
    sync.add_argument("--destination", required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--upstream", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--benchmark", required=True)
    prepare.add_argument("--source", required=True)
    prepare.add_argument("--out", required=True)
    aggregation = subparsers.add_parser("aggregate")
    aggregation.add_argument("--runs", nargs="+", required=True)
    aggregation.add_argument("--out")
    state = subparsers.add_parser("status")
    state.add_argument("--results-dir", default="benchmarks/results/truememory")
    args = parser.parse_args()
    protocol = load_protocol(Path(args.protocol))

    if args.command == "sync":
        result = sync_upstream(protocol, Path(args.destination))
    elif args.command == "verify":
        result = verify_protocol(protocol, Path(args.upstream))
    elif args.command == "prepare":
        result = prepare_dataset(args.benchmark, Path(args.source), Path(args.out))
    elif args.command == "aggregate":
        result = aggregate([Path(path) for path in args.runs], protocol)
        if args.out:
            Path(args.out).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    else:
        result = status(protocol, Path(args.results_dir))

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result.get("passed", True) else 2


if __name__ == "__main__":
    raise SystemExit(main())
