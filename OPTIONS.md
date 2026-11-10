# Optimal Engine Options

This file lists the setup options that matter for users, agents, and products embedding Optimal Engine.

## Command Surface

Use the repo wrapper for normal usage:

```bash
bin/optimal <command>
```

For API-backed wrapper commands, `OPTIMAL_ENGINE_API_KEY` authenticates both the availability probe and the operation.
Reachable HTTP errors stop execution; only an unconfigured default-local probe with no HTTP response can select trusted local Mix fallback.
Native commands remain local, so this wrapper is not a remote-only client or an isolation boundary.

Use direct Mix tasks when you are developing the engine internals:

```bash
mix optimal.<task>
```

Recommended agent commands:

```bash
bin/optimal boot
bin/optimal doctor
bin/optimal find "query" --workspace default:my-workspace
bin/optimal capture "raw signal" --workspace default:my-workspace
bin/optimal aware "durable correction" --workspace default:my-workspace
bin/optimal close "what changed and how verified"
```

## Runtime Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPTIMAL_ENGINE_API_URL` | `http://localhost:4200` | CLI API target. |
| `OPTIMAL_ENGINE_API_KEY` | empty | Bearer token for wrapper/client HTTP calls; supplying it does not configure server authentication. |
| `OPTIMAL_AUTH_REQUIRED` | configured auth setting, normally false | Literal `true` requires HTTP credentials; literal `false` enables trusted local mode; other values fail startup configuration. |
| `OPTIMAL_API_ENABLED` | disabled outside development startup | Literal `true` enables the configured API listener; development launcher/config also enables it. |
| `OPTIMAL_API_PORT` | `4200` | Port for an environment-enabled HTTP listener. |
| `OPTIMAL_API_INTERFACE` | `127.0.0.1` | Bind address for an environment-enabled listener. Any address but loopback with authentication off logs `API is open: auth is off on <interface>; set OPTIMAL_AUTH_REQUIRED=true` at boot and every 10 minutes, and `/api/health` warns `auth_open_on_network`. |
| `OPTIMAL_REFUSE_OPEN_NETWORK` | unset (`0`) | `1` (or `true`) refuses to start an Engine whose API listens beyond loopback with authentication off. Off by default in this release; the next release makes the refusal the default, and `0` (or `false`) keeps this release's behaviour, the error. Empty is unset; other values fail startup configuration. |
| `OPTIMAL_OPEN_NETWORK_ACKNOWLEDGED` | unset (`0`) | `1` (or `true`) says the API is open beyond loopback on purpose, with every request authenticated by a proxy in front: the Engine logs one line at boot and is neither warned about, degraded in `/api/health`, nor refused. Empty is unset; other values fail startup configuration. |
| `OPTIMAL_ENGINE_DB` | `.optimal/index.db` | Local SQLite store path. |
| `OPTIMAL_ENGINE_CACHE` | `.optimal/cache` | Local cache path. |
| `OPTIMAL_BACKUP_DIR` | `backups/` beside the database | Only directory `POST /api/backup` may write into; restores verify the catalog checksum first. |
| `OPTIMAL_BUNDLE_MAX_BYTES` | `5368709120` (5 GiB) | Largest raw bundle upload `POST /api/bundles/import` accepts; a larger one is refused with 413 before or while it is read. |
| `OPTIMAL_BUNDLE_URL_HOSTS` | none | Comma-separated hosts a bundle import job may download its bundle from (`source_url`); with none, `source_url` is refused. A `*.` entry covers a domain's hosts. |
| `OPTIMAL_BUNDLE_RETENTION_HOURS` | `168` | How long a finished bundle export job's bundle is kept before it is removed. |
| `OPTIMAL_BACKUP_KEY` | none | 64 hex characters, or an OpenBao reference `openbao:<path>#<field>`; encrypts every offsite backup copy with AES-256-GCM. Offsite copies are refused without it, also when a transit key is set (unless `OPTIMAL_BACKUP_TRANSIT_ONLY=true`, below). Losing it loses every copy sealed with it. |
| `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS` | unset (off) | Interval for scheduled encrypted offsite backups; 0 or unset disables, otherwise at least 60000. |
| `OPTIMAL_OFFSITE_BACKUP_KEEP` | `14` | Scheduled offsite copies kept; older ones are deleted from the bucket. |
| `OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL` | `3` | Scheduled local backup files kept in `OPTIMAL_BACKUP_DIR`. |
| `OPTIMAL_S3_CREDENTIALS_FILE` | unset | File holding the S3 access key id and secret (two lines or `KEY=VALUE`); environment values win. |
| `OPTIMAL_ASSET_RECONCILE_INTERVAL_MS` | `600000` (10 minutes) | How often assets kept on the local disk during an object store outage are put in the bucket, while any are pending and S3 is configured; `0` turns it off. |
| `OPTIMAL_ENGINE_ROOT` | repo root | Engine root for source-checkout usage. |
| `OPTIMAL_KNOWLEDGE_BACKEND` | `ets` | Backend of the triple-store mirror of `graph_edges`: `ets`, `rocksdb`, or `mnesia`. `scripts/run-engine.sh` defaults it to `rocksdb`; the Docker image and MIOSA template set nothing. |
| `CONNECTOR_KEY` | generated into `.optimal/connector_key` | Local connector secret, or an OpenBao reference. Connector credentials are refused without it unless OpenBao holds them (`OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao`); they are never stored in plaintext. |
| `OPTIMAL_CLAIM_PROMOTION_MODE` | `auto_threshold` | `auto_threshold`: the Engine promotes Claims whose confidence meets the workspace threshold every 30 minutes, as `system:promotion-scheduler`. `manual` or `agent_review`: it promotes nothing, and every Claim waits for a reviewer with `claims:review`. Other values fail startup configuration. |

Keep private values in environment variables, local secret stores, or deployment secret managers.
Do not commit them.

## Storage And Providers

One Engine instance holds every store inside it, so none of these is needed for the default deployment.
Names come from `config/runtime.exs`, `config/config.exs`, and the provider adapters.
"Compile time" means the value is fixed when the Engine is built and changing the environment of a running release does nothing.

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPTIMAL_STORE` | `sqlite` | Read when the Engine boots. `sqlite` or `postgres`: which canonical store the Engine runs; one build runs either. See `docs/guides/postgres-provider.md` for how a PostgreSQL store differs. Any other value stops the boot. |
| `OPTIMAL_POSTGRES_URL` | none | Connection URL of a Postgres build, read when the store starts. Never logged or returned. |
| `OPTIMAL_POSTGRES_SCHEMA` | `public` | Schema a Postgres build keeps its tables in; use one per Engine. |
| `OPTIMAL_S3_ENDPOINT` | none | S3-compatible endpoint base URL. |
| `OPTIMAL_S3_BUCKET` | none | Bucket name. |
| `OPTIMAL_S3_REGION` | `us-east-1` | Region of the credential scope; must match the provider (Garage's `s3_region`, the AWS region, `auto` for R2). |
| `OPTIMAL_S3_ACCESS_KEY_ID`, `OPTIMAL_S3_SECRET_ACCESS_KEY` | none | Credentials, each a value or an OpenBao reference `openbao:<path>#<field>`. |
| `OPTIMAL_S3_CREDENTIALS_FILE` | none | File holding the credentials; environment values win. |
| `OPTIMAL_S3_PREFIX` | none | Key prefix owned by this Engine. |
| `OPTIMAL_S3_PATH_STYLE` | path style | `false` selects virtual-hosted addressing. |
| `OPTIMAL_S3_TIMEOUT_MS`, `OPTIMAL_S3_MAX_RETRIES` | `30000`, `2` | Per-request timeout and retries. |
| `OPTIMAL_S3_TRACE` | off | `1` logs the canonical request when a signature is rejected. |
| `OPTIMAL_ASSET_STORAGE` | filesystem | `s3` stores asset bytes in the bucket. |
| `OPTIMAL_SIZE_PROFILE` | `business` | `agent`, `workspace`, `business`, `platform`, or `scale`. Any other value fails startup configuration. |
| `OPTIMAL_ENGINE_SCOPE` | `org` | `org`, or `workspace` (serves only `OPTIMAL_ENGINE_WORKSPACE`). |
| `OPTIMAL_ENGINE_WORKSPACE` | none | Workspace id served when the scope is `workspace`; required then. |
| `OPTIMAL_RELEASE_CHANNEL` | unset | `dev`, `stable`, `beta`, or `pinned`, reported by `GET /api/version`. Any other value fails startup. |
| `OPTIMAL_BOOTSTRAP_KEY` | none | `oe_<24 hex>_<secret of 32+ chars>`; registers the first API key at boot. |
| `OPTIMAL_METRICS_TOKEN` | none | A bearer token that opens `GET /api/metrics/prometheus` and no other route, for a scraper that holds no API key; may be an `openbao:<path>#<field>` reference. Without it the route needs the Engine operator's key (an admin key of the default tenant whose workspace scope is `*`); on an Engine that requires no key, a request without one is served. |
| `OPTIMAL_BOOTSTRAP_TENANT`, `OPTIMAL_BOOTSTRAP_SCOPES`, `OPTIMAL_BOOTSTRAP_WORKSPACES` | `default`, `read,write`, `*` | Tenant, operation scopes, and workspace allowlist of the bootstrap key. |
| `OPTIMAL_KNOWLEDGE_BACKEND` | `ets` | Mirror backend: `ets`, `rocksdb`, or `mnesia` (`ram_copies` only). |
| `OPTIMAL_KNOWLEDGE_ROCKSDB_PATH` | `.optimal/knowledge-rocksdb` | Where RocksDB keeps the mirror, relative to the working directory; set an absolute path on the data volume. |
| `OPTIMAL_BACKUP_DIR` | `backups/` beside the database | The only directory `POST /api/backup` writes into. |
| `OPTIMAL_BACKUP_KEY` | none | 64 hex characters, or `openbao:<path>#<field>`; seals offsite backups. |
| `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS`, `OPTIMAL_OFFSITE_BACKUP_KEEP`, `OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL` | off, `14`, `3` | Scheduled offsite backups and how many copies are kept. |
| `CONNECTOR_KEY` | none | 64 hex characters, or `openbao:<path>#<field>`; seals connector and peer credentials in the database. |
| `OPTIMAL_AUTHORITY_KEY` | none | 64 hex characters, or `openbao:<path>#<field>`; wraps the authority signing keys. |
| `OPTIMAL_VALKEY_PASSWORD`, `OPTIMAL_NATS_TOKEN`, `OPTIMAL_NATS_PASSWORD`, `OPTIMAL_QDRANT_API_KEY` | none | Service credentials, each a value or `openbao:<path>#<field>`; the Valkey and NATS ones take the place of a credential in `OPTIMAL_VALKEY_URL` or `OPTIMAL_NATS_URL`. |
| `OPTIMAL_OPENBAO_ADDR`, `OPTIMAL_OPENBAO_TOKEN` | none | OpenBao address and token. With both set the secret references above resolve; connector credentials stay in the Engine unless `OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao`. |
| `OPTIMAL_OPENBAO_RETRY_AFTER_MS` | `5000` | After OpenBao is found sealed or not answering, how long every call fails at once with that reason before OpenBao is asked again. `0` asks every time. |
| `OPTIMAL_OPENBAO_KV_MOUNT` | `secret` | KV version 2 mount for references and connector credentials; enabled on first write when the token may. |
| `OPTIMAL_OPENBAO_TRANSIT_KEY`, `OPTIMAL_OPENBAO_TRANSIT_MOUNT` | none, `transit` | Transit key that wraps each offsite backup's data key beside `OPTIMAL_BACKUP_KEY`, which stays required so a copy restores without this OpenBao. |
| `OPTIMAL_BACKUP_TRANSIT_ONLY` | `false` | `true` lets a transit key seal copies without `OPTIMAL_BACKUP_KEY`. Risk: those copies open only through that OpenBao, and are lost with it (its machine, storage or unseal keys). |
| `OPTIMAL_CONNECTOR_CREDENTIAL_STORE` | `engine` | `openbao` keeps new connector credentials in OpenBao (refused without OpenBao configured). They are then not in Engine backups: back up OpenBao's storage and unseal keys yourself. Anything else keeps them as database envelopes. |

The mirror is not what retrieval reads: the graph that search and assembly read is the `graph_edges` table in SQLite.

`OPTIMAL_VALKEY_URL` puts the rate limits, the verified API key cache and the sync gate cache in Valkey, with `OPTIMAL_VALKEY_POOL_SIZE`, `OPTIMAL_VALKEY_TIMEOUT_MS` and `OPTIMAL_VALKEY_KEY_PREFIX` (default: keys under `optimal:shared:` and a hash of `OPTIMAL_ENGINE_ID`, else of the store's replica id, else on the PostgreSQL store of its URL without credentials; the prefix, not the default, isolates Engines, and an Engine with none of them must set it), `OPTIMAL_ENGINE_ID` and `OPTIMAL_VALKEY_OUTAGE_POLICY` (`closed`, the default, or `open`); see [Valkey](docs/guides/storage-providers.md#valkey).
OpenBao (above) is in the data path: see [Storage providers](docs/guides/storage-providers.md#openbao).
`OPTIMAL_ANALYTICS_PATH` (DuckDB and Parquet, below) holds each workspace's analytics files.
The provider with an adapter that no Engine feature uses yet is Qdrant: `OPTIMAL_QDRANT_URL` with `OPTIMAL_QDRANT_API_KEY`.
Setting these lets `GET /api/storage/providers?probe=true` check each service and the provider proofs prove it with a round trip; the Engine's data stays where it is.
NATS JetStream is reached the same way, and runs the flows it is given:

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPTIMAL_NATS_URL` | unset | `nats://[user:password@\|token@]host[:port]`, `tls://` for TLS. The Engine's JetStream client, the probe and the proof. |
| `OPTIMAL_NATS_FLOWS` | none | What runs through JetStream, comma-separated: `ledger` (the change ledger as a stream), `jobs` (background job dispatch), `intake` (connector intake queue), or `all`. Without it nothing the Engine holds is sent to NATS. |
| `OPTIMAL_NATS_NAMESPACE` | `optimal` | Prefix of every subject and stream (`OPTIMAL_LEDGER`); one per Engine on a shared NATS account. |
| `OPTIMAL_NATS_LEDGER_MAX_AGE_HOURS` | `168` | How long the ledger stream keeps a change; `0` keeps it forever. |
| `OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS` | `720` | How long a dead letter is kept before JetStream purges it (the dead-letter stream's `max_age`); `0` keeps letters until they are requeued. |

`OPTIMAL_FRACTAL_ENDPOINT` with `OPTIMAL_FRACTAL_CREDENTIAL_REF` is declared with no adapter, and the inventory reports it `adapter_missing` whatever is set.
See [Storage providers](docs/guides/storage-providers.md) and [Installation and deployment](docs/guides/installation-and-deployment.md).

### Analytics (DuckDB and Parquet)

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPTIMAL_ANALYTICS_PATH` | none (analytics off) | A writable directory; the daily `analytics_export` analysis writes each workspace's Parquet files under it, and `GET /api/analytics/query` reads them. Needs the `duckdb` executable on the PATH (the Engine image ships it). |
| `OPTIMAL_ANALYTICS_MAX_PROCESSES` | `1` | How many `duckdb` processes analytics runs at once. Each may use 512 MB, so `1` suits a 1 GiB guest; raise it on a larger machine. A query past the cap is `503 {"error": "analytics_busy"}` with `Retry-After: 5`. An export runs on one process of its own beside the cap, at 256 MB with the rest spilled to disk, so the daily export never turns queries away (peak: the cap at 512 MB each plus 256 MB); a second export waits for it. |
| `OPTIMAL_ANALYSES_INTERVAL_MS` | `300000` | How often the analyses worker schedules and drains analyses, the export among them; `0` turns it off. |

See [DuckDB And Parquet Analytics](docs/guides/storage-providers.md#duckdb-and-parquet-analytics).

## Text Embeddings

| Variable | Default | Purpose |
| --- | --- | --- |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama for generation, vision, and text embeddings when `OPTIMAL_EMBED_URL` is unset. |
| `OPTIMAL_EMBED_MODEL` | `nomic-embed-text` | Text embedding model, whichever endpoint serves it. |
| `OPTIMAL_EMBED_URL` | unset | Embedding endpoint for every text embedding, for example a shared gateway's `/v1/embeddings`. |
| `OPTIMAL_EMBED_DIALECT` | inferred | `openai` or `ollama`; other values fail startup configuration. |
| `OPTIMAL_EMBED_API_KEY` | unset | Key sent to `OPTIMAL_EMBED_URL` as a bearer token. |
| `OPTIMAL_EMBED_API_KEY_FILE` | unset | File holding that key, used when `OPTIMAL_EMBED_API_KEY` is unset. |
| `OPTIMAL_EMBED_DIMENSIONS` | 768 for `nomic-embed-text` | Vector width the endpoint must return; other values fail startup configuration unless a positive whole number. |
| `OPTIMAL_EMBED_CACHE_MAX_AGE_DAYS` | 30 | Days a cached embedding is kept (`config :optimal_engine, :text_embedding, cache_max_age_days:`); `0` keeps entries until their workspace is purged; other values fail startup configuration unless a whole number. |

With `OPTIMAL_EMBED_URL` unset, text embeddings come from Ollama at `OLLAMA_HOST`, exactly as before.
With it set, the semantic pipeline at intake, chunk embeddings, search queries, durable memory projections, app data, and the embedding backfill all embed through that endpoint.
An Engine with no local model still embeds each ingested document there, so semantic search finds it.
The URL must be `http` or `https`; an empty value counts as unset.
A URL whose path ends in `/api/embed` speaks Ollama's native API, and any other URL speaks the OpenAI-compatible `POST /v1/embeddings` API.
`OPTIMAL_EMBED_DIALECT` overrides that inference.
A URL that stops short of the request path gets it appended: `/v1/embeddings` (or `/embeddings` after `/v1`) for OpenAI, `/api/embed` for Ollama.
The key goes only to `OPTIMAL_EMBED_URL`, never to `OLLAMA_HOST`.
It is read when a request is made, so a rotated key file takes effect without a restart, and it never enters the application configuration, a log line, or the store.
An endpoint that refuses the key (HTTP 401 or 403) is logged as an error naming the status and these variables, the health check reports `embedder_unauthorized`, and the embedding backfill stops instead of counting every document as failed.
An endpoint that cannot serve right now (402 out of credit, 404 no such model, 429 rate limited, 5xx such as the gateway's 502 `embedding_backend_unavailable`) or does not answer makes semantic retrieval unavailable for the moment.
Capture and intake still succeed, search serves full-text results, the document is embedded later by the backfill, and the backfill itself stops.
Log lines name the endpoint, the status, and the endpoint's error code; they never carry the text sent for embedding or the key.
`OPTIMAL_EMBED_URL` is where the Engine sends its requests, usually MIOSA's gateway; it is not the gateway's own `OPTIMAL_EMBED_UPSTREAM_URL`, which names the model server behind the gateway.
Inputs are capped at 6,000 characters after invalid UTF-8 is replaced, and identical inputs are served from the filesystem cache.
Ollama's cache entries are keyed by the model and the input; an endpoint's are keyed by the endpoint, the model and the input, so vectors from one never answer for the other.
The cache is kept per workspace, under `<cache path>/tenants/<tenant>/<workspace>/embeddings/`.
An entry is named by an HMAC-SHA256 digest of its key and holds the vector only, so the cache never holds the text that was embedded.
The digests, which also name the tenant and workspace directories, are keyed with a secret that belongs to the install: `embed_cache.key` in the database's directory, created at first use (`config :optimal_engine, :embed_cache_key_path` moves it).
A guess at a text, a tenant id or a workspace id therefore cannot be confirmed from the cache's file names.
Cache files are mode 0600 and the directories the cache creates are 0700.
The vector remains: it is derived from the text and can be inverted to approximate it, so the cache is a derived copy of the data, kept under the same access rules and removed with it, not an anonymised one.
When the key is created, entries written under another one (an earlier digest scheme, or a key that was lost) cannot be attributed to a workspace and are removed, and the log says how many.
If the key cannot be created or read, nothing is cached and the log names the path; lookups are misses and writes fail quietly.
Two workspaces that embed the same text each keep their own entry.
An embedding is cached only when its workspace is known: ingest uses the chunk's or document's workspace, a search uses the workspace being searched, and the memory and app data projections use their own.
An embedding asked for with no workspace is computed every time.
Deleting, archiving, moving or erasing a workspace removes everything the cache holds for it.
What else an erasure removes and what stays in backups, with how long, is in [`docs/guides/erasure-and-retention.md`](docs/guides/erasure-and-retention.md).
Erasing a principal does the same for every workspace that held one of their contexts, and deletes what is derived from those contexts: the document vectors, chunks and chunk vectors, entity mentions, claims and the facts that accepted them, source packages with their decomposition runs, assets and extractions, the wiki pages written from their chunks, and episodes, processor runs, decisions and edges that name them, with the files those rows point at.
The contexts go in batches of 200, each batch one transaction together with the rows derived from it, so a failure stops the erasure with the earlier batches done and erasing the principal again finishes the rest.
A source package shared with a context that stays is kept, and so is an asset file shared with an asset that stays.
A retention sweep that deletes a context removes the same derived material and purges its workspace's cache as well.
A retention `redact` that changes a context's text rewrites its abstract and overview too, removes everything derived from the original text (chunks, vectors, claims, the source package), and builds the chunks and the document vector again from the redacted text; text that redaction leaves unchanged is not touched.
Archiving or moving a workspace also removes its decomposition checkpoints (`<cache path>/decomposition/<run>.json`, which carry chunk text, named by `decomposition_runs.checkpoint_uri`) and the local copies of its object-store assets (`<cache path>/assets/...`); an erasure or a retention delete removes those of the rows it deletes. A file is removed only if it is the one the Engine writes for the row, see [Erasure And Retention](docs/guides/erasure-and-retention.md).
A replica that applies a peer's delete of a context purges its workspace's embedding cache once the batch has committed. It removes the checkpoints, the local asset files and the rows this Engine made itself (decomposition runs, assets, extraction, transcript and OCR text) of a source package only once the package row is gone, as the origin does: the origin deletes them with the package, and keeps the package, with them, while a context or a claim refers to it. A package a context or a claim here still refers to keeps them too.
Entries also expire by age: a sweep at boot and every six hours removes entries last written more than `cache_max_age_days` (30) ago.
A cache hit does not extend an entry's life.
Deleting or forgetting a single record removes the entry cached from its text when the text is at hand at that moment: a durable memory deleted or forgotten (its content and its retrieval document), an app data record deleted, or one whose indexed fields were rewritten (the old text).
An entry whose text is not known any more stays until it expires: a memory embedded with a custom document prefix, a collection dropped whole, and a search query.
Earlier versions kept the cache unpartitioned, with the embedded text inside each entry.
The first boot after upgrading removes that cache, because its entries cannot be attributed to a workspace, before the API answers.
It logs the number of files and bytes (`removed the unpartitioned embedding cache of earlier versions: N files, M bytes`), and records a `cache.legacy_purge` audit event when it removed files.
Embeddings are recomputed on demand afterwards; later boots find nothing to remove and say nothing.
The first boot of this release records the result on every Engine, including one with an empty cache (0 files, 0 bytes), in `embed_cache_legacy_purge.json` next to the database.
The record is Engine-local: it is not a table, so it is not replicated, not in a workspace bundle, and not in a database backup.
`GET /api/storage` returns it as `embed_cache_legacy_purge`: `{"ran_at": "<ISO 8601 UTC>", "files": N, "bytes": M, "engine_version": "<version that ran it>"}`, or `null` if it has never run.
`GET /api/metrics` (`gauges`) and `GET /api/metrics/prometheus` carry it as the gauges `optimal_engine_embed_cache_legacy_purge_files` and `optimal_engine_embed_cache_legacy_purge_bytes`.
The run also emits the telemetry event `[:optimal_engine, :embed_cache, :legacy_purge]` with the measurements `files` and `bytes`.
Files of the old layout that appear again, for example after a rollback to an earlier version, are removed at the next boot and recorded again.
An endpoint's vectors must have the model's width; a different width is refused as `embed_dimension_mismatch`, logged with the two widths, never cached, and stops a backfill.
A cached vector of another width than the model now needs, after the width setting changed, is fetched again.
Stored vectors of another dimension are never scored, so a model with a different dimension cannot mix with an existing index.
A request waits at most 5 seconds; an endpoint that accepts the connection and never answers counts as unavailable, and the search path's health probe gives up after 2 seconds.
A request that finds the endpoint unavailable marks it unhealthy for the process that made it, for 60 seconds (`config :optimal_engine, :text_embedding, health_ttl_ms:`), so its searches skip the vector hop instead of waiting again; a successful request clears the mark.
With an endpoint, the chunks of an ingested document that are embedded by text (text, audio transcripts, and the OCR or caption text of images and video without an asset embedded by vision) go out in one batched request, recorded as one governed model call (`embedder.embed_text_batch`, with the input count and size, never the text), so an unavailable endpoint is asked once per document, not once per chunk.
A transcript whisper makes, or a video's text used after vision fails, goes out on its own, so each such chunk can wait out the timeout once more.
With Ollama at `OLLAMA_HOST`, each chunk is embedded on its own, as before.
A batch answered 429 with a `Retry-After` of at most 60 seconds is retried once after that wait; a single embedding, such as a search query, is not.
A key sent over plain `http` to another machine is warned about once, without the key.

## Knowledge Graph Backend

The graph that search, assembly, and materialization read is the SQLite `graph_edges` table.
The triple store is a mirror rebuilt from it, and no retrieval path reads it.
`OPTIMAL_KNOWLEDGE_BACKEND` chooses the mirror's backend.

The default is ETS, held in memory and reloaded at each start.
It is what bare `mix`, tests, the Docker image, and the MIOSA template run, because none of them sets the variable.
`scripts/run-engine.sh` defaults it to RocksDB.

Use RocksDB to keep the mirror on disk:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=rocksdb
OPTIMAL_KNOWLEDGE_ROCKSDB_PATH=/data/.optimal/knowledge-rocksdb
```

Use ETS for fast in-memory testing:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=ets
```

Use Mnesia only when intentionally testing distributed graph behavior.
Its tables are `ram_copies`, so nothing is persistent:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=mnesia
```

A Riak backend exists in the source but is in no build, because its client is not a dependency, and it cannot be selected.
SQLite remains the durable source of truth.

## Product Embedding

Products such as BusinessOS should connect over HTTP:

```text
BusinessOS
  -> scoped engine URL
  -> scoped API key or local connector grant
  -> tenant, organization, workspace, Node, and policy scope
  -> Optimal Engine API
```

Downloaded users should get their own local bundled engine and local store.
They should not connect to the owner's private engine unless explicitly configured as the owner's machine.

## Setup Profiles

| Profile | Use when | Expected behavior |
| --- | --- | --- |
| Local source checkout | Developer or local agent work | `bin/optimal dev` runs the engine on `localhost:4200`. |
| Bundled desktop engine | BusinessOS desktop user | App launches a local release with fresh local runtime data. |
| Production service | Hosted org or workspace | Service uses production secrets and scoped keys. Postgres is an optional provider chosen when the Engine boots (`OPTIMAL_STORE=postgres`), not switched on by configuring a URL alone. |
| Test mode | CI and unit tests | Use isolated temp stores and avoid private `.optimal/` data. |

## Compatibility And API Grants

The current source contract is application `0.3.14`, contract schema `1`, API `v1`, and migration `89`.
The tracked [engine-contract.json](engine-contract.json) lists capabilities; [release identity](docs/guides/versioning-and-releases.md) explains the running build's SHA and version response.
A checkout pin does not attest a separately running HTTP process.

Ordinary `read`/`write` clients need separate `claims:review`, `topology:write`, or `admin` grants for privileged operations.
`POST /api/auth/keys` refuses a request without `scopes` (400 `scopes_required`) unless the minting key's own scopes are named, in which case they are inherited; ask for `["*"]` explicitly when a root key is meant. `mix optimal.auth mint` (local operator shell) still defaults to `*`.
Follow [API grants and migration](docs/guides/interfaces-and-publishing.md#api-grants-and-identity) for tenant/reviewer binding and administrator-issued replacement keys.

## Safe Defaults

Prefer repo-relative defaults.
Prefer environment-driven config.
Require credentials explicitly for untrusted HTTP access with `OPTIMAL_AUTH_REQUIRED=true`.
An Engine that listens beyond loopback without them is reported as open, and refused with `OPTIMAL_REFUSE_OPEN_NETWORK=1` (the default from the next release).
Only the interface the Engine binds is checked: a loopback Engine that a proxy, tunnel or port map publishes to the network is not detected, and needs `OPTIMAL_AUTH_REQUIRED=true` as well.
The container image and the compose files listen on all the container's interfaces and set `OPTIMAL_AUTH_REQUIRED=true`.
The default local mode is trusted and permits anonymous requests; HTTP grants do not sandbox local CLI or SQL access.
With `OPTIMAL_AUTH_REQUIRED=false` a request without a key is the Engine operator (`OptimalEngine.API.Actor.engine_operator?/1`): it reads every tenant's data, the Engine log and the Engine-wide metrics. Never run that mode where anyone but the operator can reach the port: not on a shared network, not behind a proxy or port map others can reach.
Applications must supply intended scope, while legacy API defaults remain documented compatibility behavior.
Never silently share memory across tenants, organizations, or workspaces.
