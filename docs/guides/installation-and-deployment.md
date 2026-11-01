# Installation And Deployment

Optimal Engine is backend-first.
It can run as a local CLI-backed workspace for one person, or as an organization runtime that multiple people, agents, apps, connectors, and scripts use through the same governed engine.

## One Engine, Every Store Inside

The default data layer is one Optimal Engine instance: one process on one durable disk that holds every store inside it.

| Store | Where it lives inside the instance |
| --- | --- |
| Relational | SQLite, `OPTIMAL_ENGINE_DB` |
| Full text | SQLite FTS5, in the same file |
| Vectors | Float32 BLOBs in the same file |
| Knowledge graph | The `graph_edges` table in the same SQLite file is the graph that search and assembly read. The triple store (ETS in memory, or RocksDB on disk) is a mirror rebuilt from it |
| Assets and objects | Files under `OPTIMAL_ENGINE_ROOT` |
| Caches | ETS and files under `OPTIMAL_ENGINE_CACHE` |
| Jobs | The `jobs` and `dead_letter_jobs` tables |
| Change ledger | The `sync_mutations` table, carried to peers over HTTP or the MIOSA relay |
| Backups | `OPTIMAL_BACKUP_DIR`, catalogued in `backup_records` |
| Sealed connector keys | Ciphertext in the database; the keys stay in the environment |

The Engine does not run Postgres, Qdrant, or Redis inside.
It embeds its own equivalents.

Providers are things a deployment grows onto, not the default shape:

| Provider | Status | Use |
| --- | --- | --- |
| S3-compatible storage (Garage, AWS S3, R2, MinIO, a MIOSA bucket) | Wired | Assets and offsite backups |
| PostgreSQL | Wired but partial: a compile-time `OPTIMAL_STORE=postgres` build that refuses full-text search, replication, and app data collections | The canonical relational store for engines that share one database |
| NATS JetStream, Valkey, Qdrant, DuckDB and Parquet, OpenBao, Fractal | Declared, no adapter yet | Nothing: the Engine cannot use them |

## Choosing A Mode

| Mode | Use when | Data lives in |
| --- | --- | --- |
| 1. [Self-hosted, embedded](#mode-1-self-hosted-embedded) | One person, one team, or one organization on a laptop, a server, or Docker. This is the default. | The instance's own disk |
| 2. [Self-hosted with providers](#mode-2-self-hosted-with-providers) | Assets or backups should leave the machine, or several engines must share one database. | The instance's disk plus S3, or a Postgres build |
| 3. [Cloud providers](#mode-3-cloud-providers) | The same as mode 2, with managed S3 and managed Postgres. | The instance's disk plus a managed bucket or database |
| 4. [MIOSA-managed](#mode-4-miosa-managed) | You want the platform to run it: volume, credentials, backups, upgrades. | A MIOSA-managed durable volume |

Every mode starts from mode 1.
You add a provider only when a limit shows you need it, and `GET /api/storage` tells you when (see [Sizes and presets](sizing-and-presets.md)).

The data model is the same in every mode:

```text
Tenant / Organization
  -> Workspace
    -> Node graph
      -> Source Packages, Signals, Claims, Facts, Memories, Context Packages,
         Active Memory Pools, Workflows, Skills, packages, and exports
```

Projects are Nodes inside a Workspace.
A Workspace is the bounded operating area.
A package is a receiver/channel bundle; it is not a note.

## Mode 1: Self-Hosted, Embedded

Everything runs in one instance on a laptop, a server, or in Docker.
No external service is needed.

### Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPTIMAL_API_ENABLED` | off outside the launchers | `true` turns on the HTTP API |
| `OPTIMAL_API_PORT`, `OPTIMAL_API_INTERFACE` | `4200`, `127.0.0.1` | Where the API listens; the image listens on `0.0.0.0` |
| `OPTIMAL_AUTH_REQUIRED` | `false` bare, `true` in the image | Require credentials; set `true` beyond loopback |
| `OPTIMAL_BOOTSTRAP_KEY` | none | Registers the first API key at boot, for an unattended instance |
| `OPTIMAL_ENGINE_ROOT` | `.optimal/workspaces` | Workspace files and asset bytes |
| `OPTIMAL_ENGINE_DB` | `.optimal/index.db` | The SQLite store |
| `OPTIMAL_ENGINE_CACHE` | `.optimal/cache` | Rebuildable cache |
| `OPTIMAL_BACKUP_DIR` | `backups/` beside the database | Where `POST /api/backup` writes |
| `OPTIMAL_KNOWLEDGE_BACKEND` | `ets`; `scripts/run-engine.sh` defaults it to `rocksdb` | Triple-store mirror backend |
| `OPTIMAL_KNOWLEDGE_ROCKSDB_PATH` | `.optimal/knowledge-rocksdb` | Where RocksDB keeps the mirror; put it on the data volume |
| `OPTIMAL_SIZE_PROFILE` | `business` | Tuning for the machine ([Sizes and presets](sizing-and-presets.md)) |
| `OPTIMAL_RELEASE_CHANNEL` | unset (`dev` in the image) | Reported by `GET /api/version` |

The full table, with every other variable, is in [OPTIONS.md](../../OPTIONS.md#storage-and-providers).

Three keys are generated once and kept outside the container and outside the data volume:

| Key | Seals | If lost |
| --- | --- | --- |
| `CONNECTOR_KEY` | Connector and peer credentials in the database | Stored credentials cannot be read; reconnect each connector |
| `OPTIMAL_AUTHORITY_KEY` | The authority signing keys in the database | The wrapped signing keys cannot be opened |
| `OPTIMAL_BACKUP_KEY` | Offsite backup copies | Every offsite copy sealed with it is unrecoverable |

Generate each with `openssl rand -hex 32`, keep it in a secret manager or a mode-600 env file, and pass it to every start.
A replaced container that is started with new random keys cannot read what the old keys sealed.
Keep a copy of `OPTIMAL_BACKUP_KEY` away from the machine.

### Graph and its mirror

The graph that search, assembly, and materialization read is the SQLite `graph_edges` table.
The triple store is a mirror rebuilt from that table, and no retrieval path reads it.
`OPTIMAL_KNOWLEDGE_BACKEND` chooses the mirror's backend.
The config default is `ets`, which holds the mirror in memory and reloads it from SQLite at each start.
It is what bare `mix`, tests, the Docker image, the MIOSA template, and managed Engines run, because none of them sets the variable.
`scripts/run-engine.sh` defaults it to `rocksdb`.
To keep the mirror on disk anywhere else, set `OPTIMAL_KNOWLEDGE_BACKEND=rocksdb` and point `OPTIMAL_KNOWLEDGE_ROCKSDB_PATH` at the data volume, for example `/data/.optimal/knowledge-rocksdb` in the image.
Without the path, RocksDB writes `.optimal/knowledge-rocksdb` under the working directory, which in a container is not the volume.
If RocksDB is requested and its native library is missing, the Engine logs a warning and falls back to ETS.

### Volume and disk layout

```text
<data>/
  .optimal/
    index.db, index.db-wal, index.db-shm   the SQLite store
    backups/                               verified backups
    cache/                                 rebuildable cache
    embed_cache.key                        secret that names embedding cache entries
    imports/                               import staging
    knowledge-rocksdb/                     the triple-store mirror (when RocksDB is selected)
  <workspace folders>/                     workspace files and asset bytes
```

In the Docker image `<data>` is `/data`, the only writable volume.
On a laptop it is the checkout's `.optimal/` directory plus the workspace root.
Back up the volume only through the Engine (below), never by copying the live database files.

### Laptop

```bash
make install
make bootstrap
make dev
```

`make dev` runs `scripts/run-engine.sh`, which starts the API, selects RocksDB, and creates `.optimal/connector_key` when `CONNECTOR_KEY` is not set.
See [Local Install](#local-install) for the requirements.

### Server or Docker

Run the container image, or an OTP release behind a process supervisor and a TLS reverse proxy.
The container needs one volume at `/data` and the three keys in its environment.

```bash
docker run -d --name optimal-engine -p 127.0.0.1:4200:4200 \
  -v optimal-data:/data \
  --env-file /etc/optimal/engine.env \
  optimal-engine:<version>
```

`/etc/optimal/engine.env` holds `CONNECTOR_KEY`, `OPTIMAL_AUTHORITY_KEY`, `OPTIMAL_BACKUP_KEY`, `OPTIMAL_BOOTSTRAP_KEY`, and `OPTIMAL_ENGINE_API_KEY` (the key the health check uses).
It lives on the host, outside the volume, so a replaced container keeps the keys.
[`deploy/README.md`](../../deploy/README.md) has the Compose stack, the production overlay with TLS, and the quickstart's mint step.

### Backup and restore

Take a verified online backup while the Engine serves:

```bash
curl -s -X POST "$URL/api/backup" \
  -H "Authorization: Bearer $ADMIN_KEY" -H 'content-type: application/json' \
  -d '{"name": "nightly.db"}'
```

The file lands in `OPTIMAL_BACKUP_DIR` and is catalogued with its SHA-256 and the result of `PRAGMA integrity_check`.
The route needs the `admin` scope.
The backup is the database only: asset bytes on the filesystem and workspace folders are not in it, so snapshot the volume with the Engine stopped, or move assets to S3 (mode 2).

For a copy that survives the machine, set `OPTIMAL_BACKUP_KEY` and an object store (mode 2), then send `{"offsite": true}` or set `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS`.
Offsite copies are sealed on the Engine's machine before upload.

Restore with the Engine stopped.
On a checkout:

```bash
mix optimal.restore /path/to/nightly.db
```

In a release or container, call the same function in a one-off process with the API disabled:

```bash
OPTIMAL_API_ENABLED=false bin/optimal eval 'OptimalEngine.Backup.restore("/data/.optimal/backups/nightly.db") |> IO.inspect()'
```

The restore checks the file against the catalog checksum, runs `integrity_check`, and archives the previous database before replacing it.
If you keep the mirror on RocksDB, remove its directory before the next start so it is rebuilt from the restored edges.
Drill the restore against a copy before you rely on it; [Storage providers](storage-providers.md#restore-drill) has a full drill.

### Upgrade

Migrations run when the new version boots, and the previous version is not guaranteed to read a store the new one migrated.

1. Take a backup with `POST /api/backup`.
2. Stop the Engine, then start the new version with the same data volume and the same keys.
3. Verify (below), and check the version, channel, and expected migration in `GET /api/version`.
4. To roll back, stop the new version, start the previous one, and restore the backup from step 1.

On a checkout, `git pull`, `mix deps.get`, and restart `make dev`.
[Versioning and releases](versioning-and-releases.md) lists the per-migration upgrade notes.

### Verify

```bash
curl -s "$URL/api/health" -H "Authorization: Bearer $KEY"
curl -s "$URL/api/stores/audit" -H "Authorization: Bearer $KEY"
```

`GET /api/health` reports liveness and readiness.
`GET /api/stores/audit` returns 503 when any check fails: SQLite integrity, foreign keys, migrations, full-text parity, workspace isolation, vector validity, asset files, the latest verified backup, and the offsite schedule.
A request to a protected route without a key must return 401.

## Mode 2: Self-Hosted With Providers

Start from mode 1 and add providers on your own infrastructure.
Only two providers are usable today.

| Provider | Status | What it holds |
| --- | --- | --- |
| S3-compatible storage (Garage, MinIO, or another) | Wired | Assets and offsite backups |
| PostgreSQL | Wired but partial | The canonical relational store of a Postgres build |
| NATS JetStream, Valkey, Qdrant, DuckDB and Parquet, OpenBao, Fractal | Not wired yet | Nothing; declared with no adapter |

### S3 with Garage

Garage is a single-binary S3 server.
The stack in [`deploy/docker-compose.storage.yml`](../../deploy/docker-compose.storage.yml) runs it next to the Engine.

```bash
cd deploy
docker compose -f docker-compose.yml -f docker-compose.storage.yml --profile storage up -d
```

The Engine side is these variables:

| Variable | Value |
| --- | --- |
| `OPTIMAL_S3_ENDPOINT` | `http://garage:3900` |
| `OPTIMAL_S3_BUCKET` | `optimal-artifacts` |
| `OPTIMAL_S3_REGION` | Must match Garage's `s3_region` (`garage` in `deploy/storage/garage.toml`) |
| `OPTIMAL_S3_ACCESS_KEY_ID`, `OPTIMAL_S3_SECRET_ACCESS_KEY` | The Garage key; replace the development defaults |
| `OPTIMAL_S3_PREFIX` | One prefix per Engine when Engines share a bucket |
| `OPTIMAL_ASSET_STORAGE` | `s3` to keep asset bytes in the bucket |
| `OPTIMAL_BACKUP_KEY` | Required for any offsite backup |
| `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS` | Optional schedule, for example `86400000` |

Check it end to end:

```bash
curl -s "$URL/api/storage/providers/s3?probe=true" -H "Authorization: Bearer $KEY" | jq
```

The probe writes, reads back, lists, and deletes a small object, and reports `unreachable` rather than `healthy` for a wrong key, bucket, or region.
The recipe, the encryption format, and the restore drill are in [Storage providers](storage-providers.md).

With assets and backups in the bucket, the volume holds the database and the cache, plus the mirror if it is on RocksDB.
Backup, restore, upgrade, and verification are as in mode 1, with the asset bytes now covered.

### The Postgres build

PostgreSQL replaces the canonical relational store of one Engine, and the choice is made when the Engine is compiled, not by configuration:

```bash
OPTIMAL_STORE=postgres MIX_ENV=prod mix release optimal
OPTIMAL_POSTGRES_URL='postgres://user:secret@host:5432/db?sslmode=require' \
OPTIMAL_POSTGRES_SCHEMA=engine_a \
_build/prod/rel/optimal/bin/optimal start
```

The stock `deploy/Dockerfile.engine` does not pass `OPTIMAL_STORE` to the build, so a Postgres container image needs `OPTIMAL_STORE=postgres` exported in the build stage; a build argument is not wired yet.
Setting `OPTIMAL_POSTGRES_URL` on the stock image changes nothing: the provider reports `selected: false` and the data stays in SQLite.

Use one schema per Engine (`OPTIMAL_POSTGRES_SCHEMA`) so that Engines that must not see each other's data do not share tables.

What a Postgres build gives up:

| Feature | On a Postgres build |
| --- | --- |
| Full-text search | Refused. Search, context assembly, and asking return an error naming it. |
| Replication | Refused. Enabling sync and adding a peer return 501. |
| App data collections | Refused. |
| SQLite-only statements | Refused by name where used (some JSON functions, date arithmetic, `rowid`, `PRAGMA`). |
| ETS hot cache | Off. |
| Engine backup routes | They copy the SQLite file, so they do not back up a Postgres build. Back the database up with Postgres tooling. |
| Moving an existing Engine's data to Postgres | Not implemented (stage 4 of the provider plan). |

An Engine whose Postgres database holds replication or app data collection data does not start.
[PostgreSQL Provider](postgres-provider.md) lists every refusal.
Choose this build only when several Engine processes must write one database and you can live without the features above.

## Mode 3: Cloud Providers

The same two providers, run by a cloud vendor instead of by you.
The Engine is still one instance on one durable disk.

| Provider | Status | Notes |
| --- | --- | --- |
| Managed S3: AWS S3, Cloudflare R2 | Wired | Assets and offsite backups |
| Managed PostgreSQL | Wired but partial | The Postgres build above, with the same refusals |
| Managed Qdrant, Valkey, NATS | Not wired yet | Cannot be used |

### Managed S3

| Variable | AWS S3 | Cloudflare R2 |
| --- | --- | --- |
| `OPTIMAL_S3_ENDPOINT` | `https://s3.<region>.amazonaws.com` | `https://<account>.r2.cloudflarestorage.com` |
| `OPTIMAL_S3_REGION` | The bucket's region | `auto` |
| `OPTIMAL_S3_PATH_STYLE` | `false` for virtual-hosted addressing, which hosted AWS prefers; the default is path style | Default |
| `OPTIMAL_S3_BUCKET`, `OPTIMAL_S3_PREFIX` | Your bucket, one prefix per Engine | Your bucket, one prefix per Engine |
| Credentials | `OPTIMAL_S3_ACCESS_KEY_ID` and `OPTIMAL_S3_SECRET_ACCESS_KEY`, or `OPTIMAL_S3_CREDENTIALS_FILE` | The same |

Use a key scoped to the one bucket, with read, write, list, and delete.
The credentials file is read on every request, so replacing it rotates the key without a restart.
Give each Engine its own prefix or bucket and write nothing else under it, because erasure deletes the objects of the assets it removes.

### Managed Postgres

Use the Postgres build from mode 2 with the managed database's connection string and `sslmode=require` or stricter.
Give each Engine its own schema.
Back the database up with the provider's backups; the Engine's backup routes do not cover it.
Managed Postgres does not remove any limit above: full-text search, replication, and app data collections stay refused.

### Backup, upgrade, verify

As in mode 2.
Use `OPTIMAL_BACKUP_KEY` with a managed bucket so the vendor only ever holds ciphertext.

## Mode 4: MIOSA-Managed

The Engine runs as MIOSA's managed `optimal` database engine.
The platform provides the durable volume, the credentials, and the backups.
You use the Engine over HTTP.

- **Shape.** One org Engine per organization, with a walled section per workspace.
  An agent's key opens only its workspace section unless it is scoped to all workspaces.
  A customer gets an Engine of their own only when a wall requires it: co-owned data, private views, clients, or white-label end users.
- **Sizes.** Agent memory, Workspace, Business, Platform, and Scale, which map to the Engine's `agent`, `workspace`, `business`, `platform`, and `scale` profiles.
  Providers are added at Scale.
- **Operating model.** One-command resize and scale to zero are planned.
  The Engine reports usage and the resize recommendation today.
- **Installs.** From built, versioned release archives with channels, backups, and rollback, never from a repository clone on the machine.

[MIOSA-managed Engine](miosa-managed-engine.md) has the full model, the size table, what exists today and what is planned, the environment, and the verification steps.
[`deploy/miosa-template/`](../../deploy/miosa-template/README.md) holds the build and template scripts.

## Local Install

Required:

```text
Erlang/OTP 27+, but not 28.0 to 28.2
Elixir ~> 1.17
Git
C toolchain for the SQLite NIF
Snappy for the RocksDB knowledge graph backend
```

OTP 28.0 to 28.2 (erts 16.0 and 16.1) can crash the whole VM when a process is killed during a long regular expression match, which a classification time limit does to a slow document.
OTP 28.3 fixed it, and the release image uses 28.5.0.5.

Run:

```bash
git clone https://github.com/Miosa-osa/OptimalEngine.git
cd OptimalEngine
brew install snappy
make install
make bootstrap
make dev
```

`make dev` runs `scripts/run-engine.sh`.
The launcher starts the HTTP API, uses the repo checkout as the runtime root, and creates `.optimal/connector_key` when `CONNECTOR_KEY` is not already set.
The generated key and `.optimal/` runtime files are local machine state, not repository content.

Verify:

```bash
curl http://localhost:4200/api/health
curl http://localhost:4200/api/stores/audit
```

Use the checked-in local CLI wrapper:

```bash
bin/optimal --help
bin/optimal doctor
```

The wrapper is for source checkouts.
API-backed commands send `OPTIMAL_ENGINE_API_KEY` to both the health probe and the requested operation.
Any HTTP response indicating failure stops the command, including missing or expired credentials, without falling back to a different local store.
If `OPTIMAL_ENGINE_API_URL` is explicitly set or `OPTIMAL_ENGINE_API_KEY` is nonempty, an unavailable API also stops execution.
Only an unconfigured default-local probe receiving no HTTP response may fall back to local Mix tasks using the configured local database.
Native-only commands also use local Mix directly; the wrapper does not sandbox local operating-system access.
Use an API client directly when a remote integration must never execute a local fallback.
For example:

```bash
bin/optimal health
bin/optimal setup my-workspace --name "My Workspace"
bin/optimal topology --workspace default:my-workspace
```

Do not treat the checkout wrapper as the production database/server binary.
For a long-running API or team runtime, use the OTP release or container deployment.

Create a known structure:

```bash
mix optimal.setup my-workspace --name "My Workspace"
```

Or initiate from a messy context dump:

```bash
mix optimal.initiate my-workspace --name "My Workspace" --dump setup.md
```

The default local paths are:

```text
.optimal/index.db        SQLite runtime store (with -wal and -shm while running)
.optimal/backups/        verified backups, beside the database
.optimal/cache/          rebuildable local cache
.optimal/embed_cache.key secret that names embedding cache entries, beside the database
.optimal/knowledge-rocksdb/  the triple-store mirror, when RocksDB is selected
.optimal/connector_key   local connector secret (written by scripts/run-engine.sh)
workspace files          markdown/wiki/package/export projection
```

`.optimal/` is ignored by git.
Do not commit local databases, WAL files, cache, connector keys, workspace runtime state, or imported private data.

## Docker

Docker is optional. Use it when you want a repeatable service stack, production
process packaging, or isolated adapter runtimes.

```bash
docker compose -f deploy/docker-compose.yml up
```

Do not use Docker as a substitute for the data model. The same ownership rules
still apply:

```text
canonical runtime rows -> database
raw files/media        -> artifact storage
indexes/caches         -> rebuildable projections
markdown/wiki/API      -> projection surfaces
```

## Production / Organization Setup

A production deployment starts as one Engine instance (mode 1) and separates five concerns as it grows:

| Concern | Recommended role |
| --- | --- |
| Canonical runtime rows | The instance's SQLite file with verified backups. A Postgres build is an optional, partial provider for scale (mode 2). |
| Raw artifacts | The instance's files, or S3-compatible object storage (wired) with retention, backup, and access policy. |
| Indexes and caches | Rebuildable FTS/vector/chunk/parse/cache projections. |
| Worker runtime | Supervised Elixir workers plus adapter/model/tool worker processes. |
| Access and secrets | SSO/IAM/API keys/secret manager; never store secrets in markdown or context. |

Minimum production controls:

```text
tenant/workspace scoping
role and membership checks
connector/tool grants
source retention policy
backup and restore procedure
audit log retention
stale context refresh schedule
projection rebuild procedure
```

## Release Maintenance Tasks

A release has no Mix, so `mix optimal.<task>` is not there.
`bin/optimal maintenance <task> [args]` runs the same task code in a new VM that never serves the HTTP API, with the same flags and output as the Mix task:

```bash
bin/optimal maintenance help
bin/optimal maintenance migrate --status
bin/optimal maintenance graph_backfill --workspace <id> --no-claims
bin/optimal maintenance conformance --url http://127.0.0.1:4200 --key-file /path/to/key
```

| Task | Engine | What it does |
| --- | --- | --- |
| `migrate` | stopped | applies pending schema migrations; `--status` lists them |
| `health` | stopped | store diagnostics; exits 1 on a critical finding |
| `embed_backfill` | stopped | embeds chunks that have no embedding (`--workspace`, `--limit`, `--batch`, `--dry-run`) |
| `graph_backfill` | stopped | writes the graph edges of contexts and claims (`--workspace`, `--batch`, `--no-claims`) |
| `facts` | stopped | lists or shows Memory Core facts |
| `claims` | stopped | lists, shows, promotes or rejects Memory Core claims |
| `conformance` | running | checks a running Engine over HTTP (`--url`, `--key` or `OPTIMAL_ENGINE_API_KEY`) |

The Engine is the store's only writer, so a task marked stopped refuses while an Engine is up and changes nothing.
It counts the Engine as up when something listens on the API port (`OPTIMAL_API_PORT`, default 4200, on 127.0.0.1 or `OPTIMAL_API_INTERFACE`) or the release node (`RELEASE_NODE`, default `optimal`) is registered with epmd.
Stop the service first, run the task with the service's environment (the same `OPTIMAL_ENGINE_DB`, `OPTIMAL_ENGINE_ROOT` and keys), then start the service again.
The task then starts the Engine in its own VM with the HTTP API and the background loops off (analyses, connector pulls, sync, offsite backups, the maintenance sweep), logs warnings and errors only, and stops it when the task ends.
`conformance` is the other way round: it talks to a running Engine and refuses when nothing answers at its target.
A running Engine also runs the chunk embedding and graph backfills as jobs, with no pause (`POST /api/maintenance/embeddings {"kind": "chunks"}` and `POST /api/maintenance/graph/backfill`, see the [operating layer](operating-layer.md#maintenance-jobs)).

Exit codes: 0 the task succeeded, 1 it failed, 64 no task or an unknown one (the message lists the tasks), 78 refused because the Engine was in the wrong state.
`rel/env.sh.eex` adds the command to the release script, and puts a packaged release's `libextra/` on the loader path as `start-engine` does.

## Isolated Fixture Verification

`mix optimal.reality_check` writes diagnostic fixtures and may alter topology, memory, and retrieval records.
It is a development regression probe, not a read-only live-store audit.
Run it only in a disposable environment, separately from any live Engine:

```bash
engine_check_root="$(mktemp -d)"
MIX_ENV=test \
OPTIMAL_AUTH_REQUIRED=false \
OPTIMAL_API_ENABLED=false \
OPTIMAL_ENGINE_ROOT="$engine_check_root/workspaces" \
OPTIMAL_ENGINE_DB="$engine_check_root/index.db" \
OPTIMAL_ENGINE_CACHE="$engine_check_root/cache" \
OPTIMAL_ENGINE_TOPOLOGY="$engine_check_root/config.yaml" \
OPTIMAL_ENGINE_TOPOLOGY_FULL="$engine_check_root/topology.yaml" \
OPTIMAL_KNOWLEDGE_BACKEND=ets \
mix optimal.reality_check
```

This uses test configuration, a separate SQLite file and filesystem root, and the in-memory graph backend.
It does not start a second HTTP listener on port 4200.
Inspect the command's actual probe results; a historical probe count is not a current acceptance criterion.
A clean empty-fixture run does not establish production-data health, RocksDB qualification, or authorization for every endpoint.
Use the running service's `/api/health` and `/api/stores/audit` for live diagnostics.
Health and audit responses do not prove a completed authenticated application session or cross-repository compatibility.

## Local Auth Vs Remote Auth

Local CLI commands are trusted local commands. They run on the machine that owns
the checkout/store and do not need an API key:

```text
mix optimal.setup ...
mix optimal.initiate ...
mix optimal.topology ...
mix optimal.rag ...
```

Anything connecting over HTTP/API, MCP, app integration, remote script, or
remote agent should use a scoped API key:

```bash
mix optimal.auth mint --name "Business OS" --scope read --scope write --tenant default --workspace default:my-workspace
mix optimal.auth env --name "Local Agent" --scope read --scope write --workspace default:my-workspace
mix optimal.auth list
mix optimal.auth revoke <key-id>
```

API clients send the token as either:

```text
Authorization: Bearer <token>
X-API-Key: <token>
```

Set `OPTIMAL_AUTH_REQUIRED=true` in the service environment before exposing the API to untrusted clients.
Alternatively set `config :optimal_engine, :auth, auth_required: true` in its loaded Elixir configuration.
The environment override accepts only literal `true` or `false`; invalid values stop configuration, and an absent override preserves the configured setting.
Selecting `MIX_ENV=prod` alone does not enable authentication.
Verify that a protected request without credentials returns 401 and that the intended scoped credential succeeds.
Unauthenticated local mode is privileged development access, and direct CLI or database access is outside HTTP authorization.
An Engine whose API listens on any interface but loopback (`OPTIMAL_API_INTERFACE=0.0.0.0`, a LAN address) with authentication off is open to everyone who can reach it.
It logs `API is open: auth is off on <interface>; set OPTIMAL_AUTH_REQUIRED=true` at boot and every 10 minutes, and `/api/health` and `/api/status` report the warning `auth_open_on_network` (check `network_auth`, status `degraded`).
`OPTIMAL_REFUSE_OPEN_NETWORK=1` makes such an Engine refuse to start instead; the refusal is off by default in this release and becomes the default in the next, where `OPTIMAL_REFUSE_OPEN_NETWORK=0` keeps the error without the refusal.
An Engine opened on purpose, behind a proxy that authenticates every request, says so with `OPTIMAL_OPEN_NETWORK_ACKNOWLEDGED=1`: it logs one line at boot naming the interface and the setting, and is neither warned about, degraded, nor refused.
Only the interface the Engine binds is checked, so a loopback Engine published by a reverse proxy, a tunnel or a port map is not detected; it needs `OPTIMAL_AUTH_REQUIRED=true` like any other.
The container image (`deploy/Dockerfile.engine`) and `deploy/docker-compose.yml` listen on all the container's interfaces and set `OPTIMAL_AUTH_REQUIRED=true`; the compose file publishes the port on the host's loopback (`OPTIMAL_API_BIND`), and its health check uses `OPTIMAL_ENGINE_API_KEY` (`deploy/env.example`).
An Engine on `127.0.0.1` with authentication off is unaffected.

The `read` and `write` grants do not authorize Claim review, topology changes, or key administration.
Add `claims:review`, `topology:write`, or `admin` only for the operations the client needs.
The Engine itself still promotes high-confidence Claims on a schedule unless `OPTIMAL_CLAIM_PROMOTION_MODE=manual` (or `agent_review`) is set; set it when every Claim must be decided by a reviewer.
`POST /api/auth/keys` refuses a request without `scopes` (400 `scopes_required`) when the minter is a root key or an anonymous local caller; a minter with named scopes passes its own down. `mix optimal.auth mint` in the operator's shell still defaults to `*`.
Authenticated tenant parameters cannot override the key's tenant, and Claim reviewers are derived from its principal or key ID.
See [API grants and migration](interfaces-and-publishing.md#api-grants-and-identity) for exact grants, identity checks, replacement-key creation, and revocation.
Keep credentials in a secret manager or environment variables, not markdown, Source Packages, Context Packages, or generated packages.

## Environment Variables

The default runtime reads these paths:

```text
OPTIMAL_ENGINE_ROOT          workspace/root path
OPTIMAL_ENGINE_DB            SQLite path for local runtime
OPTIMAL_ENGINE_CACHE         cache path
OPTIMAL_ENGINE_TOPOLOGY      local workspace config path
OPTIMAL_ENGINE_TOPOLOGY_FULL root topology config path
OPTIMAL_ENGINE_API_KEY       API key used by external clients/agents
OPTIMAL_AUTH_REQUIRED        true/false override for HTTP authentication
OPTIMAL_REFUSE_OPEN_NETWORK  1 refuses to start with auth off beyond loopback
OPTIMAL_OPEN_NETWORK_ACKNOWLEDGED 1: open beyond loopback on purpose, authenticated in front
OPTIMAL_KNOWLEDGE_BACKEND    ets (default) or rocksdb, for the triple-store mirror
OPTIMAL_KNOWLEDGE_ROCKSDB_PATH  where RocksDB keeps the mirror
OPTIMAL_SIZE_PROFILE         agent, workspace, business, platform, or scale
OPTIMAL_RELEASE_CHANNEL      dev, stable, beta, or pinned
OLLAMA_HOST                  local model server URL
OPTIMAL_VLM_MODEL            local visual model name for configured adapters
```

The complete list, with defaults and which are compile-time, is in
[OPTIONS.md](../../OPTIONS.md#storage-and-providers).

An object store is optional and off by default. A deployment that wants assets or
offsite backups in a bucket sets:

```text
OPTIMAL_S3_ENDPOINT           S3-compatible endpoint base URL
OPTIMAL_S3_BUCKET             bucket name
OPTIMAL_S3_REGION             region for the credential scope; default us-east-1
OPTIMAL_S3_ACCESS_KEY_ID      access key id
OPTIMAL_S3_SECRET_ACCESS_KEY  secret access key
OPTIMAL_S3_PREFIX             optional key prefix owned by this engine
OPTIMAL_S3_PATH_STYLE         "false" for virtual-hosted addressing; default path style
OPTIMAL_S3_CREDENTIALS_FILE   optional file with the access key id and secret; environment wins
OPTIMAL_ASSET_STORAGE         s3 to store workspace asset bytes in the bucket
```

Offsite backups are encrypted before upload and need a backup key; the engine can also take them on a schedule:

```text
OPTIMAL_BACKUP_KEY                   64 hex characters; offsite copies are refused without it
OPTIMAL_BACKUP_DIR                   where backups are written; default beside the database
OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS   scheduled offsite backups; 0 or unset disables
OPTIMAL_OFFSITE_BACKUP_KEEP          scheduled offsite copies kept; default 14
OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL    scheduled local files kept; default 3
```

A managed Engine whose connectors take short-lived credentials from a broker
(`credential_source: "broker"`, see [Connectors](connectors.md)) names the
brokers it may call; with none named, no broker is called:

```text
OPTIMAL_CREDENTIAL_BROKER_HOSTS   comma-separated https hosts; api.miosa.ai on MIOSA
OPTIMAL_CREDENTIAL_BROKER_PATHS   comma-separated path prefixes; default /api/v1/connect/broker/
CONNECTOR_KEY                     also seals each connector's broker reference
```

A workspace can select the bucket for its assets through its storage policy
instead of the engine-wide setting. Read
[Storage providers](storage-providers.md) for the provider inventory, the health
probe, offsite backup encryption and key handling, the schedule, and the restore
drill.

Production can add environment variables or secret-manager entries for connector
credentials, hosted model keys, API keys, and SSO/IAM configuration. Those
values should be referenced by tool/model/connector definitions, not copied into
Node markdown, package manifests, Source Packages, or Context Packages.

## Multimodality Install Profiles

Multimodal support is adapter-based. An adapter can be local open source, hosted,
or organization-specific, but it must write the same governed records:

```text
Raw asset
  -> Source Package
  -> assets row
  -> asset_adapter_runs
  -> asset_extractions / typed projection row
  -> pending Claim only when text-bearing output should enter review
```

Start with only the adapters you need.

### Local / Open-Source Profile

| Need | Adapter family |
| --- | --- |
| PDF/Office/document parsing | Docling, Marker, olmOCR, Unstructured |
| OCR fallback | Tesseract |
| Audio transcription | whisper.cpp or Whisper |
| Video demux/frame/audio extraction | FFmpeg |
| Visual reasoning | Qwen VL family |
| Page-image retrieval | ColPali / ColQwen |
| Image-text embeddings | OpenCLIP / SigLIP-style adapters |
| Broad cross-modal experiments | ImageBind-style adapters |

These tools are optional. If a binary is missing, the engine should preserve the
raw asset, record the unavailable or failed adapter run, and keep the rest of the
pipeline alive.

### Hosted Adapter Profile

Hosted providers are useful when an organization wants managed quality,
throughput, or cross-modal embeddings without maintaining every model locally.
They are still adapters, not truth sources.

| Need | Current hosted option examples |
| --- | --- |
| Unified multimodal embeddings across text, image, video, audio, and documents | Google Gemini API / Vertex AI `gemini-embedding-2`. |
| Vertex AI image/text/video embeddings compatibility | Google `multimodalembedding@001`. |
| Rich document/image/video retrieval embeddings | Voyage multimodal embedding models. |
| Text/image/PDF multimodal embeddings | Jina embedding models. |

Hosted calls should record:

```text
provider
model_id / model_version
request object links
output refs / hashes
cost and latency where available
security labels and partitions
derivation ledger entry
audit event
```

## Adapter Output Rule

No parser, VLM, embedding model, transcript model, connector, API, script, or
agent output should become a Fact directly.

```text
adapter/model/tool output
  -> derived Source Package or extraction row
  -> pending Claim when claimable
  -> review/policy
  -> Fact / Memory Object
```

This is what keeps an organization from treating generated captions,
transcripts, OCR, summaries, or embeddings as verified truth.

## Enterprise Readiness Checklist

Before inviting multiple people or production agents, confirm:

```text
organization/tenant IDs are present
workspace IDs are present
Node IDs are stable
aliases resolve inside scope
Source Packages preserve evidence
assets preserve raw files/media
Claims are reviewed before Facts
Context Packages are permission-filtered
tool/model/connector calls are registered and audited
packages live under the owning Node unless cross-node by manifest
backups cover canonical DB and raw artifacts
indexes/caches/projections can be rebuilt
```

If any item is missing, the system can still be useful locally, but it is not yet
ready as a shared enterprise runtime.
