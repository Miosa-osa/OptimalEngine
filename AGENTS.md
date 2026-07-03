# Optimal Engine Agent Boot

This file is the boot contract for agents working in this repo.
Read it before changing code, running the engine, or touching runtime data.

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
make install
make bootstrap
make dev
```

`make dev` starts the HTTP engine at `http://localhost:4200`.
It runs `scripts/run-engine.sh`.
The launcher creates `.optimal/connector_key` if `CONNECTOR_KEY` is not already set.

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
| ETS, RocksDB, Mnesia, Riak style backends | Optional graph or knowledge backends, not the main product DB today. |
| Markdown, wiki, HTML, API, app views | Projection and control surfaces. |

One physical store can hold many layer-owned records.
Do not confuse physical storage with domain ownership.

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
docs/guides/agent-cli-sop.md
docs/architecture/STORAGE-AND-PROJECTION-MAP.md
docs/reference/backend-readiness.md
skills/optimal-engine/README.md
```
