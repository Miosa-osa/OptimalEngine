# Optimal Engine Governed Tiered Behavioral Smoke

## Results

| Metric | Value |
|---|---:|
| Questions | 7 |
| Correct | 1 |
| Partial | 0 |
| Incorrect | 6 |
| Unjudged | 0 |
| Accuracy | 14.3% |
| Correct-or-partial | 14.3% |
| Judge votes correct | 1 |
| Judge votes partial | 0 |
| Judge votes incorrect | 6 |
| Engine errors | 0 |
| Wiki hits | 0/7 |
| Avg candidates | 0.29 |
| Avg delivered | 0.29 |
| Avg latency | 9 ms |
| Median latency | 3 ms |
| P95 latency | 26 ms |
| P99 latency | 26 ms |
| Min latency | 3 ms |
| Max latency | 26 ms |

## Evaluation Config

| Parameter | Value |
|---|---|
| Dataset | 7 governed behavioral categories, 50-token span |
| Dataset size | 7 questions |
| Answer system | Governed tiered Context Package |
| Answer temperature | n/a |
| Judge | deterministic behavioral-exact |
| Judge voting | 1x majority |
| Retrieval top-k | 5 |
| Compute | local Apple Silicon |
| Result file | `benchmarks/results/behavioral_governed_tiered_2026-08-13.jsonl` |

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
| source:context_package | 7 |

## Per-Question

| ID | Category | Label | Vote split | Latency | Source | Candidates |
|---|---|---|---:|---:|---|---:|
| behavior-50-0000-delayed_recall | delayed_recall | incorrect | 0/0/1 | 26 ms | context_package | 0 |
| behavior-50-0000-knowledge_update | knowledge_update | incorrect | 0/0/1 | 3 ms | context_package | 0 |
| behavior-50-0000-conflict_resolution | conflict_resolution | incorrect | 0/0/1 | 3 ms | context_package | 0 |
| behavior-50-0000-prospective_memory | prospective_memory | incorrect | 0/0/1 | 3 ms | context_package | 0 |
| behavior-50-0000-trigger_response | trigger_response | correct | 1/0/0 | 22 ms | context_package | 2 |
| behavior-50-0000-spatial_reasoning | spatial_reasoning | incorrect | 0/0/1 | 4 ms | context_package | 0 |
| behavior-50-0000-abstention | abstention | incorrect | 0/0/1 | 3 ms | context_package | 0 |
