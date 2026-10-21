# PostgreSQL Provider

SQLite is the engine's durable local store and stays the default.
A busy workspace needs more than one writer, and one SQLite file has exactly one.
The PostgreSQL provider is how an engine moves its canonical relational store to a server that accepts many concurrent writers without changing what the engine stores or how it is queried.

This guide describes the provider's contract and the staged port.
Stages 1 to 3 have landed: `OptimalEngine.Store.Postgres` implements the canonical store contract on PostgreSQL, and the inventory reports the adapter.
Stage 4, moving an existing engine, has not.

## What The Provider Replaces

The provider replaces the whole canonical store of one engine, not one workspace inside it.
One engine keeps one canonical store, because the `OptimalEngine.Store` process owns a single connection, federated search reads across workspaces, and retention sweeps touch every workspace at once.
Many writers therefore means several engine processes sharing one PostgreSQL database, not several stores inside one engine.

Vectors stay embedded until PostgreSQL with pgvector is available to the tenant.
Vector data is a projection: a replica that re-embeds locally gets the same answers, so the provider may move relational data first and vectors later.

## Configuration

The provider reads its connection from one variable and never stores it:

```text
OPTIMAL_POSTGRES_URL=postgres://user:secret@host:5432/database?sslmode=require
OPTIMAL_POSTGRES_SCHEMA=public
```

The URL is parsed into connection options and never logged, returned by an API route, or written to a file.
`OPTIMAL_POSTGRES_SCHEMA` names the PostgreSQL schema the store's tables live in (default `public`): engines that share a workspace share the schema, and engines that must not see each other's data use different ones.
`GET /api/storage/providers/postgres` reports `configured`, `health`, `adapter_implemented`, `lifecycle_state`, and `selected` and never the URL.
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

Stage 3 landed in four slices, each its own change with the full suite green:

1. Schema and connection: the PostgreSQL schema, the connection pool, and the boundary that runs the engine's SQLite statements on PostgreSQL.
2. Read paths of `OptimalEngine.Store.Postgres`.
3. Write paths and `transaction/2`.
4. The two-writer proof and the 20-query parity check.

### One Schema Definition

The SQLite migrations stay the only schema definition.
`OptimalEngine.Store.Postgres.Schema` runs them against an in-memory SQLite database, reads the result back through SQLite's catalog, and derives the PostgreSQL tables, keys, unique indexes, check constraints, foreign keys, indexes, views, defaults, and the rows the migrations insert.
A new migration is picked up by the next build with no PostgreSQL work, unless it moves or changes data.

| SQLite | PostgreSQL |
| --- | --- |
| `INTEGER PRIMARY KEY` | `BIGINT GENERATED BY DEFAULT AS IDENTITY` |
| INTEGER affinity, `BOOLEAN` | `BIGINT` |
| TEXT affinity, `DATE`, `DATETIME`, `JSON` | `TEXT COLLATE "C"` |
| REAL affinity, `NUMERIC` | `DOUBLE PRECISION` |
| `BLOB` | `BYTEA` |
| unique keys, checks, foreign keys, indexes | objects named with a hash of their definition |
| foreign keys | `DEFERRABLE INITIALLY IMMEDIATE` |

Text uses the `C` collation, so text sorts and compares byte by byte, as SQLite's default `BINARY` collation does, whatever the database locale.

The derivation fails loudly: a column type, default, check, index, expression unique key, foreign key to a table without a key, trigger, reserved or mixed-case name, or seeded table without a key that it cannot carry stops the derivation, and the store does not start.
Only the FTS5 tables and the triggers that maintain them are skipped, by name; a trigger that writes any other table fails the derivation.
A view PostgreSQL cannot run is reported, not fatal.
`test/store/postgres/schema_derivation_test.exs` runs every statement of every migration through the translator, so a migration PostgreSQL cannot take fails CI, not a database.

A migration that moves or changes data (`UPDATE`, `DELETE`, `INSERT`, a table drop, a column drop, a rename, a table rebuild) needs a declared PostgreSQL step in `OptimalEngine.Store.Postgres.Steps` once it is above the baseline.
The derivation refuses to run while one is missing.
No PostgreSQL store predates the baseline, so older migrations never run on PostgreSQL.
Until the first PostgreSQL store is deployed, the baseline is the newest migration: a new migration needs no step, because a database is created in its final shape, and a database an older build created is refused as drift.
The release that deploys the first PostgreSQL store freezes the baseline (`@frozen_baseline` in `OptimalEngine.Store.Postgres.Steps`, see the versioning and releases guide); from then on every new data statement needs its step.

Applying the schema runs in one transaction under an advisory lock, so engines that start together against one database apply it once:

1. A database with no recorded migration versions and none of the tables is fresh: it is created in the derived shape and gets the rows the migrations insert, once.
2. Otherwise, the versions it lacks are pending: their tables and columns are added, their declared steps run, and the versions are recorded; seed rows are never inserted again.
3. Every unique index, index, check and foreign key the plan has is created, and a check, foreign key or unique index on the store's tables that the plan does not have is dropped, so a changed constraint never keeps its old definition; any rejection fails the sync.
4. The live catalog is compared with the plan: every table, column type, collation, `NOT NULL`, identity, default, primary key, index, check, foreign key, and the recorded versions.
   Any difference rolls the sync back with `{:error, {:schema_drift, differences}}`.

A database that records a version this build does not have is refused with `{:error, {:schema_newer, versions}}`.
An unchanged fingerprint of the derived DDL skips straight to the comparison.

### Statements And Results

Engine code keeps writing SQLite statements.
`OptimalEngine.Store.Postgres.Connection` translates each one with the stage 2 dialect, binds parameters with SQLite's type affinity, and returns rows and errors the way SQLite returns them:

- An integer bound to a text column is stored as text, integer text bound to an integer column is stored as an integer, and `{:blob, data}` binds to `BYTEA`.
- `SUM` over integers returns an integer, `AVG` a float, and a comparison in a select list returns 1 or 0.
- A unique, not-null, foreign key, or check violation and a missing table or column read as the SQLite message, because callers read those messages for control flow.
- `LIKE` becomes `ILIKE (pattern) COLLATE "C" ESCAPE ''`: SQLite's `LIKE` ignores the case of ASCII letters only and has no escape character, and so does this.
- `ORDER BY` terms get `NULLS FIRST` ascending and `NULLS LAST` descending, SQLite's order.
- `datetime('now')` is the statement's time, as on SQLite, not the transaction's.
- `json_extract` compared to a value compares JSON values, so a JSON number never equals text; its placeholder must be bound to text.
  Selected, it is the value as text, so a JSON number comes back as its text; an ordered comparison or an `ORDER BY` on it is refused.
- An `INSERT` that writes an identity column explicitly moves the column's sequence past the largest id, as SQLite's rowid does.
- A construct the dialect refuses, a schema change outside the migrations, and a transaction statement return `{:error, {:unsupported, name}}` and never reach the database.

### What Does Not Work On PostgreSQL

These features are not on the PostgreSQL store yet.
`OptimalEngine.Storage.Postgres.unavailable/0` lists them, `GET /api/storage/providers/postgres` and `mix optimal.postgres.check` report them, and each is refused by name when it is used, never answered as if it worked:

| Feature | On a PostgreSQL store |
| --- | --- |
| Replication | Capture is SQLite triggers and applying reads SQLite's catalog. Enabling sync and adding a peer return `{:error, {:unsupported, "replication is not available on the PostgreSQL store"}}`, and the API answers 501. |
| App data collections | A collection creates a table, a full-text index and triggers at runtime. Creating one is refused, and so is any schema change outside the migrations. |
| Full-text search | The FTS5 tables are not created. Search, context assembly and asking return `{:error, {:unsupported, "full-text search is not available on the PostgreSQL store"}}`, and a `MATCH` statement is refused, until a slice ports search to `tsvector`. |
| SQLite JSON functions | `json_set`, `json_each`, `json()`, `json_array_length` and the rest, and the `json_extract` forms PostgreSQL cannot compare as SQLite does (an ordered comparison, `ORDER BY` on it, a comparison to an expression or a non-text value), are refused at their call sites (routing placement, memory partition and security label filters, reconstruction learning). |
| Date arithmetic | A `datetime` or `strftime` with a computed modifier or another format, `julianday`, `unixepoch`, `date()` and `time()` are refused (viability metrics, retention windows). |
| The SQLite catalog | `PRAGMA`, `sqlite_master` and the `pragma_*` functions are refused (workspace bundles, the data steward's table list, a workspace slug change, replication). |
| `rowid` | A statement that orders or filters by `rowid`, or reads `last_insert_rowid()`, is refused (backup schedules, the storage audit, graph edge listings, model call history, a workspace slug change). |
| Other SQLite functions | `group_concat`, `typeof`, `instr`, `printf` and the rest, `GLOB`, SQLite's collations and a `LIKE` with a computed pattern are refused (action chain lists, clusters, insight health). |
| Replace writes | `INSERT OR REPLACE`, `REPLACE INTO` and an `INSERT OR IGNORE` with its own `ON CONFLICT` are refused at their call sites; the store's context and chunk writes replace rows as SQLite does. |
| Schema and transaction statements | The schema comes from the migrations and transactions from the store, so a schema change, a transaction statement sent as a statement, and SQLite-only table options (`AUTOINCREMENT`, `WITHOUT ROWID`) are refused. |

`OptimalEngine.Store.Dialect.refusals/0` lists every refused construct with its reason, and `test/store/postgres/unavailable_test.exs` checks both ways: every refusal of the dialect is under a feature here, and every name a feature lists is one the dialect or the store refuses with.

A store that finds replication or app data collection data in its database does not start: `{:postgres_store_failed, {:unsupported_in_use, features}}`.
An engine moved there from SQLite would otherwise run on and silently stop replicating, or stop serving its collections.

### Decisions

- The ETS hot cache is disabled when PostgreSQL is the canonical store, because a per-process cache cannot see another engine's writes.
  It returns only with a `LISTEN`/`NOTIFY` invalidation that has its own test.
- `transaction/2` keeps its contract, and every transaction runs at `SERIALIZABLE` instead of taking per-call-site row locks.

The second decision replaces the earlier plan of one `SELECT ... FOR UPDATE` per call site.
An audit of the 51 `Store.transaction` call sites found eight that check for an absent row or a maximum before inserting (an upsert, `MAX(seq) + 1`, a version counter, the head of a hash chain).
A row lock cannot protect a row that does not exist yet, so those eight would each need an advisory lock of their own, and a missed lock point would be a silent lost update.
At `SERIALIZABLE`, PostgreSQL aborts one side of any interleaving that no serial order could produce, for every call site, including ones written later.
Every transaction begins with `BEGIN ISOLATION LEVEL SERIALIZABLE`, and each connection is checked on connect for its isolation and `search_path`.
The store then rolls the transaction back and runs the fun again, with jittered backoff, at most 25 times and never past the call's timeout, which must be finite.
The audit also confirmed that no transaction fun has an effect outside the database beyond generating ids and timestamps, so running one again is safe.
A single statement that meets a serialization failure or a deadlock did not commit and is retried the same way.

PostgreSQL aborts a transaction at its first failed statement.
A statement whose failure the fun handles and goes on from, as SQLite allows, passes `recoverable: true` and runs in its own savepoint; every other statement runs without one, because more than 64 subtransactions in one transaction slow every snapshot on the server.
Each session also has a statement timeout of 60 seconds, a lock timeout of 15 seconds, and an idle-in-transaction timeout of 60 seconds.

Hot rows still serialize their writers, as they do on SQLite: the replication identity row, `MAX(seq)` of the app data change feed, and the job claim.
Under contention those writers retry instead of waiting on a lock.

Seven call sites read an input before they open the transaction and decide inside it from that value: `sync.ex` (apply), `data_steward.ex` (two moves), `sync/capture.ex`, `authority/action_chain.ex`, `authority/policy.ex`, and `app_data/files.ex` (`below_file_limit`).
That read is already racy between two callers in one engine on SQLite, and a retry reuses the value it read.
Slice 3 moves each read inside its fun, and does not land until all seven are moved.

Acceptance: two engine processes writing one workspace through PostgreSQL produce no lost update, and the 20-query parity check matches the embedded copy.

### The Proof

`test/store/postgres/two_writers_test.exs` runs in CI against a PostgreSQL 16 service.
Two peer BEAM nodes, separate operating system processes that share nothing but the database, each start their own `OptimalEngine.Store.Postgres` against one schema and write one workspace at the same time for 50 rounds.
Every round a node writes a context of its own (or a batch of five), writes a context the other node also writes, increments a shared counter with a read-check-write transaction, and claims a key with an insert-if-absent transaction.

The test then checks that neither node saw an error, that every context is stored exactly once, that the counter equals the number of increments, that every key was claimed by exactly one node, and that each context both nodes replaced holds one version's entities and never a mix.
It also checks that PostgreSQL did abort conflicting transactions and the store ran them again, so the proof is not passing on writers that never overlapped.

The embedded copy replays every write both nodes made into the SQLite store, then the version of each shared context PostgreSQL kept.
Twenty queries scoped to the workspace (counts, ordering and pagination, grouping, joins, subqueries, JSON fields, text timestamps, entities, edges, and the `signals` view) return the same rows from both stores.

`scripts/proof-postgres-two-engines.sh` runs the same workload in two whole engines instead of two store processes:

```bash
OPTIMAL_POSTGRES_URL=postgres://user:secret@host:5432/database scripts/proof-postgres-two-engines.sh
```

It builds the engine with `OPTIMAL_STORE=postgres`, boots two engine processes with their full supervision tree against one fresh PostgreSQL schema, has each write the workspace through `OptimalEngine.Store`, and then runs the same checks and the same 20 queries against an embedded SQLite copy in a third process.
While they write, both engines publish ten policy packs each for one scope; the 20 packs must take versions 1 to 20 with exactly one active, because each publish reads the active pack and the next version inside its own transaction.
Each engine also checks that search, asking and enabling replication are refused by name.
The schema is dropped at the end.

### What Is On PostgreSQL

| On PostgreSQL | Not on PostgreSQL |
| --- | --- |
| Every table, key, unique index, foreign key, check, index, and view the SQLite migrations create, with their seeded rows. | The FTS5 tables (`contexts_fts`, `memories_fts`) and the triggers that maintain them: full-text search is unavailable, and search is refused by name. |
| The whole store contract: contexts and signals, entities and edges written with them, node listings, stats, raw statements, transactions, chunks, classifications, intents, chunk embeddings, clusters. | The ETS hot cache, by decision. |
| Vector and embedding rows, stored as `BYTEA` with the same float32 bytes. | Vector search on the database: the engine keeps ranking vectors itself until pgvector is available. |
| Any engine statement the dialect translates and PostgreSQL accepts. | Statements written with SQLite-only constructs, listed below. |

The SQL census measures the last row instead of guessing it.
With `OPTIMAL_SQL_CENSUS=<file>`, the test suite records every distinct statement the SQLite store executes and then classifies each one on a PostgreSQL schema derived from the same migrations (`test/support/sql_census.ex`): supported (it prepares), refused (the dialect or the store refuses it by name), or rejected (PostgreSQL does not accept the translation).
A supported statement with a `LIMIT` and no `ORDER BY` is also unordered: SQLite returns its rows in rowid order and PostgreSQL in no promised order.
An existence probe (`SELECT 1 ... LIMIT 1`) is not, because every matching row gives the same answer.
Statements that differ only in literals, numbers, generated names or the length of a placeholder list are one shape, and each shape is classified.

The census is a CI check.
Every refused, rejected and unordered shape is listed in `test/support/sql_census_allowlist.txt`, and a run that meets a shape the list does not have fails, so a new SQLite-only statement shows up in review rather than on a PostgreSQL store.
The failure prints each line to add, the refusal or PostgreSQL error and an example statement, and what to do: write the statement so both databases run it, make the dialect refuse its construct by name under a feature of `Storage.Postgres.unavailable/0`, order an unordered read by a unique key, or list the line.
A line leaves quoted identifiers out, so a statement the code runs on every table of the schema, such as `PRAGMA table_info("...")`, is one line while each table's statement is still classified.
`OPTIMAL_SQL_CENSUS_WRITE=1` adds a run's new shapes to the list and keeps the lines already there, because a run does not reach every statement; it reports how many listed shapes the run did not meet, a line is removed by hand once its statement is gone, and the diff is reviewed like code.

A census run of 2026-10-20 on main `ac1368f` recorded 2434 distinct statements: 1541 prepare on PostgreSQL, 797 are refused, and 96 are rejected; 17 of those that prepare are unordered.
The counts move a little between runs (2454 statements in another run of the same engine code); the allowlist check does not depend on them.
The ones that do not run are grouped by the SQLite feature they depend on, each counted once:

| SQLite feature | Statements |
| --- | --- |
| Replication change capture: `CREATE TRIGGER` and `DROP TRIGGER` per replicated table, refused as schema changes | 469 |
| The SQLite catalog: `sqlite_master`, and `PRAGMA`, mostly `PRAGMA table_info` on every table | 165 |
| App data collections: an FTS5 table, triggers, and tables created at runtime | 122 |
| SQLite JSON functions: `json_each`, `json_set`, `json_array_length`, `json_group_array` | 38 |
| Date and time arithmetic with a computed modifier, such as `datetime('now', '-' \|\| ?1 \|\| ' seconds')`, and `julianday` | 27 |
| Full-text search: `MATCH` and the FTS5 tables | 18 |
| `rowid` | 15 |
| `BEGIN IMMEDIATE` sent as a statement | 1 |
| Other: `INSERT OR REPLACE`, an integer used as a boolean, `group_concat`, a `json_extract` ordered comparison, migration statements a test runs, and tables only one test creates | 38 |

Without the capture triggers, which have no place on a PostgreSQL store, 1541 of 1965 statements run.
The rest belong to the features under What Does Not Work On PostgreSQL, each refused by name.
A rejected statement fails with PostgreSQL's error at the call site; none is answered wrongly.
Each is ported at its call site with its own parity test, not by widening the dialect until it guesses.

Of the 17 unordered statements, some read one row by a unique key and return the same row on both stores.
The others (graph neighbourhoods, entity co-occurrence, chunks without embeddings, and a content search capped at 100 rows) can return a different subset or order on PostgreSQL when more rows match than the limit.
They are listed for review, a new one fails the check, and giving each an `ORDER BY` is follow-up work.

### Selecting PostgreSQL

The store is chosen when the engine is compiled, so a release ships one implementation and never dispatches per call:

```bash
OPTIMAL_STORE=postgres MIX_ENV=prod mix release optimal
OPTIMAL_POSTGRES_URL=postgres://user:secret@host:5432/database?sslmode=require _build/prod/rel/optimal/bin/optimal start
```

`GET /api/storage/providers` reports `selected: true` for the store the build runs and `selected: false` for the other, and `mix optimal.postgres.check` prints the same.

An engine built this way boots its whole supervision tree on PostgreSQL, and the two-engine proof runs on it.
The features listed under What Does Not Work On PostgreSQL are refused by name, so a PostgreSQL build is the canonical relational store for engines that share one database, not yet a replacement for every feature of an embedded engine.
Replication change capture is switched off on a PostgreSQL store and says so once at boot.

## Stage 4: Moving An Existing Engine

Moving is a one-way switch with a frozen window, not dual writing.

1. Take a verified backup and record its checksum.
2. Stop writes, export every table in dependency order, and import into PostgreSQL inside one transaction.
3. Reconcile row counts and a checksum per table, then run the 20-query parity check.
4. Set `OPTIMAL_POSTGRES_URL`, start the engine, and confirm the same queries through the API.
5. Keep the SQLite file untouched for the rollback window.

The import replaces the rows a fresh PostgreSQL schema was seeded with, including the replica identity in `sync_identity`, so the moved engine keeps the identity it had on SQLite.

Rollback is restoring the backup, because writes accepted by PostgreSQL after the switch do not exist in SQLite.
That is why the window stays short and the parity check runs before the switch.

## Non-Goals

- The engine does not speak the PostgreSQL wire protocol to applications; the Engine API stays the interface.
- The provider does not run a PostgreSQL or Redis server.
- The provider does not move vectors, graph, or assets; those keep their own providers.
