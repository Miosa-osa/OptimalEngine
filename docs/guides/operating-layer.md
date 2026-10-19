# Operating layer

The operating layer turns a workspace's Engine data into what a person or agent needs at the start of a session and through the day.
Everything is stored in the Engine and works on a fresh org with empty-state answers; nothing reads local files.

| Route | CLI | What it returns |
| --- | --- | --- |
| `GET /api/boot?workspace=` | `mix optimal.operate boot` | The actual day in the workspace's time zone, today's rhythm note, fires (overdue and due-today loops), open loop counts, recent decisions, stale items, the brief, the operating protocol, and the org policy the workspace follows (`org_policy`) |
| `GET /api/brief?workspace=` or `?workspaces=a,b` or `?workspaces=*` | `mix optimal.operate brief` | Ranked items that need a decision today, each with sources and a next action |
| `GET /api/loops`, `POST /api/loops`, `POST /api/loops/:id/{close,drop,reopen}` | `mix optimal.operate loops` | Open loops: commitments, owed replies, follow-ups, money due or owed, decisions needed |
| `POST /api/loops/extract {workspace, since?}` | `mix optimal.operate extract` | Detects loops in recent contexts and closes loops answered in their thread |
| `GET /api/rhythm/current?workspace=&cadence=daily` | `mix optimal.operate today` | The note for the current day, ISO week, or month, generated on first request |
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

## Analyses as jobs

The Engine runs its standing analyses as durable jobs (`OptimalEngine.Jobs`: retries with backoff, then a dead letter) and keeps a report of each run.

| Kind | Scope | Report |
| --- | --- | --- |
| `promises` | each workspace | loops detected and closed by reply in the last 7 days, open loops by kind, the overdue ones |
| `workspace_population` | the intake workspace | items placed in their workspace and items queued for routing review |
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

## Reindex Requests

A writer that changes files in the engine root asks for a crawl instead of running one inline.

```
POST /api/reindex {"workspace": "<id>"}     (admin; returns 202)
```

The request becomes a durable `reindex` job, so it survives a restart and retries on failure.
While one reindex is queued or running, another request returns that job with `status: "already_running"` instead of adding a second one.
The job completes once `OptimalEngine.Pipeline.Indexer` has started the crawl, not when the crawl finishes; `GET /api/jobs?workspace=<id>` shows the job and `GET /api/status` reports indexing progress.
The crawl reads the whole engine root, not one workspace, which is why the route needs the `admin` scope.
