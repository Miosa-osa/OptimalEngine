# Viability (VSM and Signal Theory measures)

The Engine reports how viable a workspace or an org is from what is actually in it.
It models Beer's five systems, computes the six proxy metrics and the requisite variety ratio from Signal Theory, alerts on trajectories before they fail, audits a weekly sample of sent Signals, and keeps the chain of every agent action.
None of it blocks ingest; it reads and annotates.

## The report

`GET /api/viability?workspace=<id>` (or `?workspaces=*` for the org) returns:

| Field | Content |
| --- | --- |
| `summary` | verdict (`viable`, `at_risk`, `not_viable`), counts, and the predicted failure of every system that is not present |
| `systems` | Systems 1 to 5 and 3*, each `present`, `degraded`, or `missing`, with evidence and findings |
| `metrics` | the six proxy metrics for the last 7 days, each with its method, numerator, denominator, and direction |
| `variety` | R, its band, V(system), V(disturbance), coverage, and the largest gaps |
| `trajectory` | four weekly periods of every metric and flow, and alerts |
| `workspaces` | for the org view, each workspace's verdict and system states |

The org view covers the workspaces the caller's key may read.

## The five systems

| System | Present when | Predicted failure when not (source) |
| --- | --- | --- |
| 1 Operations | units (nodes, or workspaces for an org) received Signals in 30 days, counting the copies routed to each unit; a unit with more than half of them is reported as a bottleneck | No operations (Engine) |
| 2 Coordination | rhythm templates, routing rules, or a declared repertoire exist and were used in 14 days | Cross-team misalignment (paper P3) |
| 3 Control | open loops are closed (one in 30 days) and at most half the open ones are overdue | Drift of commitments and priorities (Engine) |
| 3* Audit | an audit ran in 14 days and no flagged sample waits more than 7 days | Undetected decay (Engine) |
| 4 Intelligence | outward Signals arrived in 30 days | Blindsided by change (paper P3) |
| 5 Policy | an active policy pack and an org protocol are set | Inconsistent encoding standards (paper P3) |

A Signal is outward when an `outward` Signal event tags it with a topic (`market`, `customers`, `competitors`, `technology`, `risk`, `regulation`, `partners`), or when its writer stored that topic in `metadata.outward`.
Connectors and agents post the event after ingest (`POST /api/signal-events`).

## The six proxy metrics

Signals received are contexts of type `signal`, excluding agent action steps, cross-reference copies of a Signal routed to a second node (`metadata.cross_ref_from`, kept from the copy's frontmatter), and Signals the workspace sent (`metadata.direction = "outbound"`, or a `produced` event naming the context).
Engines with data indexed before this release mark old copies once with `mix optimal.viability repair-cross-refs`.

| Metric | Better | Method |
| --- | --- | --- |
| action completion rate | higher | open loops closed in the window over loops closed, dropped, or missed (due in the window, unresolved at its end) |
| re-encoding frequency | lower | `re_encoded` events, follow-up loops, and Signals that re-explain or ask again (configurable phrases), per 100 Signals |
| time to decode | lower | median hours from receipt to the first action: an `acted` event or the first loop closed from the Signal |
| signal bounce rate | lower | Signals rerouted (`rerouted` events, rejected routing feedback) over Signals received |
| genre recognition rate | higher | Signals classified to a registry genre other than the fallback `note`, plus passed pre-send genre checks |
| feedback loop closure rate | higher | reply, follow-up, and decision loops closed, plus direct Signals confirmed by a `feedback_confirmed` or `acted` event |

A metric with nothing to measure is `null` with `status: "no_data"`.

## Requisite variety

R = V(system) / V(disturbance).
V(disturbance) counts the genre and mode classes of Signals received in the window.
V(system) counts the classes the workspace employs: its declared repertoire and the classes of Signals it sent in the last 90 days.
Bands follow the paper: under 1 failing, 1 to 3 marginal, 3 to 10 adequate, 10 or more robust.
`coverage` is the share of encountered classes the repertoire covers, and `gaps` lists the largest uncovered ones.
Without a repertoire R is `null` with `status: "no_repertoire"`.

Declare a repertoire as an operating document, one class per line, `genre` (any mode) or `genre/mode`:

```
PUT /api/protocol {"workspace": "<id>", "kind": "repertoire", "content": "- email\n- proposal\n- transcript/linguistic"}
```

## Signal events

`POST /api/signal-events {workspace, kind, context_id?, value?, genre?, mode?, topic?, occurred_at?, metadata?}` records what the metrics read.
Kinds: `acted`, `rerouted`, `re_encoded`, `feedback_confirmed`, `genre_checked` (`value` 1 fit, 0 mismatch), `produced` (a sent Signal: `context_id`, or `genre` and `mode`), `outward` (`topic`).
The actor is the caller's key.

## Trajectory

The last four 7-day periods are compared.
An alert fires when every step moved the wrong way: any metric, the inbound and outward flows, the average S/N, and each unit's volume and S/N (units with at least 5 Signals).

## System 3* audit

Each week a random sample (default 10) of the Signals a workspace sent is scored with triple-layer verification: formal 0.40 (title, body, recorded dimensions, required sections when the text has headings), semantic 0.35 (recorded genre and mode against what the text reads as now, so Signals stored by an older classification are caught, and the S/N estimate), information 0.25 (novelty against the 30 Signals before it).
When a workspace sent none, received Signals are sampled and `basis` says so.
A sample scoring under 0.5, or with any one layer under 0.4, is flagged, listed by `GET /api/viability/audit?workspace=&state=flagged`, shown in the brief, and confirmed or dismissed with `POST /api/viability/audit/:id/review {workspace, decision, note}`.

## History

The scheduler keeps one snapshot per workspace and per org each day (`viability_reports`), refreshes today's on every pass, and backfills up to 30 days the first time.
Backfilled days carry metrics only, since how the systems stood then was not recorded.
`GET /api/viability/history?workspace=&days=30` returns the snapshots and any missing days; the org history needs a key scoped to every workspace.
`POST /api/viability/snapshot {workspace | workspaces: "*", days}` (admin) catches up now.
`OPTIMAL_VIABILITY_INTERVAL_MS` sets the pass interval (default one hour, 0 disables).

## Agent action chains

Every agent action that goes through an approval is recorded as linked steps: `request`, `approval` or `denial`, `action`, `result`, `reply`.

```
POST /api/agent-actions {workspace, stage: "request", agent, action, resource, summary, detail}
POST /api/agent-actions {workspace, stage: "approval", correlation_id, detail: {"request_id": "...", "jti": "..."}}
GET  /api/agent-actions/<correlation id | request id | grant id>?workspace=<id>
```

Each step is a row numbered within its correlation id and pointing at the step before it, an Engine Signal (genre `audit-trail`, node `agent-actions`) carrying the correlation and causation ids, and an `agent_action.step` entry in the signed authority evidence chain with the step's canonical SHA-256.
Recording `approval` or `denial` needs the `authority:enforce` scope; other stages need `write`.
The trace also follows the Engine's own flow (approval request, approval, grant, admission, release) by request or grant id, reports whether the chain is complete, verifies every step against the evidence, and names gaps such as an action without an approval.

## CLI

```
mix optimal.viability report [--workspace <id> | --org]
mix optimal.viability history [--workspace <id> | --org] [--days 30]
mix optimal.viability snapshot [--workspace <id> | --org]
mix optimal.viability audit [--workspace <id>] [--size 10]
mix optimal.viability chain <id>
```
