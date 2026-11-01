# Optimal Engine Deployment

Docker is optional.
The normal local path is still:

```bash
make install
make bootstrap
make dev
curl http://localhost:4200/api/health
```

Local runtime state is created under `.optimal/`.
That directory contains the SQLite store, caches, WAL files, and the local connector key.
It is ignored by git and should not be committed or copied into public docs.

Use this directory when you want a packaged backend service with a persistent data volume and HTTP API.
The deployment modes, and which one fits, are in [Installation and deployment](../docs/guides/installation-and-deployment.md).

## What Runs By Default

```bash
cd deploy
cp env.example .env
docker compose up --build
```

Default service:

| Service | URL | Purpose |
| --- | --- | --- |
| `engine` | `http://localhost:4200` | One Elixir/OTP process that holds every store: SQLite with FTS5, vectors, and the graph edges, assets, caches, jobs, the change ledger, and backups. |

The Engine does not need Postgres, Qdrant, or Redis, and it does not start them.
Optional app, docs, and site surfaces are not part of the backend contract.
Start them only when you explicitly need them:

```bash
docker compose --profile surfaces up --build
```

## Volume Layout

The engine container uses `/data` as its only writable volume.
The image's runtime root is `/data`, and its database, cache, and topology paths are set by environment variables.

```text
/data/
  .optimal/
    index.db                  the SQLite store (OPTIMAL_ENGINE_DB)
    index.db-wal              write-ahead log, part of the live database
    index.db-shm              shared-memory file, part of the live database
    backups/                  verified backups (OPTIMAL_BACKUP_DIR, default: beside the database)
    cache/                    rebuildable cache (OPTIMAL_ENGINE_CACHE)
    embed_cache.key           secret that names the embedding cache entries, next to the database
    imports/                  staging area for imports, next to the database
    knowledge-rocksdb/        the triple-store mirror, only when you select RocksDB and
                              point OPTIMAL_KNOWLEDGE_ROCKSDB_PATH here
    config.yaml               workspace topology (OPTIMAL_ENGINE_TOPOLOGY)
  topology.yaml               root topology (OPTIMAL_ENGINE_TOPOLOGY_FULL)
  <workspace folders>/        workspace files and asset bytes kept on the filesystem
```

What each part is:

| Path | Truth or rebuildable | Notes |
| --- | --- | --- |
| `index.db` and its `-wal`, `-shm` | Truth | Never copy these three files while the Engine runs. Use `POST /api/backup`. |
| `backups/` | Copies | Plaintext. Treat it as sensitive and move copies off the machine. |
| Workspace folders and asset bytes | Truth | Not inside the database backup. Keep assets in S3 (see below) or snapshot the volume with the Engine stopped. |
| `cache/` | Rebuildable | Safe to delete. |
| `embed_cache.key` | Part of the cache | Losing it empties the embedding cache, which is rebuilt on demand. |
| `knowledge-rocksdb/` | Rebuildable | A mirror hydrated from the `graph_edges` table in `index.db`. |

The graph that search and assembly read is the `graph_edges` table in `index.db`.
The triple store is a mirror rebuilt from it, and no retrieval path reads it.
The image does not set `OPTIMAL_KNOWLEDGE_BACKEND`, so the mirror is ETS, held in memory and reloaded from `index.db` at every start.
To keep the mirror on the volume, set both variables:

```dotenv
OPTIMAL_KNOWLEDGE_BACKEND=rocksdb
OPTIMAL_KNOWLEDGE_ROCKSDB_PATH=/data/.optimal/knowledge-rocksdb
```

Without the path variable RocksDB would write `.optimal/knowledge-rocksdb` under the container's working directory, which is not on the volume.
If RocksDB is requested and its native library is missing, the Engine falls back to ETS and logs a warning.

## Secrets Stay Outside The Container

Three keys are generated once and kept outside the container and outside the data volume:

| Variable | Seals | If lost |
| --- | --- | --- |
| `CONNECTOR_KEY` | Connector and peer credentials stored in the database. | Stored credentials cannot be read; reconnect each connector. |
| `OPTIMAL_AUTHORITY_KEY` | The authority signing keys stored in the database. | The wrapped signing keys cannot be opened. |
| `OPTIMAL_BACKUP_KEY` | Offsite backup copies. | Every offsite copy sealed with it is unrecoverable. |

Generate each once, and keep a copy away from the machine:

```bash
openssl rand -hex 32
```

Put them in `deploy/.env` (mode 600, ignored by git) or in your secret manager, never in the image or the volume.
`docker-compose.yml` passes them through from that file when they are set, so replacing the container or the image keeps the same keys.
A container started with new random keys cannot read what the old ones sealed.

## Optional Storage Profile

The default deployment is self-contained and needs no external service.
Use the optional overlay to add an S3-compatible object store for assets and offsite backups.

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.storage.yml \
  --profile storage up -d
```

Only S3 is usable by the stock image today.
The overlay starts Garage and points the Engine at it with development credentials.
Replace every development credential before exposing the service.

| Service in the overlay | Status |
| --- | --- |
| Garage (S3) | Wired. Assets and offsite backups. |
| PostgreSQL | Wired but partial, and only for a custom engine built with `OPTIMAL_STORE=postgres` at compile time. Behind the separate `postgres` profile. The stock image keeps its data in SQLite. |
| NATS JetStream, Valkey, Qdrant, OpenBao | No adapter yet. Commented out in the overlay. |

Garage signs requests for the region in `storage/garage.toml` (`s3_region = "garage"`).
The overlay sets `OPTIMAL_S3_REGION` to the same value; if you change one, change the other.
Add `OPTIMAL_ASSET_STORAGE=s3` to keep asset bytes in the bucket, and see [Storage providers](../docs/guides/storage-providers.md) for the full recipe, including scheduled encrypted offsite backups.
Fractal Computing is configured separately as an enterprise partner substrate and is not started by Compose.

Read [`../docs/architecture/STORAGE-CAPABILITIES-AND-WORKSPACE-FLOW.md`](../docs/architecture/STORAGE-CAPABILITIES-AND-WORKSPACE-FLOW.md) before activating or migrating a provider.

## Environment

Copy `env.example` to `.env` for local Docker or `.env.prod` for the production overlay.

Important variables:

| Variable | Meaning |
| --- | --- |
| `OPTIMAL_API_PORT` | Host/API port, default `4200`. |
| `OPTIMAL_AUTH_REQUIRED` | Literal `true` requires HTTP credentials; `false` selects trusted local mode; invalid values fail configuration. |
| `OPTIMAL_ENGINE_ROOT` | Runtime root inside the container, default `/data`. |
| `OPTIMAL_ENGINE_DB` | SQLite database path, default `/data/.optimal/index.db`. |
| `OPTIMAL_ENGINE_CACHE` | Cache path, default `/data/.optimal/cache`. |
| `OPTIMAL_KNOWLEDGE_BACKEND` | `ets` (default) or `rocksdb`. |
| `OPTIMAL_KNOWLEDGE_ROCKSDB_PATH` | Where RocksDB keeps the mirror; set it to a path under `/data`. |
| `OPTIMAL_RELEASE_CHANNEL` | `dev`, `stable`, `beta`, or `pinned`, reported by `/api/version`. |
| `OPTIMAL_OLLAMA_URL` | Optional local model endpoint for embeddings/generation. |

Keys need explicit operation grants and workspace scope.
Use [API grants and migration](../docs/guides/interfaces-and-publishing.md#api-grants-and-identity) for review/topology/admin permissions and authenticated tenant/reviewer binding.
Verify missing credentials receive 401 after deployment; a health response alone does not prove authentication works.
`MIX_ENV=prod` alone does not select authenticated mode.

## Backend Production

Production should expose the engine through a TLS reverse proxy and require auth:

```bash
cd deploy
cp env.example .env.prod
```

Set:

```dotenv
OPTIMAL_AUTH_REQUIRED=true
DOMAIN=engine.example.com
LETSENCRYPT_EMAIL=admin@example.com
```

Then run:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

The production overlay starts Caddy for TLS and keeps the engine port private behind the proxy.

## Backups

Do not back up a live Engine by archiving its volume.
A tar of `index.db` taken while the Engine writes can capture the database and its write-ahead log at different moments.
Ask the Engine for a verified online backup instead:

```bash
curl -s -X POST http://localhost:4200/api/backup \
  -H "Authorization: Bearer $OPTIMAL_ENGINE_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"name": "nightly.db"}'
```

The Engine runs `VACUUM INTO` while it keeps serving, records the copy in its catalog, runs `PRAGMA integrity_check`, and returns the path, size, and SHA-256.
The file lands in `OPTIMAL_BACKUP_DIR`, which defaults to `/data/.optimal/backups`.
The route needs the `admin` scope, and the backup is the whole database, every tenant in it.

Add `"offsite": true` to also send a copy, sealed with `OPTIMAL_BACKUP_KEY`, to the configured S3 bucket.
Set `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS` to have the Engine do that on a schedule.
See [Storage providers](../docs/guides/storage-providers.md#offsite-backups).

The backup holds the database only.
Asset bytes kept on the filesystem and workspace folders are not in it.
Put assets in S3 with `OPTIMAL_ASSET_STORAGE=s3`, or snapshot the volume while the Engine is stopped.
The triple-store mirror and caches are rebuildable, and the keys live outside the volume.

Restore with the Engine stopped.
A release has no Mix, so call the function the `mix optimal.restore` task wraps, in a one-off container that opens the same volume with the API disabled:

```bash
docker compose stop engine
docker compose run --rm --no-deps -e OPTIMAL_API_ENABLED=false engine \
  /app/bin/optimal eval \
  'OptimalEngine.Backup.restore("/data/.optimal/backups/nightly.db") |> IO.inspect()'
docker compose up -d engine
```

The restore refuses a file that is not in the catalog (or whose checksum differs), runs `integrity_check`, and archives the previous database and its sidecars before replacing it.
If you keep the mirror on RocksDB, remove `/data/.optimal/knowledge-rocksdb` before starting, so it is rebuilt from the restored edges.
Run the same restore against a copy first, as a drill, before you depend on it.

## Upgrade

Migrations run when the new version boots, and an older version is not guaranteed to read a store a newer one has migrated.
Take a backup first.

1. `POST /api/backup`, and keep the returned file name.
2. Build or pull the new image (see [Versioning and releases](../docs/guides/versioning-and-releases.md)).
3. `docker compose up -d engine` with the same volume and the same keys.
4. Check `GET /api/health`, then `GET /api/version` for the version, the channel, and the expected migration.
5. Check `GET /api/stores/audit`.
6. To roll back, stop the Engine, run the previous image, and restore the backup from step 1.

## When Not To Use Docker

Do not use Docker just to organize a local workspace or run the CLI.
For that, run the local setup commands and let agents use the `bin/optimal` wrapper, Mix tasks, or the HTTP API directly.
