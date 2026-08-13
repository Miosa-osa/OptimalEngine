#!/usr/bin/env python3
"""Run prepared TrueMemory benchmark cases through Optimal Engine."""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from truememory_compat import load_protocol, percentile, protocol_prompts, sha256, verify_protocol, wilson


def request_json(method: str, url: str, payload: dict[str, Any] | None = None, retries: int = 8) -> dict[str, Any]:
    body = json.dumps(payload).encode() if payload is not None else None
    for attempt in range(retries + 1):
        request = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json"} if body else {},
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.loads(response.read().decode())
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            if error.code == 429 and attempt < retries:
                try:
                    wait = int(json.loads(detail).get("retry_after_ms", 500)) / 1000
                except (ValueError, TypeError, json.JSONDecodeError):
                    wait = 0.5
                time.sleep(max(wait, 0.1))
                continue
            raise RuntimeError(f"HTTP {error.code} {url}: {detail}") from error
    raise RuntimeError(f"retry exhaustion: {url}")


def post_json(url: str, payload: dict[str, Any]) -> dict[str, Any]:
    return request_json("POST", url, payload)


def get_json(url: str, params: dict[str, Any]) -> dict[str, Any]:
    return request_json("GET", f"{url}?{urllib.parse.urlencode(params)}")


def load_prepared(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def ensure_workspace(engine_url: str, slug: str) -> str:
    """Resolve or create an isolated benchmark workspace and return its canonical id."""
    response = get_json(
        f"{engine_url.rstrip('/')}/api/workspaces",
        {"tenant": "default", "status": "all", "limit": 500},
    )
    for workspace in response.get("workspaces", []):
        if workspace.get("slug") == slug:
            return workspace["id"]
    created = post_json(
        f"{engine_url.rstrip('/')}/api/workspaces",
        {
            "slug": slug,
            "name": f"TrueMemory benchmark {slug}",
            "description": "Isolated, reproducible TrueMemory compatibility fixture workspace.",
            "tenant": "default",
        },
    )
    return created["id"]


def seed_conversation(
    engine_url: str,
    workspace: str,
    conversation: dict[str, Any],
    sleep_ms: int,
    message_limit: int | None = None,
) -> int:
    messages = conversation["messages"][:message_limit] if message_limit else conversation["messages"]
    for index, message in enumerate(messages):
        evidence_tag = message.get("evidence_tag") or f"message:{index + 1}"
        content = (
            f"[{evidence_tag}] [{message.get('timestamp', '')}] "
            f"{message.get('speaker', '?')} to {message.get('recipient', '?')}: {message['content']}"
        )
        post_json(
            f"{engine_url.rstrip('/')}/api/memory",
            {
                "workspace": workspace,
                "audience": "benchmark",
                "content": content,
                "metadata": {
                    "benchmark": "truememory-compatible",
                    "conversation_id": conversation["conversation_id"],
                    "evidence_tag": evidence_tag,
                    "timestamp": message.get("timestamp"),
                    "speaker": message.get("speaker"),
                    "session": message.get("session"),
                },
            },
        )
        if sleep_ms:
            time.sleep(sleep_ms / 1000)
    return len(messages)


def retrieve(engine_url: str, workspace: str, question: str, top_k: int) -> tuple[list[dict], float]:
    started = time.perf_counter()
    response = get_json(
        f"{engine_url.rstrip('/')}/api/memory",
        {"workspace": workspace, "q": question, "limit": top_k},
    )
    return response.get("memories") or [], time.perf_counter() - started


def evidence_recall(expected: list[str], memories: list[dict[str, Any]]) -> tuple[int, int]:
    if not expected:
        return 0, 0
    text = "\n".join(memory.get("content", "") for memory in memories)
    found = sum(1 for evidence in expected if f"[{evidence}]" in text)
    return found, len(expected)


def openrouter_chat(api_key: str, model: str, messages: list[dict[str, str]], max_tokens: int) -> tuple[str, dict]:
    payload_bytes = json.dumps(
        {"model": model, "messages": messages, "temperature": 0, "max_tokens": max_tokens}
    ).encode()
    for attempt in range(6):
        request = urllib.request.Request(
            "https://openrouter.ai/api/v1/chat/completions",
            data=payload_bytes,
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                payload = json.loads(response.read().decode())
            return payload["choices"][0]["message"]["content"], payload.get("usage", {})
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
            if attempt == 5:
                raise
            time.sleep(2 ** attempt)
    raise RuntimeError("OpenRouter retry exhaustion")


def verdict(text: str) -> bool:
    try:
        return json.loads(text.strip()).get("label", "").upper() == "CORRECT"
    except (json.JSONDecodeError, AttributeError):
        upper = text.upper()
        return "CORRECT" in upper and "WRONG" not in upper


def evaluate_answer(
    question: dict[str, Any], memories: list[dict[str, Any]], prompts: dict[str, str],
    config: dict[str, Any], provider: dict[str, Any], api_key: str,
) -> dict[str, Any]:
    context = "\n\n".join(memory.get("content", "") for memory in memories)
    answer_prompt = prompts["ANSWER_PROMPT"].format(
        context=context, question=question["question"], question_date=question.get("question_date", "")
    )
    started = time.perf_counter()
    answer, answer_usage = openrouter_chat(
        api_key, provider["answer_model"], [{"role": "user", "content": answer_prompt}],
        config["answer_max_tokens"],
    )
    answer_latency = time.perf_counter() - started
    if question.get("expected_abstention"):
        phrases = ("don't have", "no information", "not mentioned", "not available", "cannot find",
                   "no record", "wasn't discussed", "not discussed", "don't recall", "no conversation", "not in our")
        votes = [any(phrase in answer.lower() for phrase in phrases)] * provider["judge_runs"]
        judge_usage = []
        judge_latency = 0.0
    else:
        template = prompts.get("JUDGE_USR") or prompts["JUDGE_PROMPT"]
        judge_prompt = template.format(
            question=question["question"], gold=question["gold"], ideal=question["gold"], generated=answer
        )
        votes, judge_usage = [], []
        judge_started = time.perf_counter()
        for _ in range(provider["judge_runs"]):
            messages = [{"role": "user", "content": judge_prompt}]
            if prompts.get("JUDGE_SYS"):
                messages.insert(0, {"role": "system", "content": prompts["JUDGE_SYS"]})
            judged, usage = openrouter_chat(
                api_key, provider["judge_model"], messages, config["judge_max_tokens"]
            )
            votes.append(verdict(judged))
            judge_usage.append(usage)
        judge_latency = time.perf_counter() - judge_started
    return {
        "generated_answer": answer,
        "correct": sum(votes) > len(votes) / 2,
        "judge_votes": votes,
        "answer_latency_s": round(answer_latency, 4),
        "judge_latency_s": round(judge_latency, 4),
        "answer_usage": answer_usage,
        "judge_usage": judge_usage,
    }


def summarize(details: list[dict[str, Any]], benchmark: str, run_id: int, source: Path, paid: bool) -> dict[str, Any]:
    recall_found = sum(item["evidence_found"] for item in details)
    recall_total = sum(item["evidence_total"] for item in details)
    hit_questions = sum(item["evidence_found"] > 0 for item in details if item["evidence_total"] > 0)
    scorable_questions = sum(item["evidence_total"] > 0 for item in details)
    latencies = [item["retrieval_latency_s"] for item in details]
    answer_correct = sum(bool(item.get("correct")) for item in details)
    result = {
        "system": "optimal_engine",
        "benchmark": benchmark,
        "protocol": "truememory-compat-v1",
        "run": run_id,
        "mode": "matched_answer_judge" if paid else "retrieval_only",
        "source_sha256": sha256(source),
        "total_questions": len(details),
        "total_correct": answer_correct if paid else hit_questions,
        "retrieval_question_recall": round(hit_questions / scorable_questions * 100, 3) if scorable_questions else None,
        "evidence_recall": round(recall_found / recall_total * 100, 3) if recall_total else None,
        "evidence_found": recall_found,
        "evidence_total": recall_total,
        "wilson_95": wilson(hit_questions, scorable_questions),
        "retrieval_latency_p50_s": round(percentile(latencies, 0.50), 4),
        "retrieval_latency_p95_s": round(percentile(latencies, 0.95), 4),
        "retrieval_latency_p99_s": round(percentile(latencies, 0.99), 4),
        "details": details,
        "answer_evaluation_state": "COMPLETE" if paid else "NOT RUN - requires --paid and OPENROUTER_API_KEY",
    }
    if paid:
        result["answer_accuracy"] = round(answer_correct / len(details) * 100, 3) if details else None
        result["wilson_95"] = wilson(answer_correct, len(details))
        usages = [item.get("answer_usage", {}) for item in details]
        usages.extend(usage for item in details for usage in item.get("judge_usage", []))
        result["model_usage"] = {
            "prompt_tokens": sum(int(usage.get("prompt_tokens", 0)) for usage in usages),
            "completion_tokens": sum(int(usage.get("completion_tokens", 0)) for usage in usages),
            "total_tokens": sum(int(usage.get("total_tokens", 0)) for usage in usages),
        }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark", required=True)
    parser.add_argument("--prepared", required=True)
    parser.add_argument("--engine-url", default="http://127.0.0.1:4200")
    parser.add_argument("--workspace-prefix", default="benchmark:truememory")
    parser.add_argument("--run-id", type=int, default=1)
    parser.add_argument("--conversation-limit", type=int)
    parser.add_argument("--question-limit", type=int)
    parser.add_argument("--message-limit", type=int, help="Smoke-test only: seed the first N messages")
    parser.add_argument("--sleep-ms", type=int, default=700)
    parser.add_argument("--skip-seed", action="store_true")
    parser.add_argument("--out", required=True)
    parser.add_argument("--paid", action="store_true", help="Run exact upstream answer and three-vote judge protocol")
    parser.add_argument("--upstream", help="Pinned TrueMemory checkout used to load exact prompt literals")
    args = parser.parse_args()
    protocol = load_protocol()
    config = protocol["benchmarks"][args.benchmark]
    api_key = os.environ.get("OPENROUTER_API_KEY")
    prompts = None
    if args.paid:
        if not api_key:
            parser.error("--paid requires OPENROUTER_API_KEY")
        if not args.upstream:
            parser.error("--paid requires --upstream pointing at the pinned TrueMemory checkout")
        upstream = Path(args.upstream)
        commit = __import__("subprocess").check_output(
            ["git", "rev-parse", "HEAD"], cwd=upstream, text=True
        ).strip()
        verification = verify_protocol(protocol, upstream)
        if commit != protocol["upstream"]["commit"] or not verification["passed"]:
            parser.error("upstream checkout does not match the pinned TrueMemory protocol")
        prompts = protocol_prompts(upstream / config["upstream_script"])
    source = Path(args.prepared)
    conversations = load_prepared(source)
    if args.conversation_limit:
        conversations = conversations[: args.conversation_limit]
    details = []
    remaining_questions = args.question_limit
    for conversation_index, conversation in enumerate(conversations):
        slug = f"{args.workspace_prefix}-{args.benchmark}-r{args.run_id}-c{conversation_index}".replace(":", "-")
        workspace = ensure_workspace(args.engine_url, slug)
        if not args.skip_seed:
            seeded = seed_conversation(
                args.engine_url, workspace, conversation, args.sleep_ms, args.message_limit
            )
            print(f"seeded {seeded} messages into {workspace}")
        questions = conversation["questions"]
        if remaining_questions is not None:
            questions = questions[:remaining_questions]
        for question in questions:
            memories, latency = retrieve(args.engine_url, workspace, question["question"], config["top_k"])
            found, total = evidence_recall(question.get("evidence", []), memories)
            detail = {
                    "id": question["id"],
                    "category": question["category"],
                    "question": question["question"],
                    "gold": question["gold"],
                    "num_retrieved": len(memories),
                    "evidence_found": found,
                    "evidence_total": total,
                    "retrieval_latency_s": round(latency, 4),
                }
            if args.paid:
                detail.update(evaluate_answer(question, memories, prompts, config, protocol["provider"], api_key))
            details.append(detail)
            print(f"[{len(details)}] {question['id']} evidence={found}/{total} latency={latency:.3f}s")
        if remaining_questions is not None:
            remaining_questions -= len(questions)
            if remaining_questions <= 0:
                break
    result = summarize(details, args.benchmark, args.run_id, source, args.paid)
    output = Path(args.out)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "details"}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
