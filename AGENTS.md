# Optimal Engine Agent Boot

This file is the boot contract for agents working in this repo.
Read it before changing code, running the engine, or touching runtime data.
Read `OPINIONS.md` before making setup, store, memory, API, CLI, or architecture decisions.
Read `~/OPINIONS.md` when the task touches Roberto's broader technical or product viewpoints.

## Canonical Repo

Use this repo as the engine source of truth:

```text
OptimalEngine
```

Do not assume an embedded copy inside another app is newer.
Check `git status`, branch, remotes, and the running process before making changes.

## Local Boot

Use the standard local path:

```bash
brew install snappy
make install
make bootstrap
make dev
```

`make dev` starts the HTTP engine at `http://localhost:4200`.
It runs `scripts/run-engine.sh`.
The launcher creates `.optimal/connector_key` if `CONNECTOR_KEY` is not already set.
It starts the knowledge graph with RocksDB by default when the `rocksdb` NIF is available.
Override with `OPTIMAL_KNOWLEDGE_BACKEND=ets` or `OPTIMAL_KNOWLEDGE_BACKEND=mnesia` when intentionally testing another backend.

Verify:

```bash
curl http://localhost:4200/api/health
mix optimal.reality_check
```

If another engine is already using port `4200`, do not kill it unless the user asked you to.
Check which process owns the port and which checkout it is running from.

## Runtime Data Boundary

Local runtime state lives under:

```text
.optimal/index.db
.optimal/index.db-wal
.optimal/index.db-shm
.optimal/cache/
.optimal/connector_key
.optimal/knowledge-rocksdb/
.optimal/workspaces/
```

These files are local machine state.
They are ignored by git.
Do not commit them.
Do not copy private data, connector keys, imported workspace data, or generated local stores into docs, Source Packages, Context Packages, prompts, commits, or issues.

The repo should contain code, docs, schemas, setup scripts, examples, and public sample fixtures only.
Each clone creates its own local store when it boots.

## Store Model

Use these terms precisely:

| Store | Role |
| --- | --- |
| SQLite | Local canonical runtime store today. |
| Postgres | Production canonical runtime target. |
| Raw artifact storage | Preserved files, uploads, attachments, and media evidence. |
| FTS, vector, chunk, cache rows | Rebuildable retrieval and acceleration projections. |
| RocksDB | Default local persistent knowledge graph backend when installed. |
| ETS | In-memory fallback knowledge graph backend. |
| Mnesia | Optional distributed knowledge graph backend. |
| Markdown, wiki, HTML, API, app views | Projection and control surfaces. |

One physical store can hold many layer-owned records.
Do not confuse physical storage with domain ownership.

## Layer Flow

Use this flow when explaining or debugging the engine:

```text
Raw inputs
  -> ingestion
  -> SQLite canonical store
  -> RocksDB graph runtime plus retrieval projections
  -> search, graph, and RAG
  -> API, CLI, wiki, and app surfaces
```

SQLite is the durable local truth.
RocksDB is the default persistent local knowledge graph backend when installed.
Chunks, vectors, FTS rows, and caches are retrieval material or rebuildable projections.
RAG is an answer path across retrieved context, not a database and not the source of truth.
BusinessOS is an app surface.
It must call Optimal Engine with explicit tenant, organization, and workspace scope.

## Workspace And Tenant Isolation

Every read and write must respect tenant, organization, workspace, Node, and policy scope.
Never test cross-workspace behavior by sharing private data between workspaces.
Use explicit workspace IDs in API calls and tests.
Ambiguous names should trigger clarification or scoped lookup, not silent writes.

## Agent Operating Rules

Start every session with:

```bash
git status --short --branch
curl http://localhost:4200/api/health
```

If this engine is being used from Roberto's private OptimalOS checkout, prefer the parent wrapper for operating tasks:

```bash
/Users/rhl/code/OptimalOS/.system/oe boot
/Users/rhl/code/OptimalOS/.system/oe health
/Users/rhl/code/OptimalOS/.system/oe find "query" <workspace>
/Users/rhl/code/OptimalOS/.system/oe aware "important correction" <workspace>
/Users/rhl/code/OptimalOS/.system/oe close "what changed and how verified" <workspace>
```

Use direct `mix optimal.*` commands only when developing or debugging the engine itself.
Use the wrapper for agent memory, Roberto context, workspace retrieval, and BusinessOS integration checks.

Then inspect the relevant workspace:

```bash
mix optimal.topology --workspace default:my-workspace
mix optimal.search "current state"
mix optimal.rag "what context should I know?"
```

Agents may preserve evidence, create pending Claims, assemble Context Packages, and render projections.
Agents should not directly write final Facts or rewrite topology without review or an explicit user request.

Use registered tools, connector grants, partition policy, and audit paths for external actions.
Do not build a side memory system outside Optimal Engine.

## Agent Docs In Parent Products

BusinessOS, OptimalOS, and other apps that embed or connect to this engine must include agent instructions that explain:

- BusinessOS owns app state, UI state, users, sessions, workspace records, and operational records.
- Optimal Engine owns knowledge, memory, source packages, claims, facts, retrieval, graph, RAG, and context packages.
- Every read and write must include explicit tenant, organization, and workspace scope.
- Downloaded users use their own local bundled engine and must not read Roberto's private engine data.
- Roberto's private agents use `/Users/rhl/code/OptimalOS/.system/oe` for Roberto/MIOSA/BusinessOS context.
- Agents should run boot/search/capture/aware/close loops instead of treating memory as optional.

## Verification Before Push

For setup or backend changes, run:

```bash
bash -n scripts/run-engine.sh
mix compile
mix optimal.reality_check
```

If the live engine already owns port `4200`, either verify against the live engine or run checks in a clean environment.
Do not stop a live user session without permission.

For docs-only changes, still run:

```bash
git diff --check
bash -n scripts/run-engine.sh
```

## Related Docs

Read these when changing setup, stores, agents, or deployment:

```text
docs/guides/getting-started.md
docs/guides/installation-and-deployment.md
docs/guides/store-and-layer-reality.md
docs/guides/agent-cli-sop.md
docs/architecture/STORAGE-AND-PROJECTION-MAP.md
docs/reference/backend-readiness.md
skills/optimal-engine/README.md
```
