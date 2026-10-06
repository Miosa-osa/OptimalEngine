# Optimal Engine System Map

Optimal Engine is a scoped memory and retrieval runtime.
It turns raw inputs into governed context that humans, agents, APIs, and apps can use.

## Core Flow

```text
Raw inputs
  -> Source Packages
  -> Signals
  -> Claims
  -> Review and policy
  -> Facts
  -> Memory Objects
  -> Retrieval and Context Packages
  -> Agent or app action
  -> Observations
  -> new Claims
```

## Ownership

| Layer | Owns |
| --- | --- |
| Topology | Tenants, organizations, workspaces, Nodes, relationships, aliases, and policies. |
| Intake | Raw source preservation, source metadata, and evidence boundaries. |
| Signal | Mode, genre, type, format, structure, routing, and classification. |
| Memory Core | Claims, Facts, Memory Objects, provenance, lifecycle, and active pools. |
| Retrieval | Search, graph recall, context assembly, ranking, and token budgets. |
| Workflow and Skill | Repeatable procedures, tool traces, skill packages, and run records. |
| Governance | Tool grants, API keys, policy checks, audit, and fail-closed access. |
| Export | Markdown, wiki, HTML, APIs, app views, and other projections. |

## Store Model

SQLite is the local durable store today.
Postgres is the production durable target.
RocksDB is the default local persistent graph backend when installed.
ETS and Mnesia are alternate graph backends.
Vectors, chunks, FTS rows, and caches are projections.
The live logical-store catalog is available through `GET /api/stores`.
Use `GET /api/stores/audit` to verify SQLite integrity, foreign keys, migrations, FTS parity, workspace isolation, vector validity, asset cataloging, verified backups, RLM readiness, and cache readiness.
The audit endpoint returns HTTP `503` when any required check fails.

Do not call RAG a store.
RAG is a retrieval and answer path over scoped context.

## Isolation Rule

Every read and write must carry explicit scope:

```text
tenant
organization
workspace
Node
policy
principal
```

Applications must supply the intended scope and resolve ambiguity before writing.
Authenticated HTTP tenant identity is derived from the key, and conflicting tenant parameters are rejected.
Workspace authorization and operation grants are separate checks; some legacy endpoints still default to the `default` workspace.
This is a design obligation with compatibility defaults, not a claim that every missing scope field is rejected.
Never intentionally share one workspace's records with another.

## Enforced HTTP Trust Boundary

`PermissionPlug` enforces operation grants after authentication and workspace checks.
Ordinary writes cannot grant themselves Claim review, topology mutation, or API-key administration.
Claim reviewers are bound to authenticated credentials; persisted evidence and lifecycle checks remain in Memory Core.
See [API grants and migration](docs/guides/interfaces-and-publishing.md#api-grants-and-identity) for exact scope names and endpoint groups.
Trusted anonymous local mode and wildcard keys remain privileged; direct Elixir and database access are outside HTTP authorization.
See [control-plane evidence](docs/guides/agent-control-plane.md) for tests and limits rather than treating this system map as exploit proof.

## BusinessOS Boundary

BusinessOS is an app surface and operational system.
It owns desktop state, windows, modules, roles, users, sessions, and operational records.

Optimal Engine is the knowledge and memory system.
It owns evidence, retrieval, graph, RAG, claims, facts, memories, context packages, and source packages.
