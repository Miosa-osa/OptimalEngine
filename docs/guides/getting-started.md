# Getting Started

This guide takes a new user from clone to a working Optimal Engine workspace.

The first workflow is intentionally simple:

```text
install
  -> run reality check
  -> initiate or set up workspace
  -> inspect topology
  -> ingest/search/render
  -> use the workspace from CLI, agent, app, or markdown
```

## 1. Prerequisites

Required:

- Erlang/OTP 26+
- Elixir `~> 1.17`
- Git
- C toolchain for the SQLite NIF

Optional:

- Node 20+ for app/site/extension surfaces
- Ollama for local embeddings and generation
- Docker for packaged service deployment
- RocksDB runtime if you want the optional RocksDB graph/knowledge backend

RocksDB is not required for the default local engine. SQLite is the local
canonical runtime store today.

## 2. Clone And Compile

```bash
git clone https://github.com/Miosa-osa/OptimalEngine.git
cd OptimalEngine
mix deps.get
mix compile
```

## 3. Run The Reality Check

```bash
mix optimal.reality_check
```

Expected current result:

```text
126 probes, 126 ok, 0 warn, 0 fail
```

This checks the runtime spine: store, topology, source evidence, memory,
retrieval, pools, workflows, tools, connectors, evaluation, wiki, compliance,
and retrieval edge cases.

## 4. Choose A Workspace Setup Path

Use initiation when the user starts with a messy dump:

```bash
mix optimal.initiate my-workspace --name "My Workspace" --dump setup.md
```

Use setup when the user already knows the initial structure:

```bash
mix optimal.setup my-workspace --name "My Workspace"
```

Add explicit Nodes:

```bash
mix optimal.setup my-workspace \
  --node project:launch-plan:"Launch Plan" \
  --node person:founder:"Founder" \
  --node operational:weekly-review:"Weekly Review"
```

## 5. Understand What Was Created

The hierarchy is:

```text
Tenant / Organization
  -> Workspace
    -> Node graph
```

Projects are Nodes inside a Workspace:

```text
Workspace
  -> Project Node
  -> Person Node
  -> Product Node
  -> Operational Node
  -> Context Node
  -> Learning Node
```

Inspect topology:

```bash
mix optimal.topology --workspace default:my-workspace
```

## 6. Know Where Data Lives

Local default runtime state:

```text
.optimal/index.db
.optimal/cache/
```

Workspace projection files:

```text
my-workspace/
  AGENTS.md
  rhythm/
  nodes/
```

Important distinction:

```text
SQLite/Postgres = canonical runtime state
raw artifacts   = preserved source evidence
indexes/caches  = rebuildable acceleration
markdown/wiki   = projection and editing surface
```

See [Storage and projection map](../architecture/STORAGE-AND-PROJECTION-MAP.md)
for the full storage map.

## 7. Ingest Or Search

Ingest a quick text Signal:

```bash
mix optimal.ingest "Customer asked about pricing and wants a follow-up" --genre note
```

Search:

```bash
mix optimal.search "pricing"
```

Ask:

```bash
mix optimal.rag "what changed this week?"
```

## 8. Render Human-Facing Projections

Render a workspace tree:

```bash
mix optimal.wiki render-tree --workspace default:my-workspace
```

Render a Node page:

```bash
mix optimal.wiki render-node first-project --workspace default:my-workspace
```

Check a page:

```bash
mix optimal.wiki check node-first-project --workspace default:my-workspace
```

## 9. Use With Agents

For Codex, Claude Code, MCP clients, scripts, or app agents, use this sequence:

```text
inspect topology
  -> retrieve governed context
  -> work inside task scope
  -> use registered tools
  -> record observations
  -> create pending Claims
  -> let review/policy promote Facts
  -> render projections from engine state
```

Read [Agent and CLI SOP](agent-cli-sop.md) before wiring agents to tools,
connectors, scripts, or APIs.

## 10. What To Read Next

- [Engine structure](../architecture/ENGINE-STRUCTURE.md)
- [Storage and projection map](../architecture/STORAGE-AND-PROJECTION-MAP.md)
- [Agent and CLI SOP](agent-cli-sop.md)
- [Mix tasks](mix-tasks.md)
- [Build goal alignment](../reference/build-goal-alignment.md)

