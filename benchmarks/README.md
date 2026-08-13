# Optimal Engine Benchmarks

## Run the complete release scorecard

```bash
python3 benchmarks/scripts/release_benchmark.py
```

This runs twelve named benchmark families and writes:

- `benchmarks/results/release-current.json` for automation
- `benchmarks/results/RELEASE-CURRENT.md` for people
- `benchmarks/results/release-history.jsonl` for comparisons over time

The twelve families cover the governed Gold Set contract, entity identity, episodic memory, graph reasoning, citation quality, ingestion, recovery, capacity, overload, adversarial mutation, workflow-skill-asset governance, and benchmark history.
Each suite records its qualification level and any remaining limitation so a harness check cannot masquerade as production proof.

This directory contains dependency-free benchmark harnesses for measuring Optimal Engine quality, speed, safety, and reliability.

## What the numbers mean

- Accuracy asks: did the system return the right answer?
- Recall asks: did the right evidence appear anywhere in the returned results?
- Precision asks: how much returned material was actually useful?
- Abstention asks: did the system say it lacked evidence instead of inventing an answer?
- P50 is a typical request.
- P95 is a slow request that about 1 in 20 users experiences.
- P99 is a bad-tail request that about 1 in 100 users experiences.
- Throughput is how many requests finish per second at a declared concurrency.
- Error rate is the share of requests that fail or time out.
- Leakage rate is the share of answers that expose data outside the authorized tenant, workspace, label, or partition.

A fast wrong answer fails.
A correct answer that leaks private data also fails.
Optimal Engine is only classified as optimal when every required gate passes on a current, reproducible run.

The full scorecard and release gates are documented in
`docs/guides/BENCHMARKING.md`.

The first harness is model-provider agnostic: it calls the local Optimal Engine
API for answers, then optionally asks a separate judge model to grade the answer
against a gold answer.

## Local Smoke Test

Start the engine first:

```bash
../.system/oe start
```

Then run the sample questions without a model judge:

```bash
python3 benchmarks/scripts/optimal_eval.py \
  --questions benchmarks/sample_questions.jsonl \
  --judge none \
  --out benchmarks/results/sample_unjudged.jsonl
```

## Ollama Cloud Judge

Ollama Cloud direct API access uses `https://ollama.com/api` and bearer-token
auth via `OLLAMA_API_KEY`.

```bash
export OLLAMA_API_KEY=...

python3 benchmarks/scripts/optimal_eval.py \
  --questions benchmarks/sample_questions.jsonl \
  --judge ollama \
  --judge-model gpt-oss:120b \
  --judge-votes 3 \
  --out benchmarks/results/sample_ollama.jsonl
```

Useful options:

- `--engine-url http://127.0.0.1:4200`
- `--workspace default`
- `--limit 20`
- `--judge-temperature 0`
- `--judge-base-url https://ollama.com/api`

## OpenAI-Compatible Judge

For any provider exposing `/v1/chat/completions`:

```bash
export JUDGE_API_KEY=...

python3 benchmarks/scripts/optimal_eval.py \
  --questions benchmarks/sample_questions.jsonl \
  --judge openai-compatible \
  --judge-base-url https://example.com/v1 \
  --judge-model some-model \
  --out benchmarks/results/sample_openai_compat.jsonl
```

## Question Format

Each line is JSON:

```json
{"id":"q1","workspace":"default","question":"...","gold":"...","category":"single-hop"}
```

`workspace` is optional; `--workspace` is used as the default.

## Output Format

Each result line includes:

- question metadata
- Optimal Engine answer and trace
- latency in milliseconds
- judge votes
- final label: `correct`, `partial`, `incorrect`, or `unjudged`

Never put provider API keys in question files or result files.

## System Performance

Measure endpoint tail latency, throughput, reliability, and declared SLOs:

```bash
python3 benchmarks/scripts/system_benchmark.py \
  --profile smoke \
  --workspace default:miosa \
  --out benchmarks/results/system-smoke.json
```

Set `--warmup 0` to include cold-first-request cost.
Use the profile warmup for steady-state measurements.
Set `--request-rate 5` for a paced sustained workload.
Omit it for an intentional saturation burst.
Latency percentiles use successful requests only, while 429 responses remain visible in the error rate, status counts, and rate-limited request count.

Run the isolated security and governance benchmark against the test database:

```bash
python3 benchmarks/scripts/security_benchmark.py \
  --out benchmarks/results/security-regression.json
```

This never writes benchmark fixtures into the live Engine database.

Profiles live in `benchmarks/configs/system_profiles.json`.
Use `interactive` for release qualification and reserve `soak` for an isolated or explicitly scheduled run.

## Benchmark Card

Render a benchmark-card style summary from any result JSONL:

```bash
python3 benchmarks/scripts/summarize_results.py \
  --results benchmarks/results/sample_ollama_qwen35_397b.jsonl \
  --out benchmarks/results/sample_ollama_qwen35_397b.md \
  --title "Optimal Engine Sample Memory Results" \
  --dataset "Sample pricing memory, 3 Qs" \
  --answer-system "Optimal Engine /api/rag, wiki-first" \
  --judge "qwen3.5:397b via Ollama Cloud" \
  --judge-votes 3 \
  --retrieval-top-k "engine default; returned 1" \
  --compute "local engine + Ollama Cloud judge"
```

This produces a small public-facing report with evaluation config, aggregate
score, latency, retrieval source mix, and per-question vote splits.

## Large-Scale Memory Benchmarks

Generate a 500-question institutional-memory dataset:

```bash
python3 benchmarks/scripts/generate_memory_dataset.py \
  --name synthetic-500 \
  --out-dir benchmarks/generated/synthetic-500 \
  --workspace bench-synthetic-500 \
  --conversations 100 \
  --questions-per-conversation 5
```

Seed it into the running engine and promote each conversation to a wiki page:

```bash
python3 benchmarks/scripts/seed_memory_corpus.py \
  --corpus benchmarks/generated/synthetic-500/corpus.jsonl \
  --out benchmarks/generated/synthetic-500/seeded.jsonl \
  --workspace bench-synthetic-500 \
  --benchmark synthetic-500 \
  --promote
```

Run the benchmark:

```bash
python3 benchmarks/scripts/optimal_eval.py \
  --questions benchmarks/generated/synthetic-500/questions.jsonl \
  --workspace bench-synthetic-500 \
  --engine-mode memory-search \
  --query-field retrieval_query \
  --retrieval-limit 3 \
  --judge ollama \
  --judge-model qwen3.5:397b \
  --judge-votes 3 \
  --http-retries 6 \
  --retry-sleep-ms 300 \
  --out benchmarks/results/synthetic_500_memory_ollama_qwen35_397b.jsonl
```

Run the same questions through natural-language `/api/rag` while bypassing the
intent model for benchmark throughput:

```bash
python3 benchmarks/scripts/optimal_eval.py \
  --questions benchmarks/generated/synthetic-500/questions.jsonl \
  --workspace bench-synthetic-500 \
  --engine-mode rag \
  --rag-skip-intent \
  --memory-limit 5 \
  --judge none \
  --http-retries 6 \
  --retry-sleep-ms 300 \
  --out benchmarks/results/synthetic_500_rag_skip_intent_unjudged.jsonl
```

Then render the public card:

```bash
python3 benchmarks/scripts/summarize_results.py \
  --results benchmarks/results/synthetic_500_memory_ollama_qwen35_397b.jsonl \
  --out benchmarks/results/synthetic_500_memory_ollama_qwen35_397b.md \
  --title "Optimal Engine Synthetic-500 Memory Results" \
  --dataset "100 conversations, 500 questions" \
  --answer-system "Optimal Engine /api/memory FTS" \
  --judge "qwen3.5:397b via Ollama Cloud" \
  --judge-votes 3 \
  --retrieval-top-k 3 \
  --compute "local engine + Ollama Cloud judge"
```

The generated question rows include both a natural-language `question` and a
focused `retrieval_query`. Use `--query-field retrieval_query` when the goal is
to measure scoped memory retrieval. Use the default `/api/rag` mode separately
when testing natural-language routing and wiki-first recall. Use
`--rag-skip-intent` for large controlled runs where the question text already
contains the needed retrieval cues and the benchmark should measure retrieval
rather than intent-model latency.

For BEAM-like question volume, generate 35 conversations and 700 paraphrased
questions:

```bash
python3 benchmarks/scripts/generate_memory_dataset.py \
  --name synthetic-700 \
  --out-dir benchmarks/generated/synthetic-700 \
  --workspace bench-synthetic-700 \
  --conversations 35 \
  --questions-per-conversation 20
```

Long-context stress runs can add filler tokens per conversation. Treat these as
dedicated runs because corpus size, indexing time, latency, and judge cost grow
quickly:

```bash
python3 benchmarks/scripts/generate_memory_dataset.py \
  --name synthetic-1m-context \
  --out-dir benchmarks/generated/synthetic-1m-context \
  --workspace bench-synthetic-1m \
  --conversations 35 \
  --questions-per-conversation 20 \
  --filler-tokens 1000000
```

## Behavioral Memory Benchmark

The behavioral suite uses original deterministic fixtures modeled on the task taxonomy from GoodAI's LTM Benchmark.
It does not copy GoodAI datasets.
It tests delayed recall, updated facts, conflicting evidence, future reminders, trigger-response rules, spatial reasoning, and abstention at multiple memory spans.

Generate a small local run:

```bash
python3 benchmarks/scripts/generate_behavioral_memory_dataset.py \
  --out /tmp/optimal-behavioral \
  --cases-per-task 2 \
  --spans 100,1000

python3 benchmarks/scripts/seed_memory_corpus.py \
  --corpus /tmp/optimal-behavioral/corpus.jsonl \
  --out /tmp/optimal-behavioral/seeded.jsonl \
  --benchmark optimal-behavioral-memory-v2 \
  --promote-governed \
  --sleep-ms 700

python3 benchmarks/scripts/optimal_eval.py \
  --questions /tmp/optimal-behavioral/questions.jsonl \
  --engine-mode rag \
  --rag-context-package \
  --rag-skip-wiki \
  --retrieval-strategy reconstructive \
  --out /tmp/optimal-behavioral/unjudged.jsonl

python3 benchmarks/scripts/judge_results.py \
  --results /tmp/optimal-behavioral/unjudged.jsonl \
  --judge behavioral-exact \
  --out /tmp/optimal-behavioral/judged.jsonl
```

The deterministic judge requires current evidence, rejects forbidden stale evidence, and scores unsupported-answer abstention without using a judge model.
The seeder creates real Memory version chains, creates review-required Claims, promotes them into governed Facts and Memory Objects, and explicitly supersedes the prior Fact on updates.
It honors HTTP rate-limit retry instructions.
Use `--resume` after an interrupted recorded run.

The 2026-08-13 governed baseline found a useful tradeoff.
Tiered retrieval answered only 14.3% of the seven behavioral smoke cases, while reconstructive retrieval answered 100% at a 43 ms P95.
The 21-case scale run across 50, 500, and 5,000 filler-token spans reached 100% at a 31 ms P95 after fixing cue ranking, graph hydration order, and Context Package budget allocation.
These are deterministic local fixtures, not evidence that every real workload is solved.
