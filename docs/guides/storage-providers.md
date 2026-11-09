# Storage Providers

An Optimal Engine keeps its logical stores on one machine by default: one SQLite file, one asset directory, one knowledge projection.
That is the right default for a private workspace, and it is a single point of failure once assets grow or a backup has to leave the machine.
Physical providers are how a deployment adds capacity or durability without changing what the engine stores or how it is queried.

The engine distinguishes a logical store from the technology behind it.
Logical stores describe ownership and lifecycle: relational, full text, vector, graph, assets, cache, jobs, replication, metrics, backups, decomposition, models, and secrets.
Providers describe the replaceable technology used to persist, index, transport, or project that data, and one logical store can move between providers without any record changing meaning.

## Provider Inventory And Health

`GET /api/storage/providers` lists every provider the engine knows about, and `GET /api/storage/providers/:id` returns one.

```bash
curl -s "$URL/api/storage/providers?probe=true" | jq '.providers[] | {id, configured, health, lifecycle_state}'
```

Each entry reports:

```text
configured            every required environment variable is present and non-empty
health                healthy, unreachable, not_configured, not_installed, unknown, configured
adapter_implemented   the engine ships a module that can actually talk to it
lifecycle_state       active, available, configured_unverified, unavailable, not_configured, adapter_missing
serves                what the Engine routes through it when configured and selected; [] for an adapter that only probes
data_path             serving, standby, probe_only, none
```

Two rules make the inventory trustworthy.

A provider is only usable when the engine ships an adapter for it.
A provider listed without an implementing module reports `adapter_missing` regardless of configuration or a reachable endpoint, because a healthy remote service the engine cannot talk to is not available storage.

Health is only claimed on evidence.
Without `probe=true` a configured service provider reports `configured_unverified`, and with `probe=true` the adapter makes a real authenticated request.

The embedded providers report `active` because the running engine uses them.
RocksDB is the exception: it is `active` only when `OPTIMAL_KNOWLEDGE_BACKEND=rocksdb` put the knowledge store on it, and on an ETS knowledge store it reports `available`.

Reachable is not the same as in the data path.
`lifecycle_state` says whether a provider answers; `serves` and `data_path` say whether the Engine keeps anything in it.
`serving` means it serves something, is configured, is the store this build selected or the backend in use, and is not `unavailable`; `standby` means it would but is not configured, selected, in use or reachable; `probe_only` means the adapter only checks and proves the provider and nothing the Engine stores goes there; `none` means there is no adapter.
An adapter that exports `serves/0` declares what it carries itself; otherwise the registry in `OptimalEngine.Storage.Providers` does.
A platform that needs a provider to hold data checks `data_path == "serving"`, and a plan lists the providers that would hold none of its data under `probe_only`.

Provider status never returns credentials, connection strings, or secret values; only the names of the environment variables a provider reads.

Today `s3` and `postgres` are the service providers with an adapter.
`valkey` and `nats_jetstream` have adapters and report `not_configured`, `available` or `unavailable` like `s3`; `qdrant`, `openbao` and `duckdb` have one too; `fractal` is declared and reports `adapter_missing` until an adapter ships.

`sqlite` and `postgres` are canonical stores, and an engine runs exactly one of them.
The choice is made when the engine is compiled, so both report `selected`: `true` for the store this build runs and `false` for the other.
A healthy `postgres` provider in a build that selected SQLite holds none of the engine's data.
See [PostgreSQL Provider](postgres-provider.md) for what is and is not on PostgreSQL.

## S3-Compatible Object Storage

The S3 provider speaks the plain S3 REST API with AWS Signature Version 4, so it works against AWS S3, Cloudflare R2, MinIO, a MIOSA bucket, or any endpoint that implements the same protocol.
Only the operations the engine needs are implemented: put, get, head, list, delete, and multipart upload for large objects.

```text
OPTIMAL_S3_ENDPOINT           endpoint base URL, for example https://s3.example.com
OPTIMAL_S3_BUCKET             bucket name
OPTIMAL_S3_REGION             region for the credential scope; default us-east-1
OPTIMAL_S3_ACCESS_KEY_ID      access key id
OPTIMAL_S3_SECRET_ACCESS_KEY  secret access key
OPTIMAL_S3_PREFIX             optional key prefix owned by this engine
OPTIMAL_S3_PATH_STYLE         "false" for virtual-hosted addressing; default path style
OPTIMAL_S3_TIMEOUT_MS         per-request timeout; default 30000
OPTIMAL_S3_MAX_RETRIES        retries for transport errors, 5xx, and 429; default 2
OPTIMAL_S3_TRACE              "1" logs the canonical request when diagnosing a rejected signature
OPTIMAL_S3_CREDENTIALS_FILE   optional file holding the access key id and secret
```

The bucket and the prefix belong to one Engine: an erasure or a retention delete deletes the objects of the assets it removes, by key, and it cannot see another Engine's rows.
Give each Engine its own `OPTIMAL_S3_PREFIX` (or bucket) and write nothing else under it; see [Erasure And Retention](erasure-and-retention.md).

Path-style addressing is the default because it works against every S3-compatible endpoint.
Hosted AWS prefers virtual-hosted addressing, which a deployment opts into with `OPTIMAL_S3_PATH_STYLE=false`.

Credentials are read from the environment on every call.
They are never written to a database, logged, or placed in an error value, and `OPTIMAL_S3_TRACE` deliberately prints the canonical request and the string to sign, neither of which contains the secret.

### Credentials File

An operator can drop the credentials into a file instead of editing a launcher, and point `OPTIMAL_S3_CREDENTIALS_FILE` at it.
The file holds either two lines, the access key id and then the secret, or `KEY=VALUE` lines:

```text
# /etc/optimal/s3-credentials, mode 0600
OPTIMAL_S3_ACCESS_KEY_ID=AKIAEXAMPLE
OPTIMAL_S3_SECRET_ACCESS_KEY=example-secret
```

`KEY=VALUE` lines may also use the AWS names `aws_access_key_id` and `aws_secret_access_key`, so a profile from an AWS credentials file works as is.
Blank lines, `#` comments, `[section]` headers, a leading `export`, and surrounding quotes are allowed.
In the two-line form a secret may contain `=`.

The environment wins, value by value: a variable that is set is used, and the file fills only what the environment leaves unset.
The file is read on every request, so replacing it rotates the credentials without a restart.
An unreadable file or one without both values makes the provider report `credentials_file_unreadable` or `credentials_file_invalid`, never the file's contents.
The provider inventory counts credentials from the file as configured.
Keep the file readable only by the engine's user.

Check the provider end to end rather than trusting a TCP connection:

```bash
curl -s "$URL/api/storage/providers/s3?probe=true" | jq
```

The probe writes a small object under the engine prefix, reads it back, verifies the checksum, lists it, and deletes it.
A configured endpoint with a wrong key, a wrong bucket, or no route to it reports `unreachable` rather than `healthy`.

Large objects are uploaded in parts, defaulting to 8 MiB per part with a 16 MiB threshold before multipart is used.
S3 itself requires parts of at least 5 MiB except the last, so a deployment that lowers the part size is only safe against a test endpoint.

## Assets On An Object Store

Raw artifacts are the evidence a parser's output is derived from, so the engine stores the file itself, writes an `assets` row, creates a Source Package, and records the derivation link.
Asset bytes live on the local filesystem by default.

A workspace can move them to the object store in two ways.
A workspace storage policy names s3 for assets:

```bash
curl -s -X PUT "$URL/api/storage/workspaces/$WORKSPACE/policy" \
  -H 'content-type: application/json' \
  -d '{"use_cases": ["media_archive"], "provider_overrides": {"s3": {"assets": true}}}'
```

Or an engine-wide default applies to every workspace: `OPTIMAL_ASSET_STORAGE=s3`.

The asset row then records where its bytes live, under the tenant, the workspace slug, the shard, and the content hash:

```text
s3://<bucket>/<prefix>/<tenant>/<workspace>/assets/<shard>/<sha256><extension>
```

Readers resolve through the asset store rather than opening `storage_path` directly, so both backends work: `MemoryCore.read_asset/2` returns bytes from either, and `MemoryCore.materialize_asset/2` returns a local path, downloading an object into the engine cache once for tools that take a file argument.

A selected object store that is unconfigured or unreachable never loses the file.
The bytes are written to the local filesystem, the asset row records `storage_fallback_reason` (`s3_upload_failed` or `s3_not_configured`), and the engine raises an alert, because an upload that failed to leave the machine must not be reported as a successful remote store.
The alert is an error log line (`asset storage alert: ...`) and a counter an operator can alert on: `optimal_engine.storage.asset_fallback` in `GET /api/metrics`, `optimal_engine_storage_asset_fallback_total` in `GET /api/metrics/prometheus`.
Once the object store answers again, the Engine puts those assets in the bucket (`OptimalEngine.Storage.AssetReconcile`), every ten minutes while any are pending (`OPTIMAL_ASSET_RECONCILE_INTERVAL_MS`, 0 turns it off).
Each one is uploaded under the key a direct write would have used, read back, and compared with the local copy's SHA-256 before the asset is recorded as placed: its `storage_path` becomes the object URI, its metadata names the object and `storage_placed_at`, and the fallback reason moves to `storage_fallback_resolved`.
The local copy stays on disk.
An asset whose object does not read back the same stays pending; the first transport error ends a pass, so a store still down is not asked once per asset.
A workspace storage policy that cannot be read is not an answer either: the asset stays pending and the next pass asks again.
An asset whose workspace now keeps assets on the local filesystem is resolved without an upload (`backend_now_filesystem`).
A stored path is data, and rows reach the assets table from a workspace bundle import as well as from an upload.
A pass therefore opens a local copy only if it is a regular file under the Engine root once symlinks are followed; a FIFO, a device, a directory or a path that leads outside the root is never opened.
A row that can never be placed is quarantined instead of retried by every pass: a path outside the root (`outside_root`), a path that is not a regular file (`not_a_regular_file`), a missing copy (`local_copy_missing`) or a copy that does not match the asset's hash (`local_copy_differs`).
Its metadata gains `storage_placement_quarantined` and `storage_placement_quarantined_at`, the fallback record stays, and the pass goes on to the next asset.
Removing the two quarantine keys from the asset's metadata queues it again.
A row that a bundle import or a re-ingest changes while a pass is working on it is left as that change made it.
The assets still waiting are the gauge `optimal_engine_storage_assets_pending_placement`, and the quarantined ones the gauge `optimal_engine_storage_assets_placement_quarantined`, in `GET /api/metrics` (`gauges`) and in Prometheus.
Both are read from a count cached for a minute, so a scrape does not scan the assets table; it is dropped when an asset falls back to disk and refreshed by every pass.
`GET /api/storage/providers?probe=1` makes an authenticated request to the bucket and reports `s3` as `unreachable` while the object store is down; without `probe` it reports configuration only.
`scripts/proof-offsite-backup.sh` proves the outage, the recovery and the placement of the outage asset end to end against a real bucket.

## Offsite Backups

`Backup.create/2` runs an online SQLite backup with `VACUUM INTO`, catalogs it in `backup_records`, and verifies `PRAGMA integrity_check` before returning.
Adding `offsite: true` then encrypts the verified file, copies the ciphertext to the object store under `backups/<tenant>/<file name>.enc`, and marks the catalog row offsite and encrypted.

```bash
# One backup, shipped offsite
mix optimal.backup /var/backups/engine-$(date +%F).db --offsite

# What the catalog knows is out there, and the schedule's state
mix optimal.backup --list-offsite

# What the bucket holds, whether or not this catalog knows it
mix optimal.backup --list-offsite-objects
```

Over HTTP:

```bash
curl -s -X POST "$URL/api/backup" -H 'content-type: application/json' -d '{"name": "nightly.db", "offsite": true}' | jq
curl -s "$URL/api/backup/offsite" | jq
```

The backup is complete locally whether or not the copy succeeds.
A failed ship is reported in the response with `status: "failed"` and the command exits non-zero, so a scheduled job cannot mistake a broken bucket for a durable offsite copy.

Three checks stand between a local file and an object in the bucket.
The file must already be a verified catalog row, its bytes must still hash to the catalog checksum while they are encrypted, and the checksum the object store reports back must match the ciphertext.
An object that fails the last check is deleted rather than left in the bucket where a restore could later trust it.

### Encryption

The object store only ever holds ciphertext.
A copy is sealed on the engine's machine before upload with a key the bucket never sees, so the bucket's operator, a leaked bucket credential, or a public bucket does not expose the database.

```text
OPTIMAL_BACKUP_KEY   64 hex characters (32 bytes); required for every offsite copy
```

Generate the key once and store it the way `OPTIMAL_AUTHORITY_KEY` and `CONNECTOR_KEY` are stored:

```bash
openssl rand -hex 32
```

Without `OPTIMAL_BACKUP_KEY` an offsite copy is refused with `backup_key_missing` and a message naming the variable, and nothing is uploaded.
A key that is not 64 hex characters is refused with `backup_key_invalid`.
There is no setting that uploads a plaintext copy.
The local backup in `OPTIMAL_BACKUP_DIR` stays plaintext and stays on the machine.

Each copy has its own random 256-bit data key.
The backup is encrypted with AES-256-GCM in 1 MiB chunks, so a multi-gigabyte database is streamed through the cipher and never held in memory, and the data key is wrapped with AES-256-GCM under `OPTIMAL_BACKUP_KEY`.
Every chunk is authenticated together with the file header, its position, and whether it is the last chunk, so a changed byte, a changed header, a reordered or missing chunk, a truncated object, or appended bytes all fail to decrypt.

```text
"OEBACKUP" | version 1 | header length | JSON header | chunk frames (ciphertext + 16 byte tag)
header: cipher, chunk_bytes, key_id, wrapped_key, plaintext_bytes, plaintext_sha256, backup_id, sealed_at
```

The catalog row records that the copy is encrypted (`encrypted = 1`), the plaintext checksum (`checksum_sha256`), and in its metadata the ciphertext checksum, the cipher, and the key id.
The key id is the first 16 hex characters of a hash of the key, enough to tell which key sealed a copy and nothing about the key itself.
The sealed header carries the plaintext checksum and the key id too, so a copy can be checked and restored without the catalog that describes it.

### Losing Or Rotating The Key

Losing `OPTIMAL_BACKUP_KEY` means losing every copy sealed with it.
There is no recovery path and no copy of the key anywhere in the engine, by design.
Keep the key somewhere that survives the machine, such as a password manager or a secret manager, and never only beside the database it protects.

Rotating the key affects new copies only.
A copy sealed under the old key still needs the old key to restore, and a restore with the wrong key fails with `backup_key_mismatch` naming the key id the copy was sealed with.
Keep the old key until every copy sealed with it has been pruned.

### Scheduled Offsite Backups

The engine can take, encrypt, ship, and prune offsite backups on its own.
The schedule is off unless `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS` is set.

```text
OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS   interval between backups; 0 or unset disables; otherwise at least 60000
OPTIMAL_OFFSITE_BACKUP_KEEP          scheduled offsite copies to keep; default 14
OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL    scheduled local files to keep in OPTIMAL_BACKUP_DIR; default 3
```

Nightly backups with two weeks offsite:

```bash
OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS=86400000
OPTIMAL_BACKUP_KEY=<64 hex characters>
OPTIMAL_S3_ENDPOINT=... OPTIMAL_S3_BUCKET=... OPTIMAL_S3_CREDENTIALS_FILE=/etc/optimal/s3-credentials
```

Each run is a durable `backup.offsite` job on the engine's job queue.
Runs fall on fixed slots of the interval counted from the Unix epoch, so a daily interval runs once per UTC day, and a restart or a repeated tick never adds a second job for the same slot.
An engine that was down when a slot started runs it when it comes back.

A run takes a verified backup into `OPTIMAL_BACKUP_DIR`, encrypts it, ships it, and prunes.
The backup uses `VACUUM INTO` on its own SQLite connection, and the encryption and upload run in the scheduler's process, so the single-writer Store is only touched to catalog the result.
A run refuses to start without the backup key or the object store, rather than taking a backup it cannot ship.

Pruning keeps the newest `OPTIMAL_OFFSITE_BACKUP_KEEP` scheduled offsite copies and the newest `OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL` scheduled local files, and deletes the rest.
It only ever touches copies the schedule made: a backup taken by hand, with `mix optimal.backup` or `POST /api/backup`, is never deleted by the schedule.
Each catalog row records what was removed and when, and a backup with no copy left anywhere is marked `pruned`.

A failed run is never silent.
The job retries after five minutes, and a retry ships the backup its job already took instead of taking another.
After three attempts the job is dead-lettered.
The error is logged, and the schedule's state is reported in two places:

```bash
# The copies and the schedule: state, settings, last job, last success, dead letters
curl -s "$URL/api/backup/offsite" | jq .schedule

# The storage audit (503 when any check fails) includes the schedule as offsite_backup_schedule
curl -s "$URL/api/stores/audit" | jq '.checks[] | select(.name == "offsite_backup_schedule")'
```

`state` is `disabled`, `misconfigured` (the backup key or the object store is missing), `pending`, `running`, `retrying`, `failing` (the latest job was dead-lettered), `stale` (no run completed in two intervals), or `ok`.
The storage audit fails on `misconfigured`, `failing`, and `stale`.
The status reports whether a backup key is configured and its key id, never the key.

## Restore Drill

A backup that has never been restored is a hope, not a copy.
`Backup.restore_offsite/2` downloads a cataloged copy to a temporary file, checks it against the ciphertext checksum in the catalog, decrypts it with `OPTIMAL_BACKUP_KEY`, and restores the plaintext with exactly the guarantees the local restore applies: the checksum must match the catalog, `integrity_check` must pass, and the previous database is archived before anything is replaced.
The download is streamed to disk, so a large copy never sits in memory.
A wrong key is refused before the object is downloaded, and a changed object fails its checksum or its authentication; either way nothing is written to the target.
A plaintext copy shipped before offsite encryption existed still restores, checked against the catalog checksum.

```bash
# Restore an offsite copy into a fresh data directory
mix optimal.restore --from-offsite <backup-id> --data-dir /tmp/restore-drill

# Confirm the restored engine opens clean
sqlite3 /tmp/restore-drill/index.db "PRAGMA integrity_check;"
sqlite3 /tmp/restore-drill/index.db "SELECT COUNT(*) FROM workspaces;"
```

Over HTTP, with an admin key:

```bash
curl -s -X POST "$URL/api/backup/offsite/restore" -H 'content-type: application/json' \
  -d '{"backup_id": "<backup-id>", "target": "drill.db"}' | jq
```

An HTTP restore writes only to a file directly inside `restores/` under the engine backup directory (`OPTIMAL_BACKUP_DIR`).
An absolute path, a nested path, `..`, an existing symlink, or the live database is refused with 400, so no API key can make the Engine overwrite a file elsewhere on the host.
Restoring into another directory is an operator action: `mix optimal.restore --from-offsite <backup-id> --data-dir <dir>` on the host.
Every `/api/backup` route needs the `admin` scope.
A backup holds the whole Engine database, every tenant in it, so in an Engine shared by several tenants give admin keys only to the Engine's operator.

The bucket is read, never modified, and the temporary download and plaintext are removed afterwards, so the same drill can be repeated against the same backup.
Restoring over the live database still requires the engine to be stopped, and the restore refuses to run while the supervisor is up.

A drill that proves the whole path is: take a backup, ship it, delete the local copy so the object is the only source left, restore into a fresh data directory, and compare row counts.

### After Losing The Machine

The catalog lives in the database, so losing the machine loses the catalog too.
A sealed copy does not need it: its header carries the plaintext checksum and the id of the key that sealed it.
On a new machine with the same object store settings and the same `OPTIMAL_BACKUP_KEY`:

```bash
# Find the copies
mix optimal.backup --list-offsite-objects

# Restore one by its object key into a fresh data directory
mix optimal.restore --from-offsite-key backups/default/scheduled-20261019T000012Z-0a1b2c3d.db.enc \
  --data-dir /var/lib/optimal/restored
```

Every chunk is authenticated and the plaintext must match the checksum sealed into the object before the usual restore checks run.
Only sealed copies restore this way.

## Storage Mutations

`POST /api/storage/workspaces/:id/mutations` appends an entry to the workspace's replication ledger, and `GET` on the same path lists the workspace ledger after a sequence.
An entry's entity type is free-form, but it may not name a table of the engine or an `authority_*` table (422 `entity_type_names_a_table`), and its idempotency key may not start with the engine's own replica id followed by `:`, with `mut_` and that id, or with `peer:` (422 `reserved_idempotency_key`).
The Engine gives each entry its id, and the same key with the same change returns the entry already written, an entry written before these checks included.
Replication never serves or pushes an entry: see "Storage mutation entries share the ledger" in `docs/guides/replication.md`.

## NATS JetStream

`OPTIMAL_NATS_URL` is `nats://[user:password@|token@]host[:port]`, or `tls://` for TLS with the server's certificate and host name verified against the system's roots.
The URL carries the credential, so the Engine never logs it, describes it or returns it from the API.

The provider has two halves:

* The probe and the proof (`OptimalEngine.Storage.NATS`) each open a connection of their own: the probe is a PONG and a JetStream account answer, the proof a memory stream created, a message published, read back by sequence, and the stream deleted.
* The Engine's own client (`OptimalEngine.Storage.NATS.Connection`) is one long-lived connection, started at boot under `OptimalEngine.Storage.NATS.Supervisor` and kept for the life of the Engine.
  It answers the server's PINGs and sends its own every 30 seconds, and treats two unanswered ones as a dead connection.
  When the connection goes, every request still waiting is answered at once, and the client reconnects after an exponential backoff with jitter, from half a second up to 30 seconds, without ever giving up.
  While it is down, every call answers `not_connected` at once: nothing that runs through NATS waits on a server that is not there.
  Without `OPTIMAL_NATS_URL` it idles as `not_configured`. It reads the URL when it starts, so a changed URL takes a restart.

On that client, `OptimalEngine.Storage.NATS.JetStream` provisions streams (created when missing, left alone when they already hold the settings asked for, updated when one differs) and durable pull consumers with explicit acks, publishes with the stream's acknowledgement and a `Nats-Msg-Id` (a second publish of the same id within the stream's duplicate window is stored once), and pulls messages that are acknowledged, refused for redelivery (`-NAK`, at once or after a delay) or terminated one at a time.
It needs a server with JetStream enabled, 2.9 or later (the tests run against 2.11).

### Flows

Setting `OPTIMAL_NATS_URL` alone checks and proves the server; nothing the Engine holds leaves it.
`OPTIMAL_NATS_FLOWS` names what runs through JetStream, a comma-separated list or `all`:

| Flow | What runs through JetStream | Without NATS, or while it is down |
| --- | --- | --- |
| `ledger` | The change ledger of every workspace enabled for replication, as stream `<NAMESPACE>_LEDGER` | The ledger stays in SQLite (`sync_mutations`), as it always does; the backlog goes out when NATS is back |
| `jobs` | The dispatch of background jobs: every queued job announced on `<NAMESPACE>_JOBS`, its worker woken when it is due | Workers poll the `jobs` table as they always have; jobs queued meanwhile are announced when NATS is back |
| `intake` | Connector pulls: each pulled Signal queued on `<NAMESPACE>_INTAKE` and ingested by the queue's consumer | The pull ingests its Signals in process, as it always has |

Every subject and stream starts with `OPTIMAL_NATS_NAMESPACE` (default `optimal`, stream names upper-cased: `OPTIMAL_LEDGER`).
Two Engines on one NATS account need two namespaces.
No flow makes an Engine write wait on NATS or fail because NATS is down: each one reads what the Engine has already stored durably, and sends it afterwards.
The provider's `serves` names the flows that are on (`change_ledger_stream`, `background_job_dispatch`, `connector_intake_queue`).

### The change ledger stream

With `ledger` on, `OptimalEngine.Storage.NATS.LedgerPublisher` publishes, every second, what `GET /api/sync/changes` would serve a peer that pulls: the changes of the workspaces enabled for replication, only the tables that replicate, and never a row the data-class gate keeps home (`config :optimal_engine, :sync_serve_max_class`, default `confidential`).
A workspace that is not enabled for replication has no ledger, and nothing of it is published.
Storage mutation entries (`POST /api/storage/workspaces/:id/mutations`) are not changes and are not published either.

* Stream `<NAMESPACE>_LEDGER`, file storage, limits retention, kept `OPTIMAL_NATS_LEDGER_MAX_AGE_HOURS` (default 168, `0` keeps it forever).
* Subject `<namespace>.ledger.<tenant>.<workspace>.<table>.<row>`, one per row, each id made a subject token: bytes other than letters, digits, `_` and `-` are percent-encoded (`default:notes` is `default%3Anotes`).
  Follow one workspace with `<namespace>.ledger.<tenant>.<workspace>.>` as a consumer's filter, one row with its own subject, or everything with `<namespace>.ledger.>`.
* Each message is one change as JSON, the shape a peer pulls (`sequence`, `id`, `device_id`, `entity_type`, `entity_id`, `operation`, `payload`, `payload_hash`, `idempotency_key`, `occurred_at`) with `tenant_id` and `workspace_id`.
  Headers: `Nats-Msg-Id` (the change's id), `Optimal-Ledger-Seq`, `Optimal-Entity-Type`, `Optimal-Operation`, `Optimal-Replica`.

Changes go out one at a time in ledger order, each acknowledged by the stream before the next, so a workspace's subject holds its changes in the order the Engine made them.
A publish whose acknowledgement was lost is sent again with the same message id, and the stream stores it once.
Where to resume is read from the stream (the `Optimal-Ledger-Seq` of the last message on the workspace's subject) at start and after every reconnect: a restart repeats nothing, and a stream that was deleted or lost is filled again from the start of the ledger.

`runtime.flows.ledger` in `GET /api/storage/providers/nats_jetstream` says where it stands: `state` (`off`, `buffering` while NATS is down, `publishing` while a backlog remains, `caught_up`, `error` with `last_error`), the changes published since start, and each workspace's `published_through` and `backlog`.

The stream is a copy for subscribers, not a replication transport: Engines still replicate over HTTP or the MIOSA relay (see [Replication](replication.md)), and a peer's conflict detection, gates and version checks do not apply to a reader of the stream.
The stream follows what the Engine forgets (next section); the age limit bounds the rest.
The stream holds workspace content up to the serve ceiling, so the NATS account needs the same care as a replication peer.

### What the Engine forgets leaves the stream

The Engine's own ledger is append-only (see [Erasure And Retention](erasure-and-retention.md)), so the stream cannot be refilled from it naively.
The publisher keeps the stream to what the Engine still holds instead:

* A forget is a `delete` in the ledger (an erasure, a retention delete, a derived-data removal, any delete) or a `memories` change that sets `is_forgotten` (`Memory.forget/2`).
  Before the forget goes out, every earlier message on the row's subject is purged, and the message that replaces them is a tombstone: a delete carries the row's key only, a forgotten memory its `id` and `is_forgotten` and nothing it said.
* A create or update that a later forget in the ledger covers is never published, so a stream filled again from the ledger (after a loss, or a first start after the forget) holds nothing forgotten either.
* An archived workspace (`Workspace.archive/1`) and the old id of a renamed one (`DataSteward.rename_workspace/3`) have their whole subject tree purged (`<namespace>.ledger.<tenant>.<workspace>.>`), and an archived workspace is no longer published.
  The request is written first as an `events` row (`kind = 'nats_purge_requested'`), done at once when NATS is reachable and otherwise on the next pass after it is, so a purge asked for during an outage, or across a restart, is not lost.

Every purge is evidence in `events`:

| `kind` | `target_uri` | `metadata` |
| --- | --- | --- |
| `nats_purge` | `workspace:<id>` | A pass that forgot rows: `rows_forgotten`, `messages_purged`, `through_sequence`, `stream` |
| `nats_purge_requested` | `workspace:<id>` | A workspace purge asked for: `reason` (`archived`, `renamed`), `namespace` |
| `nats_purge` | `nats-purge-request:<request id>` | That purge done: `messages_purged`, `subjects`, `reason` |

An erasure (`Compliance.Erasure.erase/2`) runs a pass over the erased workspaces before it reports, and its report and `erasure` audit event carry `nats_ledger`: `messages_purged` and `rows_forgotten`, `state: "off"` without the flow, or `pending: true` while NATS is down, in which case the purge happens when the deletes go out and is recorded as a `nats_purge` event.
`runtime.flows.ledger` counts `messages_purged` and the workspace purges still pending (`purges_pending`).

What this does not cover: the Engine's own derived rows that a soft forget leaves (`Memory.forget/2` marks the memory, and the source package and claim its creation wrote keep their text in the Engine, and so on the stream, until they are deleted); a subscriber's own copy of what it already read; and the intake queue, whose items carry connector content until they are ingested, dead-lettered or requeued.

### Background jobs

With `jobs` on, `OptimalEngine.Storage.NATS.JobQueue` dispatches background jobs through stream `<NAMESPACE>_JOBS` (work-queue retention, one durable consumer).
The `jobs` table stays the record of every job: its lease, attempts, backoff and dead letters work exactly as without NATS.

* A job queued by `Jobs.enqueue/4`, `enqueue_exclusive/5`, `enqueue_coalesced/4`, `complete_and_enqueue/4` or `replay_dead_letter/3` is announced on `<namespace>.jobs.<kind>`, with the job's id as the message id, after its row is committed.
  Announcing is a message to a local process: it never fails or delays the enqueue.
* Each time the job's message is delivered, the consumer reads the job's row.
  Finished (`completed`, `dead`) or gone: the message is acknowledged and leaves the queue.
  Due (`available` past its `run_at`, or `running` with an expired lease): the worker for its kind is woken at once, and the message comes back five seconds later to see it finished.
  Not due yet: it comes back when the job will be due, at most an hour later.
* Woken by kind: `reindex`, `import.*`, `analysis.*` and `maintenance.*`, each only while its worker's own interval is above zero, so a worker an operator turned off stays off.
  Bundle jobs and offsite backups are announced and followed to completion, and run when their worker next polls.
* Every new connection starts by announcing every job still queued or running (oldest first, up to 5000); the stream's duplicate window is an hour, so a job announced twice is stored once.

So the stream holds one message for every unfinished job, a worker starts a job when it is queued instead of at its next poll, and no job is lost to a restart of the Engine or of NATS: the row is committed before the announcement, and the message is acknowledged only when the row says the job is finished.
The workers still poll the `jobs` table: that is the in-process path, and the one jobs take while NATS is down.

### Connector intake

With `intake` on, a connector pull hands its Signals to `OptimalEngine.Storage.NATS.IntakeQueue`, which queues each one on stream `<NAMESPACE>_INTAKE` at `<namespace>.intake.<tenant>.<connector>` and waits for the stream's acknowledgement before the Runner moves the connector's cursor.
A Signal is therefore either stored in the stream or ingested in the pull, never neither: what could not be queued (NATS down, or gone mid-way) is ingested in process, as without NATS.

The queue's durable consumer ingests each Signal through the same intake as the in-process path, with the connector's current routing config read from its row.
A stored Signal is acknowledged and leaves the queue.
One intake refuses is terminated and logged, as the in-process path logs it; one whose connector was deleted since is terminated.
One whose intake raised is delivered again after a backoff (one second, doubling to ten minutes), up to ten deliveries; the delivery that fails at the cap, or one that arrives past it unanswered, moves it to the dead letters (next section) and off the queue.
JetStream's own `max_deliver` is the cap plus one, so that last delivery is still seen.
One the Engine stopped in the middle of is delivered again after ten minutes.
The message id is `<connector>:<signal id>`: a pull that runs again over items it already queued queues each once inside the stream's duplicate window (two minutes), and intake stores a source item once whatever arrives.

A refusal at consumption, and a dead letter, are counted in the `connector_runs` row of the pull that queued the Signal (its id travels with the message): `errors_encountered` goes up by one and `error_detail` counts them as `queue_refused` and `dead_lettered`.
The row is written when the pull ends, so a refusal that comes while the pull still runs waits for it: the message comes back two seconds later instead of the count being lost.
The Signal's content is in the stream until it is ingested, so the NATS account holds connector content in the meantime.

### Dead letters

An item a work queue gave up on is kept in stream `<NAMESPACE>_DEAD_LETTERS` (limits retention, file storage, kept until requeued or purged), on `<namespace>.dead.<flow>`, with its payload as it was queued and headers saying why: `Optimal-Flow`, `Optimal-Subject` (where it was queued), `Optimal-Delivered`, `Optimal-Error` (the last failure, one line, at most 500 bytes), `Optimal-Stream-Seq`.
Intake is the flow that dead-letters; a job is never dead-lettered here, because the `jobs` table already dead-letters a job that runs out of attempts (`dead_letter_jobs`), and a job's message comes back for as long as the job is not finished.

The inventory counts them (`runtime.dead_letters`: `total` and per flow).
The Engine operator lists and requeues them; a letter is listed without its payload:

```bash
curl -s localhost:4200/api/maintenance/nats/dead-letters?flow=intake
curl -s -X POST localhost:4200/api/maintenance/nats/dead-letters/42/requeue
mix optimal.nats dead-letters --flow intake
mix optimal.nats requeue 42
```

Both routes need an admin key of the default tenant whose workspace scope is `*` (403 `operator_only` otherwise), because the letters are every tenant's.
A requeue publishes the payload to its original subject under a new message id (`requeue:<namespace>:<seq>`) and deletes the letter; 404 when there is no such letter, 503 while NATS is not reachable.

### Replication over NATS: not implemented

Engines replicate over HTTP or the MIOSA relay (see [Replication](replication.md)); NATS is not a sync transport, and the ledger stream is not one either.
The ledger stream is a one-way copy at the Engine's own serve ceiling.
A replication transport would have to carry what each HTTP exchange carries today, and none of it maps onto a stream subscription:

* Identity and grants: a peer authenticates with a replica key that holds the `sync` scope, and the receiving Engine binds the tenant and the workspace to it. A NATS account's publish and subscribe permissions are not that key, and the Engine cannot verify a NATS subscriber.
* The per-peer data-class gate: each peer has its own `max_class`, applied on send and on receive. One stream at the serve ceiling cannot hold a lower ceiling per peer.
* Conflict detection: a push carries the sender's `base_seq` and `base_replica_id`, a pull keeps the `local_floor` of the last complete cycle, and the receiver answers `base_rejected` when it does not trust the base. These are per-exchange request and reply, not fire-and-forget messages.
* Version safety: every page carries the sender's schema migration, and a mismatch pauses sync with a message. A stream message carries no migration.
* Bookkeeping keyed by the peer: cursors, push sequences, run history and labels in `sync_peers`, `sync_cursors` and `sync_runs`.

Doing it means a transport behaviour in `OptimalEngine.Sync` (today the HTTP and relay calls are chosen by the peer URL inside `Sync.run_peer/1`), a NATS request and reply pair on per-Engine subjects that carries the replica key and is checked like the HTTP bearer, and a responder that serves `changes/3` and `apply_changes/4` to it.
That is a change to the replication engine's core, not to the provider, and it is not in this release.

`GET /api/storage/providers` shows the client under the provider's `runtime.client`: `state` (`connected`, `connecting`, `disconnected`, `not_configured`), `reconnects` (connections lost since the Engine started), `last_error`, `connected_since`, `server` (`version`, `jetstream`) and `pending` (requests waiting on an answer).

```console
$ curl -s localhost:4200/api/storage/providers/nats_jetstream | jq -c .runtime.client
{"connected_since":"2026-11-08T10:00:00Z","last_error":null,"pending":0,"reconnects":0,"server":{"jetstream":true,"version":"2.11.17"},"state":"connected"}
```

The integration tests run the client against a real server and are skipped without one:

```bash
docker run --rm -d -p 127.0.0.1:4222:4222 nats:2.11 -js
OPTIMAL_TEST_NATS_URL=nats://127.0.0.1:4222 mix test test/storage/nats_jetstream_integration_test.exs
```

## Provider Status

One Engine instance is the default data layer: it holds every store inside it and runs no Postgres, Qdrant, or Redis next to it.
Providers are what a deployment grows onto, and this table is the status of each in this repository.
"Wired" means a working adapter exists, "partial" means the adapter works with listed limits, and "declared" means the inventory lists the provider and no adapter exists.

| Provider | Status | What works | What does not |
| --- | --- | --- | --- |
| SQLite, FTS5, embedded vectors, filesystem, ETS | Wired, the default | Everything the Engine stores | |
| RocksDB | Wired, opt in | A persistent triple-store mirror of `graph_edges` (`OPTIMAL_KNOWLEDGE_BACKEND=rocksdb`) | Falls back to ETS when the native library is missing |
| `s3` (S3-compatible: Garage, AWS S3, R2, MinIO, a MIOSA bucket) | Wired | Asset bytes, offsite backups, the probe and the placement reconciler | |
| `postgres` | Wired, partial | The canonical relational store of a compile-time `OPTIMAL_STORE=postgres` build | Replication and the engine's backup routes; moving an existing Engine to it |
| `nats_jetstream` | Wired | The probe and the proof, a supervised JetStream client that reconnects with backoff, and with `OPTIMAL_NATS_FLOWS` the change ledger published as a stream per workspace subject, background jobs dispatched through a work queue, and connector intake queued | Replication between Engines does not use it (see "Replication over NATS: not implemented") |
| `valkey` | Wired, in the data path | The probe (PING), the proof (set, get, delete), and, over a supervised connection pool, the API and connector rate limits, the verified API key cache and the sync gate cache ([Valkey](#valkey)), over `OPTIMAL_VALKEY_URL`, TLS with `rediss://` | Durable data: everything in it can be lost, and is rebuilt or falls back to ETS |
| `qdrant` | Wired | The probe (list collections with the key) and the proof (a collection created, a point upserted, searched and read back, the collection deleted) over `OPTIMAL_QDRANT_URL` | The Engine's vector search still reads the embedded vectors |
| `duckdb` (DuckDB and Parquet) | Wired | The probe (a query through the `duckdb` executable against a writable `OPTIMAL_ANALYTICS_PATH`) and the proof (a Parquet file written and read back) | No Engine projection is written to it yet |
| `openbao` | Wired | The probe (unsealed, token accepted) and the proof (a KV v2 secret written under `optimal/proof/`, read back and deleted) over `OPTIMAL_OPENBAO_ADDR` | The Engine's own secrets still come from the environment |
| `fractal` | Declared, no adapter yet | | Everything |

`GET /api/storage/providers` reports `adapter_implemented` for each entry and `adapter_missing` as the lifecycle state of the declared ones, whatever is configured.

## Use Cases And Plans

A use case names the capabilities a workspace needs and the providers that supply them.
`OptimalEngine.Storage.Planner` turns use cases into a plan.
A plan is advice: it never enables a provider and never moves data.

`GET /api/storage/use-cases` lists the use cases:

```bash
curl -s "$URL/api/storage/use-cases" | jq '.use_cases[] | {id, providers}'
```

```json
{"use_cases": [{"id": "cloud_team", "label": "Multi-user cloud workspace", "providers": ["postgres", "s3", "openbao", "nats_jetstream", "valkey"], "reason": "Concurrent writes, durable artifacts, managed secrets, and distributed coordination"}], "count": 11}
```

The entries are sorted by `id`, and each has `id`, `label`, `providers`, and `reason`.

| Use case id | Providers |
| --- | --- |
| `desktop_local` | `sqlite`, `fts5`, `embedded_vectors`, `rocksdb`, `filesystem`, `ets` |
| `cloud_team` | `postgres`, `s3`, `openbao`, `nats_jetstream`, `valkey` |
| `multi_device` | `postgres`, `s3`, `nats_jetstream`, `openbao` |
| `high_volume_connectors` | `nats_jetstream`, `s3`, `postgres` |
| `analytics` | `duckdb` |
| `high_scale_semantic` | `qdrant` |
| `media_archive` | `s3` |
| `regulated` | `postgres`, `s3`, `openbao`, `nats_jetstream` |
| `enterprise_ai` | `postgres`, `s3`, `openbao`, `nats_jetstream`, `fractal` |
| `geospatial` | `postgres` |
| `time_series` | `postgres`, `duckdb` |

`POST /api/storage/plan` plans one or more use cases.
The body is `{"use_cases": ["media_archive", "analytics"], "probe": false}`, where `use_cases` is a list or a comma-separated string, and `probe: true` makes each provider run its health probe.

```bash
curl -s -X POST "$URL/api/storage/plan" -H 'content-type: application/json' \
  -d '{"use_cases": ["media_archive"]}' | jq '{ready, activation_required, adapter_missing}'
```

The response has this shape:

| Field | Meaning |
| --- | --- |
| `use_cases` | The use cases asked for, each with `id`, `label`, `providers`, `reason` |
| `providers` | The union of their providers, each as in the provider inventory |
| `ready` | `true` only when every selected provider is `active` or `available`, and a canonical store is the one this build runs |
| `activation_required` | Ids of the providers that are not ready |
| `adapter_missing` | Ids of the providers with no adapter |
| `invariant` | The rule that projections and transports never become truth |

An unknown use case answers 422 with `{"error": "unknown use cases", "unknown": ["..."]}`.
A plan that selects a provider with no adapter is never `ready`; `cloud_team` and `regulated` are ready once every provider they select is configured and answers its probe.
`media_archive` is ready once the `s3` provider is configured and a plan made with `"probe": true` finds it healthy.

The same is available from the shell as `mix optimal.storage use-cases` and `mix optimal.storage plan <ids>`.

## Recipe: Garage

Garage is a small open-source S3 server that fits one machine.
This recipe runs it next to the Engine and uses it for assets and encrypted offsite backups.

1. Start Garage and the Engine with the storage overlay, then wait for both to be healthy:

   ```bash
   cd deploy
   docker compose -f docker-compose.yml -f docker-compose.storage.yml --profile storage up -d
   ```

   The overlay runs Garage in single-node mode with the bucket `optimal-artifacts` and a development key.
   Replace the key and secret (`OPTIMAL_S3_ACCESS_KEY_ID`, `OPTIMAL_S3_SECRET_ACCESS_KEY`) in `deploy/.env` before anything but a trial.

2. Set the region to the value in `deploy/storage/garage.toml`.
   Garage signs for the `s3_region` it is configured with (`garage` in the shipped file), and a request signed for another region is rejected.

   ```dotenv
   OPTIMAL_S3_ENDPOINT=http://garage:3900
   OPTIMAL_S3_BUCKET=optimal-artifacts
   OPTIMAL_S3_REGION=garage
   OPTIMAL_S3_ACCESS_KEY_ID=<garage key id>
   OPTIMAL_S3_SECRET_ACCESS_KEY=<garage secret>
   OPTIMAL_ASSET_STORAGE=s3
   OPTIMAL_BACKUP_KEY=<64 hex characters>
   OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS=86400000
   ```

   Path-style addressing is the default and is what Garage serves, so leave `OPTIMAL_S3_PATH_STYLE` unset.

3. Prove the provider end to end:

   ```bash
   curl -s "$URL/api/storage/providers/s3?probe=true" -H "Authorization: Bearer $KEY" | jq '{health, lifecycle_state}'
   ```

   Expect `healthy` and `available`.
   `unreachable` with a good key means the region does not match `s3_region`.

4. Ingest a file and confirm its `storage_path` starts with `s3://optimal-artifacts/`.

5. Take an offsite backup and list it:

   ```bash
   curl -s -X POST "$URL/api/backup" -H "Authorization: Bearer $KEY" -H 'content-type: application/json' -d '{"name": "first.db", "offsite": true}' | jq .offsite
   curl -s "$URL/api/backup/offsite" -H "Authorization: Bearer $KEY" | jq '.backups[0], .schedule.state'
   ```

6. Run the [restore drill](#restore-drill) into a fresh data directory before you rely on it.

Keep `OPTIMAL_BACKUP_KEY` away from the machine, and give a Garage bucket that holds more than one Engine's data one `OPTIMAL_S3_PREFIX` per Engine.

## Valkey

With `OPTIMAL_VALKEY_URL` set (`redis://[user:password@]host[:port][/db]`, `rediss://` for TLS), the Engine starts a supervised pool of connections to it at boot and keeps there what its processes must agree on:

| What | Module | Without Valkey |
| --- | --- | --- |
| HTTP API rate limits, one token bucket per key or IP | `OptimalEngine.API.RateLimiter` | one bucket per key per Engine process |
| Outbound connector rate limits | `OptimalEngine.Connectors.RateLimit` | one bucket per connector per Engine process |
| API key secrets bcrypt already verified, and their removal on revoke or delete | `OptimalEngine.Auth.KeyCache` | per process |
| The workspace scans a sync gate reuses, per store | `OptimalEngine.Sync.GateCache` | per process |

All of it goes through `OptimalEngine.Storage.Shared`, a small cache, counter, lock and token-bucket interface whose fallback is the process's own ETS table.
Nothing durable lives in Valkey, and every key it holds has a TTL.

| Setting | Default | Meaning |
| --- | --- | --- |
| `OPTIMAL_VALKEY_URL` | unset | Unset: no pool, everything on ETS, as before. |
| `OPTIMAL_VALKEY_POOL_SIZE` | 4 | Connections per Engine process (1 to 32). |
| `OPTIMAL_VALKEY_TIMEOUT_MS` | 500 | How long a command waits for its reply before the call is answered from ETS. |

Valkey being down never fails a request.
A connection that cannot open, or fails mid-command, is closed and opened again with a backoff of 100 ms doubling to 5 seconds; while no connection is up every call runs on ETS at once, and a server that stops answering costs one timeout per connection before that.
A removal Valkey could not take while it was unreachable (a revoked key, a cleared gate cache) is kept and applied before anything is read from Valkey again, so a revoked key's entry is never read back.
`ApiKey.verify/1` reads the key row on every request in any case, so a revocation takes effect at once whatever any cache holds.

What is stored, and how:

* Keys are `optimal:shared:<namespace>:<generation>:<key>`; clearing a namespace moves its generation in one command, and the old keys expire.
* Cached values are signed with an HMAC: a value this Engine did not write reads as a miss. The key comes from `CONNECTOR_KEY`; give every process that shares a Valkey the same `CONNECTOR_KEY` and they share cache entries, otherwise each reads only its own (the rate limits are shared either way).
* The key cache stores the SHA-256 of the stored bcrypt hash and the secret, never either of them.
* A gate cache entry is keyed by the Engine's replica id, so Engines with stores of their own never share one.
* The URL and its credential are never logged or returned; the inventory shows only whether TLS is on and how many connections are up (`OptimalEngine.Storage.Valkey.Adapter.status/1`).

The scripts need a standalone Valkey (or Redis 7 or later); Valkey Cluster is not supported, because a script reads the namespace generation next to the key.
`mix test --only valkey` with `OPTIMAL_TEST_VALKEY_URL=redis://127.0.0.1:6390/15` runs the shared interface against a real server (for example `docker run --rm -p 6390:6379 valkey/valkey:8.1`).

## What Is Not Implemented

The Engine has no adapter for Fractal, and the provider inventory says so; NATS JetStream, Qdrant, OpenBao and DuckDB are reached and proved, but no Engine feature is served from them yet.
Valkey carries the rate limits and caches listed under [Valkey](#valkey) and nothing durable.
PostgreSQL holds the canonical relational store but not replication, and moving an existing Engine's data to it (stage 4 of [PostgreSQL Provider](postgres-provider.md)) is not implemented.
An embedded deployment remains the default, and no provider is activated by configuration alone: canonical store changes and cross-workspace routing are reviewed deployment decisions, and `OptimalEngine.Storage.Planner` reports a plan that selects a provider without an adapter as not ready.

## Related

- `docs/guides/installation-and-deployment.md` describes the four deployment modes and the environment variables a runtime reads.
- `docs/guides/miosa-managed-engine.md` describes the MIOSA-managed mode.
- `docs/guides/store-and-layer-reality.md` describes what each logical store is proved to do on a running engine.
- `docs/guides/replication.md` describes the workspace sync ledger and how peers carry it, over HTTP or the MIOSA relay.
