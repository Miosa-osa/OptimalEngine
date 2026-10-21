# Optimal Engine Notes

- 2026-07-08: The repo-native `bin/optimal` wrapper is the standard agent-facing command surface for this checkout.
- 2026-07-08: Direct `mix optimal.*` is appropriate for engine development, but product/agent memory operations should use `bin/optimal` when available.
- 2026-07-08: SQLite is the durable local runtime store today.
- 2026-07-08: RocksDB is the default persistent local knowledge graph backend when the NIF is installed.
- 2026-07-08: ETS and Mnesia are fallback or alternate graph backends, not the default source of truth.
- 2026-07-08: BusinessOS must store app state in BusinessOS and knowledge/memory in Optimal Engine.
- 2026-07-08: Every integration must preserve tenant, organization, workspace, Node, and policy scope.
- 2026-07-08: Public defaults must be repo-relative or environment-driven.
- 2026-07-08: Private machine paths, connector keys, runtime stores, and user data do not belong in public commits.
- 2026-07-09: `CLAUDE.md`, `BOOT.md`, `OPTIONS.md`, and `SYSTEM.md` are public entry docs for agents and users.
- 2026-07-09: Claude users should get the same `bin/optimal boot/find/capture/aware/close` memory loop from repo docs without relying on a private checkout.
- 2026-07-09: Explicit `optimal.remember` CLI writes must use governed Memory Core intake, not only the older insight observation loop.
- 2026-07-09: CLI retrieval commands must pass workspace scope through to the retrieval layer so local source-checkout behavior matches API behavior.
- 2026-07-09: Blank embedding input is rejected before Ollama, absent optional routing YAML loads empty defaults without warning, and exhaustive connector/context assembly call sites no longer retain impossible error branches.
- 2026-07-09: Release runtime configuration must re-read database, cache, workspace, topology, RocksDB, and Ollama environment values because config.exs is evaluated when the release is built, not when a downloaded app starts it.
- 2026-07-09: Runtime environment overrides must preserve values already selected by environment-specific config when an override is absent, especially isolated test storage.
- 2026-07-20: Every workspace starts with an explicit `desktop_local` storage policy, and optional providers require configuration plus a successful health probe before they are reported as available.
- 2026-07-20: BusinessOS modules use scoped APIs and logical store contracts instead of physical databases, so local, self-hosted, cloud, and Fractal enterprise providers can change without creating a second product data model.
- 2026-07-20: Fractal Computing is an enterprise partner substrate for governed AI against a synchronized digital twin and is never a default local dependency or an unreviewed write path.
- 2026-08-13: Natural-language memory queries must normalize stop words and use ranked discriminating-term matches because raw FTS5 whitespace semantics require every token and silently miss otherwise valid memories.
- 2026-08-13: Unanchored Claims cannot participate in global conflict matching because missing subject, action, and object anchors otherwise make every accepted Fact appear contradictory.
- 2026-08-13: Updating a versioned Memory must create a new review-required Claim, and promotion must explicitly supersede the prior accepted Fact.
- 2026-08-13: Reconstructive recall must preserve traversal rank, prioritize distinctive cues, and reserve Context Package budget for canonical Facts so graph expansion cannot crowd correct evidence out.
- 2026-08-13: Behavioral benchmark seeding must honor API rate limits and support recorded-run resume because governed promotion creates several writes per case.
- 2026-08-13: Release benchmark reports must distinguish executed regressions, public data contracts, paced smoke measurements, and production qualification so a green harness cannot overstate coverage.
- 2026-08-13: Every benchmark history row carries the Engine commit and dataset SHA-256 hashes, and pass-to-fail changes are first-class regressions.
- 2026-08-13: Semantic embedding hashes must cover the exact searchable representation, including contextual metadata and task prefixes, rather than canonical Memory content alone.
- 2026-08-13: Benchmark evidence addresses and gold labels are evaluation metadata, not retrieval features, and contextual retrieval projections must exclude them.
- 2026-08-13: Named Memory embedding projections require `(memory_id, model)` identity; keying only by Memory silently replaces earlier projections and makes ensemble results invalid.
- 2026-08-13: LoCoMo multimodal preparation preserves source captions but excludes generated image queries, URLs, evidence addresses, answers, and gold labels from Retrieval Documents.
- 2026-08-13: Compatible semantic projections use max-similarity fusion because rank-agreement fusion suppresses unique modality evidence by rewarding redundant hits.
- 2026-08-13: Semantic profile routing is deterministic from the Evidence Plan intent; inference uses contextual Retrieval Documents while other intents retain text-plus-multimodal fusion.

- 2026-09-08: Agent authority now has an explicit registry and adversarial structural validator.
Historical architecture reports remain evidence and cannot own current concepts.
Cross-repo execution compatibility and governed API authorization require runtime tests, not documentation assertions alone.

- 2026-09-08: Current setup docs now separate read-only live health/storage audit from fixture-writing reality checks, with a single disposable verification recipe.
- 2026-09-08: The authority index classifies historical evidence explicitly; directory membership and index links do not independently grant normative authority.
- 2026-09-08: Canopy checkout preflight validates the source/task contract and does not attest a separately running Engine HTTP process or sandbox trusted local execution.
- 2026-09-08: Reproduced and fixed the advertised OPTIMAL_AUTH_REQUIRED flag being ignored at runtime; literal true/false now override the configured auth setting, absence preserves it, and invalid values fail configuration.
- 2026-09-08: Report fixtures A-G have distinct structural, runtime, and administrative evidence; natural-language contradictions, historical retrieval poisoning, and universal independent red-team closure are not established by the structural validator.
- 2026-09-08: The wrapper health probe now forwards bearer credentials and refuses local-store fallback after a reachable HTTP failure; black-box tests cover authentication failures, denied writes, and intentional unconfigured default-local no-response fallback without using a real database.
- 2026-09-08: CODEOWNERS now covers Markdown at every directory depth, including deployment guidance, so newly registered nested documents retain independent owner-review coverage.
- 2026-09-08: Candidate-owned permissive validators and all-success tests reproduced a false green; the trusted harness now runs prior validator/test expectations and preserves exact hashed positive/negative evidence with additive supersession.
- 2026-09-08: Initial ledger installation remains explicitly pending independent bootstrap review; existing base validator/tests still execute, while subsequent installed-baseline runs reject missing or rewritten evidence.

- 2026-09-08: Real fresh-agent missing-authority reviews correctly stopped with validator exit 1, but the initial evaluator rejected Codex's terminal `status=failed` event.
The exact event and causal lesson are retained under scripts/fixtures/fresh-agent, and a regression now verifies expected nonzero tool execution without changing the required permission or authority decisions.
- 2026-10-20: Graph edges moved to `graph_edges` (a new migration), unique per tenant and workspace; the baseline `edges` table kept one edge per endpoint pair and relation across all workspaces and never wrote `tenant_id`.
SQLite cannot widen a UNIQUE constraint in place and migrations must stay additive, so `edges` stays in the store unread for one release (`Store.Migrations.superseded_tables/0`); bundles and replicated changes that still name it are written to `graph_edges`.
An edge's tenant is its workspace's tenant, derived in the insert itself as `Store.insert_context` does for contexts; reads take the requester's tenant (API routes) or the workspace's own (`Graph.scope/1`).
- 2026-10-20: Rows written under a bare unregistered workspace id take tenant `default` (contexts and graph edges), so another tenant writing there lands in the default tenant's rows.
A 404 for other tenants' keys on bare ids was tried in #65 and dropped: the steward, entity, relationship and graph routes (#79, #92, #97, #99) let tenants share a bare id and filter each row by tenant, so the fix belongs at the writers.
- 2026-10-21: The upgrade's graph backfill state is a row per completed run in `graph_backfills` (engine state, never replicated), read per workspace by `Graph.backfill_status/1` and `GET /api/maintenance/graph`, because migration numbers float until merge and an automation cannot key on "after migration N".
A full run records a row with no workspace; a workspace run records that workspace.
`OptimalEngine.Release.graph_backfill/1` is the entry point on a release build, which has no mix.
An unregistered `<tenant>:<slug>` id now gives its contexts and edges the tenant its prefix names, when that tenant exists, instead of `default`.
- 2026-10-20: Intake classification costs about 100 ms for a 24 KB page and `Intake.process/2` runs one call at a time, so a bulk importer classifies ahead in parallel with `Intake.classify/2` and `Intake.known_entities/0` and passes `:classified`; the Notion importer measured 104.5 MB of Markdown and CSV (5,400 contexts) searchable in 280 s on an 8-core gate this way, against 695 s classifying inside intake.
- 2026-10-20: The PostgreSQL store derives its schema from the SQLite migrations (run in memory and read back through SQLite's catalog), so the migrations stay the only schema definition and a type or default the derivation cannot map fails a test.
- 2026-10-20: The PostgreSQL store runs every connection at SERIALIZABLE and re-runs a transaction fun on a serialization failure instead of per-call-site row locks, because eight of the 51 transaction call sites check for an absent row before inserting and a row lock cannot protect a row that does not exist.
- 2026-10-20: PostgreSQL text columns use the C collation so ordering and comparison match SQLite's BINARY collation regardless of the database locale.
- 2026-10-20: PostgreSQL store indexes and constraints are named with a hash of their definition, the sync drops checks, foreign keys and unique indexes the plan does not have, and then compares the live catalog with the plan; a name kept across a changed definition would otherwise hide schema drift.
- 2026-10-20: A migration above the PostgreSQL baseline that moves or changes data needs a declared step in Store.Postgres.Steps, and seed rows reach a PostgreSQL database only when it is created. Until the first PostgreSQL store is deployed the baseline is the newest migration, so other PRs' migrations need nothing; the release that deploys one sets @frozen_baseline.
- 2026-10-20: PostgreSQL store statements inside a transaction run without a savepoint unless the caller passes recoverable: true, because more than 64 subtransactions per transaction overflow the per-backend cache and slow every snapshot on the server.
