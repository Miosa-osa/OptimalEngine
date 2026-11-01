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

One Engine instance is the default data layer: one process on one durable disk that holds every store inside it.
SQLite is the durable store, with FTS5 and vectors in the same file.
Assets and objects are files, caches are ETS and files, jobs and the change ledger are SQLite tables, and backups and sealed connector keys are part of the same instance.
The Engine does not run Postgres, Qdrant, or Redis inside; it embeds its own equivalents.
The graph that search, assembly, and materialization read is the SQLite `graph_edges` table.
The triple store (ETS or RocksDB) is a mirror rebuilt from it, and no retrieval path reads it.
The mirror is ETS, in memory, under bare `mix`, in tests, in the Docker image, and in the MIOSA template and managed Engines, because none of them sets `OPTIMAL_KNOWLEDGE_BACKEND`.
`scripts/run-engine.sh` defaults it to RocksDB, and `OPTIMAL_KNOWLEDGE_BACKEND=rocksdb` with `OPTIMAL_KNOWLEDGE_ROCKSDB_PATH` selects it anywhere.
Mnesia is an experiment with `ram_copies` tables, and Riak is in no build.
Providers are things a deployment grows onto: S3-compatible storage is wired for assets and offsite backups, and Postgres is an optional, partial provider for scale (a compile-time `OPTIMAL_STORE=postgres` build without full-text search, replication, or app data collections).
NATS JetStream, Valkey, Qdrant, DuckDB, OpenBao, and Fractal are declared with no adapter yet.
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
