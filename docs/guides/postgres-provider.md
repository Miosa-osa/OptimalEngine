# PostgreSQL Provider

SQLite is the engine's durable local store and stays the default.
A busy workspace needs more than one writer, and one SQLite file has exactly one.
The PostgreSQL provider is how an engine moves its canonical relational store to a server that accepts many concurrent writers without changing what the engine stores or how it is queried.

This guide describes the provider's contract and the staged port.
The provider is not available yet: until the stages below land, the inventory reports `adapter_missing` and `GET /api/storage/providers/postgres` must never say otherwise.

## What The Provider Replaces

The provider replaces the whole canonical store of one engine, not one workspace inside it.
One engine keeps one canonical store, because the `OptimalEngine.Store` process owns a single connection, federated search reads across workspaces, and retention sweeps touch every workspace at once.
Many writers therefore means several engine processes sharing one PostgreSQL database, not several stores inside one engine.

Vectors stay embedded until PostgreSQL with pgvector is available to the tenant.
Vector data is a projection: a replica that re-embeds locally gets the same answers, so the provider may move relational data first and vectors later.

## Configuration

The provider reads one variable and never stores it:

```text
OPTIMAL_POSTGRES_URL=postgres://user:secret@host:5432/database?sslmode=require
```

The URL is parsed into connection options and never logged, returned by an API route, or written to a file.
`GET /api/storage/providers/postgres` reports `configured`, `health`, `adapter_implemented`, and `lifecycle_state` and never the URL.
`mix optimal.postgres.check` prints the same facts for an operator, and redacts the credential.

## Why This Is Staged

The engine does not use Ecto.
It uses `Exqlite` directly: 111 files under `lib/` contain raw SQL, about 725 statements in total.
The measured SQLite-specific surface is:

```text
datetime('now')          260 occurrences in 46 files
strftime(                 52 occurrences in 16 files
INSERT OR IGNORE          66 occurrences in 23 files
INSERT OR REPLACE         13 occurrences in 10 files
json_extract(             31 occurrences in 16 files
AUTOINCREMENT             29 occurrences in  4 files
PRAGMA                    19 occurrences in  9 files
MATCH ?                    4 occurrences in  3 files
CREATE VIRTUAL TABLE       3 occurrences in  3 files
last_insert_rowid          3 occurrences in  3 files
```

A single change that swaps the driver would be unverifiable.
Each stage below has its own acceptance check, and the SQLite path must keep passing its existing tests at every stage.

## Stage 1: Connection And Honest Inventory

Add the driver, parse the URL, probe with a real `SELECT 1`, and report health without claiming the adapter exists.
The provider entry keeps `adapter: nil`, so `lifecycle_state` stays `adapter_missing` while `health` becomes truthful.

Acceptance:

```bash
mix optimal.postgres.check                     # not_configured without the variable
OPTIMAL_POSTGRES_URL=postgres://... mix optimal.postgres.check   # healthy against a reachable database
curl -s "$URL/api/storage/providers/postgres?probe=true" | jq '{configured, health, adapter_implemented, lifecycle_state}'
```

## Stage 2: Dialect Parity, Both Directions

Add a dialect module that rewrites the constructs above and a parity suite that runs the same statement through SQLite and PostgreSQL and compares rows.
No call site changes in this stage.
A construct is only accepted when the parity test covers it, including ordering and null handling.

Acceptance: every construct in the table above has a parity test, and `mix test` is unchanged on the SQLite path.

## Stage 3: Store Behaviour

Turn the `OptimalEngine.Store` API into a behaviour and move the current implementation behind it unchanged.
The PostgreSQL implementation follows, starting with the read paths, then writes, then `transaction/1`.

Two decisions are fixed for this stage:

- The ETS hot cache is disabled when PostgreSQL is the canonical store, because a per-process cache cannot see another engine's writes.
  It returns only with a `LISTEN`/`NOTIFY` invalidation that has its own test.
- `transaction/1` keeps its contract, but each read-check-write sequence that relied on SQLite's single writer takes an explicit row lock (`SELECT ... FOR UPDATE`).
  The lock points are listed in the migration notes, one per call site.

Acceptance: two engine processes writing one workspace through PostgreSQL produce no lost update, and the 20-query parity check matches the embedded copy.

## Stage 4: Moving An Existing Engine

Moving is a one-way switch with a frozen window, not dual writing.

1. Take a verified backup and record its checksum.
2. Stop writes, export every table in dependency order, and import into PostgreSQL inside one transaction.
3. Reconcile row counts and a checksum per table, then run the 20-query parity check.
4. Set `OPTIMAL_POSTGRES_URL`, start the engine, and confirm the same queries through the API.
5. Keep the SQLite file untouched for the rollback window.

Rollback is restoring the backup, because writes accepted by PostgreSQL after the switch do not exist in SQLite.
That is why the window stays short and the parity check runs before the switch.

## Non-Goals

- The engine does not speak the PostgreSQL wire protocol to applications; the Engine API stays the interface.
- The provider does not run a PostgreSQL or Redis server.
- The provider does not move vectors, graph, or assets; those keep their own providers.
