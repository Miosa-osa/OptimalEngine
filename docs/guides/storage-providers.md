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
```

Two rules make the inventory trustworthy.

A provider is only usable when the engine ships an adapter for it.
A provider listed without an implementing module reports `adapter_missing` regardless of configuration or a reachable endpoint, because a healthy remote service the engine cannot talk to is not available storage.

Health is only claimed on evidence.
Without `probe=true` a configured service provider reports `configured_unverified`, and with `probe=true` the adapter makes a real authenticated request.

The embedded providers report `active` because the running engine uses them.
RocksDB is the exception: it is `active` only when `OPTIMAL_KNOWLEDGE_BACKEND=rocksdb` put the knowledge store on it, and on an ETS knowledge store it reports `available`.

Provider status never returns credentials, connection strings, or secret values; only the names of the environment variables a provider reads.

Today `s3` and `postgres` are the service providers with an adapter.
`nats_jetstream`, `valkey`, `qdrant`, `duckdb`, `openbao`, and `fractal` are declared, and they report `adapter_missing` until an adapter ships for each.

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

## What Is Not Implemented

The engine still has no adapter for NATS JetStream, Valkey, Qdrant, DuckDB, OpenBao, or Fractal, and the provider inventory says so.
PostgreSQL holds the canonical relational store but not full-text search, and moving an existing engine's data to it (stage 4 of [PostgreSQL Provider](postgres-provider.md)) is not implemented.
An embedded deployment remains the default, and no provider is activated by configuration alone: canonical store changes and cross-workspace routing are reviewed deployment decisions, and `OptimalEngine.Storage.Planner` reports a plan that selects a provider without an adapter as not ready.

## Related

- `docs/guides/installation-and-deployment.md` describes the deployment profiles and the environment variables a runtime reads.
- `docs/guides/store-and-layer-reality.md` describes what each logical store is proved to do on a running engine.
- `docs/guides/replication.md` describes the workspace sync ledger that a distributed runtime would transport.
