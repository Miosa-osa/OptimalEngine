# Current TrueMemory Compatibility Status

Generated and verified on 2026-08-13.

| Check | State | Evidence |
| --- | --- | --- |
| Upstream protocol pin | PASS | Commit `e7f1fd79e4188637f9b168337c5a219af890a613`; all five script constant checks passed. |
| LoCoMo adapter | PASS | Official source hash verified; 10 conversations, 5,882 messages, 1,540 scored questions; category 5 excluded. |
| LongMemEval strict adapter | PASS | Official source hash verified; 500 cases and 246,750 messages. |
| LongMemEval oracle adapter | PASS | Official source hash verified; 500 cases and 10,960 messages. |
| BEAM-1M adapter | PASS | Official Parquet hash verified; 35 conversations, 74,630 messages, and 700 questions. |
| BEAM-10M adapter | PASS | Both official Parquet hashes and the bundle hash verified; 10 conversations, 208,696 messages, and 200 questions. |
| Live Engine integration | PASS | One LoCoMo question retrieved its one gold evidence address; retrieval latency was 6.1 ms. |
| LoCoMo BM25 baseline | MEASURED | At top-100: 77.409% question recall and 61.346% evidence recall across 1,536 evidence-scored questions; P95 7.192 ms. |
| LoCoMo oracle-address audit | UPSTREAM GAPS | 2 of 2,362 normalized gold addresses do not exist in the corresponding official conversations; both are retained as explicit diagnostics. |
| LongMemEval strict/oracle corpus comparison | PASS | All 500 question IDs match; oracle reduces 246,750 messages to 10,960, a 95.558% reduction. |
| LoCoMo lexical Engine run 1 | MEASURED | 1,540/1,540 cases: 87.857% answer accuracy, 83.984% question evidence recall, 70.703% evidence-address recall, 472 ms P50 and 572 ms P95 retrieval, estimated model cost $3.96. Two more matched runs remain required for an aggregate claim. |
| LoCoMo semantic retrieval run 1 | MEASURED | 1,540/1,540 retrieval cases: 93.750% question evidence recall and 84.081% evidence-address recall, with 407 ms P50 and 597 ms P95 retrieval. Answer judging has not yet been run for this strategy. |
| LoCoMo Candidate Portfolio run 3 | MEASURED | 1,540/1,540 retrieval cases: 96.094% question evidence recall and 87.130% evidence-address recall, with 453 ms P50 and 666 ms P95 retrieval. This adds 22 covered questions and 28 evidence addresses over routed retrieval. Temporal evidence recall regressed 0.8 points, and answer judging remains unrun. |
| LongMemEval strict matched score | NOT RUN | Requires `OPENROUTER_API_KEY` and three full runs. |
| LongMemEval oracle matched score | NOT RUN | Requires `OPENROUTER_API_KEY` and three full runs. |
| BEAM-1M matched score | NOT RUN | Requires official dataset, `OPENROUTER_API_KEY`, and three full runs. |
| BEAM-10M matched score | NOT RUN | Requires official dataset, `OPENROUTER_API_KEY`, and three full runs. |

The 1/1 smoke result proves that dataset preparation, workspace creation, ingestion, retrieval, and evidence accounting connect end to end.
It is not statistically meaningful and is not an Optimal Engine quality score.

The internal 12/12 release score is also not a TrueMemory score.

See `locomo_bm25_diagnostics.json` for top-k 1/5/10/25/50/100 results and `longmemeval_strict_oracle_diagnostics.json` for the paired corpus analysis.
The complete case-level LoCoMo results include `optimal_engine_locomo_candidate_portfolio_retrieval_run3.json`.
