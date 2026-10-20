# Client CLI and MCP server

`optimal` is the Optimal Engine client.
`oe` is the same program under another name; both behave identically.
It talks to any Engine over HTTP(S): one on your machine, a managed Engine, or one named by a profile.
The same commands work against all of them, so habits do not change when an Engine moves.

The client lives at `apps/cli/optimal`.
It is one POSIX shell program that needs only `sh`, `curl` 7.55 or newer, and `awk`.
It needs no Elixir, Node, or Python, and runs unchanged on Linux and macOS on amd64 and arm64.

Two other command surfaces exist and are not this client:

| Surface | Use |
| --- | --- |
| `bin/optimal` | Source-checkout wrapper; may fall back to local `mix optimal.*` tasks. |
| `mix optimal.*` | Native development and operator tasks with direct store access. |

## Install

From a release archive:

```bash
tar -xzf optimal-0.3.4-linux-amd64.tar.gz
optimal-0.3.4-linux-amd64/install.sh            # /usr/local/bin if writable, else ~/.local/bin
optimal --version
```

From a checkout, without copying:

```bash
apps/cli/install.sh ~/.local     # or: ln -s "$PWD/apps/cli/optimal" ~/.local/bin/optimal
```

Build the archives with `apps/cli/build.sh [out-dir]` (default `dist/cli`).
It writes `optimal-<version>-<os>-<arch>.tar.gz` for linux-amd64, linux-arm64, darwin-amd64 and darwin-arm64, and their lines in `SHA256SUMS`.
Each archive holds `optimal`, the `oe` link, `install.sh`, `install-client.sh` (the machine installer of the same release), `LICENSE`, and `VERSION`.
The client version is the Engine version from `mix.exs`; the build refuses to run when they differ.
`apps/mcp/build.sh [out-dir]` adds `optimal-engine-mcp-<version>.tar.gz`, the MCP server with its production dependencies, to the same directory and `SHA256SUMS`.
CI builds and tests both on every run; the release files are built from the tagged source on the release build host and staged there with `SHA256SUMS`.

To put the client and the MCP server on a machine in one step, with every archive's sha256 checked, use `deploy/miosa-template/install-client.sh`:

```bash
OPTIMAL_CLIENT_SOURCE=/path/to/release-files deploy/miosa-template/install-client.sh
```

It installs `optimal`, `oe` and `optimal-engine-mcp` under a prefix, writes the profile from `OPTIMAL_ENGINE_URL`, `OPTIMAL_ENGINE_API_KEY_FILE` and `OPTIMAL_WORKSPACE` when they are set, registers the MCP server with Claude Code and Codex when they are installed, and verifies the result.
[Client install on MIOSA machines](../../deploy/miosa-template/CLIENT-INSTALL.md) lists its inputs and checks.

## Configure

| Setting | Flag | Environment | Profile |
| --- | --- | --- | --- |
| Engine URL | `--api <url>` | `OPTIMAL_ENGINE_URL`, then `OE_API`, then `OPTIMAL_ENGINE_API_URL` | `url=` |
| API key | `--key-file <path>` | `OPTIMAL_ENGINE_API_KEY`, then `OPTIMAL_ENGINE_API_KEY_FILE`, then `OPTIMAL_API_KEY` | `key=` |
| Workspace | `-w`, `--workspace <id>` | `OPTIMAL_WORKSPACE` | `workspace=` |
| Profile | `--profile <name or path>` | `OPTIMAL_PROFILE` | |
| Timeout | `--timeout <s>` | `OPTIMAL_TIMEOUT` (default 120) | |

Precedence: flags, then a profile named with `--profile` or `OPTIMAL_PROFILE`, then the environment, then the default profile, then `http://127.0.0.1:4200`.
The default profile is `${XDG_CONFIG_HOME:-~/.config}/optimal/profile`; a named profile is `~/.config/optimal/profiles/<name>`.

```text
# ~/.config/optimal/profile  (chmod 600)
url=https://engine.example.com
key=oe_...
workspace=default:sales
```

Instead of `key=`, a profile may name a file holding the key with `key_file=/path/to/key` (from 0.3.3).
The client reads the file each time it uses the key, so a platform that rotates it needs no new profile; the MCP server reads it when it starts.
`key=` wins when both are present.
`OPTIMAL_ENGINE_URL=`, `OPTIMAL_ENGINE_API_KEY=`, `OPTIMAL_ENGINE_API_KEY_FILE=` and `OPTIMAL_WORKSPACE=` are accepted as profile keys too, so a platform tool can write either form.
A profile's key is sent only to that profile's own `url`; with a different URL from a flag or the environment, the profile key is not used.
The client warns when a profile holding a key is readable by other users.

Workspace ids are passed as written, for example `default:sales`.
Commands that take a workspace accept it as a trailing argument too: `optimal search "renewal" default:sales`.
Naming two different workspaces is an error.

For a private certificate authority, set `CURL_CA_BUNDLE`; curl reads it directly.

## Authentication and identity

The key goes out as `Authorization: Bearer <key>`.
The client hands it to curl on stdin, so it never appears in a process list, and it never prints it: errors, `--verbose`, and `doctor` show where the key came from, not its value, and any echo of it in a response is replaced with `[redacted]`.
The client never sends `actor_id`, `verifier_id` or `created_by`; the Engine takes identity from the key.

| Response | Exit | Message |
| --- | --- | --- |
| 401 | 77 | `authentication required` (no key) or `authentication failed` with the key's source, plus the Engine's code |
| 403 | 77 | `permission denied (HTTP 403: <code>)`, for example `permission_scope_denied` or `workspace_scope_denied` |
| 400 `workspace_required` | 64 | The key is limited to named workspaces; pass `--workspace` or set `OPTIMAL_WORKSPACE` |
| No response | 69 | `cannot reach the Engine at <url>` |
| Other errors | 1 | `HTTP <status> from <method> <path>` with the Engine's code |

Exit 64 is a usage error and 78 a refused operator command or bad configuration.

## Commands

Responses are JSON.
On a terminal they are pretty-printed when `jq` or `python3` is available; `--raw` and `--pretty` force either.
`--field a.b` prints one field; a string field prints as plain text, for example `optimal protocol --field content`.
Text arguments may be `-` to read standard input.

| Command | Route |
| --- | --- |
| `boot [ws] [--timezone]` | `GET /api/boot` |
| `today [ws] [--cadence daily\|weekly\|monthly]` (alias `rhythm`) | `GET /api/rhythm/current` |
| `fires [ws]` | the `fires` field of `GET /api/boot` |
| `brief [ws] [--workspaces a,b\|*]` | `GET /api/brief` |
| `protocol [ws]` | `GET /api/protocol` |
| `commitments [ws]` | `GET /api/operating-projection` |
| `loops [list] [ws] [--state --owner --kind --due-before --workspaces]` | `GET /api/loops` |
| `loops add "title" [ws] [--kind --owner --counterparty --due --source-uri]` | `POST /api/loops` |
| `loops close\|drop\|reopen <id> [--reason --source-uri]` | `POST /api/loops/:id/:action` |
| `loops extract [ws] [--since]` | `POST /api/loops/extract` |
| `search "q" [ws] [--limit --offset --type memory]` (alias `find`) | `GET /api/search` |
| `grep "q" [ws] [--intent --scale --modality --literal --path]` | `GET /api/grep` |
| `assemble "topic" [ws]` | `POST /api/assemble` |
| `read <optimal://uri or id> [ws] [--tier l0\|l1\|full]` | `GET /api/read` |
| `ask "q" [ws]` (alias `rag`) | `POST /api/rag` |
| `reconstruct "q" [ws]` | `POST /api/reconstruct` |
| `memory [ws] [--limit --query]` | `GET /api/memory` |
| `claims [ws]` | `GET /api/memory-core/claims` |
| `review [ws]` | `GET /api/memory` and `GET /api/memory-core/claim-review` |
| `capture "text" [ws] [genre] [--title --node]` (alias `signal`) | `POST /api/ingest` with claim extraction |
| `aware "text" [ws]` | capture, remember, then search for related context |
| `note\|lesson\|decision\|task\|close "text" [ws] [--owner --due]` | `POST /api/memory/remember` as `Note:`, `Lesson:`, `Decision:`, `Task:`, `Close-loop:` with `metadata.kind` |
| `remember "text" [ws]` | `POST /api/memory/remember` |
| `session commit <messages.json\|-> [ws] --correlation-id <id> [--title --summary]` | `POST /api/sessions/commit` |
| `session [list] [ws] [--correlation-id]` (alias `sessions`), `session show <id> [ws] [--transcript]` | `GET /api/sessions`, `GET /api/sessions/:id` |
| `policy [ws]` (alias `org-policy`) | `GET /api/org-policy` |
| `org-section [show\|set <workspace>\|clear]` | `GET`, `PUT`, `DELETE /api/org-section` (set and clear: admin scope) |
| `routing [review [state]]`, `routing rules [ws]` | `GET /api/review/routing`, `GET /api/routing/rules` |
| `routing classify [--sender --label --channel --title --text]` | `POST /api/routing/classify` |
| `authority effective [ws] [--subject]` | `GET /api/authority/effective` |
| `authority decide --action --resource [--data-class --subject] [ws]` | `POST /api/authority/decide` |
| `authority request --action --resource [--data-class --ttl --justification] [ws]` | `POST /api/authority/requests` |
| `init --for agent\|workspace\|business\|app\|tenant-per-customer [--slug --name]` | `POST /api/init` (admin scope) |
| `size` (alias `usage`) | `GET /api/storage` |
| `viability [ws] [--workspaces *]`, `viability history [ws] [--days]` | `GET /api/viability`, `GET /api/viability/history` |
| `chain <correlation, request, or grant id> [ws]` | `GET /api/agent-actions/:id` |
| `check "draft"\|- [ws] [--channel --bandwidth --genre --type]` | `POST /api/signals/check` (pre-send check) |
| `analyses [ws] [--kind]`, `analyses run <kind> [ws]` | `GET /api/analyses`, `POST /api/analyses/run` (admin scope) |
| `jobs [ws] [--state]` | `GET /api/jobs` |
| `status`, `health`, `workspaces`, `organizations` | `GET /api/status`, `/api/health`, `/api/workspaces`, `/api/organizations` |
| `whoami` | `GET /api/auth/whoami`: the key's scopes and workspaces, never the key |
| `version` | client version and `GET /api/version` |
| `doctor` | configuration sources, curl version, and health |
| `api <METHOD> /api/<path> [json\|-]` | any other route, with the same authentication |

`GET /api/read` returns one context by `uri` or `id` from the named workspace only.
When the requested tier is empty it serves the next fuller tier and says so in `served_tier`.
It never indexes files; a URI the store does not hold is 404.

## The operating loop

```bash
optimal boot                                     # day, fires, brief, protocol
optimal search "renewal terms"                   # before answering about past work
optimal read "optimal://..." --tier full         # when the summary is not enough
optimal capture "Customer moved the start date to 2026-11-02" default:sales
optimal loops add "Send revised proposal" --owner user:jane --due 2026-10-23
optimal decision "Hold pricing for the renewal" --owner user:jane
optimal close "What changed, how it was verified, what is unverified"
```

## Operator commands

`start`, `stop`, `restart`, `log`, `index`, `graph [backfill]` and `reality-check` act on a local process and store.
They run only when the URL's host is `127.0.0.1`, `localhost` or `::1` and the client runs from an Engine checkout (or `OPTIMAL_ENGINE_CHECKOUT` names one).
Against any other URL they refuse with exit 78 and change nothing, because the Engine API has no maintenance endpoint for them; a managed Engine is maintained through its platform.

* `start` runs `scripts/run-engine.sh` on the URL's port, waits for an answer, and records the process in `.optimal/cli-engine.pid` with its log in `.optimal/cli-engine.log`.
  If an Engine already answers, it reports that and starts nothing.
* `stop` stops only the process in that pid file, after checking the pid still runs the same command.
  It never stops a process it did not start: with another Engine answering it refuses.
  It waits 30 seconds after SIGTERM; `--force` sends SIGKILL after that.
* `log [-n lines]` shows that log.
* `index`, `graph` and `reality-check` run the Mix task in the checkout with the store defaults of `scripts/run-engine.sh`.
  They refuse while any Engine answers at the URL, because they need the store to themselves.
  `reality-check` writes diagnostic fixtures and requires `--disposable`.

`backup [--name file]` is the exception: it calls `POST /api/backup`, which writes inside the Engine's own backup directory, so it works against local and remote Engines and needs the `admin` scope.

## MCP server

`apps/mcp` is a stdio MCP server over the same HTTP API.

```bash
cd apps/mcp && npm ci && npm run build
OPTIMAL_ENGINE_URL=https://engine.example.com OPTIMAL_ENGINE_API_KEY=... OPTIMAL_WORKSPACE=default:sales \
  node dist/index.js
```

It reads the same settings as the client, without flags: `OPTIMAL_PROFILE`, `OPTIMAL_ENGINE_URL` (then `OE_API`, `OPTIMAL_ENGINE_API_URL`), `OPTIMAL_ENGINE_API_KEY` (then `OPTIMAL_ENGINE_API_KEY_FILE`, `OPTIMAL_API_KEY`), `OPTIMAL_WORKSPACE`, and the default profile (including `key_file=`), with the same rule that a profile key only goes to its own URL.
It reads them once, when it starts: restart the server after its key rotates.
It sends the key as a bearer token and logs one line to stderr naming the URL and where the key came from, never the key; error messages carry the Engine's code and are redacted.

Tools for the operating loop: `boot`, `brief`, `protocol`, `loops_list`, `loops_add`, `loops_close`, `search`, `assemble`, `read`, `capture`, `record` (note, lesson, decision, task), `close`, `authority_decide`, and `authority_effective`.
They write the same records as the client and never name an actor.
For chats: `session_commit`, `sessions_list`, `session_get`, and `org_policy` (`chat-memory.md`).
The earlier tools remain: `ask`, `grep`, `profile`, `add_memory`, `forget_memory` (sends the workspace the memory belongs to), `recall`, `wiki_get`, `workspaces`, and `render_context`.

Register it with a harness as a stdio server running `node <path>/apps/mcp/dist/index.js` with those environment variables.
From a release archive, `install-client.sh` installs a launcher, `optimal-engine-mcp`, and registers it as `optimal-engine` with Claude Code (user scope) and Codex 0.47.0 or newer (`[mcp_servers.optimal-engine]` in `$CODEX_HOME/config.toml`).
Codex gives a stdio server only a fixed environment, so the Codex table lists the Engine settings in `env_vars`; Claude Code passes its own environment.
`npm test` builds the server and checks tool listing, routes, bearer authentication, and that keys never appear in results.

## Verification

`scripts/tests/test_optimal_cli.py` checks the client against a fake HTTP server: route mapping, URL encoding and JSON escaping, configuration precedence, the bearer header, that the key never reaches a process argument list or any output, error codes, operator refusals, the start and stop of a process the client started, a minimal tool PATH, other shells, and the release archives.
Run it with `python3 -m unittest discover -s scripts/tests -p 'test_optimal_cli.py'`; set `OPTIMAL_CLI_TEST_SHELL=dash` to run every case under another shell.
`scripts/tests/test_install_client.py` runs `install-client.sh` in a temporary home against release files and a fake Engine: exit codes, checksums, a tampered CLI or MCP archive or a full disk leaving the install untouched, directory, HTTPS and pinned HTTP sources, the shared install found without a prefix, root never installing into its own home, the installer refreshed from the CLI archive, the profile and its modes, verification from the profile and the environment, a 0.3.2 release, harness registration with Codex `env_vars` (a symlinked, unreadable or unfilterable Codex config included), and that the key is never a program argument or in a harness configuration.
Set `OPTIMAL_CLIENT_TEST_RELEASE_DIR` to a directory of real release files to install those instead of a stand-in MCP archive.
