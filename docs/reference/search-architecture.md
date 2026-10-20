# Search And Retrieval Architecture

Retrieval is not just semantic search. It is governed recall planning.

## Retrieval Flow

```text
query / task
  -> actor identity
  -> authorization envelope
  -> query intent
  -> subject/action/object/time/modality hints
  -> candidate generation
  -> structured filters
  -> lexical search
  -> vector search
  -> graph expansion
  -> temporal/freshness checks
  -> workflow/skill lookup
  -> evidence packaging
  -> Context Package
  -> audit
```

## Candidate Sources

| Source | Purpose |
| --- | --- |
| Facts | Accepted current or historical assertions. |
| Memory Objects | Contextual meaning around accepted knowledge. |
| Claims | Unaccepted assertions when the request explicitly asks for pending/disputed material. |
| Source Packages | Evidence inspection and citation. |
| Asset Extractions | Transcripts, OCR spans, visual observations, embedding refs. |
| Relationship Edges | Supports, contradicts, supersedes, depends_on, part_of, etc. |
| Workflow/Skill records | Process recall and reusable procedure lookup. |
| Wiki/export pages | Human-readable projections when fresh and authorized. |

## Ranking Signals

```text
permission fit
workspace/node scope
subject/action/object match
valid-time fit
transaction-time fit
freshness
confidence
precision
evidence strength
relationship distance
lexical score
vector score
workflow applicability
```

## Ordering And Reproducibility

Two Engines that hold the same data return the same ranked list.
One Engine returns the same list every time it is asked.

Every ranked list follows one rule (`OptimalEngine.Retrieval.Ranking`):

1. Results are ordered by their exact score, best first.
   A result carries `score`, the exact value rounded for display, and `rank_score`, the exact value.
   Ordering reads `rank_score` and never the rounded `score`, so two hits that print the same four decimals still order by their true scores.
2. A tie goes by `uri`, then by `id`, both ascending.

Every SQL `ORDER BY` that feeds a ranked list ends in a unique column, so a tie at the edge of a candidate window cannot change which contexts are considered.
This covers the context search, durable memory search and its embeddings, the vector store, and the governed recall queries of the Retrieval Coordinator.
Budget-aware selection (`Retrieval.MCTS`) is reproducible for the same candidates in the same order, and returns its selection best first.

Freshness decay measures age against one instant per request.
`as_of` sets that instant: an ISO 8601 timestamp, or a `DateTime` in Elixir.
Omit it and the Engine reads the clock once when the request starts.

```text
GET /api/search?q=renewal&workspace=sales&as_of=2026-10-20T12:00:00Z
GET /api/grep?q=renewal&workspace=sales&as_of=2026-10-20T12:00:00Z
mix optimal.search "renewal" --workspace sales --as-of 2026-10-20T12:00:00Z
```

To compare two Engines, send both the same `as_of` and compare the `uri` of each result in order.
A timestamp without an offset is read as UTC, and an `as_of` that does not parse is a 400.
Write `+` in an offset as `%2B` in a URL, or use `Z`.

## Output

Retrieval returns Context Packages, not loose chunks:

```text
answer-ready summary
facts_used
memory_objects_used
source_links
asset_extractions_used
workflow_or_skill_links
confidence_summary
precision_summary
validity_state
filtered_object_summary
audit_event_id
```

This makes the agent's context inspectable, refreshable, and auditable.

## Retrieval Strategies

`MemoryCore.RetrievalCoordinator` owns one deep Interface with three strategies:

```text
tiered          -> authorized governed objects packaged directly
reconstructive  -> authorized governed objects plus bounded Association Paths
hybrid          -> tiered packaging with reconstructive evidence in one budget
```

All strategies accept the same Scope Envelope and return one Context Package.

Reconstructive expansion reads the rebuildable `memory_associations` projection.

Every association retains canonical endpoint IDs, provenance, security labels, partitions, valid time, transaction time, confidence, and precision.

Unauthorized rows are excluded during candidate expansion.

The projection can improve recall but cannot decide truth.

## Reconstruction Learning

Each Reconstruction Run stores ordered steps and exact Association Paths.

Human outcomes credit paths within a workspace and intent.

They do not globally boost every returned object.

Recurring successful paths may create Consolidation Proposals, but those proposals remain review-required and cannot create Facts directly.
