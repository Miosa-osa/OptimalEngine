# Optimal Engine Docs

This documentation explains the backend runtime, not a standalone frontend.
External apps, CLIs, MCP servers, scripts, and agents can all use the same
engine state.

## Start Here

1. [Getting Started](../GETTING_STARTED.md) — install, verify, create a
   workspace, and run the CLI.
2. [Roadmap](../PLAN.md) — build gates and what is complete versus still
   hardening.
3. [Sample Workspace](../sample-workspace/README.md) — current filesystem
   projection shape.
4. [Deployment](../deploy/README.md) — optional Docker/backend service setup.

## Core Architecture

| Doc | Purpose |
| --- | --- |
| [Architecture](architecture/ARCHITECTURE.md) | Runtime overview and subsystem map. |
| [Full System Architecture](architecture/FULL-SYSTEM-ARCHITECTURE.md) | End-to-end architecture notes. |
| [Data Architecture](architecture/DATA_ARCHITECTURE.md) | Storage roles and data lifecycle. |
| [Data Anatomy and Multimodality](architecture/DATA-ANATOMY-AND-MULTIMODALITY.md) | How text, files, images, audio, video, and structured records enter the system. |
| [Layer Ownership and Data Flow](architecture/LAYER-OWNERSHIP-AND-DATA-FLOW.md) | Which layer owns which lifecycle and tables. |
| [Node Ontology](architecture/NODE-ONTOLOGY.md) | What a Node is, how projects fit, and how topology works. |
| [Memory Core Codebase Fit](architecture/MEMORY-CORE-CODEBASE-FIT.md) | How new governed memory code fits around legacy Store/Context modules. |

## Concepts

| Doc | Purpose |
| --- | --- |
| [Signal Theory](concepts/signal-theory.md) | Mode, Genre, Type, Format, and Structure classification. |
| [Methodology](concepts/methodology.md) | How humans and agents operate the system over time. |
| [Failure Modes](concepts/failure-modes.md) | What the engine should prevent. |
| [Kernel Vocabulary](concepts/kernel.yaml) | Stable vocabulary primitives. |

## Guides

| Doc | Purpose |
| --- | --- |
| [Mix Tasks](guides/mix-tasks.md) | CLI and Mix task reference. |
| [Writing Guide](guides/writing-guide.md) | How to write engine-friendly markdown and Signals. |

## Backend Layers

```text
Workspace / Topology
  -> Signal Pipeline
  -> Memory Core
  -> Retrieval / Context
  -> Active Memory Pools
  -> Workflow / Skill Runtime
  -> Tool / Model Governance
  -> Workspace Export / Wiki
  -> Audit / Governance
```

The physical store can be one database. Ownership is still separated by layer.
