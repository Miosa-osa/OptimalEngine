# PostgreSQL Provider

SQLite is the engine's durable local store and stays the default.
A busy workspace needs more than one writer, and one SQLite file has exactly one.
The PostgreSQL provider is how an engine moves its canonical relational store to a server that accepts many concurrent writers without changing what the engine stores or how it is queried.

This guide describes the provider's contract and the staged port.
Stages 1 to 3 have landed: `OptimalEngine.Store.Postgres` implements the canonical store contract on PostgreSQL, and the inventory reports the adapter.
Stage 4, moving an existing engine, has too: `mix optimal.postgres.migrate` copies an SQLite Engine's store into PostgreSQL and commits only a copy it has proved.

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

Ranked lists break score ties with `ORDER BY ... uri, id` (see "Ordering And Reproducibility" in the search architecture reference).
SQLite compares text byte for byte, so the dialect module must give `uri`, `id` and every other text tie-break column `COLLATE "C"` on PostgreSQL, or a database created with the `C` collation.
With a locale collation the two stores break ties in a different order, and the 20-query parity check misses on exactly the ties it exists to catch.

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
  Ordered against a number it orders as SQLite does, and compared with a column or another `json_extract` it compares as SQLite does.
  Selected as a whole item of a query's own select list it is SQLite's value: a number as a number, `true` and `false` as 1 and 0, an object or array as JSON text. Anywhere else it is its text; `BETWEEN` and an `ORDER BY` on it are refused.
- A selected placeholder (`SELECT ?1`) is the value bound, as on SQLite; PostgreSQL would type it as text.
- A statement that waits past its call's time for a lock, or runs past it, is `{:error, :busy}`, as SQLite's store answers a call it cannot serve in time; a transaction shorter than the session's lock timeout takes its own. An API key or workspace check that meets a busy store answers 503 with `Retry-After`.
- SQLite runs one writer, so a transaction that reads `MAX(seq)` and inserts the next never meets a concurrent insert of that key. At SERIALIZABLE PostgreSQL can report that interleaving as a unique violation; the transaction is run again, and the next attempt reads the key the other writer took. When the same violation comes back the key is the transaction's own, and its answer is returned.
- A long transaction that rewrites a row others keep updating holds it first (`Store.txn_lock_row/4`); a bulk write over many tables of rows that are its own runs at READ COMMITTED (`Store.txn_read_committed/1`). Both do nothing on SQLite.
- A job claim runs at READ COMMITTED and selects its job `FOR UPDATE SKIP LOCKED` (`Store.skip_locked/0`), so concurrent claimers each take a different job instead of all reading the same one and all but one being aborted. Completing, failing, deferring and extending a lease lock the job's row first and run at READ COMMITTED too. The sweep of expired leases with no attempts left skips a job another transaction holds; a later claim sweeps it, and no claim runs it meanwhile. On SQLite the clause is empty.
- A workspace rename and an orphan repair (`OptimalEngine.DataSteward`; the repair is recorded as a merge) read and rewrite a workspace in every table. At SERIALIZABLE any short writer of those tables aborted them, and under steady load their 25 attempts ran out. They now take every table of the store in `SHARE ROW EXCLUSIVE` mode first (`Store.txn_lock_tables/2`), before their snapshot, and stay SERIALIZABLE. **The cost:** while one runs, writers in every workspace stall for its duration (readers do not). A writer that arrives meanwhile queues behind the `LOCK`, and one that waits past its lock timeout (the session's 15 seconds, or less when its call has less time left) gets `{:error, :busy}`, as SQLite's store answers a call it cannot serve in time. `LOCK TABLE a, b, …` takes its tables one at a time, in name order, and keeps those it has while it waits for the next. A writer that already holds a later table and then wants an earlier one can therefore deadlock with the rename. PostgreSQL detects that after `deadlock_timeout` (1 s by default) and cancels one side with 40P01 (`deadlock_detected`), which the store retries like a serialization failure: either the rename or the writer starts again. The tables locked are every plain or partitioned table of the store's schema (`Store.Catalog.tables/1`: `relkind` `r` or `p`, so never a view such as `contexts_fts`). The full-text index's own `optimal_fts_*` tables are left out: a rename only appends to `optimal_fts_queue` through a trigger, and the index refresh runs at READ COMMITTED, so neither is a serialization conflict for it. Renames and repairs are rare operator actions, so this buys an operation that finishes. Locking only the tables the operation rewrites would not narrow the stall much, because they are nearly all of the store's tables and they are shared by every workspace. A per-workspace fence would need writers to take a workspace lock, which is a larger change. On SQLite nothing is locked.
- A storage mutation entry takes the ledger lock and inserts its row at READ COMMITTED. At SERIALIZABLE its snapshot was taken by the lock statement, before the wait, so a replay of the same key committed during the wait turned the insert into a serialization failure, and the whole transaction ran again. At READ COMMITTED the insert sees the replay and ignores it, with no retry. `ON CONFLICT DO NOTHING` still calls `nextval` before it finds the conflict, so an ignored replay uses up one sequence value: a gap the readers go past.
- Retries back off with full jitter over a window that doubles from 4 ms to a second. A call that runs out returns the reason, how many attempts ran and over how long, and nothing else: the error can reach an API caller, and PostgreSQL's detail and hint can quote other sessions' queries (a deadlock's does), with another tenant's values in them. The statement (or `COMMIT`) that met the last conflict and the server's detail and hint are logged on the server as a warning.
- An `INSERT` that writes an identity column explicitly moves the column's sequence past the largest id, as SQLite's rowid does.
- A construct the dialect refuses and a schema change outside the migrations return `{:error, {:unsupported, name}}` and never reach the database.
- A transaction statement sent as a statement (`BEGIN`, `COMMIT`, `END`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`, and PostgreSQL's `START` and `ABORT`) raises `ArgumentError` before it reaches the database, as it does on SQLite (`OptimalEngine.Store.TransactionControl`).
  Leading whitespace, comments and empty statements are skipped first, so `/* x */ COMMIT` is refused too.
  Inside a transaction, `SAVEPOINT`, `RELEASE` and `ROLLBACK TO` work as on SQLite.

### What Does Not Work On PostgreSQL

Every feature of the SQLite store works on the PostgreSQL store except the ETS hot cache, which is off by design (a per-process cache cannot see another engine's writes). One kind of statement does not work either, by design.
`OptimalEngine.Storage.Postgres.unavailable/0` lists it, `GET /api/storage/providers/postgres` and `mix optimal.postgres.check` report it, and it is refused by name when it is used, never answered as if it worked:

| Feature | On a PostgreSQL store |
| --- | --- |
| Schema and transaction statements | The schema comes from the migrations, so a schema change and SQLite-only table options (`AUTOINCREMENT`, `WITHOUT ROWID`) sent as statements are refused; the schema PostgreSQL needs of its own (full-text indexes, app data collections, capture triggers) runs through its own DDL. A transaction statement sent as a statement raises `ArgumentError` on both stores. |

`OptimalEngine.Store.Dialect.refusals/0` lists every refused construct with its reason, and `test/store/postgres/unavailable_test.exs` checks both ways: every refusal of the dialect is under a feature here or under a ported feature (`OptimalEngine.Storage.Postgres.ported/0`, a feature that works on PostgreSQL through statements of its own while the SQLite statements behind it stay refused), and every name a feature lists is one the dialect or the store refuses with.

### SQLite Functions

SQLite's JSON, date and time, and text functions run on a PostgreSQL store as PostgreSQL functions with SQLite's results (`OptimalEngine.Store.Postgres.SQLiteFunctions`), which the schema sync creates before any index or view.
The dialect renames each call (`json_set` to `sqlite_json_set`, `datetime` to `sqlite_datetime`, and so on), so none collides with PostgreSQL's own `json_object`, `json_array`, `date` or `time`, and passes every argument as text, as SQLite reads it.
`test/store/postgres/sqlite_functions_parity_test.exs` runs each form on both stores and compares the rows.

| SQLite | On PostgreSQL |
| --- | --- |
| `json()`, `json_set`, `json_insert`, `json_replace`, `json_remove`, `json_object`, `json_array` | JSON text, minified, with an object's members in the order written, as SQLite writes it. A value is JSON when it is another JSON function's result (or `json_extract`'s), and otherwise the SQL value: a number stays a number. A value bound to a parameter is bound as text, so it is a JSON string; bind JSON with `json(?)`. |
| `json_type`, `json_array_length`, `json_valid` | The same answers, with a path. |
| `json_each` | SQLite's columns; `value`, `atom` and an array's `key` are text. |
| `json_group_array` | An aggregate with the same array, `DISTINCT` included. |
| `datetime`, `date`, `time`, `julianday`, `unixepoch`, `strftime` | A time is held as SQLite holds it, in milliseconds since the Julian epoch, from any SQLite time value, with SQLite's modifiers: `±N days`, `hours`, `minutes`, `seconds`, `months`, `years` (months by the calendar fields, so January 31 plus one month is March 3, as on SQLite), `start of day`, `month`, `year`, `unixepoch`, `subsec`, and `utc` and `localtime`, which leave a UTC time as it is. `now` is the statement's start, to the millisecond. A modifier or `strftime` format the functions do not have raises an error rather than answer. |
| `group_concat`, `instr`, `char` | `string_agg`, `strpos`, `chr`. |
| `x GLOB p` | A regular expression match, when `x` is a column, a placeholder or a `json_extract` of a column and `p` a literal or a placeholder. |

`json_extract` ordered against a number (`<`, `<=`, `>`, `>=`, a literal or a placeholder bound to a number) orders as SQLite orders values: a JSON number or boolean compares as a number, and text sorts after every number.

Still refused by name: the other `json_extract` forms that order or compare by SQLite's types (`BETWEEN`, an ordering against text or a column, `ORDER BY`), `json_tree`, `json_patch` and the other JSON functions no call site uses, `typeof`, `printf` and SQLite's other functions without a counterpart, a `GLOB` of an expression, SQLite's collations, and a `LIKE` with a computed pattern.
### Replication
Replication works on a PostgreSQL store with the ledger a SQLite Engine keeps, so SQLite and PostgreSQL Engines replicate with each other (`OptimalEngine.Sync.Postgres`, `docs/guides/replication.md`).
- Capture is a PL/pgSQL row trigger on each replicated table, calling `optimal_sync_capture()` with the table's key columns, its `BYTEA` columns and whether it is append-only. It records in `sync_capture` what SQLite's capture triggers record: the whole row on an insert or an update, the key on a delete, bytes as upper-case hex in `blob_data`, the key as text or a compact JSON array, nothing while `sync_identity.applying` is set or for a workspace that does not sync. `test/sync/postgres_capture_test.exs` makes the same writes on both stores and compares what each captured.
- The column lists come from the PostgreSQL catalog of the store's schema, an identity column standing for SQLite's rowid key, so a table an app creates at runtime is captured the same way.
- Sealing runs at READ COMMITTED: it is idempotent (a mutation id is its capture key), and a batch of thousands of rows takes enough predicate locks at SERIALIZABLE to be aborted again and again beside the writers it overlaps. Seals in one Engine take turns.
- The gate reads JSON as SQLite's JSON functions do, through `oe_json_valid`, `oe_json_type`, `oe_json_extract`, `oe_json_each` and `oe_json_raw` on PostgreSQL's `json` type, which keeps a key that appears twice (`OptimalEngine.Store.Postgres.SqliteJson`).
- The gate cache's stamp is the largest key a committed row of `sync_capture`, `sync_local_stamp` and `sync_mutations` holds; PostgreSQL's sequences move before a writer commits, so they cannot be the stamp. The local stamp triggers of the tables the gate scans have SQLite's conditions, translated by the dialect.
- `test/sync/cross_store_apply_test.exs` applies a page a SQLite Engine served and a page a PostgreSQL Engine served, recorded on each build, and checks the rows that result; CI runs it on both builds.
- Ledger sequences commit in order. PostgreSQL draws a `sync_mutations` sequence when the row is inserted, before its writer commits, and every reader follows the ledger by sequence (a peer's `GET /api/sync/changes`, the NATS ledger publisher, the storage ledger reader `PolicyStore.mutations_after/3`), so a writer that drew 10 and committed after one that drew 11 would be skipped for good by a reader that had already seen 11. Every ledger writer (a seal, an applied change, a storage mutation entry) therefore takes one transaction-scoped advisory lock, keyed on the store's schema, before it inserts, and holds it until it commits: Engines that share a database and a schema share the lock, and every snapshot sees a prefix of the ledger. A writer that rolls back leaves a gap that nothing fills, and readers go past it as before. An apply writes its ledger rows at the end of its transaction and takes the lock once there, so a long page of changes holds the lock only for those inserts and its commit, not while it writes the rows. The lock's key falls back to the empty schema name when `current_schema()` is NULL, so it is always taken. The ledger's identity sequence must hand out values in the order they are drawn, so it caches none (`CACHE 1`). Boot checks it once, inside the DDL lock so Engines booting together do not both change it (`Sync.Postgres.ensure_ledger_sequence/1`):
  - A larger cache is set back to 1 with a warning (`ALTER TABLE … ALTER COLUMN sequence SET CACHE 1` for the identity column the store derives, `ALTER SEQUENCE … CACHE 1` for a serial one). Sessions that cached a block before that may still hand it out (the ALTER SEQUENCE documentation says they use up their cached values first; PostgreSQL 16.14 was seen to drop them, and `test/sync/ledger_sequence_test.exs` checks it with dedicated sessions). Nothing relies on either: after a set-back, every ledger writer of this Engine runs `DISCARD SEQUENCES` under the ledger lock before it draws, for the rest of the boot. Every Engine that booted while the cache was larger found it at its own check and discards too; a cache raised by hand while Engines run is found at their next boot.
  - A check that could not run (the database busy, a timeout) is tried again at the next `Capture.install`, rather than marking the boot checked.
  - A role that does not own the table cannot change it. The boot goes on: it logs the statement to run as the owner (`ALTER SEQUENCE <schema>.sync_mutations_sequence_seq CACHE 1`), readiness warns (`ledger: {:warn, {:ledger_sequence_cached, n}}`), and until it is fixed every ledger writer runs `DISCARD SEQUENCES` under the lock before it draws, so its session's block is dropped and the draw is the sequence's next value: the order holds, with gaps of up to `n - 1`.
  - A column without a sequence, or a check that fails, warns as well (`ledger_sequence_unchecked`) and never fails the boot.

  A seal that fails or times out ends that workspace's part of the NATS publisher's pass (`state: "error"`); the workspaces and pages published earlier in the pass keep their cursors, and after 5 failed passes in a row readiness warns (`ledger: {:warn, {:nats_ledger_failing, n, last_error}}`). The publisher's status never seals: its backlog counts the ledger past the cursor and the writes captured but not sealed yet. The cost is that ledger writes take turns: measured on one PostgreSQL 16 with 16 concurrent writers of storage entries, about 420 to 460 entries a second instead of 820 to 1,020, and 4 to 7 % less for a single writer; seals already took turns within one Engine, and a reader that seals first (`Sync.changes/3`) waits for the ledger writer ahead of it. A safe-horizon reader (`pg_snapshot_xmin`) was not used: a transaction's id is assigned at its first write, not when it draws its ledger sequence, so the order of ids is not the order of sequences. `test/sync/ledger_commit_order_test.exs` holds a writer open with its sequence drawn and checks that a pulling peer, the NATS publisher and the storage ledger reader still read its row.
- The NATS ledger flow (`OPTIMAL_NATS_FLOWS=ledger`, `OptimalEngine.Storage.NATS.LedgerPublisher`) reads this ledger, so a PostgreSQL Engine publishes its changes, purges what it forgets and records each purge as a SQLite Engine does (`docs/guides/storage-providers.md#the-change-ledger-stream`); `test/storage/nats_ledger_test.exs` and `test/storage/nats_erasure_test.exs` run on both builds.
- `scripts/proof-postgres-replication.sh` starts two Engines over HTTP, each on a PostgreSQL schema of its own, pairs them as each other's peer, and checks that a memory written on either reaches the other in one sync cycle, with healthy peers and no conflicts after.

### Full-Text Search

Search, context assembly and asking work on a PostgreSQL store, with the tokens and the ranking of SQLite's FTS5 (`OptimalEngine.Store.FullText`, `OptimalEngine.Store.Postgres.FullText`).

- `contexts_fts` and `memories_fts` are posting lists: one row per indexed row with its token count (`optimal_fts_docs`), one row per term of a row with its positions (`optimal_fts_postings`), and the row and token totals of each index (`optimal_fts_totals`).
- A row is tokenized by SQLite itself: an in-memory FTS5 table with the index's own `tokenize` option, read back through `fts5vocab`. The case folding, the diacritics and the Porter stemming of `memories_fts` are FTS5's, with no second tokenizer to keep in step. A query's phrases are tokenized the same way.
- `optimal_fts_match(index, query)` returns the rows a query matches with FTS5's `bm25()` score (k1 = 1.2, b = 0.75, every column weighted 1, IDF floored at 1e-6, over the whole index as FTS5 computes it), negated as `-bm25()` is. The phrases are summed in query order in double precision, so a score matches SQLite's to the last few bits; `test/store/postgres/full_text_test.exs` compares every query of a corpus with an FTS5 table to 1e-12.
- A row trigger on `contexts` and `memories` appends the key of every inserted, deleted or updated row (an update of its key or an indexed column) to `optimal_fts_queue` in the writer's transaction, so every write path, cascade and engine is covered. Before a statement reads an index, the store indexes the queued rows as they are then and deletes exactly the entries it read; a key a writer queues meanwhile waits for the next refresh. A timer in the store does the same every 2 seconds (`full_text_interval_ms`, 0 turns it off), so a search rarely has to.
- The views `contexts_fts` and `memories_fts` give the indexed keys as `id`, so the storage audit's and the health checks' counts run unchanged.
- The index is a projection: `OptimalEngine.Store.Postgres.rebuild_full_text/1` empties it and indexes every row again.
- The engine builds every `MATCH` string from quoted phrases joined by ` OR ` or by spaces, the last optionally a prefix; any other syntax is refused by name (`FTS5 query syntax`), and a `MATCH` statement sent to the PostgreSQL store is still refused (`FTS5 MATCH`).

An engine moved there from SQLite would otherwise run on and silently stop replicating, or stop serving its collections.

### The Catalog, `rowid` And Replace Writes

The call sites that read SQLite's catalog, break ties by `rowid` or write with `INSERT OR REPLACE` run on PostgreSQL through statements of their own; the SQLite statements stay refused by name (`OptimalEngine.Storage.Postgres.ported/0`).

- `OptimalEngine.Store.Catalog` answers what `sqlite_master` and the `PRAGMA` functions answer: the store's tables, a table's columns and primary key, its foreign keys, the tables with an index that starts at a column, whether a table exists. On PostgreSQL it reads `pg_catalog`, limited to the store's schema and without the store's own `optimal_*` tables, and a column's key position is the one the migrations declare. `PRAGMA integrity_check` answers `ok` and `PRAGMA foreign_key_check` no rows, because PostgreSQL enforces every key as it writes. Workspace bundles, the data steward, a workspace slug change, the storage audit, health, optimality, policy entity types and erasure read it.
- A listing that broke ties of one second by `rowid` (API keys, analysis reports, a verified backup, a workspace's earlier slugs) breaks them by the table's key on PostgreSQL (`Catalog.insertion_order/1`), which has no insertion order; rows written in the same second can therefore list in another order than on SQLite.
- `OptimalEngine.Store.Replace` runs `INSERT OR REPLACE` as SQLite does: on PostgreSQL it deletes the row each key of the table (the primary key and every unique key, from the derived schema) names, with their `ON DELETE` actions, and then inserts, in one transaction. A key column written as an expression rather than a value is refused with `ArgumentError`. Sessions, vectors, memory embeddings, memory associations, viability reports, authority checkpoints, model call operations and tool definitions write through it.
- A workspace bundle reads one moment of the database: on PostgreSQL a read-only `REPEATABLE READ` transaction (`OptimalEngine.Store.Postgres.read_snapshot/2`), as the read-only SQLite connection is on SQLite.

`test/store/postgres/catalog_replace_test.exs` checks the catalog answers and the rows a replace leaves alike on both stores.

### App Data Collections
App data collections work on a PostgreSQL store (`OptimalEngine.AppData.Collections`).
A collection's table, indexes and columns are created, altered and dropped at runtime in PostgreSQL DDL inside the collection's own transaction, so a failed change leaves the collection as it was, as on SQLite:
- `_rowid` is a `BIGINT` identity column, field types map as the derived schema maps them (`BIGINT`, `DOUBLE PRECISION`, `TEXT COLLATE "C"`), and a reference field is a foreign key `DEFERRABLE INITIALLY IMMEDIATE`, like the store's own.
- The full-text index of a collection's search fields is a posting list created at runtime (`OptimalEngine.Store.Postgres.FullText.create_index/2`, registered in `optimal_fts_indexes`), tokenized with the collection's FTS5 option `unicode61 remove_diacritics 2` and ranked by `optimal_fts_match` as FTS5's external-content table ranks.
- A text query, a `contains` filter on a JSON field (SQLite's `json_each` values, compared by type, with `true` and `false` as 1 and 0) and on a text field (`strpos` for `instr`) are written for PostgreSQL; empty filters are `(1 = 1)` and `(1 = 0)` on both stores, as PostgreSQL has no integer booleans.
- Semantic embeddings are upserted by their key.
The SQLite statements behind collections (FTS5 tables, triggers, `STRICT` tables) are still refused there as schema changes outside the migrations.
### Decisions

- The ETS hot cache is disabled when PostgreSQL is the canonical store, because a per-process cache cannot see another engine's writes.
  It returns only with a `LISTEN`/`NOTIFY` invalidation that has its own test.
- `transaction/2` keeps its contract, and every transaction runs at `SERIALIZABLE` instead of taking per-call-site row locks.

The second decision replaces the earlier plan of one `SELECT ... FOR UPDATE` per call site.
An audit of the 51 `Store.transaction` call sites found eight that check for an absent row or a maximum before inserting (an upsert, `MAX(seq) + 1`, a version counter, the head of a hash chain).
A row lock cannot protect a row that does not exist yet, so those eight would each need an advisory lock of their own, and a missed lock point would be a silent lost update.
At `SERIALIZABLE`, PostgreSQL aborts one side of any interleaving that no serial order could produce, for every call site, including ones written later.
Every transaction begins with `BEGIN ISOLATION LEVEL SERIALIZABLE`, and each connection is checked on connect for its isolation and `search_path`.
The database must be UTF8, which the same check enforces: SQLite's text functions (`substr`, `length`, `instr`) count characters, and PostgreSQL's do so in a UTF8 database but count bytes in `SQL_ASCII`.
The store then rolls the transaction back and runs the fun again, with jittered backoff, at most 25 times and never past the call's timeout, which must be finite.
The audit also confirmed that no transaction fun has an effect outside the database beyond generating ids and timestamps, so running one again is safe.
A single statement that meets a serialization failure or a deadlock did not commit and is retried the same way.

PostgreSQL aborts a transaction at its first failed statement.
A statement whose failure the fun handles and goes on from, as SQLite allows, passes `recoverable: true` and runs in its own savepoint; every other statement runs without one, because more than 64 subtransactions in one transaction slow every snapshot on the server.
Each session also has a statement timeout of 60 seconds, a lock timeout of 15 seconds, and an idle-in-transaction timeout of 60 seconds.

Hot rows still serialize their writers, as they do on SQLite: the replication identity row and `MAX(seq)` of the app data change feed.
Under contention those writers retry instead of waiting on a lock.
The job claim used to be one of them; it now locks the job it takes and skips the ones other claimers hold (see Statements And Results).

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

It boots two engine processes with `OPTIMAL_STORE=postgres`, each with its full supervision tree, against one fresh PostgreSQL schema, has each write the workspace through `OptimalEngine.Store`, and then runs the same checks and the same 20 queries against an embedded SQLite copy in a third process.
While they write, both engines publish ten policy packs each for one scope; the 20 packs must take versions 1 to 20 with exactly one active, because each publish reads the active pack and the next version inside its own transaction.
Each engine also searches the workspace through the full-text index and must find the contexts it wrote, and enables replication for the workspace.
The schema is dropped at the end.

### What Is On PostgreSQL

| On PostgreSQL | Not on PostgreSQL |
| --- | --- |
| Every table, key, unique index, foreign key, check, index, and view the SQLite migrations create, with their seeded rows. | The FTS5 virtual tables and their triggers: their PostgreSQL counterparts are the full-text posting lists above. |
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

The store is chosen when the Engine boots, by `OPTIMAL_STORE` (`sqlite`, the default, or `postgres`), so one release runs either store and no rebuild is needed to move one:

```bash
MIX_ENV=prod mix release optimal
OPTIMAL_STORE=postgres \
OPTIMAL_POSTGRES_URL=postgres://user:secret@host:5432/database?sslmode=require \
_build/prod/rel/optimal/bin/optimal start
```

`config/runtime.exs` reads the variable and any other value stops the boot. `OptimalEngine.Store` keeps the implementation in a `:persistent_term` the first time it is asked, so a call costs one lookup and the choice cannot change while the node runs. An Engine started from a build made with the old `OPTIMAL_STORE=postgres` at boot behaves the same: the variable set at build time is still the default.

`GET /api/storage/providers` reports `selected: true` for the store the Engine runs and `selected: false` for the other, and `mix optimal.postgres.check` prints the same.

An Engine started this way boots its whole supervision tree on PostgreSQL, and the two-engine proof runs on it.
With every feature of the embedded store on it, a PostgreSQL build replaces an embedded engine's store; only schema and transaction statements sent as statements are refused (What Does Not Work On PostgreSQL).
CI's `test-postgres-store` job runs the whole test suite with the Engine on PostgreSQL. Tests of SQLite itself (its planner, its migrations on a file, its one connection) are tagged `:sqlite_store` and left out there; each names the PostgreSQL test that covers the same behaviour.
Replication works on a PostgreSQL build (see Replication below).

## Backups And Restore

Every backup feature works on a PostgreSQL store, through the same API routes, mix tasks and schedule as on SQLite (`OptimalEngine.Backup`, `OptimalEngine.Backup.Postgres`).

- A backup is a SQLite database file. The engine's migrations create its schema, and every table of the store is copied into it from one snapshot taken `SERIALIZABLE, READ ONLY, DEFERRABLE`, so the copy is consistent, never aborted, and never blocks a writer. The file's FTS5 tables are filled by its own triggers, so it is a complete engine database that a SQLite engine can open too.
- From there a backup is the SQLite one: its SHA-256 and `PRAGMA integrity_check`, its catalog row (in the PostgreSQL store's `backup_records`), sealing with `OPTIMAL_BACKUP_KEY`, the offsite copy to S3, the schedule, pruning, and an offsite restore to a file.
- `mix optimal.restore <file>` on a PostgreSQL build restores into the configured schema, `--schema <name>` into another one (an empty or new schema is created in the build's shape). The file's checksum must match the catalog or `--checksum` and its integrity check must pass, and its migration versions must be the build's, before anything changes.
- The restore is one transaction. It locks every table of the store and the full-text index tables `ACCESS EXCLUSIVE`, so any other engine's reads and writes wait for it to commit or roll back and no write lands in the middle. It empties the tables, inserts the file's rows, moves each identity sequence past its largest id, empties the full-text indexes (every restored row is queued for them by their triggers), and compares every table's row count and digest with the file's; a difference rolls it back.
- Before it replaces anything, the schema's current contents are saved as a backup file in `OPTIMAL_BACKUP_DIR` (`pre-restore-<schema>-<time>.db`), the rollback of the restore.
- Restoring into the configured schema is refused while this engine runs, as replacing the live SQLite file is.

The operator flow for a live store: stop every engine that uses the schema, run `mix optimal.restore <file>` (it starts no engine, only a connection), and start the engines again. A restore into another schema (a drill) needs nothing stopped.

The backup is not made with `pg_dump`. `pg_dump` needs a client of the server's major version beside the engine, which the release image does not ship, and writes a format only `pg_restore` reads into a schema of the dump's own name; the copy here needs only the engine's connection, restores into any schema, and is held to the same checksum and integrity check as every other backup.

## Stage 4: Moving An Existing Engine

Moving is a one-way switch with a frozen window, not dual writing.
`OptimalEngine.Store.Postgres.Migrate.run/1` does the copy, and `mix optimal.postgres.migrate` (or `bin/optimal eval` in a release) runs it:

```bash
# 1. Stop the Engine's writes (stop the engine, or put it in maintenance), then back it up.
# 2. Prove the copy without committing it, then copy.
OPTIMAL_POSTGRES_URL=postgres://user:secret@host:5432/database \
  mix optimal.postgres.migrate --source .optimal/index.db --schema public --dry-run
OPTIMAL_POSTGRES_URL=postgres://user:secret@host:5432/database \
  mix optimal.postgres.migrate --source .optimal/index.db --schema public
# In a release:
bin/optimal eval 'OptimalEngine.Store.Postgres.Migrate.run(schema: "public") |> IO.inspect()'
```

What the migration does:

1. It never writes the Engine's file. The source (or a backup given with `--snapshot`) is opened read-only and copied with `VACUUM INTO`, one consistent read; the report gives the snapshot's SHA-256 and size, so it can be checked against the backup taken in step 1.
2. The snapshot is brought to this build's schema with the SQLite store's own migrations, so an Engine one release behind moves without being upgraded in place.
3. The target schema is created and synced from the migrations, with the full-text objects. A schema that already holds tables is refused (`{:target_not_empty, schema}`) unless `--replace`, which empties it inside the copy's transaction.
4. In one transaction, with every foreign key deferred to the commit, every table is emptied of the rows a fresh schema is seeded with and every row of the snapshot is inserted, each value converted to its column's type with SQLite's affinity rules; BLOBs are `BYTEA`, byte for byte. The replica identity in `sync_identity` is the one the Engine had on SQLite. Identity sequences move past the largest id and past SQLite's `AUTOINCREMENT` high-water mark, so an id SQLite would never reuse is not handed out again.
5. Still in that transaction, each table's row count and an order-independent checksum (the sum, modulo 2^256, of the SHA-256 of each row's values as the PostgreSQL column holds them) are computed from the snapshot and read back from PostgreSQL, and 20 parity queries (`OptimalEngine.Store.Postgres.Migrate.parity_queries/1`) run against both for every workspace. Any difference rolls the whole copy back with `{:verification_failed, ...}` or `{:parity_failed, ...}`; nothing is committed.
6. After the commit, `contexts_fts` and `memories_fts` are rebuilt from the copied rows, so search ranks as FTS5 ranked on the source.

A table or column this build does not know is refused (`{:unknown_tables, ...}`, `{:unknown_columns, ...}`) unless `--ignore-unknown`, which leaves it behind and lists it in the report.
The copy takes an Engine that has not enabled replication or app data collections: both work on a PostgreSQL store, but their state (the replication ledger's capture, the collections' own tables) is not part of this copy, so an Engine using either is refused before anything is copied (`{:unsupported_in_use, features}`). Turn them on again on the PostgreSQL Engine after the move.
The connection URL is never printed; the report names tables, row counts and checksums.

Then switch:

1. Build the engine with `OPTIMAL_STORE=postgres`, set `OPTIMAL_POSTGRES_URL` (and `OPTIMAL_POSTGRES_SCHEMA` when it is not `public`), start it, and confirm the same queries through the API.
2. Keep the SQLite file and the backup untouched for the rollback window.

Rollback is restoring the backup, because writes accepted by PostgreSQL after the switch do not exist in SQLite.
That is why the window stays short and the parity check runs before the switch.

## Non-Goals

- The engine does not speak the PostgreSQL wire protocol to applications; the Engine API stays the interface.
- The provider does not run a PostgreSQL or Redis server.
- The provider does not move vectors, graph, or assets; those keep their own providers.
