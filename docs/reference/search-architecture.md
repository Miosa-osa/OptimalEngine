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
2. A tie goes by `uri`, then by `id`, both ascending, compared byte for byte.

Every SQL `ORDER BY` that feeds a ranked list ends in a unique column, so a tie at the edge of a candidate window cannot change which contexts are considered.
This covers the context search, durable memory search and its embeddings, the vector store, and the governed recall queries of the Retrieval Coordinator.
Budget-aware selection (`Retrieval.MCTS`) is reproducible for the same candidates in the same order, and returns its selection best first.

The graph boost runs after the cut and changes the scores shown, not the order.
A boosted list is in the order of the scores before the boost.

### Time

Freshness decay measures age against one instant per request.
`as_of` sets that instant: an ISO 8601 timestamp, or a `DateTime` in Elixir.
Omit it, or send it blank, and the Engine reads the clock once when the request starts.
A timestamp without an offset is read as UTC.
An `as_of` before 1970 or more than a year ahead, or one that does not parse, is a 400.
Write `+` in an offset as `%2B` in a URL, or use `Z`.

The governed recall behind `POST /api/assemble` and `POST /api/reconstruct` measures its validity windows (`valid_time_end`, `stale_after`) against the same instant when `as_of` is given.

```text
GET  /api/search?q=renewal&workspace=sales&as_of=2026-10-20T12:00:00Z&mode=lexical
GET  /api/grep?q=renewal&workspace=sales&as_of=2026-10-20T12:00:00Z
POST /api/rag        {"query": "...", "as_of": "2026-10-20T12:00:00Z"}
GET  /api/rag/stream?query=...&as_of=2026-10-20T12:00:00Z
GET  /api/recall/who?topic=...&as_of=2026-10-20T12:00:00Z
mix optimal.search "renewal" --workspace sales --as-of 2026-10-20T12:00:00Z --mode lexical
```

### Mode

`mode` pins the retrieval path of `GET /api/search`:

| mode | Path |
| --- | --- |
| `lexical` | Full text only. |
| `hybrid` | Full text and the vector hop. When the embedder cannot serve it the answer is a 503 `hybrid_unavailable`, never a quiet fall back to full text. |
| `auto` (default) | The vector hop when the embedder answers, full text otherwise. |

Without a pin, two Engines differ whenever only one of them has a healthy embedder at that moment.

### Comparing two Engines

A comparison of the ranked lists of two Engines holds when:

1. Both run the same build.
2. Both hold the same contexts with the same `uri`, `id`, text, timestamps, `node`, `genre` and `sn_ratio`.
   A migration that copies ids and URIs satisfies this; two independent ingests of the same files satisfy it only if they mint the same ids.
3. The request is the same, including `limit`, `workspace`, `tenant` and any filters.
4. Both are sent the same `as_of` and the same `mode`.
5. The comparison uses the order the server returned, not a re-sort on the client, and compares `uri` rather than the displayed `score` (four decimals).

`GET /api/grep` rows carry the `uri` of their context for the same reason.

Scores come from `exp` and `log`, which can differ by one unit in the last place between libm builds.
That cannot reorder results that differ by more than about 1e-12, and exact ties stay exact ties on each machine.

### Postgres

The ties above are broken in SQL with `ORDER BY ... uri, id`.
SQLite compares text byte for byte.
A Postgres store must do the same, so give those columns `COLLATE "C"` (or use a database created with the `C` collation), or two stores will break ties in a different order.

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
