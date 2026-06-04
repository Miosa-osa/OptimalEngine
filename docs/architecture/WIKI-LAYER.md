# Workspace Wiki / Export Layer

This document is being migrated from the older "LLM-maintained wiki" concept
to the current Optimal Engine architecture.

Current rule:

```text
The wiki/export surface is a human-operable projection.
The governed runtime owns canonical topology, source evidence, memory, policy,
workflow, tool state, and audit.
```

The wiki is still critical. It is where humans and agents can browse, edit,
link, and understand the workspace. But it must not become a separate source of
truth that bypasses Source Packages, Claims, Facts, Memory Objects, permissions,
or export records.

> A self-maintaining, citation-rich, incrementally-compacted top layer that
> sits over immutable raw sources and makes context a first-class artifact of
> the Optimal Engine — not a byproduct of retrieval.

## Updated Thesis

The wiki/export layer has two jobs:

```text
1. Make the workspace usable by humans.
2. Prove that every page is a projection of governed engine state or a new
   source/change request waiting to be processed.
```

It should provide the product mechanics users expect from a serious wiki:

```text
page tree
Markdown files
HTML pages
backlinks
broken-link status
revision history
safe editing / edit locks
rename and move link repair
import from existing Markdown folders
export records
projection freshness checks
```

It should not decide what is true. Truth promotion belongs to Memory Core:

```text
Source Package -> Claim -> Fact -> Memory Object
```

Human edits to wiki/markdown pages are handled as one of:

```text
new Source Package
topology change request
projection-only edit rejected or overwritten by next render
```

## Corrected Three-Tier Meaning

The older three-tier model is still useful if interpreted correctly:

```text
Tier 1: Source Packages and preserved raw artifacts
Tier 2: Rebuildable indexes, chunks, summaries, embeddings, graph projections
Tier 3: Human-facing wiki/export projections
```

The hard invariant is now:

```text
The wiki/export layer can be edited, but edits re-enter the engine through a
governed lifecycle. The wiki does not silently mutate canonical truth.
```

## Export Lifecycle

Every generated page should have an export record:

```text
export_record_id
workspace_id
node_id
output_path
output_kind
input_object_links
input_object_versions
source_hashes
rendered_at
rendered_by
policy_version
link_health_status
projection_freshness_status
rebuild_command
audit_event_id
```

The lifecycle is:

```text
engine object version
  -> render markdown / HTML / app view
  -> record export
  -> check page tree
  -> check links and backlinks
  -> detect broken links
  -> detect projection drift
  -> serve or expose page
  -> capture human edit/import
  -> Source Package or topology change request
  -> review/promote
  -> refresh projection
```

## Interface Health Gates

The layer is not complete until these pass:

```text
Node tree renders from Workspace -> Nodes.
Backlinks are computed from topology relationships and memory Relationship Edges.
Broken links are detected.
Renames and moves update links or create repair work.
Concurrent edits do not silently overwrite newer state.
Revision history exists for user-facing pages.
Imports preserve folder structure and source lineage.
Generated HTML/markdown can prove which object versions produced it.
Stale projections are detected before agents rely on them.
```

Useful commands to build toward:

```text
mix optimal.export.check
mix optimal.links.check
mix optimal.import.markdown
mix optimal.projection.diff
mix optimal.workspace.serve
```

## The thesis

Classical RAG re-discovers the same facts on every query. It's lossy (the
retriever only sees what matches a similarity score) and amnesic (what the LLM
figured out last time has to be rediscovered this time).

The Wiki Layer flips this. Every time new information arrives, a curation step
**integrates it into a persistent, structured, LLM-maintained wiki**. Agents
read the wiki FIRST. The wiki is a map; it carries "hot citations" — explicit
URIs — back to the immutable sources whenever the agent needs to zoom in.

Retrieval still exists, but it's scoped to what the wiki couldn't already
answer.

## The three tiers

```
┌──────────────────────────────────────────────────────────────┐
│  TIER 3 — THE WIKI (LLM-maintained, read-first)              │
│  Top-level, curated, cross-referenced, always-loaded.        │
│  Every fact carries a citation URI back to Tier 1.           │
│  Can contain executable directives (see below).              │
└──────────────────────────────────────────────────────────────┘
                          ▲  ▼
┌──────────────────────────────────────────────────────────────┐
│  TIER 2 — DERIVATIVES (machine-maintained, cheap to rebuild) │
│  Embeddings, FTS index, graph edges, clusters, L0 abstracts. │
│  Rebuildable from Tier 1 without loss.                       │
└──────────────────────────────────────────────────────────────┘
                          ▲  ▼
┌──────────────────────────────────────────────────────────────┐
│  TIER 1 — RAW SOURCES (immutable, append-only)               │
│  The signal files, PDFs, images, audio, transcripts.         │
│  The engine NEVER rewrites these. Only appends new ones.     │
└──────────────────────────────────────────────────────────────┘
```

Hard invariant: **the engine owns Tier 3 projection lifecycle. LLMs may propose
or render pages, but they do not own canonical truth and they do not touch Tier
1 directly.**

## Why three tiers (not two)

Tier 2 exists because a wiki that tried to embed all the raw text would
collapse under its own weight. Tier 2 (derivatives) is the fast-path for
retrieval; Tier 3 (wiki) is the curated read-through layer that sits on top of
BOTH raw sources and derivatives. When the wiki cites a fact, the citation can
point at any tier.

## Anatomy of a Wiki page

A wiki page is a markdown file at `.wiki/<slug>.md` in the engine's root. It
has three sections:

```markdown
---
title: Alice — pricing conversations
last_curated: 2026-04-17T14:30:00Z
curated_by: ollama:qwen3:8b
source_count: 7
---

# Alice — pricing conversations

## Summary

Ed has been negotiating on $2K/seat pricing since 2026-03-18. He has asked
three times for a discount {{cite: optimal://nodes/ai-masters/signals/2026-03-18-ed-pricing-call.md}}
{{cite: optimal://nodes/ai-masters/signals/2026-03-22-ed-followup.md}}
{{cite: optimal://nodes/ai-masters/signals/2026-04-03-ed-pricing-pushback.md}}.

Alice's position: $2K is the floor for AI Masters
{{cite: optimal://nodes/04-ai-masters/context.md}}.

## Open threads

- Discount request pending Alice's response {{expand: ed-counter-offer-options}}
- Waiting on partnership terms {{include: optimal://nodes/04-ai-masters/deliverables/external/ed-partnership/offer-stack.md}}

## Related

- [AI Masters offer stack](ai-masters-offer-stack.md)
- [Partnership structure](partnership-structure.md)
```

Three things matter here:

1. **Every factual claim has a `{{cite: uri}}` directive.** Agents see exactly
   where each sentence came from. Claims without citations are flagged by the
   maintenance loop and either grounded or removed.

2. **Executable directives pull more context on demand.** The agent (or the
   engine) resolves `{{include: uri}}` inline and `{{expand: topic}}` as a
   sub-query. Progressive disclosure — don't load what the agent doesn't ask
   for.

3. **Cross-links point to other wiki pages.** The wiki is a graph, not a flat
   bag. Following links is cheaper than re-querying.

## Executable directives

All directives are `{{verb: argument}}` and are resolved by the engine OR by
an agent with access to the engine.

| Directive                          | Resolves to                                                    |
|-----------------------------------|----------------------------------------------------------------|
| `{{cite: optimal://...}}`         | URI pointer. Rendered as an inline footnote with clickable link. Cheap — no content load. |
| `{{include: optimal://...}}`      | Inline the referenced content at the cite location. Loads at `:l1` tier by default; `{{include: ... tier=full}}` for full. |
| `{{expand: topic-slug}}`          | Run a sub-query against the wiki for `topic-slug`. Returns the summary section of the matching page. |
| `{{search: "query"}}`             | Run hybrid search, inject top-k chunks. Useful for truly dynamic lookups. |
| `{{table: uri#column=value}}`     | Fetch a structured row from a CSV/table asset. |
| `{{trace: entity}}`               | Walk the knowledge graph from `entity` and inject neighbors. |
| `{{recent: node limit=5}}`        | Inject the 5 most recent signals from a node. |

The engine rejects any directive verb not in this whitelist, so agents can't
be tricked into executing arbitrary code from a wiki page.

## Citation integrity

The maintenance loop enforces:

1. **Every factual sentence cites at least one source.** If it can't find a
   source, the claim is either removed or moved to a `## Unverified` section.
2. **Every `{{cite: uri}}` resolves to a real context.** Broken citations are
   flagged and repaired (redirect to current location if renamed) or removed.
3. **Citation recency.** Each citation carries a `last_verified` timestamp.
   When a source is re-ingested, the citation is re-verified.
4. **Conflict detection.** If two cited sources contradict each other, the
   page gets a `## Contradictions` section flagging the divergence. The agent
   (or a human) decides how to resolve.

## The maintenance loop

```
┌──────────────────────────────────────────────────────────────┐
│ NEW SIGNAL INGESTED → pipeline runs (stages 1–8)             │
└──────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│ ROUTE TO WIKI PAGES                                          │
│ For each affected topic, queue a curation job.               │
│ Affected topics = clusters the new chunks landed in +        │
│ entities mentioned + pages explicitly cited.                 │
└──────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│ CURATE (Ollama local LLM)                                    │
│   Input:  existing wiki page + new signals + their citations │
│   Prompt: integrate new facts; keep citations; flag contras- │
│           dictions; preserve structure; compact redundancy.  │
│   Output: updated wiki page with full citation coverage.     │
└──────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│ VERIFY → COMMIT                                              │
│ - Integrity checks (every claim cited, no broken URIs).      │
│ - Diff against previous version, store in page history.      │
│ - Emit a Signal on the "wiki.page.updated" topic.            │
└──────────────────────────────────────────────────────────────┘
```

Maintenance is **triggered, not scheduled**. A new signal into the `04-ai-masters`
node with the entity "Alice" queues a curation job for exactly the wiki
pages that mention Alice. No blanket rebuild.

Hard rebuild (`mix optimal.wiki.rebuild`) exists for disaster recovery: it
re-curates every page from Tier 1 + Tier 2. Idempotent, takes minutes, not
seconds.

## The schema

Wiki behavior is governed by `.wiki/SCHEMA.md`, a markdown-formatted
declaration the curator LLM is prompted with. It specifies:

- Allowed top-level sections (`## Summary`, `## Open threads`, `## Decisions`, `## Related`, etc.)
- Citation density minimums (e.g., "every claim in `## Decisions` must cite a `decision-log` signal")
- Naming conventions for page slugs (kebab-case, entity-first when applicable)
- When to create a new page vs extend an existing one
- Page size ceilings (e.g., "sections beyond 500 tokens should spawn a child page")
- Allowed directive verbs (from the table above)

The schema is a human-owned, LLM-read contract that makes the curator's
behavior predictable and auditable.

## How the Wiki Layer maps to the 8-stage pipeline

| Stage            | Wiki Layer's role                                                             |
|------------------|-------------------------------------------------------------------------------|
| 1 Intake         | wiki receives no input directly — always through the pipeline                 |
| 2 Parse          | same                                                                          |
| 3 Decompose      | wiki pages are themselves decomposed (their chunks feed retrieval like any source) |
| 4 Classify       | wiki pages are classified as `genre: wiki_page, intent: reference`            |
| 5 Embed          | wiki pages are embedded so they can be retrieved by semantic search           |
| 6 Cluster        | wiki pages tend to BE cluster summaries (or get co-clustered with their sources) |
| 7 Store          | wiki pages are stored in `.wiki/` (Tier 1 wrt themselves, Tier 3 wrt sources) |
| 8 Deliver        | Wiki/export pages are a preferred human-readable front door, but final agent context comes from governed Context Packages. Assembly can read wiki projections first, then verifies source, freshness, and permissions through retrieval. |
| 9 Curate (new)   | the maintenance loop                                                          |

## Build status

| Component                   | Status                                                  |
|----------------------------|---------------------------------------------------------|
| `.wiki/` directory          | Built. `.wiki/SCHEMA.md` exists as the human-owned contract. |
| Wiki schema                 | Built as a first schema; needs stronger validation against current Memory Core objects. |
| Wiki page template          | Partial. Page shape exists conceptually; node/page render templates need first-class service support. |
| Directive parser            | Built as `OptimalEngine.Wiki.Directives`; expand to richer render targets and stricter policy checks. |
| Citation integrity checker  | Built as `OptimalEngine.Wiki.Integrity`; expand to Source Package, Fact, Memory Object, and projection freshness checks. |
| Curation trigger (signal → affected pages)  | Partial. Scheduler/curator modules exist; affected-page routing and queue proof need hardening. |
| Curator (Ollama prompting)  | Built as a first `OptimalEngine.Wiki.Curator`; needs governed model-call records and review policy. |
| Page history / diff storage | Partial through wiki store/versioning and projection revisions; explicit diff/restore commands still needed. |
| `mix optimal.wiki.*` tasks  | Built as `mix optimal.wiki list/view/verify/verify-all`; rebuild/import/link-check/export commands still needed. |
| Deliver reads wiki first    | Partial. Wiki-first RAG exists, but Context Package assembly still needs a stricter wiki-projection-first path with source/freshness verification. |

The L0 cache is a distant cousin of the wiki/export layer. It is
machine-generated, flat, and optimized for quick context. The wiki/export layer
is structured, navigable, source-linked, and human-operable. It does not replace
governed retrieval; it becomes one projection and input surface used by
retrieval, humans, and agents.

## Correct Build Order

The wiki/export track is the next user-visible layer after Workspace/Topology.
It should be built before deeper source-first and multimodal hardening because
it is how humans and agents inspect whether the engine is organizing the world
correctly.

The order is:

1. **Markdown wiki service** — page tree, page templates, directive rendering,
   citation integrity, backlinks, broken links, revisions, import/export,
   render/rebuild helpers, and `mix optimal.wiki`/HTTP surfaces.
2. **Source-first intake** — every edit, file, connector payload, tool result,
   and API request is preserved or quarantined as a Source Package before
   classification, routing, summarization, or compatibility context writes.
3. **Multimodality** — raw artifact store, modality metadata, parser assets,
   extraction projections, adapter runs, text-bearing extraction to pending
   Claims, and failed/unsupported artifact records.
4. **Truth lifecycle** — Claim extraction, Fact promotion, Memory Object
   building, contradiction handling, temporal validity, confidence, precision,
   supersession, and review queues.
5. **Governed recall** — wiki-projection-first retrieval, then structured
   Source/Facts/Memories/asset extraction recall under permissions, freshness,
   and redaction policy.
6. **Active work loop** — Active Memory Pools, task observations, loaded
   Context Packages, refresh, membership, and promotion candidates.
7. **Workflow and Skill promotion** — Workflow Traces, Generalized Workflows,
   Procedural Memory Objects, Skill Packages, validation, rollback, exception
   paths, and disabled-by-default execution.
8. **Tool/model governance** — registered model/tool definitions, schema
   validation, permission checks, run records, output validation, and audit.
9. **Evaluation, recovery, and benchmark surfaces** — reproducible benchmark
   configs, result cards, large-scale recall tests, rebuild tests, recovery
   tests, dashboards, and failure-class reporting.

This wiki track can run alongside lower pipeline work, but it should stay first
in the implementation queue because it gives the operator a visible, linkable,
auditable surface for every later backend improvement.
