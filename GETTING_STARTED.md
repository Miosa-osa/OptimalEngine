# Getting Started

This is the shortest path to a working local Optimal Engine.

Optimal Engine is backend-first. You do not need Docker or a frontend to start.
The CLI, Mix tasks, HTTP API, and agent tools can all operate against the same
workspace.

## 1. Install

Requirements:

| Tool | Use |
| --- | --- |
| Elixir `~> 1.17` | Engine runtime and CLI tasks. |
| Erlang/OTP 26+ | BEAM runtime. |
| C toolchain | SQLite NIF build. |
| Node 20+ | Optional app/site/docs surfaces only. |
| `pdftotext`, `tesseract`, `ffmpeg` | Optional multimodal extraction helpers. |

macOS:

```bash
brew install elixir node ffmpeg tesseract snappy
mix deps.get
mix compile
```

## 2. Verify The Engine

```bash
bin/optimal doctor
bin/optimal health
```

For a running service, also inspect `GET /api/stores/audit`.
Do not start a second process against a live user store merely to run a diagnostic.
The fixture-writing reality check belongs in a [disposable environment](docs/guides/installation-and-deployment.md#isolated-fixture-verification).

## 3. Create A Workspace

Create the workspace topology first. This gives the engine a tenant/workspace
scope, starter Nodes, rhythm files, agent SOP, and projection records.

```bash
mix optimal.setup my-workspace --name "My Workspace"
```

The setup flow creates:

```text
Organization / tenant
  -> workspace
  -> starter Nodes
  -> node types
  -> relationships
  -> markdown projection files
  -> rhythm folders
  -> agent operating instructions
```

If you want to start from a copied filesystem template instead, use:

```bash
mix optimal.init ./my-workspace
```

Then paste messy notes, imports, transcripts, markdown, or tool outputs into the
workspace and ingest them. Intake preserves raw source first, then classifies,
routes, extracts claims, and builds searchable memory.

## 4. Use The Sample Workspace

```bash
mix optimal.ingest_workspace sample-workspace
mix optimal.search "launch blockers"
mix optimal.rag "what should I know before the weekly review?"
mix optimal.wiki render-tree --workspace sample
```

## 5. Use The Local Wrapper

The checked-in `bin/optimal` wrapper is the source-checkout surface for agents and humans:

```bash
bin/optimal status
bin/optimal setup my-workspace --name "My Workspace"
bin/optimal find "customer portal requirements" --workspace default:my-workspace
bin/optimal rag "prep me for the platform launch review" --workspace default:my-workspace
```

An agent can use regular CLI tools (`ls`, `rg`, `cat`, `git`, `curl`) and the
Optimal Engine CLI. MCP/tool servers are useful when authentication,
schema-validation, remote resources, or audit justify the extra structure.

Read [API grants and migration](docs/guides/interfaces-and-publishing.md#api-grants-and-identity) before using HTTP credentials.
Local CLI access is trusted operator access; API-key scopes do not sandbox local processes.

## 6. Storage Model

One local SQLite database is enough to start:

```text
.optimal/index.db
```

The database owns governed runtime state. Markdown files are projections and
editing surfaces.

```text
Database:
  workspaces, nodes, source packages, claims, facts, memories,
  context packages, active pools, workflows, skills, tools, audit

Markdown:
  node pages, current state, signals, packages, loops, wiki projections

Indexes/caches:
  FTS, embeddings, summaries, parser output, rebuildable acceleration
```

## 7. Optional Docker

Docker is for a packaged backend service:

```bash
cd deploy
cp env.example .env
docker compose up --build
```

The default compose stack starts only the backend engine. Optional surfaces are
behind the `surfaces` profile:

```bash
docker compose --profile surfaces up --build
```

## 8. What To Read Next

- [README.md](README.md): product and architecture overview.
- [docs/README.md](docs/README.md): docs map.
- [docs/architecture/ENGINE-STRUCTURE.md](docs/architecture/ENGINE-STRUCTURE.md):
  runtime architecture.
- [docs/architecture/STORAGE-AND-PROJECTION-MAP.md](docs/architecture/STORAGE-AND-PROJECTION-MAP.md):
  where state lives and what is only a projection.
- [sample-workspace/README.md](sample-workspace/README.md): workspace
  projection example.
