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
- A chunk or document link whose row is gone, and which the local ledger never recorded, stays home: the gate cannot say what the row was.
A row whose document was deleted after the ledger recorded it is judged by what the ledger recorded.
A memory with a dangling `source_chunk_id`, in a workspace where sync was turned on after the memory was written, no longer replicates until the link is repaired.
- A `security_labels` list with an element that is blank or not a string (`["internal", ""]`, `["internal", 7]`) holds the row: the gate cannot say what the element meant.
Class names are not case sensitive.
- Reading what a row derives from has a budget of 10,000 rows not read before for each row classified.
A dense mesh of links that cycles back on itself (every row naming every other) has no result that can be kept per row, so past the budget the row is `unresolved` and stays home instead of being walked path by path.
- A workspace whose `data_class` is not one of the four classes is treated as `restricted`; a workspace with no `data_class` (or not found) is `internal`.
- A Store error while classifying is not an answer.
The push cycle ends in an error with nothing sent and its cursor where it was, so the next cycle classifies the same rows again; a workspace that cannot be read is not assumed to be open.
- A value SQLite holds as a BLOB travels in `payload.blobs`; a label stored that way is read like any other, on send and on receive.
- An aggregate (`analysis_reports`, `data_quality_snapshots`, `rhythm_notes`, `sessions`, a wiki page or cluster that names nothing, an edge between entity names) has no row to point at, so it stays home while the workspace holds anything above the peer's class.
- A change is held at the higher of the row as the ledger recorded it and the row as it is stored now.
An older version of a row that has labels today (it was labelled afterwards, or a version arrived from another Engine without them) stays home with the row.
- A delete carries only the row's key.
It stays home when the row's earlier changes in the local ledger were held, so a peer that never had the row is not told of it.

Receiving reads what a row carries: its `security_labels`, the `security_labels` in its `metadata`, or its `classification_level`.
A batch arrives with its sources possibly not yet here, so the sender's gate is the one that follows lineage.

Labels only grow when a change is applied.
A row this Engine already holds keeps the `security_labels`, the `partition_ids`, the `metadata.security_labels` and `metadata.partition_ids`, and the `classification_level` (above `internal`) it has, whatever the sender wrote and however old its change is: the two sets of labels are joined, and a higher level wins.
Labels held here that cannot be read count as `restricted`.
A change that carries everything the row holds is written as sent.
The ledger keeps the change as it was received, so another peer that is pulled from the ledger gets the sender's labels, and a cleared peer behind this one learns of the extra labels only from the sender.

A versioned memory has no label column, so `security_labels` given when a memory is remembered or created are kept in its `metadata`, and its versions and children carry them.
A document that Intake writes names its source package and carries its labels in `metadata` from the first write, and its chunks are written at its class.
Rows written before this carry no such mark and are found through the derivation ledger and the claims of their source package instead.

A pulling peer does not say what it is cleared for, so what this Engine hands out (`GET /api/sync/changes` and `GET /api/storage/workspaces/:id/mutations`) is capped by the Engine's own ceiling, `config :optimal_engine, :sync_serve_max_class`, default `confidential`.
An entry that callers appended to the ledger for an entity type that is not a replicated table has no lineage.
It is held by the labels of the row it carries itself (`security_labels`, `partition_ids`, or the labels in `metadata`), and an entry with no row is not held.
The cursor moves past what the gate holds, and the class is read when the row is sent.
A row held then is not sent later because its source package arrived after it, or because a label on its source was lowered; only a new change to the row, or to a row it derives from, is classified again.
So label before writing, and write the source before what derives from it.

A gate reads the workspace once for what it needs to classify many rows: the index of the documents and memories derived from labelled sources, and whether the workspace holds anything above the peer's class.
That scan is kept between gates (a pull of many pages, the next push cycle) while nothing was written: the key is the workspace and the class, and the stamp is the write sequence of the change capture and the ledger, which every write to a replicated table of a syncing workspace moves.
An entry also expires after `config :optimal_engine, :sync_gate_cache_ttl_ms` (default `30000`; `0` turns the cache off), which bounds how long a write that capture does not see, such as an in-place update of a table without a key, can go unnoticed.
A workspace that does not sync is not captured, so it is never cached.
The scans emit `[:optimal_engine, :sync, :gate_build]` telemetry with `what: :index | :holds_above`.

### What a read key sees of exports, conflicts and the ledger

`GET /api/batch/export/{memories,signals,workspace}`, `GET /api/sync/conflicts` and `GET /api/storage/workspaces/:id/mutations` return row text, so they filter by the caller the way governed retrieval does.
A keyed caller sees a row only by the two rules retrieval applies:

- **Labels and partitions**, from the `allowed_security_labels` and `allowed_partitions` in the key's metadata.
Every label the row carries must be granted, so a key with no labels sees only rows with none.
With no partition granted a key sees only rows that have none; with partitions granted it sees the rows that share at least one, and not the rows that have none.
A row drawn from other rows must share a partition with each row it was drawn from that has any, not only with their union: a memory in `team-a` staged from a source package in `team-b` is read only by a key that holds both.
The four class names are not case sensitive (`Restricted` is `restricted`); any other label is compared exactly.
- **The access lists** (`OptimalEngine.Identity.ACL`), for the address of the row: `optimal://memory/<workspace>/<id>` for a memory, the address of a document, `wiki:<slug>:<audience>` for a wiki page.

A row carries the labels and partitions of the rows it was copied or derived from, and a row whose source cannot be found, or a label that cannot be read (not a string, not JSON), is seen by no one.
So a memory staged from a restricted source package is not exported to a key that lacks `restricted`.
A conflict version and a ledger entry show a reader the `row` and `blobs` they were judged by and nothing else; any other key in the payload is not served.
An entry on the storage ledger of an entity type that is not a replicated table is judged by the labels and partitions of the row it carries, if it carries one.
A workspace export holds every wiki page of the workspace (they are read 500 at a time) and fails with `export_failed` when they cannot be read, instead of holding the first 50.
A wiki page that names nothing, and any other aggregate, carries every label of its workspace and needs every partition of it.

A grant of `"*"` (in `allowed_security_labels`, `allowed_partitions`, or both) means every label or every partition, as it does when a key mints another (`Auth.KeyIssuance`).
The bootstrap key (`OPTIMAL_BOOTSTRAP_KEY`) carries `"*"` in both when its scopes (`OPTIMAL_BOOTSTRAP_SCOPES`) include `*` or `admin`, since it is the operator's root and may mint anything anyway, so an exporter that calls with it keeps full exports.
A bootstrap key with only `read,write` scopes, and any other key whose scopes are `["*"]` but that has no grants of its own, holds no `"*"`.
A bootstrap key registered before the grants existed is given `"*"` once, at the next boot, when its scopes include `*` or `admin`; the boot logs a warning and sets `grants_initialized` in the key's metadata.
Narrow it afterwards by replacing the lists (`[]` for none) and the next boot leaves it as it is.
A key minted without `allowed_security_labels` or `allowed_partitions` gets none, never its minter's, whatever the minter holds, so pass the grants you mean.
A minter can only give grants it holds (a minter that holds `"*"` can give any).
For any other key, give the labels it should read.
The recommended default for a machine key is `{"allowed_security_labels": ["public", "internal", "confidential"], "allowed_partitions": []}`: it reads rows labelled public, internal or confidential and rows with no label, and does not read restricted rows, rows with a label of their own (`private`, a team name) or partitioned rows.

An answer says what was left out.
Each of these routes returns `withheld` (how many items were not shown) and `complete` (false when any item was left out or, for conflicts, redacted); the export of a workspace counts its signals, memories and wiki pages together.
A conflict keeps its table, kind and state.
A version of the row the key may not see (as it was recorded, or the row as it is now) is replaced by `{"redacted": "security_labels"}` with `redacted: true` on the conflict, and a key that is a name rather than an id (a wiki page) is replaced by a hash; a conflict about a resource the principal may not read by the access lists is left out and counted.
The ledger route skips what the data-class ceiling holds and what the key may not see, and `withheld` counts both.
An export of a store that cannot be read is a `500`, and a read the gate could not make is a `503`, never a partial answer.
An anonymous local caller (no key, authentication not required) is the trusted operator and sees everything.

**Not covered yet.** These routes still answer by the access lists (or not at all) and not by the labels and partitions of a keyed caller: `GET /api/memory`, `GET /api/memory/:id`, `GET /api/signals/:id`, `GET /api/wiki/:slug`, and the labels on `GET /api/search` and `GET /api/grep` (which apply the access lists only).
A key with `read` reaches them whatever its grants. Do not rely on a key's label grants as a boundary until they follow.

Limits worth knowing:

- Reading what a row derives from is bounded to 10,000 rows not read before for each row classified.
A dense mesh of links that cycles back on itself is `unresolved`: held from a peer and read by no one.
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
