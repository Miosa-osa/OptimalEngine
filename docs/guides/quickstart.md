# Quickstart: The Engine On Its Own

This guide runs one Optimal Engine, mints a key, creates a workspace, stores a source, retrieves it with citations, and calls the same Engine from the `optimal` client CLI.
It needs no other product, no hosted account, and no network service beyond the machine you run it on.
Every example uses generic names; replace them with your own.

You will end with:

```text
a running Engine on http://127.0.0.1:4200
an API key that the Engine uses to identify and scope every request
a workspace with one stored source
a search result and a cited read of that source
```

## 1. Run the Engine

### Option A: from a checkout

Requirements: Erlang/OTP 26 or newer, Elixir `~> 1.17`, git, a C toolchain for the SQLite NIF, and Snappy when you want the RocksDB knowledge backend.

```bash
git clone https://github.com/Miosa-osa/OptimalEngine.git
cd OptimalEngine
mix deps.get
```

Mint the first key before the server starts, so the key is written to the store the server will open.
The token is printed once; store it in a secret manager or an environment variable.

```bash
mix optimal.auth mint --name "root" --workspace '*'
```

Start the Engine with the API enabled:

```bash
OPTIMAL_API_ENABLED=true OPTIMAL_AUTH_REQUIRED=true mix run --no-halt
```

Paths default to `.optimal/` beside the checkout: the SQLite store at `.optimal/index.db`, the cache at `.optimal/cache`, and workspace files under `.optimal/workspaces`.
Set `OPTIMAL_ENGINE_ROOT`, `OPTIMAL_ENGINE_DB`, `OPTIMAL_ENGINE_CACHE`, and `OPTIMAL_API_PORT` to move them, which is what a packaged or container deployment does.
See [installation and deployment](installation-and-deployment.md) for the full profile table.

### Option B: from the release image

Docker is optional.
The image builds a `mix release` on Elixir 1.19.5 and OTP 28, runs as a non-root user, keeps `/data` as the only writable volume, and takes every secret from the environment.

```bash
docker build -f deploy/Dockerfile.engine \
  --build-arg OPTIMAL_RELEASE_CHANNEL=stable \
  -t optimal-engine:quickstart .
```

Mint the first key in a one-off container that opens the same volume with the API disabled, so nothing is listening while it works:

```bash
docker run --rm -v optimal-data:/data -e OPTIMAL_API_ENABLED=false optimal-engine:quickstart \
  /app/bin/optimal eval \
  'OptimalEngine.Auth.ApiKey.mint(%{tenant_id: "default", name: "root", scopes: ["*"], workspace_scope: ["*"]}) |> IO.inspect()'
```

Start the Engine.
`OPTIMAL_ENGINE_API_KEY` is the key from the step above, and the container health check uses it to probe the authenticated `/api/health` route.

```bash
docker run -d --name optimal-engine -p 4200:4200 \
  -v optimal-data:/data \
  -e OPTIMAL_AUTH_REQUIRED=true \
  -e OPTIMAL_AUTHORITY_KEY="$(openssl rand -hex 32)" \
  -e CONNECTOR_KEY="$(openssl rand -hex 32)" \
  -e OPTIMAL_ENGINE_API_KEY=<the key> \
  optimal-engine:quickstart
```

The data volume holds the store, so stopping, removing, or replacing the container keeps your workspace.

## 2. Point The Client At The Engine

`optimal` is the client CLI at [apps/cli/optimal](../../apps/cli/optimal), and `oe` is the same program under another name.
It needs only `sh`, `curl`, and `awk`, so it runs anywhere the Engine does.
It never prints the key and never puts it in a process list.

```bash
export OPTIMAL_ENGINE_URL=http://127.0.0.1:4200
export OPTIMAL_ENGINE_API_KEY=<the key>
apps/cli/optimal --version
apps/cli/optimal doctor
```

`doctor` reports where each setting came from and whether the Engine answers.
A profile file at `~/.config/optimal/profile` holds the same three settings for later sessions; see the [client CLI and MCP guide](cli.md).

## 3. Create A Workspace

A workspace is one walled section of the Engine: its own nodes, signals, memories, loops, and rhythm.

```bash
apps/cli/optimal api POST /api/workspaces '{"slug":"personal","name":"Personal Brain"}'
apps/cli/optimal workspaces
```

Every API route is also reachable as `optimal api <METHOD> <path> <json>`, so the CLI never blocks a workflow the HTTP API supports.

## 4. Store A Source

Ingest keeps the source text and the structured signal the Engine derived from it.

```bash
apps/cli/optimal capture "Renewal call with the supplier moved to the 14th; the contract review is still open." personal --title "Supplier renewal call"
```

The response reports the signal id, the genre and type the Engine read, and the entities it found.
Nothing becomes durable workspace truth until it is reviewed; a claim the Engine proposes stays pending until someone with the review grant approves or rejects it.

## 5. Retrieve With Citations

```bash
apps/cli/optimal search "supplier renewal" personal
apps/cli/optimal ask "what is open with the supplier?" personal
apps/cli/optimal assemble "supplier renewal" personal
```

`search` returns matching memories and signals with their identifiers.
`assemble` returns a tiered context package with its sources, which is what an agent should read before answering.
`read` opens one item by its `optimal://` URI.

```bash
apps/cli/optimal read "optimal://personal/<the uri from search>"
```

## 6. Confirm What You Are Running

```bash
apps/cli/optimal version
apps/cli/optimal status
mix optimal.conformance --url http://127.0.0.1:4200 --key "$OPTIMAL_ENGINE_API_KEY"
```

`version` prints the release identity the running Engine reports: application version, release channel, git commit, build time, API version, and expected migration.
`mix optimal.conformance` runs the conformance suite against a live Engine and prints a JSON report with pass, fail, or skip plus the evidence per check.
It checks the release contract, that authentication is enforced, that a workspace-scoped key cannot read another workspace, a decision and the evidence chain, every store family, replication status, the viability report, and the operating routes.
It creates its own workspaces and key, cleans them up, and exits non-zero on any failure, so it can gate a release.
See [release identity](versioning-and-releases.md) for the identity it compares against.

## Where To Go Next

| Goal | Read |
| --- | --- |
| Every client command | [Client CLI and MCP server](cli.md) |
| A first real workspace, end to end | [First workspace story](first-workspace-story.md) |
| Agent loops over the operating routes | [Operating layer](operating-layer.md) |
| The protocol an agent follows | [Agent CLI SOP](agent-cli-sop.md) |
| Native engine tasks and stores | [Mix tasks](mix-tasks.md) |
| Deployment profiles, TLS, backups | [Installation and deployment](installation-and-deployment.md) |
| What each store owns and where the data lives | [Store and layer reality](store-and-layer-reality.md) |
| Releases, channels, upgrades | [Versioning and releases](versioning-and-releases.md) |

The Engine is a data layer with several interfaces, so the same workspace can be read by the CLI, the HTTP API, the MCP server, an app, or the desktop surface.
Nothing in this guide depends on another product being installed.
