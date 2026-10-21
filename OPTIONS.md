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
| `OPTIMAL_REFUSE_OPEN_NETWORK` | `0` | `1` refuses to start an Engine whose API listens beyond loopback with authentication off. Off by default in this release; the next release makes the refusal the default. Other values fail startup configuration. |
| `OPTIMAL_ENGINE_DB` | `.optimal/index.db` | Local SQLite store path. |
| `OPTIMAL_ENGINE_CACHE` | `.optimal/cache` | Local cache path. |
| `OPTIMAL_BACKUP_DIR` | `backups/` beside the database | Only directory `POST /api/backup` may write into; restores verify the catalog checksum first. |
| `OPTIMAL_BACKUP_KEY` | none | 64 hex characters; encrypts every offsite backup copy with AES-256-GCM. Offsite copies are refused without it. Losing it loses every copy sealed with it. |
| `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS` | unset (off) | Interval for scheduled encrypted offsite backups; 0 or unset disables, otherwise at least 60000. |
| `OPTIMAL_OFFSITE_BACKUP_KEEP` | `14` | Scheduled offsite copies kept; older ones are deleted from the bucket. |
| `OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL` | `3` | Scheduled local backup files kept in `OPTIMAL_BACKUP_DIR`. |
| `OPTIMAL_S3_CREDENTIALS_FILE` | unset | File holding the S3 access key id and secret (two lines or `KEY=VALUE`); environment values win. |
| `OPTIMAL_ENGINE_ROOT` | repo root | Engine root for source-checkout usage. |
| `OPTIMAL_KNOWLEDGE_BACKEND` | `rocksdb` when available | Graph backend selection. |
| `CONNECTOR_KEY` | generated into `.optimal/connector_key` | Local connector secret. Connector credentials are refused without it; they are never stored in plaintext. |
| `OPTIMAL_CLAIM_PROMOTION_MODE` | `auto_threshold` | `auto_threshold`: the Engine promotes Claims whose confidence meets the workspace threshold every 30 minutes, as `system:promotion-scheduler`. `manual` or `agent_review`: it promotes nothing, and every Claim waits for a reviewer with `claims:review`. Other values fail startup configuration. |

Keep private values in environment variables, local secret stores, or deployment secret managers.
Do not commit them.

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
An entry is named by the SHA-256 digest of its key and holds the vector only, so the cache never holds the text that was embedded.
Two workspaces that embed the same text each keep their own entry.
An embedding is cached only when its workspace is known: ingest uses the chunk's or document's workspace, a search uses the workspace being searched, and the memory and app data projections use their own.
An embedding asked for with no workspace is computed every time.
Deleting, archiving, moving or erasing a workspace removes everything the cache holds for it.
Erasing a principal does the same for every workspace that held one of their contexts, and deletes the vectors and chunks derived from those contexts.
A retention sweep that deletes a context purges its workspace's cache as well.
Entries also expire by age: a sweep at boot and every six hours removes entries last written more than `cache_max_age_days` (30) ago.
A cache hit does not extend an entry's life.
Deleting a single record, such as forgetting one memory, does not purge the cache, so its entry stays until it expires.
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

Use RocksDB for normal local persistence:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=rocksdb
```

Use ETS for fast in-memory testing:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=ets
```

Use Mnesia only when intentionally testing distributed graph behavior:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=mnesia
```

SQLite remains the durable local source of truth.
The graph backend supports graph runtime behavior and retrieval.

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
| Production service | Hosted org or workspace | Service uses production secrets, scoped keys, and Postgres target when configured. |
| Test mode | CI and unit tests | Use isolated temp stores and avoid private `.optimal/` data. |

## Compatibility And API Grants

The current source contract is application `0.3.5`, contract schema `1`, API `v1`, and migration `75`.
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
The default local mode is trusted and permits anonymous requests; HTTP grants do not sandbox local CLI or SQL access.
Applications must supply intended scope, while legacy API defaults remain documented compatibility behavior.
Never silently share memory across tenants, organizations, or workspaces.
