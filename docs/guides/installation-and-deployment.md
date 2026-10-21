# Installation And Deployment

Optimal Engine is backend-first. It can run as a local CLI-backed workspace for
one person, or as an organization runtime that multiple people, agents, apps,
connectors, and scripts use through the same governed engine.

## Deployment Profiles

| Profile | Use when | Canonical store | Notes |
| --- | --- | --- | --- |
| Local CLI | One person, local workspace, development, testing, agent-assisted setup. | SQLite at `.optimal/index.db`. | Fastest path. No Docker required. |
| Team server | Multiple users or agents using the same API/runtime. | Postgres target for canonical rows. | Add process supervision, backups, auth, audit, and object/file storage. |
| Enterprise | Multiple organizations, departments, controlled connectors, governed agents, retention and compliance needs. | Postgres or managed relational store target plus object storage and managed secrets. | Requires tenant/workspace isolation, SSO/IAM integration, policy, monitoring, and disaster recovery. |

The data model is the same in every profile:

```text
Tenant / Organization
  -> Workspace
    -> Node graph
      -> Source Packages, Signals, Claims, Facts, Memories, Context Packages,
         Active Memory Pools, Workflows, Skills, packages, and exports
```

Projects are Nodes inside a Workspace. A Workspace is the bounded operating
area. A package is a receiver/channel bundle; it is not a note.

## Local Install

Required:

```text
Erlang/OTP 27+
Elixir ~> 1.17
Git
C toolchain for the SQLite NIF
Snappy for the RocksDB knowledge graph backend
```

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
.optimal/index.db        SQLite runtime store
.optimal/cache/          rebuildable local cache
.optimal/connector_key   local API/connector secret
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

A production deployment should separate five concerns:

| Concern | Recommended role |
| --- | --- |
| Canonical runtime rows | Postgres target or equivalent relational store. |
| Raw artifacts | File/object storage with retention, backup, and access policy. |
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
`OPTIMAL_REFUSE_OPEN_NETWORK=1` makes such an Engine refuse to start instead; the refusal is off by default in this release and becomes the default in the next.
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
OLLAMA_HOST                  local model server URL
OPTIMAL_VLM_MODEL            local visual model name for configured adapters
```

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
OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS   scheduled offsite backups; 0 or unset disables
OPTIMAL_OFFSITE_BACKUP_KEEP          scheduled offsite copies kept; default 14
OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL    scheduled local files kept; default 3
```

A managed Engine whose connectors take short-lived credentials from a broker
(`credential_source: "broker"`, see [Connectors](connectors.md)) names the
brokers it may call; with none named, no broker is called:

```text
OPTIMAL_CREDENTIAL_BROKER_HOSTS   comma-separated https hosts; api.miosa.ai on MIOSA
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
