# Optimal Engine Options

This file lists the setup options that matter for users, agents, and products embedding Optimal Engine.

## Command Surface

Use the repo wrapper for normal usage:

```bash
bin/optimal <command>
```

For API-backed wrapper commands, `OPTIMAL_ENGINE_API_KEY` authenticates both the availability probe and the operation.
Reachable HTTP errors stop execution; only an unconfigured default-local probe with no HTTP response can select trusted local Mix fallback.
Native commands remain local, so this wrapper is not a remote-only client or an isolation boundary.

Use direct Mix tasks when you are developing the engine internals:

```bash
mix optimal.<task>
```

Recommended agent commands:

```bash
bin/optimal boot
bin/optimal doctor
bin/optimal find "query" --workspace default:my-workspace
bin/optimal capture "raw signal" --workspace default:my-workspace
bin/optimal aware "durable correction" --workspace default:my-workspace
bin/optimal close "what changed and how verified"
```

## Runtime Environment

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPTIMAL_ENGINE_API_URL` | `http://localhost:4200` | CLI API target. |
| `OPTIMAL_ENGINE_API_KEY` | empty | Bearer token for wrapper/client HTTP calls; supplying it does not configure server authentication. |
| `OPTIMAL_AUTH_REQUIRED` | configured auth setting, normally false | Literal `true` requires HTTP credentials; literal `false` enables trusted local mode; other values fail startup configuration. |
| `OPTIMAL_API_ENABLED` | disabled outside development startup | Literal `true` enables the configured API listener; development launcher/config also enables it. |
| `OPTIMAL_API_PORT` | `4200` | Port for an environment-enabled HTTP listener. |
| `OPTIMAL_API_INTERFACE` | `127.0.0.1` | Bind address for an environment-enabled listener. |
| `OPTIMAL_ENGINE_DB` | `.optimal/index.db` | Local SQLite store path. |
| `OPTIMAL_ENGINE_CACHE` | `.optimal/cache` | Local cache path. |
| `OPTIMAL_ENGINE_ROOT` | repo root | Engine root for source-checkout usage. |
| `OPTIMAL_KNOWLEDGE_BACKEND` | `rocksdb` when available | Graph backend selection. |
| `CONNECTOR_KEY` | generated into `.optimal/connector_key` | Local connector secret. |

Keep private values in environment variables, local secret stores, or deployment secret managers.
Do not commit them.

## Knowledge Graph Backend

Use RocksDB for normal local persistence:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=rocksdb
```

Use ETS for fast in-memory testing:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=ets
```

Use Mnesia only when intentionally testing distributed graph behavior:

```bash
OPTIMAL_KNOWLEDGE_BACKEND=mnesia
```

SQLite remains the durable local source of truth.
The graph backend supports graph runtime behavior and retrieval.

## Product Embedding

Products such as BusinessOS should connect over HTTP:

```text
BusinessOS
  -> scoped engine URL
  -> scoped API key or local connector grant
  -> tenant, organization, workspace, Node, and policy scope
  -> Optimal Engine API
```

Downloaded users should get their own local bundled engine and local store.
They should not connect to Roberto's private engine unless explicitly configured as Roberto's machine.

## Setup Profiles

| Profile | Use when | Expected behavior |
| --- | --- | --- |
| Local source checkout | Developer or local agent work | `bin/optimal dev` runs the engine on `localhost:4200`. |
| Bundled desktop engine | BusinessOS desktop user | App launches a local release with fresh local runtime data. |
| Production service | Hosted org or workspace | Service uses production secrets, scoped keys, and Postgres target when configured. |
| Test mode | CI and unit tests | Use isolated temp stores and avoid private `.optimal/` data. |

## Compatibility And API Grants

The current source contract is application `0.3.1`, contract schema `1`, API `v1`, and migration `62`.
The tracked [engine-contract.json](engine-contract.json) lists capabilities; [release identity](docs/guides/versioning-and-releases.md) explains the running build's SHA and version response.
A checkout pin does not attest a separately running HTTP process.

Ordinary `read`/`write` clients need separate `claims:review`, `topology:write`, or `admin` grants for privileged operations.
Omitting scopes when minting a key currently grants `*`; choose grants explicitly.
Follow [API grants and migration](docs/guides/interfaces-and-publishing.md#api-grants-and-identity) for tenant/reviewer binding and administrator-issued replacement keys.

## Safe Defaults

Prefer repo-relative defaults.
Prefer environment-driven config.
Require credentials explicitly for untrusted HTTP access with `OPTIMAL_AUTH_REQUIRED=true`.
The default local mode is trusted and permits anonymous requests; HTTP grants do not sandbox local CLI or SQL access.
Applications must supply intended scope, while legacy API defaults remain documented compatibility behavior.
Never silently share memory across tenants, organizations, or workspaces.
