# Replication (local and cloud Engines)

Replication keeps a workspace in step between separate Engines, each with its own disk: a laptop and a cloud Engine, or a workspace Engine and an org Engine.
There is never more than one writer on one data directory.

## How changes are captured

Enabling a workspace (`POST /api/sync/enable {"workspace"}`) installs SQLite triggers on every table that carries a `workspace_id` column.
Every create, update, and delete of that workspace's rows is appended to `sync_capture` in the same transaction as the write, so no write path can skip it.
The Engine seals captured changes into the ordered `sync_mutations` ledger with a SHA-256 of the payload, an idempotency key, and its replica id.
BLOB values (embeddings) travel as hex, so vectors are copied, not recomputed.
Tables keyed by a single integer row id are derivations whose ids differ per Engine; they replicate inserts only (`GET /api/sync/status` lists them).

## How changes move

| Route | Scope | Purpose |
| --- | --- | --- |
| `GET /api/sync/changes?workspace=&since=` | `sync` | Ledger page after a sequence, never the requester's own changes (header `x-optimal-replica`) |
| `POST /api/sync/changes {workspace, engine, mutations}` | `sync` | Apply a peer's batch |
| `POST /api/sync/peers {workspace, url, api_key, policy, max_class, since?}` | admin | Register a peer; its key is encrypted with `CONNECTOR_KEY` |
| `POST /api/sync/run` | admin | Run one pull and push cycle now |
| `GET /api/sync/status?workspace=` | read | Ledger sequence, peers (status, cursors, pending changes), open conflicts |
| `GET /api/sync/conflicts?workspace=`, `POST /api/sync/conflicts/:id/resolve` | read, admin | Conflicts and their resolution |

A scheduler seals changes and runs every active peer every 20 seconds (`OPTIMAL_SYNC_INTERVAL_MS`), so a change reaches the other replica within a minute when both are online.
A cycle pages up to 20 pages of 500 changes each way; once a peer's cycle has run 60 seconds (`OPTIMAL_SYNC_CYCLE_BUDGET_MS`) it finishes the page in hand and resumes on the next cycle, so one slow peer cannot hold the scheduler.
An unreachable peer keeps its status and message and is retried on the next cycle; the local Engine keeps working offline and catches up when the peer returns, in order.

Apply is idempotent by mutation id, in origin order, each change in its own savepoint inside one transaction.
The ledger is checked again inside that transaction, so two applies of the same batch at once (`POST /api/sync/run` during a scheduler tick) still apply each change once.
Applied changes are added to the local ledger under their origin device, so a hub forwards them to other replicas, and they are never captured again, so nothing echoes.

The peer key is an API key on the peer limited to the workspace with the `sync` scope (add `read` for status).
Policies per peer: `push`, `pull`, `both`, `none`.

### Data classes

A peer is cleared up to a `max_class` (`public`, `internal`, `confidential`, `restricted`; default `confidential`).
The gate applies on send and on receive: a workspace whose `metadata.data_class` is above it is refused whole, and a row classified above it never leaves the Engine.
A row's class is not only its own `security_labels`.
A row copied or derived from a labelled row is as classified as its source, so a versioned memory staged from a restricted source package, the chunks, vectors and embeddings of a restricted document, and a wiki page that cites either stay home with it.
`OptimalEngine.Sync.Lineage` names, for every replicated table, the link columns that point at the rows it derives from, and `OptimalEngine.Sync.Gate` follows them.

Sending is fail-closed:

- A row stays home when its own labels, or those of any row it derives from, are above the peer's class.
- A row stays home when a source package, claim or other labelled row it must derive from cannot be found, or its lineage is deeper than 40 hops.
- A row is as classified as anything reachable through its links, loops included: a context package and its pool that name each other are held together when either is.
- A version of a memory is as classified as every version behind it, up to the first, each read for its own labels, its source package and claim, and the documents that name it. The chain is walked a version at a time, not recursed into, so a memory with many versions is not held for its depth, and a label that came to an old version by its source (not by value) reaches the later ones.
- A change to a table the lineage map does not know stays home, and `test/sync/sync_gate_test.exs` fails until the table is classified.
- A workspace whose `data_class` is not one of the four classes is treated as `restricted`; a workspace with no `data_class` (or not found) is `internal`.
- A Store error while classifying is not an answer.
The push cycle ends in an error with nothing sent and its cursor where it was, so the next cycle classifies the same rows again; a workspace that cannot be read is not assumed to be open.
- A value SQLite holds as a BLOB travels in `payload.blobs`; a label stored that way is read like any other, on send and on receive.
- An aggregate (`analysis_reports`, `data_quality_snapshots`, `rhythm_notes`, `sessions`, a wiki page or cluster that names nothing, an edge between entity names) has no row to point at, so it stays home while the workspace holds anything above the peer's class.
- A delete carries only the row's key.
It stays home when the row's earlier changes in the local ledger were held, so a peer that never had the row is not told of it.

Receiving reads what a row carries: its `security_labels`, the `security_labels` in its `metadata`, or its `classification_level`.
A batch arrives with its sources possibly not yet here, so the sender's gate is the one that follows lineage.

A versioned memory has no label column, so `security_labels` given when a memory is remembered or created are kept in its `metadata`, and its versions and children carry them.
A document that Intake writes names its source package and carries its labels in `metadata` from the first write, and its chunks are written at its class.
Rows written before this carry no such mark and are found through the derivation ledger and the claims of their source package instead.

A pulling peer does not say what it is cleared for, so what this Engine hands out (`GET /api/sync/changes` and `GET /api/storage/workspaces/:id/mutations`) is capped by the Engine's own ceiling, `config :optimal_engine, :sync_serve_max_class`, default `confidential`.
The cursor moves past what the gate holds, and the class is read when the row is sent.
A row held then is not sent later because its source package arrived after it, or because a label on its source was lowered; only a new change to the row, or to a row it derives from, is classified again.
So label before writing, and write the source before what derives from it.

### What a read key sees of exports and conflicts

`GET /api/batch/export/{memories,signals,workspace}` and `GET /api/sync/conflicts` return row text, so they filter by the caller the way governed retrieval does.
A keyed caller sees a row only when every label and partition the row carries is among the `allowed_security_labels` and `allowed_partitions` in its key's metadata, and its principal may read the row by the access lists (`OptimalEngine.Identity.ACL`).
A row carries the labels of the rows it was copied or derived from, and a row whose source cannot be found is seen by no one, so a memory staged from a restricted source package is not exported to a key that lacks `restricted`.
A key with no grants sees only rows that carry no label and no partition; give an export key the labels it should read.
An export leaves out what a key may not see.
A conflict keeps its table, key, kind and state, and a version of the row the key may not see is replaced by `{"redacted": "security_labels"}` with `redacted: true` on the conflict.
An anonymous local caller (no key, authentication not required) is the trusted operator and sees everything.
A wiki page that names nothing, and any other aggregate, carries every label in its workspace.

Limits worth knowing:


- A row names another row's id in free-form metadata in places (the encoding gate records the memory a new one is most like).
That is an opaque id, not the row, and the gate does not scrub it.
- Rows that already reached a peer before a label or lineage existed stay there.
A held delete does not reach the peer, so purge them on the peer directly.

### Syncing through a relay

An Engine that cannot be dialed (a laptop behind NAT is the initiator; a managed Engine in an isolated network cannot dial out to peers) syncs through a relay in front of the other Engine.
On MIOSA the relay is the control plane, and its key is a MIOSA API key with the `engine:sync` scope.
Register the peer with a `relay+` URL: `{"workspace": "<id>", "url": "relay+https://api.miosa.ai/api/v1/engines/<engine id>/sync", "api_key": "<relay key>", "policy": "both"}`.
The workspace id must be the same on both Engines.

Each cycle the local Engine calls the relay with `Authorization: Bearer <relay key>` and `?workspace=<id>` on every route:

| Step | Route | What the client does |
| --- | --- | --- |
| Status | `GET <base>/status` | Learns the other Engine's replica id and migration; pauses when the migration differs or status does not report one |
| Enable | `POST <base>/enable` with `{}` | Only when status says `enabled: false`; idempotent |
| Pull | `GET <base>/pull?since=&limit=` | Applies each page and keeps its `cursor`, then pulls again from it while `more` is true |
| Push | `POST <base>/push` with `{workspace, replica_id, engine, mutations}` | Sends the local ledger a page at a time, with the sender's `engine` envelope and no cursor; moves its push cursor only after a 2xx answer that reports `applied` |

The relay wraps answers in `{"data": ...}` and refusals in `{"error": {"code", "message"}}`; the client reads both, and a direct peer's unwrapped answers too.
Pushed mutations carry the full ledger shape, `sequence` included, exactly as `GET /api/sync/changes` returns them.
A page whose rows all stay home under the data-class gate is not sent, and the push cursor still moves past it.
A page the relay refuses as too large (`413`) is sent again as pages half its size.
When an answer is lost after the other side applied a page (a timeout or a `502`), the cursor stays, the next cycle sends the page again, and the other side applies none of it twice.
The relay does not forward `x-optimal-replica`, so the local Engine's own changes come back on the next pull; they are skipped as its own, never applied twice, and never pushed back.
A `409` with code `version_mismatch` pauses the peer (`status: paused_version`) and nothing is retried that cycle; while paused, a cycle makes only the status call, and sync resumes when both run the same migration.
Any other refusal (`403` without `engine:sync`, `404` not this tenant's Engine or workspace, `409 engine_not_running`) leaves the peer in `status: error` with the code and message, and the next cycle tries again.
The message never carries the peer key or anything shaped like a key (a bearer token, a prefixed key, a long opaque token), even when the relay echoes one back.
The local Engine is always the initiator, no peer Engine address is stored, and the same idempotency keys make a repeated cycle change nothing.

`scripts/proof-relay-client.sh` proves the relay client end to end against a managed Engine (`RELAY_BASE`, `MIOSA_API_KEY_FILE`, `WORKSPACE`), and `--stand-in` runs the same checks against a second local Engine behind a relay stand-in.
Run it on a disposable machine, never on one that holds a live store; it removes its temporary data, keys included, when it exits (`KEEP_DATA=1` keeps it).
Its conflict check edits a daily note on both sides; that a contested fact becomes two claims in the review queue is proven by `test/sync/sync_test.exs`, not by this script.

## Conflicts

When both sides changed the same row since the last sync, the newer change wins by its time and the conflict is recorded with both versions.
For facts, both versions also become claims in the review queue, so a contested fact is decided by a person.
The claims quote the fact, so they carry the labels of both versions and of the fact as it is stored, and they name the fact (`metadata.fact_id`, on the claims and on the source package that holds the conflict text): they stay home as long as the fact does, including when it is labelled higher later.
Changes that cannot be applied (an unknown table or column, a constraint failure) are recorded as `apply_failed` conflicts; nothing is dropped silently.

## Version safety

Every page carries the sender's replica id, Engine version, and schema migration.
A peer on a different migration pauses with `status: paused_version` and a message until both run the same Engine version.

## Seeding a replica

Enable sync on the source, export a workspace bundle (`docs/guides/scope-and-portability.md`), import it on the new replica, and register the peer with `since` set to the bundle's `ledger_sequence`.
The replica then pulls only what happened after the snapshot, so a large workspace never resyncs from zero.
