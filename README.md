# Optimal Engine

Optimal Engine is a self-hosted operating engine for human and AI workspaces.

It lets a person or organization define a workspace, organize that workspace into
typed Nodes, preserve source evidence, classify incoming Signals, promote
reviewed knowledge into Facts and Memory Objects, assemble governed context for
humans and agents, and project the same state into markdown, APIs, dashboards,
CLI tools, and agent runtimes.

The short version:

```text
Human defines the world:
  Workspace -> Nodes -> Relationships -> Policies

Data enters the world:
  Source Package -> Signal -> Route -> Claim -> Fact -> Memory Object

Humans and agents use the world:
  Query or task -> Context Package -> Active Memory Pool -> Action

Work improves the world:
  Observation -> Pending Claim -> Reviewed Fact -> Memory -> Workflow -> Skill
```

## Current Build

The current build moves the engine from a file/search-first system toward a governed
workspace runtime.

Built and verified now:

| Area | Status |
| --- | --- |
| Workspace topology | Workspaces, Projects-as-Nodes, typed Nodes, Node Types, Node relationships, membership, and projection records. |
| Source evidence | Raw text becomes Source Packages with hash, workspace scope, trust label, security labels, partitions, and metadata. |
| Governed assets | Raw multimodal files can be preserved as Source Packages, workspace-scoped asset rows, and derivation ledger entries. |
| Pipeline asset governance | `Pipeline.run/2` preserves parser-produced assets through Memory Core before enrichment, decomposition, and embedding. |
| Indexer asset governance | Binary indexing can pass workspace scope into the governed pipeline so indexed assets do not fall back to the default workspace. |
| Multimodal tool registry | Open-source adapter targets are cataloged for document intelligence, OCR, audio, video, visual reasoning, visual document retrieval, and cross-modal embeddings. |
| Multimodal adapter runs | Adapter attempts and outputs can be recorded as governed derived artifacts linked to assets, Source Packages, scopes, hashes, and derivation ledger entries. |
| Claim/Fact separation | Extracted text becomes an unreviewed Claim first. A Claim becomes a Fact only through the truth-promotion lifecycle. |
| Memory Objects | Accepted Facts can be wrapped into source-backed Memory Objects with evidence links and confidence/precision metadata. |
| Derivation Ledger | Source-to-Claim, Claim-to-Fact, and Fact-to-Memory steps write lineage entries. |
| Governed retrieval | Retrieval returns Context Packages, not loose chunks, and filters by partition/security scope before package assembly. |
| Active Memory Pools | Task-scoped working memory can load Context Packages and publish observations as pending Claims. |
| Tool/model governance | Registered tools and model operations can enforce privileges, partitions, required inputs, required outputs, audit links, and the first governed execution path. |
| Connector governance | Connector sync can run through the governed tool-call surface, blocking unauthorized runs before connector execution and recording both connector-run and tool-call audit rows when allowed. |
| Workspace export | Markdown/files are projections and editing surfaces, not the only source of truth. |
| Reality check | `mix optimal.reality_check` covers store counts, topology, evidence/truth lifecycle, recall packages, retrieval, connectors, wiki, and compliance probes. |

Current verification:

```text
mix test test/memory_core/spine_test.exs test/workspace_export_test.exs test/topology/workspace_topology_test.exs test/topology/node_member_test.exs test/topology/node_test.exs test/topology/workspace_surface_spine_test.exs test/signal/dispatcher_test.exs test/connectors/runner_test.exs --seed 0
64 tests, 0 failures

mix test test/memory_core/asset_store_test.exs test/pipeline/pipeline_asset_store_test.exs test/pipeline/indexer_asset_store_test.exs --seed 0
5 tests, 0 failures

mix test test/pipeline/multimodal_tool_registry_test.exs test/memory_core/asset_store_test.exs test/pipeline/pipeline_asset_store_test.exs test/pipeline/indexer_asset_store_test.exs --seed 0
10 tests, 0 failures

mix optimal.reality_check
110 probes, 110 ok, 0 warn, 0 fail
```

The full legacy suite still contains older optional/backend warnings. The focused
slice above is the current verified build path.

## Product Shape

Optimal Engine has two sides that share the same state.

The human-operable side:

```text
Markdown workspace
CLI
App UI
Dashboards
Reports
Exports
```

The governed runtime side:

```text
SQLite/Postgres store
Workspace topology
Memory Core
Retrieval and Context Packages
Active Memory Pools
Workflow and Skill records
Model/tool governance
Audit and derivation records
```

Markdown stays important because it is portable, inspectable, and easy for humans
and coding agents to edit. The database becomes the canonical runtime for identity,
permissions, provenance, retrieval, audit, workflow state, and rebuildable
projections.

## Core Architecture

Optimal Engine is organized by lifecycle ownership, not just where bytes are
stored.

```text
Workspace / Topology
  owns workspaces, nodes, node types, relationships, membership, policies

Signal Pipeline
  owns classification, quality, routing hints, compatibility context rows

Memory Core
  owns source packages, claims, facts, memory objects, edges, derivation ledger

Retrieval / Context
  owns recall planning, context packages, authorization envelope, retrieval audit

Active Collaboration
  owns active memory pools, task observations, pending claims, refresh state

Workflow / Skill Runtime
  owns traces, generalized workflows, procedures, skill packages, execution records

Model / Tool Governance
  owns model calls, tool definitions, governed execution, schema validation, permissions, audit

Workspace Export
  owns markdown, HTML, app views, report packages, projection records
```

One physical database can hold many layer-owned tables. The rule is that each
table has an owning layer, and other layers write through that owner instead of
directly inventing lifecycle state.

## Node Model

A Node is not a folder. A folder can be an export of a Node, but the Node itself
is a governed topology object.

A Node represents:

- a bounded context with a clear purpose;
- a place where sources, signals, decisions, people, projects, workflows, and
  memories can attach;
- a point in a larger workspace graph;
- a unit that can be reviewed, measured, routed to, and evolved.

Common Node types include:

```text
entity
department
team
project
operational
learning
person
product
partnership
context
```

Projects live inside a workspace as `project` Nodes. They are not a peer of the
workspace. The hierarchy is:

```text
Tenant
  -> Workspace
    -> Nodes
      -> Project Node
      -> Person Node
      -> Product Node
      -> Operational Node
      -> Context Node
```

## Data Lifecycle

The backend flow is intentionally conservative:

```text
Raw input
  -> Source Package
  -> Signal
  -> Route to Workspace / Node
  -> Compatibility Context row
  -> Claim
  -> Fact
  -> Memory Object
  -> Relationship Edge
  -> Context Package
  -> Active Memory Pool
  -> Observation / Pending Claim
  -> Workflow Trace
  -> Skill Package
```

Not every source goes through every step. Some inputs stop at Signal. Some Claims
never become Facts. Some Memory Objects never become workflows. That is expected.
The important thing is that each promotion step has evidence, ownership, and audit.

## Storage Model

Local development uses SQLite at:

```text
.optimal/index.db
```

Docker is optional. You do not need Docker to run the local engine. Use Docker when
you want a packaged service stack or deployment-style environment.

Target production storage can move to Postgres while keeping the same layer
ownership model:

```text
SQLite now
Postgres target
Indexes and caches attached as rebuildable projections
Markdown/files exported from governed state
```

Table ownership:

| Table group | Owner |
| --- | --- |
| `workspaces`, `nodes`, `node_types`, `node_relationships`, `node_members` | Workspace / Topology |
| `contexts`, search projections, signal metadata | Signal/Search compatibility |
| `assets`, `asset_adapter_runs`, chunk asset refs, parser asset paths | Memory Core / Pipeline projections |
| `source_packages`, `claims`, `facts`, `memory_objects`, `relationship_edges`, `derivation_ledger` | Memory Core |
| `context_packages`, retrieval audit | Retrieval / Context |
| `active_memory_pools`, pool observations | Active Collaboration |
| `workflow_traces`, `generalized_workflows`, `procedural_memory_objects`, `skill_packages` | Workflow / Skill Runtime |
| `model_call_operations`, tool definitions, call runs | Model / Tool Governance |
| `export_records`, projection revisions, generated files | Workspace Export |

## Multimodality

The engine keeps a modality-aware data architecture. Text is still the most
complete truth-promotion path, but raw multimodal evidence now has a governed
storage path. Parser-produced assets can be copied into workspace asset storage,
linked to Source Packages, written into `assets`, and referenced by downstream
chunks through stable content hashes.

Canonical input families:

```text
text
document
code
image
audio
video
calendar/event
message/conversation
ticket/task
database/API payload
tool result
workspace projection edit
```

Each input type should still enter through the same evidence lifecycle:

```text
external source or local edit
  -> Source Package
  -> Signal classification
  -> Memory Core / Retrieval / Workflow as appropriate
```

For file-backed multimodal inputs, the current pipeline path is:

```text
file
  -> Parser asset
  -> MemoryCore.AssetStore
  -> Source Package + asset row + derivation ledger
  -> optional adapter run records for OCR/transcripts/visual outputs
  -> governed ParsedDoc
  -> Decomposer chunk with asset_ref
  -> Embedder asset_paths lookup
```

Open-source adapter targets are tracked in:

```text
lib/optimal_engine/pipeline/multimodal_tool_registry.ex
docs/reference/multimodal-open-source-stack.md
```

The current recommended stack is:

| Modality | Primary open-source targets |
| --- | --- |
| Documents | Docling, Marker, olmOCR, Unstructured, Tesseract, ColPali/ColQwen |
| Images | Docling, Qwen VL, Tesseract, OpenCLIP, ImageBind |
| Audio | Docling, whisper.cpp, Whisper, ImageBind |
| Video | FFmpeg, Qwen VL, whisper.cpp, Whisper, ImageBind |

The registry is a capability contract. It does not imply every heavyweight model
is installed by default; deployments choose which local adapters to install, and
missing tools must degrade gracefully while raw evidence is still preserved.
When an adapter does run, `asset_adapter_runs` records the adapter, role,
modality, status, input hash, output hash, output text/reference, model metadata,
security scope, partitions, and derivation ledger link.

## Human And Agent Usage

Humans can use the engine through:

```text
markdown
CLI
web/app UI
reports
workspace exports
```

Agents can use the engine through:

```text
API
MCP/tool surface
Context Packages
Active Memory Pools
Skill Packages
workspace files
```

Humans and agents should not have separate memory systems. They use different
interfaces into the same governed workspace runtime.

## Quick Start

Requirements:

- Elixir `~> 1.17`
- Erlang/OTP 26+
- Node 20+ for app/site surfaces
- a local C toolchain for optional native dependencies

Local engine:

```bash
mix deps.get
mix compile
mix optimal.reality_check
```

Focused verification for the current build:

```bash
mix test test/memory_core/spine_test.exs \
  test/workspace_export_test.exs \
  test/topology/workspace_topology_test.exs \
  test/topology/node_member_test.exs \
  test/topology/node_test.exs \
  test/topology/workspace_surface_spine_test.exs \
  test/signal/dispatcher_test.exs \
  --seed 0
```

Focused multimodal asset verification:

```bash
mix test test/pipeline/multimodal_tool_registry_test.exs \
  test/memory_core/asset_store_test.exs \
  test/pipeline/pipeline_asset_store_test.exs \
  test/pipeline/indexer_asset_store_test.exs \
  --seed 0
```

Useful commands:

```bash
mix optimal.reality_check
mix optimal.search "project"
mix optimal.rag "what changed this week?"
```

## Development Rule

Do not make `Store` the owner of business meaning.

Good:

```text
MemoryCore.extract_claim(...)
MemoryCore.promote_claim_to_fact(...)
MemoryCore.retrieve(...)
MemoryCore.open_active_pool(...)
WorkspaceTopology.create_node(...)
WorkspaceExport.project(...)
```

Avoid:

```text
Store.create_fact(...)
Store.publish_observation(...)
Context.make_truth(...)
raw SQL from feature modules into governed tables
```

`Store` can execute database writes. Domain layers own lifecycle decisions.

## What Comes Next

The next build slices are:

1. Add concrete adapters around the multimodal registry, starting with document
   intelligence and media demux/transcription.
2. Make connector and API upload paths consistently use the governed multimodal
   pipeline.
3. Add review queue UI/API ergonomics for Claims and Fact promotion.
4. Expand Retrieval Coordinator beyond simple fact/memory lookup into structured,
   full-text, vector, graph, temporal, and permission-aware recall.
5. Add review/supersession policies for stale, contradicted, and replaced
   Facts/Memory Objects.
6. Make connector governance the default runtime path for connector sync.
7. Add benchmark/evaluation records so large-scale recall tests are stored and
   inspectable.
8. Add recovery/rebuild services for summaries, indexes, workflows, and derived
   projections.

The system is meant to stay complex where complexity carries meaning: evidence,
ownership, validity, permissions, workflow, and audit. It should stay simple where
complexity only creates extra steps.
