# Optimal Engine Benchmark Standard

## Objective

Optimal Engine is evaluated as a governed memory system, not only as a text search endpoint.

No single aggregate score may hide a security, correctness, or reliability failure.
Every release report keeps quality, safety, latency, throughput, resource use, and operational integrity as separate gates.

## External benchmark families

| Benchmark | What we adopt | Optimal Engine application |
| --- | --- | --- |
| BEIR | nDCG@10, Recall@k, heterogeneous retrieval tasks, lexical baseline | Retrieval Package ranking and zero-shot robustness |
| MTEB | Retrieval, reranking, clustering, and semantic similarity tasks | Embedding and reranker selection |
| RAGBench/TRACe | Context relevance, answer faithfulness, completeness, and citation quality | Context Package and answer evaluation |
| LongMemEval | Information extraction, multi-session reasoning, temporal reasoning, updates, and abstention | Governed long-term Memory Objects and reconstruction |
| LoCoMo | Long-range conversational QA, event summarization, temporal and causal understanding | Episode and conversation memory |
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

Thresholds must be revised from measured baselines and recorded hardware.
They must never be relaxed merely to turn a failing run green.

## Research sources

- BEIR: https://arxiv.org/abs/2104.08663
- MTEB: https://arxiv.org/abs/2210.07316
- RAGBench: https://arxiv.org/abs/2407.11005
- LongMemEval: https://arxiv.org/abs/2410.10813
- LoCoMo: https://arxiv.org/abs/2402.17753
- ANN-Benchmarks: https://arxiv.org/abs/1807.05614
