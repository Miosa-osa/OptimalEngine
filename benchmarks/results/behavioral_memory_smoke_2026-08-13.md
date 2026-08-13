# Optimal Engine Behavioral Memory Smoke

## Results

| Metric | Value |
|---|---:|
| Questions | 7 |
| Correct | 4 |
| Partial | 0 |
| Incorrect | 3 |
| Unjudged | 0 |
| Accuracy | 57.1% |
| Correct-or-partial | 57.1% |
| Judge votes correct | 4 |
| Judge votes partial | 0 |
| Judge votes incorrect | 3 |
| Engine errors | 0 |
| Wiki hits | 0/7 |
| Avg candidates | 3.29 |
| Avg delivered | 3.29 |
| Avg latency | 5 ms |
| Median latency | 3 ms |
| P95 latency | 17 ms |
| P99 latency | 17 ms |
| Min latency | 1 ms |
| Max latency | 17 ms |

## Evaluation Config

| Parameter | Value |
|---|---|
| Dataset | 7 behavioral categories, 50-token span |
| Dataset size | 7 questions |
| Answer system | Optimal Engine /api/memory natural-language FTS |
| Answer temperature | n/a |
| Judge | deterministic behavioral-exact |
| Judge voting | 1x majority |
| Retrieval top-k | 5 |
| Compute | local Apple Silicon |
| Result file | `benchmarks/results/behavioral_memory_smoke_2026-08-13.jsonl` |

## Breakdown

| Group | Count |
|---|---:|
| category:abstention | 1 |
| category:conflict_resolution | 1 |
| category:delayed_recall | 1 |
| category:knowledge_update | 1 |
| category:prospective_memory | 1 |
| category:spatial_reasoning | 1 |
| category:trigger_response | 1 |
| source:memory | 7 |

## Per-Question

| ID | Category | Label | Vote split | Latency | Source | Candidates |
|---|---|---|---:|---:|---|---:|
| behavior-50-0000-delayed_recall | delayed_recall | correct | 1/0/0 | 17 ms | memory | 5 |
| behavior-50-0000-knowledge_update | knowledge_update | incorrect | 0/0/1 | 5 ms | memory | 5 |
| behavior-50-0000-conflict_resolution | conflict_resolution | incorrect | 0/0/1 | 5 ms | memory | 5 |
| behavior-50-0000-prospective_memory | prospective_memory | correct | 1/0/0 | 2 ms | memory | 1 |
| behavior-50-0000-trigger_response | trigger_response | correct | 1/0/0 | 1 ms | memory | 1 |
| behavior-50-0000-spatial_reasoning | spatial_reasoning | correct | 1/0/0 | 2 ms | memory | 1 |
| behavior-50-0000-abstention | abstention | incorrect | 0/0/1 | 3 ms | memory | 5 |
