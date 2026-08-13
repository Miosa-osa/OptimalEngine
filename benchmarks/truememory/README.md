# TrueMemory-Compatible Benchmark Program

This harness makes an apples-to-apples comparison possible without calling the internal twelve-family release suite a TrueMemory result.

## Protocol lock

The manifest pins TrueMemory commit `e7f1fd79e4188637f9b168337c5a219af890a613`.
The verifier checks the answer model, judge model, temperatures, token limits, judge count, top-k, and upstream script hashes directly from that checkout.
The dataset adapter verifies known official source hashes for LoCoMo and both LongMemEval variants.

```bash
python3 benchmarks/scripts/truememory_compat.py sync --destination /tmp/truememory
python3 benchmarks/scripts/truememory_compat.py verify --upstream /tmp/truememory
```

## Prepare official datasets

Large or externally licensed datasets are not committed to this repository.
Pass official files to the adapters and keep the generated JSONL outside Git.

```bash
python3 benchmarks/scripts/truememory_compat.py prepare \
  --benchmark locomo \
  --source /tmp/truememory/benchmarks/locomo/data/locomo10.json \
  --out /tmp/optimal-truememory/locomo.jsonl

python3 benchmarks/scripts/truememory_compat.py prepare \
  --benchmark longmemeval_strict \
  --source /tmp/optimal-truememory/longmemeval_s.json \
  --out /tmp/optimal-truememory/longmemeval_strict.jsonl
```

The BEAM adapter accepts the official Hugging Face Parquet files or a JSON export with `conversation_id`, `chat`, and `probing_questions` fields.
Parquet input requires optional `pyarrow`.
Pass the BEAM-1M file directly and pass a directory containing both BEAM-10M shards.
The manifest verifies the official file and bundle hashes.

```bash
PYTHONPATH=/path/to/pyarrow python3 benchmarks/scripts/truememory_compat.py prepare \
  --benchmark beam_1m --source /data/1M-00000-of-00001.parquet \
  --out /tmp/optimal-truememory/beam_1m.jsonl

PYTHONPATH=/path/to/pyarrow python3 benchmarks/scripts/truememory_compat.py prepare \
  --benchmark beam_10m --source /data/beam-10m-shards \
  --out /tmp/optimal-truememory/beam_10m.jsonl
```

Run the strict-versus-oracle corpus diagnostic:

```bash
python3 benchmarks/scripts/truememory_diagnostics.py \
  --prepared /tmp/optimal-truememory/longmemeval_strict.jsonl \
  --oracle-prepared /tmp/optimal-truememory/longmemeval_oracle.jsonl \
  --out benchmarks/results/truememory/longmemeval_strict_oracle_diagnostics.json
```

## Run retrieval-only integration checks

The runner creates an isolated workspace per conversation and uses the canonical workspace ID returned by the Engine.
It stores LoCoMo evidence addresses as session-local tags and reports question-level and evidence-level recall plus retrieval latency.

```bash
python3 benchmarks/scripts/truememory_engine_run.py \
  --benchmark locomo \
  --prepared /tmp/optimal-truememory/locomo.jsonl \
  --run-id 1 \
  --out benchmarks/results/truememory/optimal_engine_locomo_retrieval_run1.json
```

`--message-limit` and `--question-limit` exist only for smoke testing.
Do not compare a limited run with a published benchmark score.

Run the dependency-free BM25 top-k ablation and validate LoCoMo oracle evidence addresses:

```bash
python3 benchmarks/scripts/truememory_diagnostics.py \
  --prepared /tmp/optimal-truememory/locomo.jsonl \
  --top-k 1 5 10 25 50 100 \
  --out benchmarks/results/truememory/locomo_bm25_diagnostics.json
```

The matched runner accepts `--retrieval engine_memory`, `--retrieval engine_semantic`, `--retrieval engine_coverage`, `--retrieval engine_evidence`, `--retrieval bm25`, or `--retrieval oracle`.
The default `engine_memory` strategy is the durable-memory FTS endpoint and serves as the lexical Engine baseline.
The `engine_semantic` strategy uses the Engine's hybrid search endpoint, where lexical and semantic durable-memory rankings are fused.
The `engine_coverage` strategy is an experimental deterministic query-expansion ablation and is not the default.
The `engine_evidence` strategy applies those bounded probes to semantic retrieval and reserves part of top-k for complementary results.
It is an ablation only and must beat the plain semantic baseline on the same complete dataset before it can become a production default.
`--top-k` supports diagnostic ablations, but paid official runs reject a value that differs from the pinned protocol.

Existing durable memories need their rebuildable semantic projection populated before measuring `engine_semantic`.

```bash
curl -X POST http://127.0.0.1:4200/api/memory/embeddings/rebuild \
  -H 'content-type: application/json' \
  -d '{"tenant":"default","workspace":"WORKSPACE_ID"}'
```

New and updated durable memories are indexed automatically when semantic indexing is enabled.
The projection is tenant and workspace scoped and can be rebuilt without changing canonical memory content.

## Run the matched answer and judge protocol

Paid evaluation is opt-in and fails closed when its credential or pinned upstream checkout is missing.
The runner loads the exact upstream prompt literals at runtime, uses GPT-4.1-mini for answers, GPT-4o-mini for judging, and takes three judge votes.
LongMemEval abstention cases use its upstream keyword protocol.

```bash
export OPENROUTER_API_KEY='...'

for run in 1 2 3; do
  python3 benchmarks/scripts/truememory_engine_run.py \
    --benchmark locomo \
    --prepared /tmp/optimal-truememory/locomo.jsonl \
    --upstream /tmp/truememory \
    --paid \
    --resume \
    --answer-input-cost CURRENT_USD_PER_MILLION \
    --answer-output-cost CURRENT_USD_PER_MILLION \
    --judge-input-cost CURRENT_USD_PER_MILLION \
    --judge-output-cost CURRENT_USD_PER_MILLION \
    --run-id "$run" \
    --out "benchmarks/results/truememory/optimal_engine_locomo_run${run}.json"
done

python3 benchmarks/scripts/truememory_compat.py aggregate \
  --runs benchmarks/results/truememory/optimal_engine_locomo_run*.json \
  --out benchmarks/results/truememory/optimal_engine_locomo_aggregate.json
```

## What the numbers mean

- Answer accuracy is the majority decision from three matched judge calls.
- Evidence recall is the fraction of gold evidence addresses present in retrieved context when the dataset supplies addresses.
- P50 and P95 show typical and slow retrieval latency.
- The Wilson interval shows uncertainty around measured accuracy.
- Standard deviation shows variation across the required three complete runs.
- Token totals come from provider response usage.
- Estimated cost is calculated only when explicit current per-million-token prices are supplied.
- Ingestion throughput and retrieval P50, P95, and P99 remain separate from model latency.
- `NOT RUN` means no result exists and is never converted into a zero or a pass.

Every completed question is checkpointed to the output file.
Use `--resume` to skip those question IDs after an interruption.
Aggregation rejects partial runs, duplicate question IDs, mixed datasets, mixed strategies, mixed protocols, and anything other than distinct complete runs 1, 2, and 3.

The Engine is eligible to claim TrueMemory-compatible results only after all official cases complete for three runs with the pinned protocol.
