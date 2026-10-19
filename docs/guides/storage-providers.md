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

Provider status never returns credentials, connection strings, or secret values; only the names of the environment variables a provider reads.

Today `s3` is the service provider with an adapter.
`postgres`, `nats_jetstream`, `valkey`, `qdrant`, `duckdb`, `openbao`, and `fractal` are declared, and they report `adapter_missing` until an adapter ships for each.

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
```

Path-style addressing is the default because it works against every S3-compatible endpoint.
Hosted AWS prefers virtual-hosted addressing, which a deployment opts into with `OPTIMAL_S3_PATH_STYLE=false`.

Credentials are read from the environment on every call.
They are never written to a database, logged, or placed in an error value, and `OPTIMAL_S3_TRACE` deliberately prints the canonical request and the string to sign, neither of which contains the secret.

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
The bytes are written to the local filesystem, the asset row records `storage_fallback_reason`, and the engine logs an error alert, because an upload that failed to leave the machine must not be reported as a successful remote store.

## Offsite Backups

`Backup.create/2` runs an online SQLite backup with `VACUUM INTO`, catalogs it in `backup_records`, and verifies `PRAGMA integrity_check` before returning.
Adding `offsite: true` then copies the verified file to the object store under `backups/<tenant>/<file name>` and marks the catalog row offsite.

```bash
# One backup, shipped offsite
mix optimal.backup /var/backups/engine-$(date +%F).db --offsite

# What is out there
mix optimal.backup --list-offsite
```

Over HTTP:

```bash
curl -s -X POST "$URL/api/backup" -H 'content-type: application/json' -d '{"name": "nightly.db", "offsite": true}' | jq
curl -s "$URL/api/backup/offsite" | jq
```

The backup is complete locally whether or not the copy succeeds.
A failed ship is reported in the response with `status: "failed"` and the command exits non-zero, so a scheduled job cannot mistake a broken bucket for a durable offsite copy.

Three checks stand between a local file and an object in the bucket.
The file must already be a verified catalog row, its bytes must still hash to the catalog checksum, and the checksum the object store reports back must match too.
An object that fails the last check is deleted rather than left in the bucket where a restore could later trust it.

## Restore Drill

A backup that has never been restored is a hope, not a copy.
`Backup.restore_offsite/2` downloads a cataloged copy, checks it against the catalog checksum, and restores it with exactly the guarantees the local restore applies: the checksum must match, `integrity_check` must pass, and the previous database is archived before anything is replaced.

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

The bucket is read, never modified, and the temporary download is removed afterwards, so the same drill can be repeated against the same backup.
Restoring over the live database still requires the engine to be stopped, and the restore refuses to run while the supervisor is up.

A drill that proves the whole path is: take a backup, ship it, delete the local copy so the object is the only source left, restore into a fresh data directory, and compare row counts.

## What Is Not Implemented

The engine still has no adapter for Postgres, NATS JetStream, Valkey, Qdrant, DuckDB, OpenBao, or Fractal, and the provider inventory says so.
An embedded deployment remains the default, and no provider is activated by configuration alone: canonical store changes and cross-workspace routing are reviewed deployment decisions, and `OptimalEngine.Storage.Planner` reports a plan that selects a provider without an adapter as not ready.

## Related

- `docs/guides/installation-and-deployment.md` describes the deployment profiles and the environment variables a runtime reads.
- `docs/guides/store-and-layer-reality.md` describes what each logical store is proved to do on a running engine.
- `docs/guides/replication.md` describes the workspace sync ledger that a distributed runtime would transport.
