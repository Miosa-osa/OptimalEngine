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
An unreachable peer keeps its status and message and is retried on the next cycle; the local Engine keeps working offline and catches up when the peer returns, in order.

Apply is idempotent by mutation id, in origin order, each change in its own savepoint inside one transaction.
Applied changes are added to the local ledger under their origin device, so a hub forwards them to other replicas, and they are never captured again, so nothing echoes.

The peer key is an API key on the peer limited to the workspace with the `sync` scope (add `read` for status).
Policies per peer: `push`, `pull`, `both`, `none`.
The data-class gate (`max_class`, default `confidential`) applies on send and on receive: a workspace whose `metadata.data_class` is above it is refused whole, and rows whose `security_labels` include a class above it never leave the Engine.

### Syncing through a relay

An Engine that cannot be dialed (a laptop behind NAT is the initiator; a managed Engine in an isolated network cannot dial out to peers) syncs through a relay in front of the other Engine.
Register the peer with a `relay+` URL: `{"url": "relay+https://host/api/v1/engines/<id>/sync", "api_key": "<relay key>", "policy": "both"}`.
Each cycle the local Engine pulls with `GET <base>/pull?workspace=&since=` and pushes with `POST <base>/push`; the bodies are those of `GET|POST /api/sync/changes`.
The local Engine is always the initiator, no peer Engine address is stored, and the same idempotency keys make a repeated cycle change nothing.

## Conflicts

When both sides changed the same row since the last sync, the newer change wins by its time and the conflict is recorded with both versions.
For facts, both versions also become claims in the review queue, so a contested fact is decided by a person.
Changes that cannot be applied (an unknown table or column, a constraint failure) are recorded as `apply_failed` conflicts; nothing is dropped silently.

## Version safety

Every page carries the sender's replica id, Engine version, and schema migration.
A peer on a different migration pauses with `status: paused_version` and a message until both run the same Engine version.

## Seeding a replica

Enable sync on the source, export a workspace bundle (`docs/guides/scope-and-portability.md`), import it on the new replica, and register the peer with `since` set to the bundle's `ledger_sequence`.
The replica then pulls only what happened after the snapshot, so a large workspace never resyncs from zero.
