# Optimal Engine

[![Elixir](https://img.shields.io/badge/Elixir-1.17-4B275F)](https://elixir-lang.org/)
[![Runtime](https://img.shields.io/badge/runtime-self--hosted-blue)](#storage-and-deployment)
[![Database](https://img.shields.io/badge/database-SQLite%20now%20%7C%20Postgres%20target-0f766e)](#storage-and-deployment)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Optimal Engine is a self-hosted second brain for a company, team, or operator.

It is the runtime behind a markdown-operable workspace: typed Nodes, operating
rhythm, source-backed memory, retrieval, workflows, skills, tool/model
governance, and interfaces for humans and AI agents.

The engine is not only a note app, a RAG app, or an agent task runner. It is the
system that lets a human or organization define its world, preserve evidence,
classify Signals, promote reviewed truth, assemble context, run agents/tools,
and project the same state into markdown, APIs, dashboards, HTML, reports, and
agent runtimes.

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

## Status Cards

| Card | Status | What it means |
| --- | --- | --- |
| Company second brain | Active | The product framing is still a governed brain for a company, team, or operator. |
| Markdown workspace | Active | Files and folders remain a human/agent control surface. They are projections, not the only truth. |
| Workspace topology | Built | Workspaces, project-as-Node modeling, node types, node relationships, memberships, and projection records exist. |
| Signal pipeline | Built | Parse, decompose, classify, embed, route, store, cluster, and wiki tasks/modules exist, with text path strongest today. |
| Memory Core | Built | Source Packages, Claims, Facts, Memory Objects, Relationship Edges, Derivation Ledger, Context Packages, and Active Pools exist in the schema and tests. |
| Retrieval | Built, expanding | Wiki-first RAG, hybrid search, grep, tiered assembly, governed Context Packages, and receiver formatting exist. Full graph/vector/temporal coordinator expansion is ongoing. |
| Rhythm | Partly built | Rhythm is represented through Nodes, focus/review state, signals, active pools, and workspace projections. A dedicated rhythm service is still a build target. |
| Workflow and skills | Built spine | Workflow Trace, Generalized Workflow, Procedural Memory Object, Skill Package, and derivation records exist. Runtime execution is still expanding. |
| Tool/model governance | Built spine | Tool/model definitions, run records, permission checks, output validation, audit links, and dispatcher adapter coverage exist. |
| Multimodality | Partly built | Text/code/document paths are strongest. Image/audio/video parsers and processors exist, but depend on external tools/models and need deeper test coverage. |
| Benchmarks | Built spine | Benchmark/evaluation records and scripts exist, but large-scale public benchmark numbers should be treated as active evaluation work. |

## Core Concepts

These concepts are all still part of Optimal Engine. The newer Memory Core work
does not remove them; it gives them stricter storage and lifecycle boundaries.

| Concept | Meaning |
| --- | --- |
| Tiers | Where knowledge lives: raw sources, rebuildable derivatives, curated/wiki/interface memory. |
| Layers | Who owns lifecycle decisions: Topology, Signal, Memory Core, Retrieval, Active Pools, Workflow/Skill, Tool/Model Governance, Export, Audit. |
| Stages | How ingestion processes data: intake, parse, decompose, classify, embed, route, store, cluster, curate. |
| Rhythm | How humans operate the workspace over time: daily focus, weekly review, blockers, decisions, handoffs, follow-ups. |
| Gates | Checkpoints that prevent raw evidence, interpretation, accepted truth, and agent action from being mixed together. |
| Nodes | Governed topology objects. A folder can be an export of a Node, but a Node is not just a folder. |
| Wiki / curated memory | The human and agent front door, backed by citations and governed state. |

## Tiers

```text
Tier 1: Raw Sources
  Append-only source material, signal files, imported artifacts, tool outputs.

Tier 2: Rebuildable Derivatives
  Parsed text, chunks, embeddings, classifications, indexes, graph edges,
  clusters, summaries, compatibility context rows.

Tier 3: Curated / Wiki / Interface Memory
  Audience-aware wiki pages, node context projections, dashboards, HTML,
  reports, and agent-ready context surfaces.
```

The Memory Core lifecycle now makes truth handling stricter inside those tiers:

```text
Source Package -> Claim -> Fact -> Memory Object
```

A wiki page, context package, or generated report should cite accepted objects
and source evidence. It should not become unsupported truth by itself.

## Layers

Optimal Engine is organized by lifecycle ownership, not just where bytes are
stored.

| Layer | Owns |
| --- | --- |
| Workspace / Topology | Workspaces, Nodes, Node Types, relationships, membership, policies, projection scope. |
| Signal Pipeline | Classification, quality, routing hints, compatibility context rows. |
| Memory Core | Source Packages, Claims, Facts, Memory Objects, Relationship Edges, Derivation Ledger. |
| Retrieval / Context | Recall planning, Context Packages, authorization envelope, retrieval audit. |
| Active Collaboration | Active Memory Pools, task observations, pending Claims, refresh state. |
| Workflow / Skill Runtime | Workflow Traces, Generalized Workflows, procedures, Skill Packages, execution records. |
| Model / Tool Governance | Model operations, tool definitions, schema validation, permission checks, run records, audit. |
| Workspace Export / Wiki Surface | Markdown, HTML, app views, reports, packages, projection records. |
| Audit / Governance | Policy decisions, lineage, validation, access records, rebuild proof. |

One physical database can hold many layer-owned tables. The rule is that each
table has an owning layer, and other layers write through that owner instead of
directly inventing lifecycle state.

## Stages

The full ingestion contract is:

```text
1. Intake
2. Parse
3. Decompose
4. Classify
5. Embed
6. Route
7. Store
8. Cluster
9. Curate
```

Not every input currently exercises every stage. Some inputs stop early. Some
modalities are less complete than text. The invariant is that no input should
be promoted into accepted memory without scope, evidence, classification,
review/policy, and audit.

## Gates

| Gate | Question |
| --- | --- |
| Scope Gate | Who is acting, which workspace/node is in scope, and which policy applies? |
| Evidence Gate | Has the raw source been preserved or quarantined before interpretation? |
| Signal Gate | What kind of Signal is this: mode, genre, type, format, structure? |
| Routing Gate | Where does the Signal belong in the workspace topology? |
| Claim Gate | What does the source assert, and with what confidence/precision? |
| Fact Gate | What is accepted as true, valid when, and supported by which evidence? |
| Retrieval Gate | What is this actor allowed to receive now? |
| Action Gate | What is an agent, model, or tool allowed to do? |
| Promotion Gate | Which observations become durable Claims, Facts, Memories, Workflows, or Skills? |
| Projection Gate | Which markdown, HTML, app, or report view can be generated or edited? |

## Node Model

A Node is a governed topology object inside a Workspace.

Common Node types:

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

Projects are Nodes inside a Workspace. They are not a peer of the Workspace.

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

The folder is an export or editing surface. The Node identity, lifecycle,
relationships, permissions, and routing behavior belong to the engine.

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

Install and verify:

```bash
mix deps.get
mix compile
mix optimal.reality_check
```

Scaffold a markdown-operable workspace:

```bash
mix optimal.init ~/my-workspace
mix optimal.ingest_workspace ~/my-workspace
mix optimal.rag "what changed this week?" --trace
```

Useful commands:

```bash
mix optimal.reality_check
mix optimal.search "project"
mix optimal.rag "what changed this week?"
mix optimal.wiki list
mix optimal.topology
```

Start the API when enabled in config:

```bash
mix optimal.api
```

## Storage And Deployment

Local development uses SQLite:

```text
.optimal/index.db
```

Docker is optional. You do not need Docker to run the local engine. Use Docker
when you want a packaged service stack or deployment-style environment.

Target production storage can move to Postgres while keeping the same ownership
model:

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
| `contexts`, `chunks`, `classifications`, `intents`, search projections | Signal/Search compatibility |
| `source_packages`, `claims`, `facts`, `memory_objects`, `relationship_edges`, `derivation_ledger` | Memory Core |
| `context_packages`, retrieval audit | Retrieval / Context |
| `active_memory_pools`, pool observations | Active Collaboration |
| `workflow_traces`, `generalized_workflows`, `procedural_memory_objects`, `skill_packages` | Workflow / Skill Runtime |
| `model_call_operations`, `mcp_tool_definitions`, call runs | Model / Tool Governance |
| `wiki_pages`, `citations`, `export_records`, projection revisions, generated files | Wiki / Workspace Export |

## Multimodality

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

Every input family should enter through the same evidence lifecycle:

```text
external source or local edit
  -> Source Package
  -> Signal classification
  -> Memory Core / Retrieval / Workflow as appropriate
```

Text is the most complete path today. Image, audio, and video support exists in
the parser/processor architecture and should be treated as active build surface
until deeper end-to-end tests are added.

## Verification

Current focused verification:

```bash
mix test test/memory_core/spine_test.exs \
  test/workspace_export_test.exs \
  test/topology/workspace_topology_test.exs \
  test/topology/node_member_test.exs \
  test/topology/node_test.exs \
  test/topology/workspace_surface_spine_test.exs \
  test/signal/dispatcher_test.exs \
  --seed 0

mix optimal.reality_check
```

Latest local reality check:

```text
104 probes, 104 ok, 0 warn, 0 fail
```

Existing compile warnings remain around optional/legacy integrations, especially
RocksDB and transitional bridge modules. They are not ignored; they are separate
cleanup work from the README/license production pass.

## Development Rules

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

1. Harden Workspace/Topology as the first gate for every project, node, member,
   relationship, and projection edit.
2. Add a first-class workspace setup task that creates a workspace, starter
   Nodes, rhythm structure, and agent SOP in one command.
3. Expand Source Package support for richer multimodal source metadata.
4. Add review queues for Claims and Fact promotion.
5. Expand Retrieval Coordinator beyond simple fact/memory lookup into structured,
   full-text, vector, graph, temporal, and permission-aware recall.
6. Build workflow traces and Skill Packages from repeated Active Pool work.
7. Expand governed tool/model execution from the first dispatcher adapter into
   connector-wide and model-provider-wide runtime paths.
8. Add benchmark/evaluation records so large-scale recall tests are stored and
   inspectable.

The system is meant to stay complex where complexity carries meaning: evidence,
ownership, validity, permissions, workflow, and audit. It should stay simple
where complexity only creates extra steps.

## License

Optimal Engine is released under the MIT License. See [LICENSE](LICENSE).
