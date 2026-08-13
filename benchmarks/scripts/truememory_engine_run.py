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
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

from truememory_compat import category_breakdown, load_protocol, percentile, protocol_prompts, sha256, verify_protocol, wilson
from truememory_diagnostics import bm25_rank


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
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


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


def retrieve_semantic(
    engine_url: str,
    workspace: str,
    question: str,
    top_k: int,
    embedding_model: str | None = None,
    search_mode: str = "hybrid",
) -> tuple[list[dict], float]:
    started = time.perf_counter()
    params = {
        "tenant": "default", "workspace": workspace, "type": "memory",
        "q": question, "limit": top_k,
        "memory_search_mode": search_mode,
    }
    if embedding_model:
        params["memory_embedding_model"] = embedding_model
    response = get_json(
        f"{engine_url.rstrip('/')}/api/search",
        params,
    )
    return response.get("results") or [], time.perf_counter() - started


def query_variants(question: str) -> list[str]:
    """Build deterministic entity and clause probes for coverage-oriented retrieval."""
    variants = [question]
    clauses = [part.strip(" ,?.") for part in __import__("re").split(r"\b(?:and|while|but)\b", question, flags=__import__("re").I)]
    variants.extend(part for part in clauses if len(part.split()) >= 3)
    entities = __import__("re").findall(r"\b[A-Z][a-z]{2,}\b", question)
    ignored = {"What", "When", "Where", "Which", "Who", "Why", "How", "Does", "Did"}
    for entity in entities:
        if entity not in ignored:
            variants.append(entity)
    return list(dict.fromkeys(variant for variant in variants if variant))


def round_robin_fuse(result_sets: list[list[dict[str, Any]]], limit: int) -> list[dict[str, Any]]:
    fused, seen = [], set()
    for index in range(max((len(results) for results in result_sets), default=0)):
        for results in result_sets:
            if index >= len(results):
                continue
            item = results[index]
            identity = item.get("id") or item.get("content")
            if identity in seen:
                continue
            seen.add(identity)
            fused.append(item)
            if len(fused) == limit:
                return fused
    return fused


def coverage_fuse(original: list[dict[str, Any]], expansions: list[list[dict[str, Any]]], limit: int) -> list[dict[str, Any]]:
    quota = max(1, round(limit * 0.8))
    primary = original[:quota]
    candidates = primary + round_robin_fuse(expansions, limit - quota) + original[quota:]
    fused, seen = [], set()
    for item in candidates:
        identity = item.get("id") or item.get("content")
        if identity in seen:
            continue
        seen.add(identity)
        fused.append(item)
        if len(fused) == limit:
            break
    return fused


def retrieve_coverage(engine_url: str, workspace: str, question: str, top_k: int) -> tuple[list[dict], float]:
    started = time.perf_counter()
    variants = query_variants(question)
    with ThreadPoolExecutor(max_workers=min(len(variants), 6)) as executor:
        futures = [
            executor.submit(
                retrieve, engine_url, workspace, variant,
                top_k if index == 0 else min(20, top_k),
            )
            for index, variant in enumerate(variants)
        ]
        result_sets = [future.result()[0] for future in futures]
    return coverage_fuse(result_sets[0], result_sets[1:], top_k), time.perf_counter() - started


def retrieve_evidence_set(
    engine_url: str,
    workspace: str,
    question: str,
    top_k: int,
    embedding_model: str | None = None,
) -> tuple[list[dict], float]:
    """Retrieve semantic evidence independently per deterministic plan probe."""
    started = time.perf_counter()
    variants = query_variants(question)
    with ThreadPoolExecutor(max_workers=min(len(variants), 6)) as executor:
        futures = [
            executor.submit(
                retrieve_semantic,
                engine_url,
                workspace,
                variant,
                top_k,
                embedding_model,
            )
            for variant in variants
        ]
        result_sets = [future.result()[0] for future in futures]
    return coverage_fuse(result_sets[0], result_sets[1:], top_k), time.perf_counter() - started


def evidence_recall(expected: list[str], memories: list[dict[str, Any]]) -> tuple[int, int]:
    if not expected:
        return 0, 0
    text = "\n".join(memory.get("content", "") for memory in memories)
    found = sum(1 for evidence in expected if f"[{evidence}]" in text)
    return found, len(expected)


def local_retrieve(
    strategy: str, conversation: dict[str, Any], question: dict[str, Any], top_k: int
) -> tuple[list[dict[str, Any]], float]:
    started = time.perf_counter()
    if strategy == "bm25":
        selected = bm25_rank(conversation["messages"], question["question"], top_k)
    elif strategy == "oracle":
        evidence = set(question.get("evidence", []))
        selected = [message for message in conversation["messages"] if message.get("evidence_tag") in evidence]
    else:
        raise ValueError(f"unsupported local strategy: {strategy}")
    memories = [{"content": f"[{item.get('evidence_tag', '')}] {item['content']}"} for item in selected]
    return memories, time.perf_counter() - started


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


def summarize(
    details: list[dict[str, Any]], benchmark: str, run_id: int, source: Path, paid: bool,
    ingest_seconds: float = 0.0, prices: dict[str, float] | None = None,
    retrieval_strategy: str = "engine_memory",
) -> dict[str, Any]:
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
        "retrieval_strategy": retrieval_strategy,
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
        "ingest_time_s": round(ingest_seconds, 4),
        "ingest_messages_per_second": None,
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
        prices = prices or {}
        result["pricing_usd_per_million_tokens"] = prices
        result["estimated_cost_usd"] = round(
            sum(
                int(item.get("answer_usage", {}).get("prompt_tokens", 0)) * prices.get("answer_input", 0)
                + int(item.get("answer_usage", {}).get("completion_tokens", 0)) * prices.get("answer_output", 0)
                + sum(int(use.get("prompt_tokens", 0)) for use in item.get("judge_usage", [])) * prices.get("judge_input", 0)
                + sum(int(use.get("completion_tokens", 0)) for use in item.get("judge_usage", [])) * prices.get("judge_output", 0)
                for item in details
            ) / 1_000_000,
            6,
        ) if any(prices.values()) else None
        result["cost_state"] = "COMPLETE" if any(prices.values()) else "NOT CALCULATED - provide explicit current prices"
        result["by_category"] = category_breakdown(details)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark", required=True)
    parser.add_argument("--prepared", required=True)
    parser.add_argument("--engine-url", default="http://127.0.0.1:4200")
    parser.add_argument("--workspace-prefix", default="benchmark:truememory")
    parser.add_argument(
        "--retrieval", choices=("engine_memory", "engine_semantic", "engine_semantic_only", "engine_coverage", "engine_evidence", "bm25", "oracle"),
        default="engine_memory",
    )
    parser.add_argument("--top-k", type=int, help="Ablation override; official matched runs must use manifest top-k")
    parser.add_argument("--run-id", type=int, default=1)
    parser.add_argument("--conversation-limit", type=int)
    parser.add_argument("--question-limit", type=int)
    parser.add_argument("--message-limit", type=int, help="Smoke-test only: seed the first N messages")
    parser.add_argument("--sleep-ms", type=int, default=700)
    parser.add_argument("--skip-seed", action="store_true")
    parser.add_argument("--out", required=True)
    parser.add_argument("--paid", action="store_true", help="Run exact upstream answer and three-vote judge protocol")
    parser.add_argument("--upstream", help="Pinned TrueMemory checkout used to load exact prompt literals")
    parser.add_argument("--resume", action="store_true", help="Resume completed question IDs from --out")
    parser.add_argument("--answer-input-cost", type=float, default=0.0, help="USD per million tokens")
    parser.add_argument("--answer-output-cost", type=float, default=0.0, help="USD per million tokens")
    parser.add_argument("--judge-input-cost", type=float, default=0.0, help="USD per million tokens")
    parser.add_argument("--judge-output-cost", type=float, default=0.0, help="USD per million tokens")
    parser.add_argument("--workers", type=int, default=8, help="Concurrent paid answer/judge jobs")
    parser.add_argument("--embedding-model", help="Memory projection model used by engine_semantic")
    args = parser.parse_args()
    protocol = load_protocol()
    config = protocol["benchmarks"][args.benchmark]
    top_k = args.top_k or config["top_k"]
    if args.paid and top_k != config["top_k"]:
        parser.error("official paid runs must use the manifest top-k")
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
    output = Path(args.out)
    details = []
    if args.resume and output.exists():
        details = json.loads(output.read_text(encoding="utf-8")).get("details", [])
        if args.paid:
            details = [detail for detail in details if "correct" in detail]
    completed_ids = {
        detail["id"] for detail in details
        if not args.paid or "correct" in detail
    }
    pending_paid = []
    ingest_seconds = 0.0
    seeded_messages = 0
    remaining_questions = args.question_limit
    for conversation_index, conversation in enumerate(conversations):
        slug = f"{args.workspace_prefix}-{args.benchmark}-r{args.run_id}-c{conversation_index}".replace(":", "-")
        engine_strategy = args.retrieval in {"engine_memory", "engine_semantic", "engine_semantic_only", "engine_coverage", "engine_evidence"}
        workspace = ensure_workspace(args.engine_url, slug) if engine_strategy else None
        if engine_strategy and not args.skip_seed:
            seed_started = time.perf_counter()
            seeded = seed_conversation(
                args.engine_url, workspace, conversation, args.sleep_ms, args.message_limit
            )
            ingest_seconds += time.perf_counter() - seed_started
            seeded_messages += seeded
            print(f"seeded {seeded} messages into {workspace}")
        questions = conversation["questions"]
        if remaining_questions is not None:
            questions = questions[:remaining_questions]
        for question in questions:
            if question["id"] in completed_ids:
                continue
            if args.retrieval == "engine_memory":
                memories, latency = retrieve(args.engine_url, workspace, question["question"], top_k)
            elif args.retrieval == "engine_semantic":
                memories, latency = retrieve_semantic(
                    args.engine_url, workspace, question["question"], top_k, args.embedding_model
                )
            elif args.retrieval == "engine_semantic_only":
                memories, latency = retrieve_semantic(
                    args.engine_url,
                    workspace,
                    question["question"],
                    top_k,
                    args.embedding_model,
                    "semantic",
                )
            elif args.retrieval == "engine_coverage":
                memories, latency = retrieve_coverage(
                    args.engine_url, workspace, question["question"], top_k
                )
            elif args.retrieval == "engine_evidence":
                memories, latency = retrieve_evidence_set(
                    args.engine_url,
                    workspace,
                    question["question"],
                    top_k,
                    args.embedding_model,
                )
            else:
                memories, latency = local_retrieve(args.retrieval, conversation, question, top_k)
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
                pending_paid.append((detail, question, memories))
            details.append(detail)
            retrieval_checkpoint = summarize(
                details, args.benchmark, args.run_id, source, False,
                retrieval_strategy=args.retrieval,
            )
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(retrieval_checkpoint, indent=2) + "\n", encoding="utf-8")
            if not args.paid:
                pass
            print(f"[{len(details)}] {question['id']} evidence={found}/{total} latency={latency:.3f}s")
        if remaining_questions is not None:
            remaining_questions -= len(questions)
            if remaining_questions <= 0:
                break
    if args.paid and pending_paid:
        def run_paid(item):
            detail, question, memories = item
            evaluation = evaluate_answer(
                question, memories, prompts, config, protocol["provider"], api_key
            )
            return detail, evaluation

        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            futures = [executor.submit(run_paid, item) for item in pending_paid]
            for completed, future in enumerate(as_completed(futures), start=1):
                detail, evaluation = future.result()
                detail.update(evaluation)
                completed_details = [item for item in details if "correct" in item]
                checkpoint = summarize(
                    completed_details, args.benchmark, args.run_id, source, True,
                    retrieval_strategy=args.retrieval,
                )
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps(checkpoint, indent=2) + "\n", encoding="utf-8")
                print(f"paid [{completed}/{len(futures)}] {detail['id']} correct={detail['correct']}")
    prices = {
        "answer_input": args.answer_input_cost, "answer_output": args.answer_output_cost,
        "judge_input": args.judge_input_cost, "judge_output": args.judge_output_cost,
    }
    result = summarize(
        details, args.benchmark, args.run_id, source, args.paid, ingest_seconds, prices,
        args.retrieval,
    )
    if seeded_messages:
        result["ingest_messages_per_second"] = round(seeded_messages / ingest_seconds, 3)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "details"}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
