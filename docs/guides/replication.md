# Replication (local and cloud Engines)

Replication keeps a workspace in step between separate Engines, each with its own disk: a laptop and a cloud Engine, or a workspace Engine and an org Engine.
There is never more than one writer on one data directory.

## How changes are captured

Enabling a workspace (`POST /api/sync/enable {"workspace"}`) installs SQLite triggers on every table that carries a `workspace_id` column.
Every create, update, and delete of that workspace's rows is appended to `sync_capture` in the same transaction as the write, so no write path can skip it.
The Engine seals captured changes into the ordered `sync_mutations` ledger with a SHA-256 of the payload, an idempotency key, and its replica id.
BLOB values (embeddings) travel as hex, so vectors are copied, not recomputed.
Tables keyed by a single integer row id are derivations whose ids differ per Engine; they replicate inserts only (`GET /api/sync/status` lists them).
Tables that hold one Engine's own state are never captured (see What replicates).
Capture seals the whole backlog before anything reads the ledger, a batch of 5000 rows at a time, so a read never misses a change that was already captured.

## What replicates, and what a peer can write

What replicates is an explicit list of workspace knowledge (`Capture.replicated_tables/0`): contexts, chunks and their embeddings, memories and their associations, claims, facts, decisions, episodes, entities and their aliases, mentions and lineage, citations, classifications, intents, clusters, rhythm notes, open loops, observations, source packages, signal events, edges, nodes and node relationships and types, wiki pages, sessions, workflows and their traces, procedural memory, training examples, derivation records and analysis reports.
Every other table is local: it is not captured, not served, not pushed, and a change for it that a peer sends is skipped.
A table nobody has classified is local too, so a new table stays on its Engine until someone adds it to the list, and `test/sync/sync_test.exs` fails until every table with a `workspace_id` is on the list or classified local.
`GET /api/sync/tables` (scope `sync`) returns `{replicated, local_only, migration}` from the same lists, so a relay reads it from each Engine instead of keeping a list of its own.

A table is on the list only if nothing in it grants a capability, reaches outside the database, or names a row that exists on one Engine only.
These stay local, and the reason is the whole decision:

| Tables | Why they stay on their Engine |
| --- | --- |
| `workspace_members`, `node_members`, `principal_skills` | Membership and roles: a peer must never grant access. The rows also name a principal, which exists only on the Engine that created it, so a copy breaks its foreign key at commit |
| `mcp_tool_definitions`, `skill_packages`, `skills`, `routing_rules` | Tools and skills an agent runs, and the rules that steer where intake files documents: a peer must never register or steer them |
| `storage_provider_configs`, `workspace_storage_policies` | How this Engine stores data: a peer must never repoint storage |
| `model_call_operations`, `model_adapters` | Which models this Engine runs; an adapter's artifact is a file on the Engine that trained it |
| `data_collections`, `data_changes`, `data_files`, `data_schema_migrations` | A collection's `table_name` is interpolated into the SQL that serves it |
| `assets` and every `asset_*` table | `storage_path` names a file on the Engine's disk or a bucket, and asset files do not sync |
| `surfacing_subscriptions` | Decoded into atoms |
| `model_call_runs`, `tool_call_runs`, `decomposition_runs`, `training_runs`, `evaluation_runs`, `evaluation_cases`, `context_packages`, `active_memory_pools`, `export_records`, `projection_revisions`, `link_health_records` | What this Engine executed or wrote out, and what is derived from it: destinations are paths on it, and both Engines would write the same object to the same destination |
| `events`, `surfacing_events`, `audit_samples` | Telemetry whose ids differ per Engine |
| `architectures`, `rhythm_templates`, `topology_change_requests`, `resolution_decisions` | Configuration or review state kept per Engine |
| `connectors`, `connector_runs` | Credentials sealed with this Engine's `CONNECTOR_KEY`, per-Engine cursors and run logs |
| `jobs`, `dead_letter_jobs` | Each Engine enqueues and runs its own jobs; a row from another Engine would collide on the idempotency key or run twice |
| `sync_*` bookkeeping, `workspaces`, `workspace_handles`, `processor_runs`, `metric_samples`, `uri_redirects`, `federation_peers`, every `authority_*` table | This Engine's own state |

A workspace bundle (a move or a copy of a whole workspace) still carries every local table except the Engine state and authority state in the last three rows: it takes the workspace's state.
Any of these can be reopened later with a reviewed design.
`memory_reconstruction_runs` looks like a run log and replicates, because association paths and outcomes point at it; a replicated table's foreign keys must point at replicated tables (or `workspaces`, `tenants`, `organizations`), and a test checks that.

A trigger an older version left on a table that does not replicate is dropped when the Engine starts, and what it captured but had not sealed is discarded.
The ledger rows an older version wrote for such a table are removed at the same time, a batch of 5000 at a time (the log says how many, per table), and are in any case never served or pushed.
Of the tables that grant access or hold Engine state (`api_keys`, `principals`, `roles`, `tenants`, `schema_migrations`, `workspaces`, `sync_peers` and every `authority_*` table) each ledger row is logged before it is removed, with its mutation id, entity id, device and time, never its payload.
The purge runs once for each version of the replicated list (the list's version is kept in the database file), so a later boot does not scan the ledger; taking a table off the list drops its unsent ledger rows at the next boot.
Rows those entries wrote into the tables themselves are not touched: a table that is not on the list can hold a row no one on this Engine wrote (an `api_keys` or `principals` row a peer pushed before this change), and only its operator can tell, so check them.

The sender names the table of each change it applies, so applying is an allow-list.
A change for a table that is local by name is skipped and counted under `skipped.local_only`; a change for any other table (API keys, principals, roles, tenants, schema migrations, ...) is refused with `table_not_replicated`, recorded as an `apply_failed` conflict, and never written.
A key holding only the `sync` scope can therefore write replicated workspace knowledge and nothing else.
That is still all of it: such a key speaks for the workspace's knowledge, its review state and its labels, so issue a sync key only to Engines you control.
A page that mixes allowed, skipped and refused changes applies the allowed ones and answers `200` with the counts, so the sender's push cursor moves; one disallowed row never refuses the page.
Every batch that reaches apply answers `200` with counts (`applied`, `skipped`, `failed`, `conflicts`).
The refusals before it are the 4xx answers: `422 workspace_class_above_gate` (the workspace is classed above the receiving peer's `max_class`), `422` with the reason for a commit that failed for a cause other than a foreign key, `422 mutations_required` when `mutations` is missing or not a list, `409 version_mismatch` and `409 sync_not_enabled`.
The data-class gate applies to the row a change would replace as well as to the change: a delete carries no labels, so a peer limited to `confidential` that deletes or overwrites a row labelled `restricted` is skipped under `gated` and the row stays as it is.
`GET /api/sync/changes` serves a page by the `max_class` of the Engine that pulls, not by the label grants of the key that asks, so a key-level enforcement of labels on the pull route is a later change.

Every applied row is written into the tenant and workspace of the apply, whatever the payload claims.
A change whose key already exists in another tenant or workspace (a key is often just `id`) is refused with `cross_scope`, so an upsert or a delete cannot reach a row of another workspace.
A change that lacks its key is refused with `missing_key`, a delete on a table keyed by a row id with `operation_not_supported`, and a payload name (a row column or a blob) that is not a column of the table with `unknown_columns`.
Columns that name a place on this Engine's disk are confined: `nodes.slug`, `nodes.path`, `node_types.slug` and `wiki_pages.slug` must be relative, without a parent segment or a NUL, or the change is refused with `invalid_path`; `contexts.path` is the absolute path of the file on the Engine that indexed it, so an absolute value is stored as NULL and the rest of the context replicates.
A change that is malformed (a missing field, an `occurred_at` that is not text, an unknown operation, a payload that is not a row, a value that is not a scalar, a blob that is not hex) fails alone with `invalid_mutation`, `invalid_occurred_at` or `invalid_payload`; the rest of the batch applies.
Foreign keys are checked at commit so that a child may arrive before its parent in one batch; when that commit fails, the batch runs again with every key checked as its row is written, a row refused for its key is tried once more after the rest of the page (so a child that came before its parent still lands), and the rows that name something this Engine lacks fail alone.
A `contexts` or `classifications` row whose `mode`, `signal_type` or `format` is not one of the values this Engine writes is refused with `invalid_signal_value`; stored values are read back as atoms from those fixed sets only, so a peer cannot grow the atom table.
A blob named for a confined column (`nodes.path`, `contexts.path`, ...) is refused with `invalid_path`: it would be written over the checked value.

## How changes move

| Route | Scope | Purpose |
| --- | --- | --- |
| `GET /api/sync/changes?workspace=&since=` | `sync` | Ledger page after a sequence, never the requester's own changes (header `x-optimal-replica`); the page says `cursor`, `more`, `head` (the highest sequence of this workspace's ledger) and the `engine` envelope with the replica id |
| `GET /api/sync/tables` | `sync` | The tables this Engine replicates and the ones it keeps local, with its schema migration |
| `POST /api/sync/changes {workspace, engine, replica_id, base_seq, base_replica_id, mutations}` | `sync` | Apply a peer's batch; `base_seq` is this Engine's ledger sequence the sender had pulled, `base_replica_id` the replica it believed that ledger was, `replica_id` the sender (see Conflicts); the reply says which base it used (`base`) |
| `POST /api/sync/peers {workspace, url, api_key, policy, max_class, since?}` | admin | Register a peer; its key is encrypted with `CONNECTOR_KEY` |
| `POST /api/sync/run` | admin | Run one pull and push cycle now |
| `GET /api/sync/status?workspace=` | read | Ledger sequence, peers (status, cursors, `pulled_local_seq` (the pull floor), pending changes), open conflicts in total (`open_conflicts`) and per table (`conflicts_by_table`) |
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
So is a link that names no table (an id in a `citation_uri` or in the body of a wiki page) when the row it names was deleted: the ledger recorded which table it was in.
An id the ledger never saw is only text that looks like an id and names nothing; a workspace that does not sync has no ledger, so a link in it to a row that was deleted is not caught.
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
When the row is gone, it is read as the ledger last recorded it (every version it has there, newest 20), so a version written before the row was labelled and then deleted stays home with the labelled versions.
- A delete carries only the row's key.
It stays home when the row's earlier changes in the local ledger were held, so a peer that never had the row is not told of it.

Receiving reads what a row carries: its `security_labels`, the `security_labels` in its `metadata`, or its `classification_level`.
A batch arrives with its sources possibly not yet here, so the sender's gate is the one that follows lineage.

Labels only grow when a change is applied.
A row this Engine already holds keeps the `security_labels`, the `partition_ids`, the `metadata.security_labels` and `metadata.partition_ids`, and the `classification_level` (above `internal`) it has, whatever the sender wrote and however old its change is: the two sets of labels are joined, and a higher level wins.
Labels held here that cannot be read count as `restricted`.
A change that carries everything the row holds is written as sent.
A delete or an overwrite from a peer is not applied to a row this Engine holds above the class that peer is cleared for (the peer was never sent it): the change is skipped as `gated` and the row stays.
The link columns of a row (`source_package_id`, `signal_id`, the `memory_core_source_package_id` in a memory's metadata, and the like) are not kept: a change from a peer may repoint them, as an ordinary edit does.
A row that carries labels of its own keeps them whatever its links say; a legacy row that is classified only through the rows it links to is classified through the links it has after the change.
Labels never shrink on a replica through sync, so lowering a label (declassifying) has to be done on each replica.
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
That scan is kept between gates (a pull of many pages, the next push cycle) while nothing was written: the key is the scan, the tenant, the workspace, the kind of gate (a peer's or a reader's) and the class, and the stamp is the write sequence of the change capture and the ledger (`sync_capture` and `sync_mutations` in `sqlite_sequence`), which every write to a replicated table of a syncing workspace moves.
The stamp is read just before each scan, not once per gate, so a long push cycle that needs a scan late does not use an older stamp.
A table the gate scans that stays on its Engine (`assets`, `active_memory_pools`, `context_packages`, the model and tool run tables, `skill_packages`, `mcp_tool_definitions`) is not captured, so triggers on it move a third counter, `sync_local_stamp`, which keeps no row.
They fire for the rows of a workspace that syncs, for an insert, a delete, and an update that writes a column the gate reads (the labels, the metadata or the class); a status written on every call leaves the scan alone.
An entry also expires after `config :optimal_engine, :sync_gate_cache_ttl_ms` (default `30000`; `0` turns the cache off), which is a backstop for a write that nothing sees; every table the gate scans is captured or stamped, and a test pins that.
The cache is dropped after a change from a peer is applied and when sync is enabled or disabled for a workspace.
A workspace that does not sync is not captured, so it is never cached.
The scans emit `[:optimal_engine, :sync, :gate_build]` telemetry with `what: :index | :holds_above` and the `workspace_id`.

### What a read key sees of exports, conflicts and the ledger

`GET /api/batch/export/{memories,signals,workspace}`, `GET /api/sync/conflicts` and `GET /api/storage/workspaces/:id/mutations` return row text, so they filter by the caller the way governed retrieval does.
A keyed caller sees a row only by the two rules retrieval applies:

- **Labels and partitions**, from the `allowed_security_labels` and `allowed_partitions` in the key's metadata.
Every label the row carries must be granted, so a key with no labels sees only rows with none.
With no partition granted a key sees only rows that have none; with partitions granted it sees the rows that share at least one, and not the rows that have none.
A row drawn from other rows must share a partition with each row it was drawn from that has any, not only with their union: a memory in `team-a` staged from a source package in `team-b` is read only by a key that holds both.
The four class names are not case sensitive (`Restricted` is `restricted`); any other label is compared exactly.
- **The access lists** (`OptimalEngine.Identity.ACL`), for the address of the row: `optimal://memory/<workspace>/<id>` for a memory, the address of a document, `wiki:<slug>:<audience>` for a wiki page.

A row carries the labels and partitions of the rows it was copied or derived from.
A row whose source cannot be found, or whose partitions cannot be read, is seen only by a key granted every label and every partition (`"*"` for both); a key granted every label and only some partitions does not see it.
A label that cannot be read (not a string, not JSON) is seen by no key but one granted every label.
A metadata that repeats `security_labels` or `partition_ids` is read as unresolved, because two readers of the same text would disagree on which of the two counts.
So a memory staged from a restricted source package is not exported to a key that lacks `restricted`.
A conflict version and a ledger entry show a reader the `row` and `blobs` they were judged by and nothing else; any other key in the payload is not served.
An entry on the storage ledger of an entity type that is not a replicated table is judged by the labels and partitions of the row it carries, if it carries one.
A workspace export holds every wiki page of the workspace (they are read 500 at a time) and fails with `export_failed` when they cannot be read, instead of holding the first 50.
A wiki page that names nothing, and any other aggregate, carries every label of its workspace and needs every partition of it.

The exports and the conflict list are also held to the Engine's ceiling for what it hands out (`config :optimal_engine, :sync_serve_max_class`, default `confidential`), as a replication peer is: a key that is not granted `"*"` for labels is not shown a restricted row even when it is granted `restricted`, and `withheld` counts it.
Raise the ceiling, or call with a `"*"` key such as the bootstrap key, for a full export.
The ledger route has always been held to it, for every caller.

A grant of `"*"` (in `allowed_security_labels`, `allowed_partitions`, or both) means every label or every partition, as it does when a key mints another (`Auth.KeyIssuance`).
The bootstrap key (`OPTIMAL_BOOTSTRAP_KEY`) carries `"*"` in both when its scopes (`OPTIMAL_BOOTSTRAP_SCOPES`) include `*` or `admin`, since it is the operator's root and may mint anything anyway, so an exporter that calls with it keeps full exports.
A bootstrap key with only `read,write` scopes, and any other key whose scopes are `["*"]` but that has no grants of its own, holds no `"*"`.
A bootstrap key registered before the grants existed is given `"*"` once, at the next boot, when its scopes include `*` or `admin`; the boot logs a warning and sets `grants_initialized` in the key's metadata.
Narrow it afterwards by replacing the lists (`[]` for none) and the next boot leaves it as it is.
`OPTIMAL_BOOTSTRAP_SCOPES` and `OPTIMAL_BOOTSTRAP_WORKSPACES` are applied to an existing bootstrap key at every boot when they are set, with a warning in the log when they differ from what it holds; when one is not set, or is blank, the key keeps what it holds (the defaults, `read,write` and `*`, are those of a key that is being created).
A scope this API does not know (`admin` misspelled, say) fails the boot like a malformed token.
A key that stops being root loses its `"*"` grants (a list that held only `"*"` is removed, a list the operator set is left as it is), and a key that becomes root is given them once, as above, so a key made root, demoted and made root again holds them again.
A narrowing of the scopes or the workspaces made in the database is undone at the next boot when the variable is set.
Rotating the token (a new `OPTIMAL_BOOTSTRAP_KEY`) registers a new key with the defaults for its scopes and revokes the old one; grants narrowed on the old key are not carried over.
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
| Push | `POST <base>/push` with `{workspace, replica_id, engine, base_seq, base_replica_id, mutations}` | Sends the local ledger a page at a time, with the sender's `engine` envelope, its pull cursor as `base_seq` and the peer's replica id as `base_replica_id`, and no cursor of its own; moves its push cursor only after a 2xx answer that reports `applied` |

The relay wraps answers in `{"data": ...}` and refusals in `{"error": {"code", "message"}}`; the client reads both, and a direct peer's unwrapped answers too.
Pushed mutations carry the full ledger shape, `sequence` included, exactly as `GET /api/sync/changes` returns them.
The relay must forward the push body unchanged: `base_seq` as a JSON integer, and `base_replica_id` and `replica_id` as they are.
`base_seq` is a sequence of the managed Engine's `sync_mutations`, the numbering its pull pages use for `cursor`, so what the laptop sends back is what the managed Engine gave it.
The managed Engine's refusals pass through unchanged, including `422` with `invalid_base_seq` (not a non-negative integer: a float, a negative, text), `invalid_base_replica_id` and `invalid_replica_id`; the client reports them as the peer's error.
The reply to a push says which base was used: `base` is `"seq"` or `"unknown"` (`"floor"` is a pull's), and `base_rejected` (`above_head`, `replica_mismatch`) says why a base that was sent was not trusted.
When a reply carries `base_rejected`, the peer's `message` says so (the status stays `active`): it means the relay does not report the managed Engine's own replica id, so every concurrent change was judged conservatively.
Both Engines must run the same schema migration, and the pull floor adds one (`sync_peers.pulled_local_seq`), so a laptop that has this change and a managed Engine that does not pause each other (`status: paused_version`, see Version safety): the two upgrade together.
Roll it out in this order: update the managed Engine first, then the laptops. A laptop that runs ahead keeps working on its own and pauses its peer; it resumes by itself in the first cycle after the managed Engine runs the same migration, with nothing lost, because nothing was pulled or pushed while it was paused. A managed Engine that is updated first is paused from the laptops' side the same way, until each laptop is updated.
A managed Engine on the same migration that predates `base_seq` and `base_replica_id` ignores them and applies the push with the conservative check, which records every conflict as `unknown_base`.
A page whose rows all stay home under the data-class gate is not sent, and the push cursor still moves past it.
A page the relay refuses as too large (`413`) is sent again as pages half its size.
When an answer is lost after the other side applied a page (a timeout or a `502`), the cursor stays, the next cycle sends the page again, and the other side applies none of it twice.
The relay does not forward `x-optimal-replica`, so the local Engine's own changes come back on the next pull; they are skipped as its own, never applied twice, and never pushed back.
A `409` with code `version_mismatch` pauses the peer (`status: paused_version`) and nothing is retried that cycle; while paused, a cycle makes only the status call, and sync resumes when both run the same migration.
Any other refusal (`403` without `engine:sync`, `404` not this tenant's Engine or workspace, `409 engine_not_running`) leaves the peer in `status: error` with the code and message, and the next cycle tries again.
The message never carries the peer key or anything shaped like a key (a bearer token, a prefixed key, a long opaque token), even when the relay echoes one back.
The local Engine is always the initiator, no peer Engine address is stored, and the same idempotency keys make a repeated cycle change nothing.
If the peer answers as another replica id than the one its cursors were kept for (the Engine behind the URL was replaced, or restored under a new identity), its ledger sequences mean nothing to them: both cursors and the pull floor go back to zero, everything is pulled and pushed again (the mutation ids make that idempotent), and the change is kept as a resolved conflict of kind `peer_replaced` (`detail` has the reason, the old and new replica ids and the cursors it replaced).
The same reset follows a peer whose change page reports a `head` below this Engine's pull cursor: the same Engine restored from an older copy, whose ledger ends before the cursor.
A reset happens once in a run and not again for ten minutes: a peer that keeps changing its answer (a relay in front of two Engines, or a status that names another replica than the change pages) is reported as `peer_identity_unstable` in the peer's `message` (`status: error`), its cursors stay where the one reset left them, and nothing is pulled or pushed again from zero each cycle.
After such a pull nothing is pushed in the run, and a push whose reply names another replica than the peer's (`engine.replica_id`) is an error that leaves the push cursor where it was: the page went to another Engine.
A peer reset twice in a day and meeting a third change of identity is `halted` (`status: halted`, `peer_halted`): it is no longer run, and adding it again (`POST /api/sync/peers`) is the operator's word that the Engine behind the URL is settled, which clears the count.
A change page that does not say which replica sent it (`engine.replica_id`) is refused (`peer_replica_unreported`), and a peer's known replica id is never overwritten by a missing one.

`scripts/proof-relay-client.sh` proves the relay client end to end against a managed Engine (`RELAY_BASE`, `MIOSA_API_KEY_FILE`, `WORKSPACE`), and `--stand-in` runs the same checks against a second local Engine behind a relay stand-in.
Run it on a disposable machine, never on one that holds a live store; it removes its temporary data, keys included, when it exits (`KEEP_DATA=1` keeps it).
Its conflict check edits a daily note on both sides; that a contested fact becomes two claims in the review queue is proven by `test/sync/sync_test.exs`, not by this script.

## Conflicts

Concurrency is ledger order; the winner is the clock.
Two changes of a row are concurrent when the Engine that made the later-arriving one had not seen the other.
What the sender had seen is decided at apply time:

- A push carries `base_seq`, the receiver's ledger sequence the sender had pulled, `base_replica_id`, the replica the sender believed that ledger belonged to, and `replica_id`, the sender.
  The receiver takes its latest change to the row by any device other than the sender and the change's origin (their order is the sender's ledger's).
  If that change comes after `base_seq` in its ledger, the edit is concurrent.
  If it comes at or before `base_seq`, the sender had seen it: there is no conflict and no clock check, and the incoming change is applied.
- A pull is judged against a floor, `pulled_local_seq`, a sequence of this Engine's own ledger, and only against this Engine's own changes.
  The floor is this Engine's ledger head at the start of the last cycle with that peer in which the pull reached the end of the peer's ledger and the push sent everything.
  Its own changes at or below the floor were pushed in a complete cycle and count as seen by the peer; the ones after it are concurrent.
  The floor moves forward only after such a cycle: if the pull stopped with `more`, or the push stopped at its page or time budget with rows left, it stays, so a change that may not have reached the peer is never taken as seen.
  Until the first complete cycle there is no floor (it is zero): every change of this Engine's own counts as concurrent, and the conflicts are recorded as `unknown_base`.
  `last_sync_at` is the start of that last complete cycle, for display; it decides nothing.
  The floor is a sequence of this ledger, so the two Engines' clocks do not enter into which changes were seen.
  A peer this Engine only pulls from (`policy: pull`) never receives its changes, so none counts as seen: its floor stays at zero and the clock decides each.
  It is an approximation: a change the peer received in the same cycle that it edited the row in is below the floor, so the peer's edit is taken as made after seeing it; an edit the peer made before that change reached it, while this Engine's pull was already past, is decided by the clock.
- A base that cannot be trusted counts as none, and its conflicts are `unknown_base`: no `base_seq` (absent or `null`), a `base_seq` above the head of this workspace's ledger, or a `base_replica_id` that is not this Engine's (the sequence is another ledger's).
  Zero claims nothing seen and needs no replica to vouch for it.

Skipping the clock check for what the sender had seen is sound because a sender pushes only what stands after what it took from the peer.
A change of its own that the peer's change came after in the sender's ledger was overwritten there, so the peer already holds the winner: it is not sent (`superseded` in the push result, and it no longer counts as pending).
What is sent is a change made after the sender pulled, or one that won against the peer's.
So a causally later edit wins even when its clock is behind.

Of two concurrent changes the newer wins by its time, the greater device id on a tie, so both Engines keep the same version.
The times are the two Engines' own clocks: an Engine whose clock runs behind loses concurrent edits it made later, by as much as it runs behind, and a change that is not concurrent (the sender had seen the other) never goes by the clock at all.
The conflict is recorded with both versions.
A change this Engine did not take (the local one was newer) is not put in its ledger, so a hub never forwards it; the conflict is recorded once, however many times the change is delivered.
A mutation id is global in the ledger and a sender chooses it, so a conflict's id comes from the tenant, the workspace, the mutation id and the resolution, and a mutation id that another workspace or tenant already used is refused (`mutation_id_in_use`), not skipped as a repeat.
The ids this Engine gives its own changes (`mut_<replica id>_<n>`, and idempotency keys `<replica id>:<n>`) are its own: a change from another device that carries one, as its id or as its key, is refused with `mutation_id_in_use`, because the ledger keeps the first row with an id or a key and the Engine's own change would never be sealed.
A mutation id with a colon (the shape of a capture key) is refused with `invalid_mutation_id`.
The `payload_hash` and the `idempotency_key` in the ledger are set here, from the payload and the mutation id; what the sender claims for them is not stored, and an `idempotency_key` that is not text is `invalid_mutation`.
The key of a change applied from a peer is `peer:<mutation id>`, apart from the keys capture gives, so no applied change can hold one.
The row a change belongs to is named by its payload's key columns, not by the `entity_id` the sender sends: the conflict check and the ledger use the key the payload gives.
A delete carries only the row's key: it is the same change as another delete and as nothing else, so an older delete does not beat a newer update here.
A concurrent edit is recorded where it is seen: an initiator pulls before it pushes, so it records the conflict when the other Engine's change arrives, and its push then carries a `base_seq` that covers that change; the other Engine keeps the newer version without a second record, and records a conflict itself only when its own change came after the initiator's last pull.
For facts, both versions also become claims in the review queue, so a contested fact is decided by a person.
The claims quote the fact, so they carry the labels of both versions and of the fact as it is stored, and they name the fact (`metadata.fact_id`, on the claims and on the source package that holds the conflict text): they stay home as long as the fact does, including when it is labelled higher later.
Changes that cannot be applied (a table that does not replicate, an unknown table or column, a key in another workspace, a constraint failure) are recorded as `apply_failed` conflicts; nothing is dropped silently.

Every conflict says why (`GET /api/sync/conflicts`):

| `kind` | Meaning |
| --- | --- |
| `concurrent_edit` | Both Engines changed the row since the base (a push's `base_seq`, or a pull's floor) |
| `fact_divergence` | A concurrent edit of a fact; both versions also become claims |
| `unknown_base` | There was no base to judge against (none sent, one that could not be trusted, or a first pull), so any change of the row counted as concurrent |
| `apply_failed` | The change could not be applied; `detail` is the reason |
| `peer_replaced` | The peer answered as another replica, or its ledger ended before the cursor; its cursors were reset (resolved at once) |
| `superseded` | A change of this Engine's that was not pushed because the peer's change to the row came after it in this ledger, so the peer already holds the winner (resolved at once; `detail` has the later change's device and sequence) |
| `concurrent_change` | The kind rows recorded before kinds existed keep; they mean `concurrent_edit` |

For the first three, `detail` holds `mutation_id`, `local_seq` and `local_device` (the local change's ledger sequence and origin), `base_seq` (on a push), `local_floor` (on a pull), `local_occurred_at`, `remote_occurred_at`, and `resolution` (`kept_local_newer` or `applied_remote_newer`).
`GET /api/sync/status` counts open conflicts in total (`open_conflicts`) and per table (`conflicts_by_table`).

Scope.
Replication is built for two Engines, a laptop and a cloud Engine.
A cloud Engine that several laptops sync with follows the same rules: it judges each laptop's push against every other device's changes in its ledger, a third replica's included, and it forwards only changes it applied.
Engines that sync with each other and with a hub as well, so that one change can reach an Engine by two paths, are not covered.

A replica key is trusted to report what its holder saw: a `base_seq` that passes the checks above (this Engine's replica id, not past the workspace's head) is believed, and a `replica_id` that names this Engine itself is ignored.
A key that can push can already write every replicated table of the workspace, so a forged base lets it choose which of its own changes are called concurrent, not reach anything else.

## Version safety

Every page carries the sender's replica id, Engine version, and schema migration (the highest migration this Engine has).
A peer on a different migration pauses with `status: paused_version` and a message until both run the same Engine version, so two Engines that sync are upgraded together: the pause costs nothing but time, and both resume in the first cycle after they match.

## Seeding a replica

Enable sync on the source, export a workspace bundle (`docs/guides/scope-and-portability.md`), import it on the new replica, and register the peer with `since` set to the bundle's `ledger_sequence`.
The replica then pulls only what happened after the snapshot, so a large workspace never resyncs from zero.
