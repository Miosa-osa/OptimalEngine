# Optimal Engine Governed Behavioral Scale Baseline

## Results

| Metric | Value |
|---|---:|
| Questions | 21 |
| Correct | 21 |
| Partial | 0 |
| Incorrect | 0 |
| Unjudged | 0 |
| Accuracy | 100.0% |
| Correct-or-partial | 100.0% |
| Judge votes correct | 21 |
| Judge votes partial | 0 |
| Judge votes incorrect | 0 |
| Engine errors | 0 |
| Wiki hits | 0/21 |
| Avg candidates | 0.29 |
| Avg delivered | 1.24 |
| Avg latency | 17 ms |
| Median latency | 14 ms |
| P95 latency | 31 ms |
| P99 latency | 47 ms |
| Min latency | 5 ms |
| Max latency | 47 ms |

## Evaluation Config

| Parameter | Value |
|---|---|
| Dataset | 21 questions across 50, 500, and 5,000 filler-token spans |
| Dataset size | 21 questions |
| Answer system | Governed reconstructive Context Package |
| Answer temperature | n/a |
| Judge | behavioral-exact |
| Judge voting | 1x majority |
| Retrieval top-k | 5 |
| Compute | local Apple Silicon |
| Result file | `benchmarks/results/behavioral_governed_scale_2026-08-13.jsonl` |

## Breakdown

| Group | Count |
|---|---:|
| category:abstention | 3 |
| category:conflict_resolution | 3 |
| category:delayed_recall | 3 |
| category:knowledge_update | 3 |
| category:prospective_memory | 3 |
| category:spatial_reasoning | 3 |
| category:trigger_response | 3 |
| source:context_package | 21 |

## Per-Question

| ID | Category | Label | Vote split | Latency | Source | Candidates |
|---|---|---|---:|---:|---|---:|
| behavior-50-0000-delayed_recall | delayed_recall | correct | 1/0/0 | 47 ms | context_package | 0 |
| behavior-50-0000-knowledge_update | knowledge_update | correct | 1/0/0 | 6 ms | context_package | 0 |
| behavior-50-0000-conflict_resolution | conflict_resolution | correct | 1/0/0 | 5 ms | context_package | 0 |
| behavior-50-0000-prospective_memory | prospective_memory | correct | 1/0/0 | 5 ms | context_package | 0 |
| behavior-50-0000-trigger_response | trigger_response | correct | 1/0/0 | 9 ms | context_package | 2 |
| behavior-50-0000-spatial_reasoning | spatial_reasoning | correct | 1/0/0 | 8 ms | context_package | 0 |
| behavior-50-0000-abstention | abstention | correct | 1/0/0 | 8 ms | context_package | 0 |
| behavior-500-0000-delayed_recall | delayed_recall | correct | 1/0/0 | 14 ms | context_package | 0 |
| behavior-500-0000-knowledge_update | knowledge_update | correct | 1/0/0 | 18 ms | context_package | 0 |
| behavior-500-0000-conflict_resolution | conflict_resolution | correct | 1/0/0 | 15 ms | context_package | 0 |
| behavior-500-0000-prospective_memory | prospective_memory | correct | 1/0/0 | 11 ms | context_package | 0 |
| behavior-500-0000-trigger_response | trigger_response | correct | 1/0/0 | 11 ms | context_package | 2 |
| behavior-500-0000-spatial_reasoning | spatial_reasoning | correct | 1/0/0 | 13 ms | context_package | 0 |
| behavior-500-0000-abstention | abstention | correct | 1/0/0 | 13 ms | context_package | 0 |
| behavior-5000-0000-delayed_recall | delayed_recall | correct | 1/0/0 | 27 ms | context_package | 0 |
| behavior-5000-0000-knowledge_update | knowledge_update | correct | 1/0/0 | 24 ms | context_package | 0 |
| behavior-5000-0000-conflict_resolution | conflict_resolution | correct | 1/0/0 | 24 ms | context_package | 0 |
| behavior-5000-0000-prospective_memory | prospective_memory | correct | 1/0/0 | 23 ms | context_package | 0 |
| behavior-5000-0000-trigger_response | trigger_response | correct | 1/0/0 | 31 ms | context_package | 2 |
| behavior-5000-0000-spatial_reasoning | spatial_reasoning | correct | 1/0/0 | 15 ms | context_package | 0 |
| behavior-5000-0000-abstention | abstention | correct | 1/0/0 | 21 ms | context_package | 0 |
