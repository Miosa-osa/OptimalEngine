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

| Substrate | Role | Canonical? | Rebuildable? | Notes |
| --- | --- | --- | --- | --- |
| SQLite | Local canonical runtime store today. | Yes, for local/dev/personal runs. | No for durable rows; yes for derived rows. | Owns current DB-backed runtime tables. |
| Postgres | Target production canonical runtime store. | Yes, target for multi-user production. | No for durable rows; yes for derived rows. | Keeps the same layer ownership model as SQLite. |
| Raw artifact storage | Preserved source files, uploads, attachments, media, exported payloads. | Yes. | No unless external source still exists. | Source evidence must survive parser/model/index changes. |
| FTS/vector/chunk indexes | Retrieval acceleration and ranked candidate generation. | No. | Yes. | Rebuilt from sources, chunks, memories, and extraction rows. |
| Cache directories | Parse, embedding, context, and local runtime caches. | No. | Yes. | Never trust caches as source of truth. |
| ETS | In-memory graph/knowledge backend. | No for durable truth. | Yes. | Fast local process state. |
| RocksDB | Optional persistent graph/triple-store backend. | Optional for graph workload, not main workspace DB. | Depends on configured use. | Requires native RocksDB runtime support. |
| Mnesia/Riak backends | Optional distributed graph/knowledge backend experiments. | Optional. | Depends on configured use. | Not the primary product storage path today. |
| Markdown workspace | Human-operable projection and editing surface. | No by default. | Yes from engine state. | Edits re-enter as Source Packages or topology change requests. |
| HTML/wiki/dashboard/API | Display and control projections. | No. | Yes. | Should be regenerated from engine state. |

## Domain Ownership

The storage substrate does not decide meaning. Domain layers do.

| Domain layer | Owns durable lifecycle for | Writes |
| --- | --- | --- |
| Workspace / Topology | organizations, tenants, workspaces, nodes, node types, node relationships, memberships, routing rules | topology tables and topology change requests |
| Source Intake | preserved input, source package creation, raw artifact capture | `source_packages`, raw artifact records |
| Signal Pipeline | signal classification, multimodal parsing, compatibility search rows | signal metadata, contexts, chunks, classification records |
| Memory Core | claims, facts, memory objects, evidence edges, derivation ledger, temporal state | memory core tables |
| Retrieval / Context | query plans, authorization envelope, context package assembly, stale package refresh | context packages, retrieval audit, projection links |
| Active Memory Pools | task-scoped working state for humans and agents | pools, observations, loaded context links |
| Workflow / Skill Runtime | traces, generalized workflows, procedures, skill packages, execution records | workflow and skill tables |
| Tool / Model Governance | registered tools, MCP/API/script/model calls, schemas, grants, call audit | tool/model definitions and call runs |
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
Tool call output bypasses governance.
App UI invents a second data model.
Cache/index rows are treated as canonical memory.
Workspace folders become the only identity for Nodes.
```

## Production Shape

For a production deployment, the intended shape is:

```text
Postgres
  -> canonical runtime tables

object/file storage
  -> preserved raw artifacts and attachments

index/cache layer
  -> FTS, vectors, chunks, parse cache, model outputs where rebuildable

optional knowledge backend
  -> RocksDB/ETS/Mnesia/Riak style graph acceleration or triple-store workloads

projection layer
  -> markdown, wiki, HTML, app views, API responses, reports, agent context
```

The important point is not which physical store is used first. The important
point is that each table, file, cache, and projection has an owner, lifecycle,
rebuild policy, and audit path.

