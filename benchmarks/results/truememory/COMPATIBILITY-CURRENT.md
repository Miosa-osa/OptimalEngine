# Current TrueMemory Compatibility Status

Generated and verified on 2026-08-13.

| Check | State | Evidence |
| --- | --- | --- |
| Upstream protocol pin | PASS | Commit `e7f1fd79e4188637f9b168337c5a219af890a613`; all five script constant checks passed. |
| LoCoMo adapter | PASS | Official source hash verified; 10 conversations, 5,882 messages, 1,540 scored questions; category 5 excluded. |
| LongMemEval strict adapter | PASS | Official source hash verified; 500 cases and 246,750 messages. |
| LongMemEval oracle adapter | PASS | Official source hash verified; 500 cases and 10,960 messages. |
| BEAM adapters | PARTIAL | Unit-verified conversion for chat sessions and probing-question categories; official large datasets not downloaded or verified. |
| Live Engine integration | PASS | One LoCoMo question retrieved its one gold evidence address; retrieval latency was 6.1 ms. |
| LoCoMo BM25 baseline | MEASURED | At top-100: 77.409% question recall and 61.346% evidence recall across 1,536 evidence-scored questions; P95 7.192 ms. |
| LoCoMo oracle-address audit | UPSTREAM GAPS | 2 of 2,362 normalized gold addresses do not exist in the corresponding official conversations; both are retained as explicit diagnostics. |
| LongMemEval strict/oracle corpus comparison | PASS | All 500 question IDs match; oracle reduces 246,750 messages to 10,960, a 95.558% reduction. |
| LoCoMo matched score | NOT RUN | Requires `OPENROUTER_API_KEY` and three full runs. |
| LongMemEval strict matched score | NOT RUN | Requires `OPENROUTER_API_KEY` and three full runs. |
| LongMemEval oracle matched score | NOT RUN | Requires `OPENROUTER_API_KEY` and three full runs. |
| BEAM-1M matched score | NOT RUN | Requires official dataset, `OPENROUTER_API_KEY`, and three full runs. |
| BEAM-10M matched score | NOT RUN | Requires official dataset, `OPENROUTER_API_KEY`, and three full runs. |

The 1/1 smoke result proves that dataset preparation, workspace creation, ingestion, retrieval, and evidence accounting connect end to end.
It is not statistically meaningful and is not an Optimal Engine quality score.

The internal 12/12 release score is also not a TrueMemory score.

See `locomo_bm25_diagnostics.json` for top-k 1/5/10/25/50/100 results and `longmemeval_strict_oracle_diagnostics.json` for the paired corpus analysis.
