# Operating layer

The operating layer turns a workspace's Engine data into what a person or agent needs at the start of a session and through the day.
Everything is stored in the Engine and works on a fresh org with empty-state answers; nothing reads local files.

| Route | CLI | What it returns |
| --- | --- | --- |
| `GET /api/boot?workspace=` | `mix optimal.operate boot` | The actual day in the workspace's time zone, today's rhythm note, fires (overdue and due-today loops), open loop counts, recent decisions, stale items, the brief, the operating protocol, and the org policy the workspace follows (`org_policy`); the first request of a day writes that day's rhythm note, and `generate=false` (or `0`) reads it without writing (`rhythm.stored` says whether it exists); a key that holds only `read` never writes it |
| `GET /api/brief?workspace=` or `?workspaces=a,b` or `?workspaces=*` | `mix optimal.operate brief` | Ranked items that need a decision today, each with sources and a next action |
| `GET /api/loops`, `POST /api/loops`, `POST /api/loops/:id/{close,drop,reopen}` | `mix optimal.operate loops` | Open loops: commitments, owed replies, follow-ups, money due or owed, decisions needed |
| `POST /api/loops/extract {workspace, since?}` | `mix optimal.operate extract` | Detects loops in recent contexts and closes loops answered in their thread |
| `GET /api/rhythm/current?workspace=&cadence=daily` | `mix optimal.operate today` | The note for the current day, ISO week, or month, generated on first request by a caller who may write (`generate=false` or `0`, or a key without `write`, reads it without writing; `stored` says whether it exists) |
| `GET /api/rhythm/notes`, `PUT /api/rhythm/notes/:cadence/:period`, `PUT /api/rhythm/templates/:cadence` | | Note history, edits, and per-workspace templates with a time zone |
| `GET /api/protocol?workspace=`, `PUT /api/protocol` | `mix optimal.operate protocol` | The agent operating protocol: workspace version, else tenant version, else the Engine default |
| `GET /api/topology/export`, `POST /api/topology/import` | `mix optimal.operate topology-export`, `topology-import` | Organizations, workspaces, and people as one portable document |
| `GET/POST/DELETE /api/routing/rules`, `POST /api/routing/classify`, `POST /api/routing/feedback`, `POST /api/routing/seed` | `mix optimal.operate seed-routing` | Per-workspace routing rules that learn from accept and reject |

Chats and agents commit what they did with `POST /api/sessions/commit`, and every workspace reads the policy of its organization's org section; both are in `chat-memory.md`.

## Open loops

A loop has a kind (`commitment`, `owed_reply`, `follow_up`, `payment_due`, `payment_owed`, `decision_needed`), an owner, a counterparty, a due date, and the source it came from.
Detection is deterministic and explainable: commitment phrases ("I'll send", "we will follow up"), requests ("can you confirm"), money language ("invoice is outstanding"), and decision requests, with due dates from "by Friday", "next Monday" (the following calendar week), "tomorrow", "end of week", month and day, or an ISO date, relative to the context's own date.
A detected loop records its confidence; the same loop is never created twice.
A later context carrying the same `metadata.thread_ref` closes the loop as answered.

## Rhythm

Daily, weekly, and monthly notes are date-named (`2026-10-18`, `2026-W42`, `2026-10`) and generated in the workspace's time zone.
Priorities always come from the open loops at generation time; a note never copies a previous period's priorities.
Template placeholders: `{{date}}`, `{{weekday}}`, `{{period}}`, `{{workspace}}`, `{{priorities}}`, `{{due}}`, `{{waiting}}`.

## Scope

Workspace authorization applies to every route.
`workspaces=*` on `GET /api/brief` and `GET /api/loops` means every workspace the caller's key covers (all of them for an unrestricted key); no other route accepts it.
Topology import and export need the `admin` scope; routing rule and protocol changes need `topology:write`; routing rules are listed only for workspaces in the caller's scope.

## Portable topology

```yaml
schema_version: 1
organizations:
  - slug: example-co
    name: Example Co
    status: active
    role: Operating company
    workspaces: [sales, delivery]
people:
  - id: user:jane
    kind: user
    display_name: Jane Example
    workspaces: [sales]
```

Import is idempotent and never deletes; fields the Engine does not model are kept and exported back, so import followed by export returns the same document.

## Routing rules

Fields: `sender`, `domain` (also matches subdomains), `label`, `channel`, `keyword` (whole words).
`classify` proposes a workspace with confidence `high` (score at least 8 and a margin of 5), `review`, or `unresolved`, and lists the rules that fired.
Feedback moves a rule's effective weight: `weight * (1 + accepted) / (1 + rejected)`.
`POST /api/routing/seed` loads the keyword rules of the deployment's routing rules file (`OPTIMAL_CORPUS_RULES`).

## The intake workspace and the review queue

Every tenant has its own intake workspace, named `<tenant>:knowledge-intake`.
It is an ordinary workspace: create it with `POST /api/workspaces` (slug `knowledge-intake`) and ingest into it.
`config :optimal_engine, :corpus_intake_slug` changes the slug, and `config :optimal_engine, :corpus_source_workspace` names the intake of the tenant that owns that workspace.
The organizer (`/api/maintenance/corpus-organization`), the routing review queue (`GET /api/review/routing`, `POST /api/review/routing/:id`), the steward's batch decisions (`POST /api/data-steward/routes/decide`) and the `route_clusters` of the steward dashboard read and write the caller's intake and the caller's records in it, and no other tenant's.
Without a tenant, the organizer works on the deployment's intake: the configured one, else the default tenant's.
A tenant other than the default names one of its workspaces on the review and batch calls (`?workspace=<id>`, or `workspace` in the body), as on any workspace-scoped route.

A decision on a record that is not the caller's, or is not in the caller's intake, fails with `not_found_or_not_in_intake`, whether it is an acceptance, a rejection or a move.
The target of an acceptance must be an active workspace of the caller's tenant (`target_workspace_not_registered`).
A key restricted to some workspaces needs the target in its scope: the route authorizes `workspace`, and for a batch the `target_workspace_id` of every item, so a workspace of another tenant answers `404` and one outside the key's scope answers `403 workspace_scope_denied`.
Such a key also needs the intake in its scope on the review and batch routes, and the organizer needs a key that holds the whole tenant (`workspace_scope` `["*"]`).
That includes running the organizer as an analysis (`POST /api/analyses/run` with kind `workspace_population`).
The `route_clusters` of the steward dashboard are empty for a key that does not hold the intake.
A decision other than `accept` or `reject` is `400`, not a rejection.
A batch holds at most 500 items, decides them one by one, and the answer lists the result of each.
A move is one transaction.
It changes the workspace of the record and of the rows derived from it (chunks, vectors, entities, edges, claims, source packages, chunk embeddings), which take the record's tenant; a row labelled with another tenant is not the record's and stays.
The exact-duplicate sweep (`deduplicate_exact`) works on the tenant's intake workspace only, and archives all but the newest of the records with the same content; `all_tenants` in a request does not widen it.
The routing rules file names workspaces for the whole deployment, and the organizer applies only the rules that name an active workspace of the tenant whose intake it works on.

## Placement by meaning

The intake organizer (`OptimalEngine.CorpusOrganizer`) places intake records by name markers, and by meaning when the `semantic` section of the routing rules file (or `config :optimal_engine, :corpus_semantic_placement`) enables it:

```yaml
semantic:
  enabled: true
  method: knn           # centroid (the default), knn, or agree
  k: 10                 # knn, agree: the nearest filed documents that vote
  share: 0.8            # knn, agree: least share of the vote to win (0 < share <= 1)
  min_similarity: 0.75  # floor for the best similarity (see the table)
  margin: 0.04          # centroid, agree: best centroid similarity minus the runner-up
  min_examples: 5       # filed documents with vectors a target workspace needs
  exclude: [default:example-private]
```

Targets are the active workspaces of the intake workspace's tenant with at least `min_examples` vectors, other than the intake and the excluded ones; at least two are needed, so there is a choice.

| Method | A record is placed when |
| --- | --- |
| `centroid` | the closest centroid of a target's filed document vectors clears `min_similarity` and beats the runner-up by `margin` |
| `knn` | among the `k` filed documents closest to the record, the leading target holds at least `share` of the vote (each document votes for its workspace with its similarity) and its closest document clears `min_similarity`; documents of every active workspace of the tenant vote, so small and excluded workspaces dilute the vote, but only a target can win it |
| `agree` | `knn` places it and the closest centroid is the same workspace, at least `margin` ahead of the runner-up |

In every method a name marker that proposes another workspace blocks the placement.
An unknown method, a `k` that is not a positive integer, or a `share` that is not above 0 and at most 1 turns placement by meaning off, with a warning.
A record that is not placed keeps the leading workspace as its proposal in its routing review entry (`routing_review.semantic`, with the method and its numbers).
Every placement, by markers or by meaning, keeps its evidence on the record as `metadata.routing_placement`: the method (`markers` or `semantic`), the workspace, the time, and the numbers.
A placement by meaning names its `semantic_method` and keeps `similarity` and `margin` (centroid); `similarity`, `share`, `votes` and `neighbours` (knn); or all of these with the centroid's workspace and similarity (`centroid_workspace_id`, `centroid_similarity`) and margin (agree).

A centroid favours small, focused workspaces: a record of the right kind but the wrong subject lands closer to their centroid than to the centroid of a large, varied workspace.
The nearest documents have much less of that bias: votes are weighted by similarity, so a workspace usually needs most of the `k` neighbours to reach `share`.
It can win with fewer only when its documents are much closer than the rest (with `k` 10 and `share` 0.8, seven neighbours at 0.90 against three at 0.50 hold 0.81 of the vote), so a small workspace rarely attracts records.
On one deployment (about 1,900 filed documents in 13 target workspaces, 768-dimension `nomic-embed-text` vectors), leave-one-out over the filed documents gave:

| Settings | Precision | Coverage | Worst workspace precision (3 or more placed) |
| --- | --- | --- | --- |
| centroid, margin 0.04 | 96.1% | 23.4% | 33.3% |
| knn, k 10, share 0.8, min_similarity 0.75 | 97.7% | 41.6% | 94.6% |
| agree, k 10, share 0.8, margin 0, min_similarity 0.75 | 98.3% | 35.4% | 95.2% |

The similarity floor keeps short or generic records, such as contact form submissions and small talk, in review: their closest documents stay below it even when the vote is unanimous.
The right floor depends on the embedding model; 0.75 suits `nomic-embed-text`.
`knn` and `agree` compare each intake record the preview reads (its `limit`) with every filed document of the same dimensions, spread over all schedulers but one, which stays free for requests and the Store.

Only documents with a vector take part.
`GET /api/maintenance/embeddings` counts active documents without one (`?workspace=` for one workspace), and `POST /api/maintenance/embeddings {"limit": 100, "workspace"?}` embeds them with the configured text model; both need `admin` and stay in the caller's tenant.
An unreachable embedder answers 503.
With placement by meaning on, the daily `workspace_population` analysis embeds up to 200 such documents before it places.

## Analyses as jobs

The Engine runs its standing analyses as durable jobs (`OptimalEngine.Jobs`: retries with backoff, then a dead letter) and keeps a report of each run.

| Kind | Scope | Report |
| --- | --- | --- |
| `promises` | each workspace | loops detected and closed by reply in the last 7 days, open loops by kind, the overdue ones |
| `workspace_population` | the intake workspace | items placed in their workspace (by name markers, or by meaning when enabled) and items queued for routing review; with placement by meaning on, it first embeds up to 200 documents that have no vector (`embed_limit` in the payload) |
| `meeting_archive` | workspaces with zoom, teams, or fathom connectors | each connector's pull result |
| `file_audit` | the tenant | the storage audit checks and the hierarchy issue count |
| `storage_usage` | the tenant | usage against the size profile and the resize advice |
| `retention_sweep` | the tenant | the retention policies applied, held items skipped |

Each kind runs once a day per workspace (a worker schedules and drains every five minutes, `OPTIMAL_ANALYSES_INTERVAL_MS`, 0 disables).

```
GET  /api/analyses?workspace=<id>&kind=promises
POST /api/analyses/run {"workspace": "<id>", "kind": "promises"}     (admin; runs now and returns the report)
GET  /api/jobs?workspace=<id>&status=dead
GET  /api/jobs/dead?workspace=<id>
POST /api/jobs/dead/<id>/replay {"workspace": "<id>"}     (admin)
```

## Maintenance jobs

Two maintenance backfills run as durable jobs, so an Engine without Mix, such as a release, runs them through the API.

| Kind | Work | Mix task (same work) |
| --- | --- | --- |
| `maintenance.chunk_embeddings` | embeds the workspace's chunks that have no chunk embedding | `mix optimal.embed_backfill` |
| `maintenance.graph_backfill` | writes the relationship edges of the workspace's contexts and claims | `mix optimal.graph_backfill` |

```
GET  /api/maintenance/embeddings?kind=chunks&workspace=<id>                     (admin; missing count and the active job)
POST /api/maintenance/embeddings {"kind": "chunks", "workspace": "<id>", "limit"?: n}   (admin; 202 with the job)
POST /api/maintenance/graph/backfill {"workspace": "<id>", "claims"?: false}     (admin; 202 with the job)
```

`kind` defaults to `documents`, the document vectors described under placement by meaning, which still run in the request.
A job belongs to one workspace of the caller's tenant, named in the body or the query.
With no `workspace` the request means the `default` workspace: a key limited to named workspaces gets 400 `workspace_required`, and a tenant that does not own `default` gets 404.
While a workspace has a job of the kind queued or running, another request returns that job with `status: "already_running"` and its `job_status`.
`POST` with `kind=chunks` answers 503 while the embedder does not answer, and queues nothing.
The client CLI's `optimal graph backfill [-w ws]` calls the graph route against a remote Engine ([CLI](cli.md)).
An Engine that has these two job routes (`POST /api/maintenance/graph/backfill` and `POST /api/maintenance/embeddings` with `kind=chunks`) lists the `maintenance_jobs_v1` capability in `GET /api/version`, so a client can tell it from one that runs the backfills only through Mix.

One run handles at most 500 chunks, or 1,000 contexts and claims, and never counts the whole scope.
When more is left, the job completes and queues its continuation in the same transaction; the continuation resumes after the last row it reached.
A graph continuation also carries what the slices before it counted, so the slice that reaches the end records the backfill in `graph_backfills` when every slice wrote all its edges, and `GET /api/maintenance/graph` then reads `backfill_needed` false for that workspace.
The work reads one workspace through its `(workspace_id, id)` indexes a page at a time and pauses between pages, so the single-writer Store stays free for requests.
A failed run retries with backoff and then dead-letters, like the analyses.
An unavailable embedder is not a failure: the chunk job goes back in the queue after one minute, doubling up to an hour, without spending an attempt (`last_error` "deferred: embedder unavailable"), and marks nothing failed.
After 24 deferrals in a row it fails like any other attempt, so an embedder that never comes back ends in a dead letter that says so.
Completed maintenance jobs older than seven days are pruned hourly.

The chunk embeddings heal by themselves.
A sweep checks the embedder first and, only while it answers, queues a low-priority chunk job for each workspace this Engine serves with chunks that have no embedding.
The maintenance probe gives a model that is still loading 15 seconds and a second try five seconds later.
It runs two minutes after boot and then every 30 minutes (`OPTIMAL_EMBEDDING_SWEEP_INTERVAL_MS`, 0 disables); queued maintenance jobs are drained every ten seconds (`OPTIMAL_MAINTENANCE_INTERVAL_MS`, 0 disables).
When it queues work it logs the workspaces it queued (it counts no chunks, since a count reads the whole workspace), and it logs once each workspace it cannot queue because its chunks name a workspace that is not registered and active.
On the first boot of a large Engine that predates the sweep, set `OPTIMAL_EMBEDDING_SWEEP_INTERVAL_MS=0`, read the backlog with `GET /api/maintenance/embeddings?kind=chunks&workspace=<id>`, and turn the sweep on when the embedder can take it.

## Reindex Requests

A writer that changes files in the engine root asks for a crawl instead of running one inline.

```
POST /api/reindex {"workspace": "<id>"}     (admin; returns 202)
```

The request becomes a durable `reindex` job, so it survives a restart and retries on failure.
While a reindex for a workspace is queued or running, another request for that workspace returns that job with `status: "already_running"` instead of adding a second one; requests for different workspaces each get a job.
The job completes once `OptimalEngine.Pipeline.Indexer` has started the crawl, not when the crawl finishes; `GET /api/jobs?workspace=<id>` shows the job and `GET /api/status` reports indexing progress.
The crawl reads the whole engine root, not one workspace, which is why the route needs the `admin` scope.
`POST /api/maintenance/index` is the same request under the maintenance root; the client CLI's `optimal index` calls it against a remote Engine (`cli.md`).

## Proving it

`scripts/proof-operating-layer.sh` checks the operating layer, the viability measures, and the public API surface against a live Engine and prints one `CHECK <criterion> PASS|FAIL|SKIP` line per criterion with the facts it was judged on.

| Mode | Command | Use |
| --- | --- | --- |
| Self-contained | `scripts/proof-operating-layer.sh` | Starts an Engine on an empty temporary store with auth required, mints a root key, and runs every check |
| Existing Engine | `ENGINE_URL=<url> ENGINE_KEY_FILE=<admin key file> scripts/proof-operating-layer.sh` | Runs every check in workspaces it creates (never a shared one), then revokes the keys it minted and archives those workspaces by the ids it recorded (`KEEP=1` keeps them) |
| Read-only | `ENGINE_URL=<url> [ENGINE_KEY_FILE=<file>] WORKSPACE=<id> [BOOT=1] scripts/proof-operating-layer.sh --read-only` | Sends GET requests only; every line names the tenant and workspace it read, and the rest is counts, dates, metric values, and booleans, never content, titles, names, or emails |

The full modes check: the empty-state answers of `optimal boot`, `optimal today`, `optimal loops`, `optimal fires`, and `GET /api/brief`, with every count zero; a claim promoted with a workspace key records that key's principal; a topology file imported and exported matches; workspace creation, members as principals and workspace members, and workspace keys as an outside mirror uses them; a rename that changes the slug while old links keep resolving; every route in the [API reference](../reference/api.md) carrying a grant and a workspace scope, every route the BusinessOS client calls being documented, and every route refusing a request without a valid key; classification, System 4, the six metrics with R and 30 days of history, the pre-send bandwidth check, and a linked agent action chain.
Every `CHECK` line prints the counts and values it asserted.
The read-only mode reports boot and the brief (today's date, open loops, owed replies with sources), classification, the viability report, metric history, and agent action chains for one workspace.
Read-only mode takes the day from the brief (UTC) and the loops from `GET /api/loops`; `BOOT=1` adds `GET /api/boot?generate=false` for the day in the workspace's time zone; the script sends it only to an Engine whose `GET /api/version` lists the `boot_generate_option` capability, since an older Engine would write the note, and says so otherwise.
`CLASSIFY_PLAN=0` skips the classification plan, which reads every Signal of the workspace.
A temporary store the script made is removed on exit unless `KEEP_DATA=1`.
The Engine-only quickstart has its own proof, `scripts/proof-engine-only.sh`.
Exit codes: 0 every check passed or was skipped, 1 a check failed, 2 the Engine could not be reached or refused the key.
