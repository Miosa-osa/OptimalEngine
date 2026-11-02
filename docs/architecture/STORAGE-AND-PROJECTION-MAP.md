# Storage And Projection Map

Optimal Engine separates three concerns that are easy to accidentally mix:

```text
storage substrate = where bytes and records live
domain layer      = who owns lifecycle and meaning
projection surface = how humans, agents, and apps see or control it
```

The same information can appear in a database row, a markdown file, an API
response, a wiki page, a dashboard card, and an agent context package. Only one
layer should own the lifecycle.

## The Rule

```text
Store data once as governed state.
Project it many times for different users, agents, tools, and interfaces.
Accept edits back as new evidence or reviewed topology changes.
```

Markdown, HTML, dashboards, wiki pages, reports, and agent prompts are not
separate truth systems. They are projections or control surfaces over the engine.

## Storage Substrates

The default shape is one Engine instance that holds every store inside it.
The "Wired?" column says whether a working adapter exists in this repository today.
"Wired" means the code in `lib/` reads and writes the substrate.
"Declared" means the provider inventory lists it and no adapter exists yet, so the Engine cannot use it.

| Substrate | Role | Canonical? | Rebuildable? | Wired? | Notes |
| --- | --- | --- | --- | --- | --- |
| SQLite | The canonical relational store of every default build. | Yes. | No for durable rows; yes for derived rows. | Wired, the default. | Owns the DB-backed runtime tables. One file, one writer. |
| Postgres | Optional provider for scale: the canonical relational store of a Postgres build. | Yes, in a Postgres build. | No for durable rows; yes for derived rows. | Wired, partial. | Chosen at compile time with `OPTIMAL_STORE=postgres`. It refuses full-text search, replication and app data collections. See [PostgreSQL Provider](../guides/postgres-provider.md). |
| Raw artifact storage (filesystem) | Preserved source files, uploads, attachments, media, exported payloads. | Yes. | No unless the external source still exists. | Wired, the default. | Lives under the Engine root. Source evidence must survive parser, model, and index changes. |
| S3-compatible object storage | Assets and offsite backups for the Engine that is configured with it. | Yes for the artifacts assigned to it. | No unless replicated elsewhere. | Wired. | Garage, AWS S3, R2, MinIO, or a MIOSA bucket. Backups are sealed with `OPTIMAL_BACKUP_KEY` before upload. |
| FTS5, vector, and chunk indexes | Retrieval acceleration and ranked candidate generation. | No. | Yes. | Wired, embedded. | FTS5 tables and float32 vector BLOBs live in the SQLite file. A Postgres build has no full-text search. |
| Cache directories | Parse, embedding, context, and local runtime caches. | No. | Yes. | Wired. | Under `OPTIMAL_ENGINE_CACHE`. Never trust caches as source of truth. |
| ETS | In-memory graph backend and hot cache. | No for durable truth. | Yes, from SQLite `graph_edges`. | Wired. | The triple-store mirror under bare `mix`, in tests, in the Docker image, and in the MIOSA template (the config default); the hot cache everywhere. Process state is lost at restart and loaded again from SQLite. |
| RocksDB | Persistent graph and triple-store backend. | No. The edges are canonical in SQLite. | Yes, from SQLite `graph_edges`. | Wired, opt in. | The default of `scripts/run-engine.sh`. Elsewhere select it with `OPTIMAL_KNOWLEDGE_BACKEND=rocksdb` and place it with `OPTIMAL_KNOWLEDGE_ROCKSDB_PATH`; the Docker image and MIOSA template set neither. Falls back to ETS when the native library is missing. |
| Mnesia | Graph backend for BEAM distribution experiments. | No. | Yes, from SQLite `graph_edges`. | Wired, `ram_copies` only. | Tables are created as `ram_copies`, so nothing is persistent. Not a production path. |
| Riak | Graph backend experiment. | No. | Not applicable. | Not in any build. | `riak.ex` compiles only when the `riakc` client is present, and `riakc` is not in `mix.exs`. It cannot be selected by `OPTIMAL_KNOWLEDGE_BACKEND`. |
| Jobs | Durable background work, leases, retries, dead letters. | Yes, as queue state. | Partly: handlers rerun from the governed ledgers. | Wired. | `jobs` and `dead_letter_jobs` tables in SQLite. |
| Change ledger | Ordered, idempotent record of workspace changes for replication. | Yes, as the history of change. | No. | Wired, not on a Postgres build. | `sync_mutations` and `sync_cursors` in SQLite. Peers carry it over HTTP, or over the MIOSA relay for an Engine that cannot be dialed. |
| Backups | Verified online copies of the database and the catalog that tracks them. | Copies, not truth. | Not applicable. | Wired. | `POST /api/backup` writes into `OPTIMAL_BACKUP_DIR` and records `backup_records`. An offsite copy is sealed and stored on S3. |
| Sealed connector keys | Connector and peer credentials, authority signing keys. | Yes, as ciphertext. | No. | Wired. | Stored sealed in the database. The keys (`CONNECTOR_KEY`, `OPTIMAL_AUTHORITY_KEY`) live outside it, and `OPTIMAL_BACKUP_KEY` seals offsite backups. Losing a key loses what it sealed. |
| NATS JetStream | Replayable event, job, connector, and replication transport. | No. | Yes from the governed mutation and job ledgers. | Adapter: `OptimalEngine.Storage.NATS.Adapter` (NATS text protocol, `OPTIMAL_NATS_URL`); proved by a stream created, a message published and read back by sequence. | Transport never replaces canonical state. |
| Valkey | Distributed cache, rate limits, locks, and coordination. | No. | Yes. | Adapter: `OptimalEngine.Storage.Valkey.Adapter` (RESP over TCP, `OPTIMAL_VALKEY_URL`); proved by a set, get and delete round trip. | Ephemeral acceleration only. |
| Qdrant | High-scale semantic retrieval projection. | No. | Yes. | Declared, no adapter yet. | Vector results remain candidates, not truth. Embedded vectors serve every Engine today. |
| DuckDB and Parquet | Large analytical and historical projections. | No for transactional state. | Yes. | Declared, no adapter yet. | Analytics remain isolated from operational writes. |
| OpenBao | Secret, key, PKI, and credential lifecycle. | Yes for managed secrets. | Recovery follows secret-manager policy. | Declared, no adapter yet. | Workspace policies contain references, not secret values. |
| Fractal Computing | Enterprise synchronized digital-twin substrate. | Governed by the enterprise integration boundary. | Depends on the enterprise contract. | Declared, no adapter yet. | Cloud-only partner capability with controlled, auditable promotion to systems of record. |
| Markdown workspace | Human-operable projection and editing surface. | No by default. | Yes from engine state. | Wired. | Edits re-enter as Source Packages or topology change requests. |
| HTML, wiki, dashboard, API | Display and control projections. | No. | Yes. | Wired. | Should be regenerated from engine state. |

## Store Decision Matrix

Use this table when adding a new feature, connector, agent action, parser, or
projection. The question is not "where can I put this fastest?" The question is
"which layer owns this lifecycle?"

| Data | Goes in | Owner | Why |
| --- | --- | --- | --- |
| Organization, tenant, workspace, Node, Node type, membership, relationship, alias, routing rule | The canonical relational store (SQLite; Postgres in a Postgres build) | Workspace / Topology | This is durable structure. It decides scope, permissions, routing, and projections. |
| Raw text dump, message, note, event, API payload, connector payload, tool result | `source_packages` plus raw artifact storage when file-backed | Source Intake / Memory Core | Preserve evidence before interpretation. |
| File, attachment, image, audio, video, PDF, archive | raw artifact storage plus `assets` row | Memory Core | The file is evidence; parser/model output is derived. |
| Signal classification | signal metadata and compatibility context/search rows | Signal Pipeline | Classification routes and parses input; it is not accepted truth. |
| Claim candidate | `claims` | Memory Core | A Claim records what a source appears to say before acceptance. |
| Reviewed truth | `facts` | Memory Core | Facts require evidence, validity, confidence, precision, and review/policy state. |
| Institutional meaning | `memory_objects` | Memory Core | Memory explains why Facts/Claims matter in context. |
| Evidence, semantic, temporal, procedural links | `relationship_edges` | Memory Core / Topology depending on edge type | Graph links need ownership and permissions, not loose references. |
| Parser/model/tool lineage | `derivation_ledger`, model/tool run records | Memory Core / Governance / Audit | Every generated artifact needs provenance and replay/rebuild information. |
| Transcript/OCR/visual observation/embedding reference | `asset_extractions` and typed projection tables | Memory Core / Pipeline | These are governed derived artifacts linked to the raw asset. |
| Vector, FTS, chunk, rerank, summary acceleration | index/cache/projection tables | Retrieval / Pipeline | Rebuild from canonical sources and derived extraction rows. |
| Query result for a human or agent | `context_packages` | Retrieval / Context | Context is an authorized package, not random chunks. |
| Cue-Tag-Content association index | `memory_associations` | Retrieval / Context | Rebuildable from governed objects and never canonical truth. |
| Reconstruction execution and path learning | reconstruction run, step, path, outcome, and prior tables | Retrieval / Evaluation | Audit and routing evidence linked to one Context Package. |
| Readiness classification | `optimality_assessments` | Evaluation / Recovery | Versioned evidence against explicit thresholds. |
| Task-local working state | `active_memory_pools`, observations, loaded context links | Active Memory Pools | Humans and agents need scoped RAM without corrupting durable truth. |
| Repeated execution evidence | `workflow_traces`, execution records | Workflow / Skill Runtime | Workflows should be learned from evidence-linked work. |
| Reusable procedure | `procedural_memory_objects`, `skill_packages` | Workflow / Skill Runtime | A Skill Package is validated operational knowledge, not a prompt file. |
| MCP/API/script/connector/model definitions and calls | governance tables and audit events | Tool / Model Governance | External action must be registered, permissioned, schema-checked, and logged. |
| Markdown node page, HTML page, wiki page, dashboard card, report, API response | projection/export records and generated files | Wiki / Export | These are views over engine state unless re-ingested as evidence. |
| Delivery bundle/zip for a receiver/channel | Node-local `packages/` or workspace-level package when cross-node | Wiki / Export plus owning Node | Packages are receiver/channel bundles with source links and review state. |
| Secrets/API keys | secret manager or deployment environment, referenced by connector/tool config | Governance / Deployment | Secrets do not belong in markdown, Source Packages, context, or package manifests. |

## Multi-User And Enterprise Scope

The hierarchy stays the same for a single person and for an organization:

```text
Tenant / Organization
  -> Workspace
    -> Node graph
      -> Sources, Signals, Claims, Facts, Memories, Workflows, Skills
```

In a team or enterprise deployment, every durable row should carry or inherit:

```text
tenant_id
workspace_id
node_id / scope where applicable
security_labels
partition_ids
created_by / actor_id
policy_version
audit_event_links
```

The purpose is not bureaucracy. It prevents the three common failures:

```text
one user's context leaking into another workspace
agent/tool calls acting outside their granted scope
project/package/workflow names resolving to the wrong Node
```

SQLite exercises this model on every Engine, from a laptop to an organization.

One org Engine serves an organization, with a walled section per workspace.
A key scoped to one workspace never reads another, and a customer gets an Engine of their own only when a wall requires it.
When one SQLite writer is no longer enough, an Engine can be built against PostgreSQL as an optional provider for scale, with the limits listed in the Substrates table, while the ownership rules stay the same.

The workspace policy and replication ledger make any move of data explicit instead of silently changing the source of truth.

## Domain Ownership

The storage substrate does not decide meaning. Domain layers do.

| Domain layer | Owns durable lifecycle for | Writes |
| --- | --- | --- |
| Workspace / Topology | organizations, tenants, workspaces, nodes, node types, node aliases, node relationships, memberships, routing rules | topology tables and topology change requests |
| Source Intake | preserved input, source package creation, raw artifact capture | `source_packages`, raw artifact records |
| Signal Pipeline | signal classification, multimodal parsing, compatibility search rows | signal metadata, contexts, chunks, classification records |
| Memory Core | claims, facts, memory objects, evidence edges, derivation ledger, temporal state | memory core tables |
| Retrieval / Context | query plans, authorization envelope, tiered or reconstructive strategy, associative projection, context package assembly, stale package refresh | context packages, reconstruction traces, association paths, retrieval audit, projection links |
| Active Memory Pools | task-scoped working state for humans and agents | pools, observations, loaded context links |
| Workflow / Skill Runtime | traces, generalized workflows, procedures, skill packages, execution records | workflow and skill tables |
| Tool / Model Governance | registered tools, MCP/API/script/model calls, schemas, grants, call audit | tool/model definitions and call runs |
| Agent Collaboration | remote agent definitions, Agent Cards, delegated task runs, returned artifacts | A2A registry/projection records and audit, backed by the governance spine first |
| Wiki / Export | markdown/wiki/html/report/package projections | export records, wiki pages, projection revisions |
| Evaluation / Recovery | benchmark runs, cases, rebuild checks, health probes | evaluation and recovery records |

## Projection Surfaces

| Surface | What it shows or controls | Backing state |
| --- | --- | --- |
| Markdown workspace | node pages, rhythm, status, playbooks, package outputs | topology, memory, workflow, export records |
| Wiki pages | curated human-readable node/workspace pages with citations | wiki pages, facts, memories, source links |
| CLI | setup, initiation, topology inspection, retrieval, rendering, verification | all domain layer interfaces |
| API | app/dashboard/service access | same engine state as CLI |
| MCP/tools | governed agent access to retrieval, memory, workspace, and tools | tool governance, context packages, active pools |
| A2A agents | delegation to other agents and returned artifact capture | agent collaboration records, context packages, active pools, audit |
| Desktop/app UI | workspace switcher, node pages, memory views, runs, dashboards | API projections over engine state |
| Browser/Raycast extensions | quick capture, search, ask, add memory | API, source intake, retrieval |
| SDKs | typed integration layer for apps and agents | API contracts |
| Reports/packages | receiver-specific exported bundles | export records and source-linked projection state |

## Data Flow Across The Separation

```text
Human / agent / connector produces input
  -> Source Intake preserves evidence
  -> Signal Pipeline classifies and parses
  -> Workspace Topology scopes it to a workspace/node
  -> Memory Core extracts Claims and promotes reviewed Facts
  -> Retrieval assembles Context Packages
  -> Active Pools give task-local working state
  -> Tools/models/workflows act under governance
  -> observations re-enter as pending Claims
  -> Wiki/Export projects state to markdown/html/app/API
```

## Edit Flow

Edits from human-facing surfaces must re-enter the engine correctly.

```text
markdown edit
  -> Source Package if it changes knowledge
  -> topology_change_request if it changes workspace structure
  -> export revision if it only changes projection metadata
```

```text
app form save
  -> owning domain service
  -> canonical table write
  -> audit event
  -> projection invalidation
```

```text
agent tool result
  -> governed tool call run
  -> Source Package or observation
  -> pending Claim
  -> review/policy promotion
```

## What Must Not Happen

```text
Markdown file directly becomes truth without source/provenance.
Agent writes Facts directly instead of Claims/observations.
Vector search becomes the final authority.
Associative projection rows become durable truth.
Reconstruction bypasses Scope Envelope or returns loose evidence instead of a Context Package.
Tool call output bypasses governance.
App UI invents a second data model.
Cache/index rows are treated as canonical memory.
Workspace folders become the only identity for Nodes.
Loose names route durable writes without stable ID resolution.
```

## One Engine, Every Store Inside

The default deployment is one Engine process on one durable disk.
It holds every store inside it and does not run Postgres, Qdrant, or Redis next to it.
It embeds its own equivalents.

```text
one Engine process, one durable disk
  relational        -> SQLite file (OPTIMAL_ENGINE_DB)
  full text         -> SQLite FTS5, in the same file
  vectors           -> float32 BLOBs, in the same file
  knowledge graph   -> graph_edges in SQLite is the graph retrieval reads; a triple-store mirror
                       (ETS in memory, or RocksDB at OPTIMAL_KNOWLEDGE_ROCKSDB_PATH) is rebuilt from it
  assets, objects   -> files under the Engine root
  caches            -> ETS hot cache, files under OPTIMAL_ENGINE_CACHE
  jobs              -> jobs and dead_letter_jobs tables
  change ledger     -> sync_mutations, carried over HTTP or the MIOSA relay
  backups           -> OPTIMAL_BACKUP_DIR, catalog in backup_records
  sealed keys       -> ciphertext in the database, keys in the environment
  projections       -> markdown, wiki, HTML, app views, API responses, reports, agent context
```

The graph that search, assembly, and materialization read is the SQLite `graph_edges` table.
The triple store (ETS or RocksDB) is a mirror rebuilt from that table, and no retrieval path reads it.
The mirror is ETS, in memory, under bare `mix`, in tests, in the Docker image, and in the MIOSA template and managed Engines, because none of them sets `OPTIMAL_KNOWLEDGE_BACKEND`.
`scripts/run-engine.sh` (and so `make dev`) defaults it to RocksDB.
A deployment that wants the mirror on disk sets both `OPTIMAL_KNOWLEDGE_BACKEND=rocksdb` and `OPTIMAL_KNOWLEDGE_ROCKSDB_PATH` to a path on the data volume.

Every deployment mode in [Installation And Deployment](../guides/installation-and-deployment.md) starts from this shape.

## Growing Onto Providers

Providers are things a deployment grows onto, not the default shape.
Each moves one concern off the single disk without changing what the Engine stores or who owns it.

| Concern | Provider | Status |
| --- | --- | --- |
| Assets and offsite backups | S3-compatible storage: Garage, AWS S3, R2, MinIO, a MIOSA bucket | Wired. |
| Canonical relational store | PostgreSQL, a compile-time `OPTIMAL_STORE=postgres` build | Wired, partial. It refuses full-text search, replication, and app data collections. |
| Replayable events and jobs | NATS JetStream | Adapter wired; `available` when `OPTIMAL_NATS_URL` answers with JetStream. |
| Distributed cache and locks | Valkey | Adapter wired; `available` when `OPTIMAL_VALKEY_URL` answers. |
| High-scale vectors | Qdrant | Declared, no adapter yet. |
| Analytics | DuckDB and Parquet | Declared, no adapter yet. |
| Secrets | OpenBao | Declared, no adapter yet. |
| Enterprise digital twin | Fractal | Declared, no adapter yet. |

`GET /api/storage/providers` reports `adapter_implemented` for each, and `POST /api/storage/plan` never marks a plan ready when it selects a provider without an adapter.
[Storage Providers](../guides/storage-providers.md) has the per-provider status and the recipes.

The important point is not which physical store is used first.
The important point is that each table, file, cache, and projection has an owner, lifecycle, rebuild policy, and audit path.
