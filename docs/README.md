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

2. [Roadmap](ROADMAP.md)  
   Backend-first build gates, layer guide, diagrams, and what each part is used
   for.

3. [Engine structure](architecture/ENGINE-STRUCTURE.md)  
   The clean system map: organization, workspace, nodes, layers, stores,
   projections, agents, and loops.

4. [Storage and projection map](architecture/STORAGE-AND-PROJECTION-MAP.md)  
   Which substrate stores what, which layer owns meaning, and which surfaces
   display/control the state.

5. [Agent and CLI SOP](guides/agent-cli-sop.md)  
   How a human, Codex, Claude Code, an MCP client, a script, or an app should
   operate the system without bypassing governance.

6. [Build goal alignment](reference/build-goal-alignment.md)  
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

```text
Workspace
  -> Project Node
  -> Person Node
  -> Product Node
  -> Operational Node
  -> Context Node
  -> Learning Node
```

The runtime is organized by lifecycle ownership:

```text
Workspace / Topology     owns the shape of the user's world.
Source Intake            preserves evidence before interpretation.
Signal Pipeline          classifies and parses inputs.
Memory Core              owns Claims, Facts, Memories, edges, and lineage.
Retrieval / Context      assembles governed context packages.
Active Memory Pools      hold task-scoped working state.
Workflow / Skill Runtime turns repeated work into reusable procedures.
Tool / Model Governance  controls external actions and model/tool calls.
Wiki / Export            projects state to markdown, HTML, reports, and apps.
Evaluation / Recovery    proves behavior and rebuilds derived artifacts.
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

## User And Agent Flow

```text
Human creates or initiates workspace
  -> engine creates workspace topology
  -> user/agent adds messy sources
  -> engine preserves evidence
  -> signal layer classifies input
  -> memory layer extracts Claims
  -> review/policy promotes Facts
  -> retrieval builds Context Packages
  -> human/agent works inside Active Memory Pool
  -> observations re-enter as pending Claims
  -> repeated work becomes Workflows and Skill Packages
  -> export layer renders markdown/wiki/app/API views
```

## Canonical Docs

### Use And Operation

- [Roadmap](ROADMAP.md)
- [Getting started](guides/getting-started.md)
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
