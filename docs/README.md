# Optimal Engine Documentation

This is the canonical documentation path for understanding and using Optimal
Engine.

Optimal Engine is a self-hosted second brain and operating engine for human and
AI workspaces. It is not only a database, not only a markdown workspace, and not
only an agent runner. It is the runtime that connects those surfaces through
governed topology, source evidence, memory, retrieval, workflows, tools, and
projections.

## Start Here

Read these in order:

1. [Getting started](guides/getting-started.md)  
   Install, run the engine, create a workspace, initiate from a messy dump, and
   inspect the result.

2. [First workspace story](guides/first-workspace-story.md)  
   How a user brings existing markdown, company wiki pages, tools, packages,
   channels, and messy context into a self-updating workspace.

3. [Roadmap](ROADMAP.md)  
   Backend-first build gates, layer guide, diagrams, and what each part is used
   for.

4. [Engine structure](architecture/ENGINE-STRUCTURE.md)  
   The clean system map: organization, workspace, nodes, layers, stores,
   projections, agents, and loops.

5. [Storage and projection map](architecture/STORAGE-AND-PROJECTION-MAP.md)  
   Which substrate stores what, which layer owns meaning, and which surfaces
   display/control the state.

6. [Installation and deployment](guides/installation-and-deployment.md)  
   Local CLI setup, Docker, production/organization setup, store roles,
   multimodality profiles, and enterprise readiness.

7. [Signal theory](concepts/signal-theory.md)  
   How the engine breaks noisy input into Mode, Genre, Type, Format, and
   Structure before routing, extracting, packaging, or retrieving it.

8. [Workspace filesystem](guides/workspace-filesystem.md)  
   What the markdown/file projection looks like and how edits flow back into
   governed engine state.

9. [Scope switching](guides/scope-switching.md)  
   How organization, workspace, Node, and Active Memory Pool scope affect
   permissions, retrieval, routing, tools, and exports.

10. [Naming and aliases](guides/naming-and-aliases.md)  
   How user language maps to canonical engine objects without creating routing
   noise.

11. [Packages and exports](guides/packages-and-exports.md)  
   Where receiver/channel bundles live, how they differ from exports, and why
   Node-owned packages stay under Nodes.

12. [Integrations and imports](guides/integrations-and-imports.md)  
   How to inventory existing systems, connect common communication channels,
   import old context, and define recurring package types.

13. [Agent and CLI SOP](guides/agent-cli-sop.md)  
   How a human, Codex, Claude Code, an MCP client, a script, or an app should
   operate the system without bypassing governance.

14. [Tool surfaces and loops](guides/tool-surfaces-and-loops.md)  
   When to use CLI, MCP, APIs, connectors, scripts, and scheduled jobs, and how
   self-updating loops feed back into memory.

15. [Build goal alignment](reference/build-goal-alignment.md)  
   What is built now, what is only a spine, what still needs work, and which
   tests/probes prove it.

## Core Mental Model

```text
Tenant / Organization
  -> Workspaces
      -> Nodes
          -> Sources, Signals, Claims, Facts, Memories, Workflows, Skills
```

Projects are Nodes inside a Workspace. They are not peers of Workspace.

```mermaid
flowchart TB
  Org[Tenant / Organization<br/>governance and policy boundary]
  Workspace[Workspace<br/>bounded operating area]
  Project[Project Node]
  Person[Person Node]
  Product[Product Node]
  Ops[Operational Node]
  Context[Context Node]
  Learning[Learning Node]

  Org --> Workspace
  Workspace --> Project
  Workspace --> Person
  Workspace --> Product
  Workspace --> Ops
  Workspace --> Context
  Workspace --> Learning
```

The runtime is organized by lifecycle ownership:

```mermaid
flowchart TB
  Gateway[Command / Query Gateway]
  Topology[Workspace / Topology<br/>shape of the user's world]
  Intake[Source Intake<br/>preserve evidence]
  Signal[Signal Pipeline<br/>classify and parse]
  Memory[Memory Core<br/>Claims, Facts, Memories, lineage]
  Retrieval[Retrieval / Context<br/>governed context packages]
  Pools[Active Memory Pools<br/>task-scoped working state]
  Workflow[Workflow / Skill Runtime<br/>repeatable procedures]
  Governance[Tool / Model Governance<br/>external actions and calls]
  Export[Wiki / Export<br/>markdown, HTML, reports, apps]
  Eval[Evaluation / Recovery<br/>proof and rebuilds]

  Gateway --> Topology
  Gateway --> Intake
  Intake --> Signal
  Signal --> Memory
  Memory --> Retrieval
  Retrieval --> Pools
  Pools --> Workflow
  Gateway --> Governance
  Memory --> Export
  Retrieval --> Export
  Gateway --> Eval
```

## Store Vs Layer Vs Surface

Use these terms precisely:

| Term | Meaning | Examples |
| --- | --- | --- |
| Storage substrate | Where bytes or records physically live. | SQLite, Postgres, raw artifact storage, FTS/vector indexes, cache directories, optional graph backends. |
| Domain layer | The owner of lifecycle and meaning. | Topology, Memory Core, Retrieval, Workflow, Governance. |
| Projection surface | A way humans, agents, apps, or tools see/control state. | Markdown, wiki, HTML, API, MCP, desktop app, reports, agent context packages. |

The same information can appear in many surfaces, but one layer owns the
canonical lifecycle.

```mermaid
flowchart LR
  Store[(Storage substrate<br/>SQLite / Postgres / artifacts / indexes)]
  Layer[Domain layer<br/>owns meaning and lifecycle]
  Surface[Projection surface<br/>markdown / wiki / API / MCP / app]
  Edit[Human or agent edit]
  Review[Source package, topology change,<br/>observation, or pending Claim]

  Store --> Layer
  Layer --> Surface
  Surface --> Edit
  Edit --> Review
  Review --> Layer
```

## Current Default Stores

| Store | Current role |
| --- | --- |
| SQLite | Local canonical runtime store today. |
| Postgres | Target production canonical runtime store. |
| Raw artifact storage | Preserved files, uploads, attachments, and media evidence. |
| FTS/vector/chunk indexes | Rebuildable retrieval projections. |
| Cache directories | Rebuildable parse, embedding, and runtime acceleration. |
| ETS/RocksDB/Mnesia/Riak-style backends | Optional graph/knowledge backends; not the main workspace database today. |
| Markdown/files | Human-operable projection and editing surface. |
| HTML/wiki/API/app views | Projection and control surfaces. |

For install profiles, Docker guidance, hosted/local multimodal adapter options,
and enterprise readiness checks, read
[Installation and deployment](guides/installation-and-deployment.md).

## User And Agent Flow

```mermaid
flowchart LR
  Human[Human / Agent] --> Setup[Create or initiate workspace]
  Setup --> Topology[Workspace topology]
  Topology --> Source[Messy sources]
  Source --> Preserve[Preserve evidence]
  Preserve --> Classify[Classify Signal]
  Classify --> Claim[Extract Claims]
  Claim --> Fact[Review / promote Facts]
  Fact --> Context[Build Context Package]
  Context --> Pool[Work in Active Memory Pool]
  Pool --> Observation[Record observations]
  Observation --> Claim
  Pool --> Workflow[Repeated work]
  Workflow --> Skill[Workflow / Skill Package]
  Fact --> Export[Render markdown / wiki / API views]
```

Humans and AI agents use the same backend state. They use different surfaces:
markdown, CLI, API, MCP/tools, wiki/export, or an external app.

## Filesystem Projection

The recommended markdown projection looks like this:

```text
organization/
  organization.yaml
  workspaces/
    company-os/
      workspace.yaml
      AGENTS.md
      rhythm/
      nodes/
        project-platform-launch/
          node.yaml
          context.md
          signal.md
          sources/
          decisions/
          workflows/
          exports/
```

This is how people can see and operate the system directly. The database still
owns canonical identity, permissions, lineage, memory, retrieval, workflow, and
audit state.

## Scope Switching

```mermaid
flowchart TB
  Org[Organization<br/>governance, credentials, audit]
  Workspace[Workspace<br/>operating area, rhythm, routing]
  Node[Node<br/>focused context and relationships]
  Pool[Active Memory Pool<br/>temporary task state]

  Org --> Workspace
  Workspace --> Node
  Node --> Pool
```

Switch organization when ownership or policy changes. Switch workspace when the
operating context changes. Switch Node when the focus changes inside a
workspace. Open an Active Memory Pool when a bounded human/agent task starts.

## Naming Discipline

Different organizations can call the same shape different things. The engine
preserves user language as aliases while keeping canonical object types stable:

```text
node_type: project
display_label: Initiative
display_name: Q3 Partner Launch
aliases: ["launch project", "partner launch", "q3 initiative"]
```

If a loose name maps to more than one active object in the current scope, the
engine asks for clarification before writing durable state.

## Canonical Docs

### Use And Operation

- [Roadmap](ROADMAP.md)
- [Getting started](guides/getting-started.md)
- [Workspace filesystem](guides/workspace-filesystem.md)
- [Scope switching](guides/scope-switching.md)
- [Naming and aliases](guides/naming-and-aliases.md)
- [Packages and exports](guides/packages-and-exports.md)
- [Agent and CLI SOP](guides/agent-cli-sop.md)
- [Mix tasks](guides/mix-tasks.md)
- [Writing guide](guides/writing-guide.md)

### Architecture

- [Engine structure](architecture/ENGINE-STRUCTURE.md)
- [Storage and projection map](architecture/STORAGE-AND-PROJECTION-MAP.md)
- [Workspace architecture](architecture/WORKSPACE.md)
- [Wiki layer](architecture/WIKI-LAYER.md)

### Reference

- [Build goal alignment](reference/build-goal-alignment.md)
- [Data model](reference/data-model.md)
- [Component map](reference/components.md)
- [Multimodal open-source stack](reference/multimodal-open-source-stack.md)
- [Search architecture](reference/search-architecture.md)
- [Operations spec](reference/operations-spec.md)
- [Agent hooks](reference/hooks.md)
- [Session lifecycle](reference/session-lifecycle.md)
- [Node template](reference/node-template.md)
- [Vocabulary](reference/vocabulary.md)

### Concepts

- [Signal theory](concepts/signal-theory.md)
- [Failure modes](concepts/failure-modes.md)

## Documentation Rule

This docs tree is intentionally current-only. Historical strategy notes,
private examples, and comparison research do not belong in the public product
documentation path. If a document is not linked from this page, treat it as
non-canonical until it is reviewed and added here.

## Verification

The broad runtime check is:

```bash
mix optimal.reality_check
```

Current expected result:

```text
126 probes, 126 ok, 0 warn, 0 fail
```
