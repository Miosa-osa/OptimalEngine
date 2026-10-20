# Optimal Engine MCP server

A stdio MCP server over the Optimal Engine HTTP API, for agent clients such as Claude Code and Codex.
It is versioned with the Engine (`engine-contract.json`).

## Build and run

```bash
npm ci && npm run build
OPTIMAL_ENGINE_URL=https://engine.example.com OPTIMAL_ENGINE_API_KEY_FILE=/path/to/key OPTIMAL_WORKSPACE=default:sales \
  node dist/index.js
```

The installed command is `optimal-engine-mcp` (`dist/index.js`).
It needs Node 20 or later.

## Settings

It reads the same settings as the `optimal` client, without flags:

| Variable | Meaning |
| --- | --- |
| `OPTIMAL_PROFILE` | profile name (`~/.config/optimal/profiles/<name>`) or a path |
| `OPTIMAL_ENGINE_URL` | Engine URL (then `OE_API`, `OPTIMAL_ENGINE_API_URL`) |
| `OPTIMAL_ENGINE_API_KEY` | bearer key (then `OPTIMAL_ENGINE_API_KEY_FILE`, `OPTIMAL_API_KEY`) |
| `OPTIMAL_WORKSPACE` | default workspace |

A profile key is only sent to its own URL.
A profile may name its key file with `key_file=`.
The server reads its settings, and that file, once when it starts: restart it after the key rotates.
The key is sent as a bearer token and never logged; one line on stderr names the URL and where the key came from.
Give the server a key with only the scopes its agent needs, for example `["read", "write"]` for one workspace.

## Register with a harness

Run it as a stdio server: `node <path>/dist/index.js` (or `optimal-engine-mcp`) with the variables above in its environment.
On a machine, `deploy/miosa-template/install-client.sh` installs it from its release archive (`apps/mcp/build.sh`, `optimal-engine-mcp-<version>.tar.gz`) and registers it with Claude Code and Codex 0.47.0 or newer, forwarding the Engine settings to Codex's server with `env_vars`; see `deploy/miosa-template/CLIENT-INSTALL.md`.

## Tools

Operating loop: `boot`, `brief`, `protocol`, `loops_list`, `loops_add`, `loops_close`, `search`, `assemble`, `read`, `capture`, `record`, `close`, `authority_decide`, `authority_effective`.
Chats: `session_commit`, `sessions_list`, `session_get`, `org_policy`.
Also: `ask`, `grep`, `profile`, `add_memory`, `forget_memory`, `recall`, `wiki_get`, `workspaces`, `render_context`.
The full description is in `docs/guides/cli.md` ("MCP server").

## Test

`npm test` builds the server and checks tool listing, routes, bearer authentication, and that keys never appear in results.
