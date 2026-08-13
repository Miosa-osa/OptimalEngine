# Optimal Engine Release Benchmark

Generated: 2026-08-13T16:17:31.314661+00:00

Overall: **PASS** (12/12 suites)

| Suite | Status | Tests or cases | Qualification | Time | What it means |
| --- | --- | ---: | --- | ---: | --- |
| Governed Gold Set | PASS | 6 | public_contract | 1.552s | Reviewed-case schemas require current evidence, forbidden evidence, authorization, time, and abstention expectations, then run through persisted evaluation. |
| Entity and identity | PASS | 18 | executed_regression | 1.408s | Aliases, mentions, merges, and similarly named entities resolve without crossing scope. |
| Episodic memory | PASS | 18 | executed_regression | 1.305s | Meetings, transcripts, speakers, event order, and episode details survive intake and recall. |
| Graph and multi-hop reasoning | PASS | 17 | executed_regression | 1.354s | Relationship traversal remains scoped, bounded, and connected to canonical evidence. |
| Citation and evidence quality | PASS | 19 | executed_regression | 1.256s | Answers preserve valid source links and expose broken or unsupported citations. |
| End-to-end ingestion | PASS | 94 | executed_regression | 2.072s | Sources become governed claims, facts, memories, episodes, and searchable projections without scope loss. |
| Crash and recovery | PASS | 14 | executed_regression | 1.291s | Transactions, backups, retries, and rebuilds do not leave partial or corrupted canonical state. |
| Capacity and soak | PASS | 10000 | paced_smoke | 1.447s | Latency, throughput, and reliability remain measurable as request volume and concurrency increase. |
| Overload and rate limits | PASS | 17 | executed_regression | 2.048s | The Engine rejects excess traffic explicitly, isolates clients, and reports accepted latency honestly. |
| Adversarial mutation | PASS | 31 | deterministic_regression | 2.955s | Noisy variants are generated, while stale distractors and hostile authorization text execute against governed retrieval. |
| Workflow, skill, and asset governance | PASS | 18 | executed_regression | 1.464s | Only eligible workflows, approved skills, and authorized extracted assets enter context. |
| Continuous benchmark history | PASS | - | executed_regression | 0.053s | Every release can be compared with a prior baseline and regressions remain visible. |

## Qualification limits

- **Governed Gold Set:** Production qualification requires a private human-reviewed OptimalOS dataset.
- **Capacity and soak:** A dedicated large-corpus soak run remains required for production capacity certification.
- **Adversarial mutation:** The public suite uses deterministic mutations rather than an adaptive external attacker.

A passing score means every listed gate completed successfully on the recorded environment.
It does not make unmeasured workloads optimal.
Suite qualification levels and limitations are recorded in the JSON report.
