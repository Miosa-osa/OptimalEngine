# Optimal Engine Benchmark Standard

## Objective

Optimal Engine is evaluated as a governed memory system, not only as a text search endpoint.

No single aggregate score may hide a security, correctness, or reliability failure.
Every release report keeps quality, safety, latency, throughput, resource use, and operational integrity as separate gates.

## Twelve-family release benchmark

Run every implemented family with one command:

```bash
python3 benchmarks/scripts/release_benchmark.py
```

The command writes a machine-readable JSON report, a plain-English Markdown scorecard, and an append-only history row containing the commit and dataset hashes.

| Family | Primary proof |
| --- | --- |
| Governed Gold Set | Versioned reviewed-case contract plus persisted Evaluation execution |
| Entity and identity | Alias, mention, merge, and Workspace isolation regressions |
| Episodic memory | Episode and ordered-detail persistence and transcript intake |
| Graph reasoning | Scoped predicates, traversal, and reconstructive paths |
| Citation quality | Citation integrity, delivery, grounding, and evidence checks |
| End-to-end ingestion | Source through governed truth lifecycle and scoped projections |
| Crash and recovery | Transaction rollback, backups, and FTS rebuild integrity |
| Capacity and soak | Isolated 10,000-record storage run plus paced endpoint artifact |
| Overload and limits | Rate-limit capacity, client override, and rejection semantics |
| Adversarial mutation | Deterministic noisy cases plus stale, unauthorized, and injection regressions |
| Workflow, skill, and asset | Promotion eligibility, extraction, and governed storage |
| Benchmark history | Append-only results and pass-to-fail regression detection |

Qualification is explicit.
`executed_regression` means the behavior ran against an isolated test database.
`public_contract` means the public fixture proves the schema and execution machinery but still needs a private reviewed dataset.
`paced_smoke` means the measured workload is useful for regression detection but is not a large production capacity certification.

The 2026-08-13 isolated storage baseline inserted 100,000 indexed records at 25,507 records per second.
Random scoped lookup P95 was 0.061 ms and the temporary table increased the SQLite file by 8,986,624 bytes before cleanup.
This measures the local storage substrate, not full governed ingestion throughput.

## External benchmark families

The implemented TrueMemory-compatible program is documented in [`benchmarks/truememory/README.md`](../../benchmarks/truememory/README.md).
It pins the upstream repository, validates model and judge settings from the upstream Python AST, checks official dataset hashes, and keeps external scores separate from internal release gates.
The exact upstream prompts are loaded from a pinned checkout at runtime so AGPL-licensed prompt text is not copied into this MIT repository.

| Benchmark | What we adopt | Optimal Engine application |
| --- | --- | --- |
| BEIR | nDCG@10, Recall@k, heterogeneous retrieval tasks, lexical baseline | Retrieval Package ranking and zero-shot robustness |
| MTEB | Retrieval, reranking, clustering, and semantic similarity tasks | Embedding and reranker selection |
| RAGBench/TRACe | Context relevance, answer faithfulness, completeness, and citation quality | Context Package and answer evaluation |
| LongMemEval | Information extraction, multi-session reasoning, temporal reasoning, updates, and abstention | Governed long-term Memory Objects and reconstruction |
| LoCoMo | Long-range conversational QA, event summarization, temporal and causal understanding | Episode and conversation memory |
| GoodAI LTM Benchmark | Delayed recall, prospective memory, trigger-response, updates, conflicts, and increasing memory span | Behavioral Memory Objects and reconstructive recall |
| ANN-Benchmarks | Recall-versus-queries-per-second tradeoff | Vector Adapter and filtered retrieval |

External datasets remain in their original formats and licenses.
Dataset adapters should convert them into versioned Optimal Engine cases rather than copying large datasets into this repository.

## Scorecards

### Retrieval quality

- Recall@1, Recall@5, Recall@10
- Precision@k
- Mean reciprocal rank
- nDCG@10
- Zero-result rate
- Cross-workspace false-positive rate

### Answer and reconstruction quality

- Exact or deterministic task accuracy
- Citation precision and citation recall
- Completeness
- Faithfulness to returned evidence
- Temporal correctness
- Supersession correctness
- Multi-session reasoning accuracy
- Abstention precision and recall
- Association-path efficiency

### Security and governance

- Tenant leakage rate must equal zero
- Workspace leakage rate must equal zero
- Security-label leakage rate must equal zero
- Partition leakage rate must equal zero
- Expired or superseded evidence leakage rate must equal zero
- Unauthorized crowd-out tests must pass

### Performance and reliability

- Warm and cold latency reported separately
- P50, P95, P99, and maximum latency
- Requests per second at declared concurrency
- Error and timeout rates
- Response bytes and token use
- Index build or projection rebuild time
- Database growth per 1,000 ingested records
- Peak memory, CPU, and database write amplification for dedicated stress runs

## Datasets

The repository already contains deterministic 500-question and 700-question synthetic institutional-memory datasets.
They test decision, owner, reason, numeric, and open-question recall.

`generate_behavioral_memory_dataset.py` adds original, deterministic GoodAI-shaped behavioral cases without redistributing GoodAI data.
Version 2 creates real updates instead of storing contradictory rows as unrelated memories.
The governed seeder promotes review-required Claims and explicitly supersedes the prior accepted Fact.

The 2026-08-13 progression exposed and then fixed several real defects:

1. Raw Memory search improved from 28.6% to 57.1% after natural-language FTS normalization.
2. Correct lifecycle seeding raised raw Memory search to 100% on the seven-case smoke set.
3. Governed tiered retrieval scored 14.3%, showing that fast lexical retrieval alone was not enough for this workload.
4. Governed reconstructive retrieval scored 100% on the same smoke set at a 43 ms P95.
5. The first 21-case multi-span run scored 57.1% because oversized evidence was dropped.
6. Evidence clipping raised it to 85.7%, but reconstruction could still consume the whole Context Package budget.
7. Reserving budget for canonical Facts raised it to 90.5%, but graph hydration reversed relevance order.
8. Preserving traversal rank and prioritizing distinctive cues produced 100% across 50, 500, and 5,000 filler-token spans at a 31 ms P95.

This progression matters more than the final perfect number.
It proves the benchmark can locate architectural failures and verify their fixes.
The dataset remains small and deterministic, so it is a regression gate rather than a universal claim of optimality.

Add four versioned dataset adapters next:

1. LongMemEval-S for extraction, temporal updates, multi-session reasoning, and abstention.
2. LoCoMo QA for long-range episodic and causal memory.
3. A BEIR subset for lexical, vector, hybrid, and reranked retrieval comparison.
4. An OptimalOS Gold dataset containing reviewed Facts, expected object links, forbidden links, effective dates, and authorization envelopes.

The OptimalOS Gold dataset is the release gate because public corpora cannot represent Roberto's actual domain, policies, or Workspace topology.

## Commands

Run deterministic answer quality:

```bash
python3 benchmarks/scripts/optimal_eval.py \
  --questions benchmarks/generated/synthetic-500/questions.jsonl \
  --workspace bench-synthetic-500 \
  --judge none \
  --out benchmarks/results/run.jsonl

python3 benchmarks/scripts/judge_results.py \
  --results benchmarks/results/run.jsonl \
  --judge synthetic-exact \
  --out benchmarks/results/run-judged.jsonl
```

Run endpoint speed and reliability:

```bash
python3 benchmarks/scripts/system_benchmark.py \
  --profile smoke \
  --workspace default:miosa \
  --out benchmarks/results/system-smoke.json
```

The system harness reports attempted requests per second and successful requests per second separately.
Latency percentiles include successful requests only, so fast 429 rejections cannot make an overloaded endpoint look healthy.
Use `--request-rate` for paced sustained load and omit it for saturation testing.

Measure cold-first-request behavior separately:

```bash
python3 benchmarks/scripts/system_benchmark.py \
  --profile smoke \
  --warmup 0 \
  --workspace default:miosa \
  --out benchmarks/results/system-cold-smoke.json
```

Run authorization and governance regressions in an isolated test database:

```bash
python3 benchmarks/scripts/security_benchmark.py \
  --out benchmarks/results/security-regression.json
```

The security benchmark fails closed if the test process crashes or its ExUnit summary cannot be parsed.
It covers tenant, workspace, label, partition, crowd-out, temporal, supersession, and reconstructive-expansion boundaries.

Use `interactive` for release qualification and `soak` for dedicated stability runs.
Do not run the soak profile casually against a shared live Engine.

## Release gates

The initial release gates are deliberately strict on safety and provisional on latency:

- All security leakage rates: 0
- Full test failures: 0
- Benchmark error rate: at most 0.1% for interactive runs
- Governed gold evaluation pass rate: at least 90%
- Citation precision: at least 95%
- Temporal and supersession accuracy: at least 95%
- Abstention F1: at least 90%
- Search P95: at most 300 ms at concurrency 10
- RAG P95: at most 1,800 ms at concurrency 10
- Assemble and reconstruct P95: at most 2,200 ms at concurrency 10

The release report must show both governed retrieval strategies.
Tiered retrieval is the low-latency path.
Reconstructive retrieval is the deeper association path.
A speed win cannot compensate for a behavioral-quality failure, and a quality win cannot compensate for leakage.

Thresholds must be revised from measured baselines and recorded hardware.
They must never be relaxed merely to turn a failing run green.

## Research sources

- BEIR: https://arxiv.org/abs/2104.08663
- MTEB: https://arxiv.org/abs/2210.07316
- RAGBench: https://arxiv.org/abs/2407.11005
- LongMemEval: https://arxiv.org/abs/2410.10813
- LoCoMo: https://arxiv.org/abs/2402.17753
- ANN-Benchmarks: https://arxiv.org/abs/1807.05614
- GoodAI LTM Benchmark: https://github.com/GoodAI/goodai-ltm-benchmark
- GoodAI dynamic conversational benchmark paper: https://openreview.net/forum?id=twFlD3C9Rt
