# Optimal Engine Governed Reconstructive Behavioral Smoke

## Results

| Metric | Value |
|---|---:|
| Questions | 7 |
| Correct | 7 |
| Partial | 0 |
| Incorrect | 0 |
| Unjudged | 0 |
| Accuracy | 100.0% |
| Correct-or-partial | 100.0% |
| Judge votes correct | 7 |
| Judge votes partial | 0 |
| Judge votes incorrect | 0 |
| Engine errors | 0 |
| Wiki hits | 0/7 |
| Avg candidates | 0.29 |
| Avg delivered | 2.86 |
| Avg latency | 13 ms |
| Median latency | 5 ms |
| P95 latency | 43 ms |
| P99 latency | 43 ms |
| Min latency | 5 ms |
| Max latency | 43 ms |

## Evaluation Config

| Parameter | Value |
|---|---|
| Dataset | 7 governed behavioral categories, 50-token span |
| Dataset size | 7 questions |
| Answer system | Governed reconstructive Context Package |
| Answer temperature | n/a |
| Judge | deterministic behavioral-exact |
| Judge voting | 1x majority |
| Retrieval top-k | 5 |
| Compute | local Apple Silicon |
| Result file | `benchmarks/results/behavioral_governed_reconstructive_2026-08-13.jsonl` |

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
| behavior-50-0000-delayed_recall | delayed_recall | correct | 1/0/0 | 43 ms | context_package | 0 |
| behavior-50-0000-knowledge_update | knowledge_update | correct | 1/0/0 | 5 ms | context_package | 0 |
| behavior-50-0000-conflict_resolution | conflict_resolution | correct | 1/0/0 | 7 ms | context_package | 0 |
| behavior-50-0000-prospective_memory | prospective_memory | correct | 1/0/0 | 21 ms | context_package | 0 |
| behavior-50-0000-trigger_response | trigger_response | correct | 1/0/0 | 5 ms | context_package | 2 |
| behavior-50-0000-spatial_reasoning | spatial_reasoning | correct | 1/0/0 | 5 ms | context_package | 0 |
| behavior-50-0000-abstention | abstention | correct | 1/0/0 | 5 ms | context_package | 0 |
