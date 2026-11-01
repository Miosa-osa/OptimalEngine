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
tar -xzf optimal-0.3.12-linux-amd64.tar.gz
optimal-0.3.12-linux-amd64/install.sh            # /usr/local/bin if writable, else ~/.local/bin
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
| 426 | 78 | The Engine refuses this client's major release; the line says which client to install |
| 200 without the field the command reads | 65 | For example a `log` answer with no `text` |
| No response | 69 | `cannot reach the Engine at <url>` |
| Other errors | 1 | `HTTP <status> from <method> <path>` with the Engine's code |

Exit 64 is a usage error, 65 an answer the client cannot read, and 78 a refused operator command, a client the Engine refuses, or bad configuration.

## Version compatibility

The client sends `User-Agent: optimal-cli/<version>`, and the Engine compares it with its own version on every route except `/api/version`, `/api/health` and `/api/status`.
A different minor release is served with `x-optimal-client-outdated: client=<v> engine=<v>`.
The client then prints one warning line on stderr per run and carries on, for example `optimal: warning: client 0.3.3 is outdated for Engine 0.4.0; upgrade the client to 0.4.0`.
A different major release is refused with 426, and the client exits 78 with one line, for example `optimal: the Engine (1.0.0) refuses client 0.3.3 (HTTP 426: client_incompatible); upgrade the client to 1.0.0`.
A patch difference is silent.
`optimal version` and `optimal doctor` compare the two versions directly.

## Commands

Responses are JSON.
On a terminal they are pretty-printed when `jq` or `python3` is available; `--raw` and `--pretty` force either.
`--field a.b` prints one field; a string field prints as plain text, for example `optimal protocol --field content`, with terminal control characters (C0 controls other than tab and newline, DEL, C1 controls, and the Unicode line and paragraph separators) replaced by `?`.
JSON prints with C1 controls and the line and paragraph separators as `\u` escapes, the same text inside a JSON string, and any raw C0 control other than tab and newline, or DEL, which valid JSON never carries, as `?`.
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
| `search "q" [ws] [--limit --offset --type memory --as-of --mode lexical\|hybrid\|auto]` (alias `find`) | `GET /api/search` |
| `grep "q" [ws] [--intent --scale --modality --literal --path --as-of]` | `GET /api/grep` |
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
| `authority export [--after --until --limit --format json\|ndjson]` | `GET /api/authority/evidence/export`, printed as the Engine wrote it |
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

An `optimal://` URI names one context in its workspace.
A signal's address comes from its file, `{date}-{title}.md` with the title cut to 60 characters.
When another context already holds that name in the folder, the new context takes the name with the first 8 characters of its id before `.md`, so an ingest never replaces another context's file and a URI never names two contexts.
A document with no usable title (empty, only symbols, or `Untitled`) always carries the suffix, `2026-03-01-untitled-9f3c01ab.md`, so its address needs no lookup to be unique.
Ingesting a context again (same id) keeps its address, and keeps `metadata.uri_repair` if the repair below touched it.

### Contexts that already share an address

Addresses written before this rule can be shared by several contexts, and the file behind such an address holds only the last writer's text.
The text of every context is still in its row (`contexts.content`); the repair writes the files again from it.

```
optimal uris plan [ws|*] [--limit n] [--after cursor] [--out plan.json]
optimal uris apply [ws|*] --apply [--limit n] [--after cursor] [--out run.json]
```

They call `GET` and `POST /api/maintenance/uris`; both need `admin` and stay in the caller's tenant.
With a workspace the key must cover it; with `*` (the whole tenant) the key must cover every workspace.
Run the repair through the running Engine like this, never with `mix optimal.repair_uris` beside it: two processes must not write one store.
`mix optimal.repair_uris` is for a stopped Engine, and writes nothing without `--apply`.

**Before the run.** Copy the signal folders, stop ingest, and read the whole plan.
The plan writes nothing and lists, for the whole scope (`limit` pages it, `next_after` is the cursor of the next page):

- per workspace: groups, contexts to repair, files to write, to replace and to leave alone, and the bytes to write;
- per group: the keeper (id, title, path) and, for each context to repair, its old and new URI and path, the bytes of its new file, whether the target already exists, the cross-reference copies it will get, and the ACL rows that will be copied;
- for the kept address's file, and for the keeper's cross-reference copies: `unchanged` (it holds the keeper's own text), `rewrite` (its body is exactly the text of another context, named), `create` (there is no file) or `left_alone` (its body is the text of no context of the group, so it may have been edited), each with the reason;
- the records that name the shared URI: `acls`, `memories`, `open_loops`, `events` and `wiki_citations`;
- the groups that are skipped because a context in them has no text (nothing to write for it), or because a path of the group (a row's path, or the folder of a copy) is not inside its workspace's folder (a bundle import copies paths as they are; nothing is read or written for such a group, and the plan lists the paths), and the counts of what is left alone: archived contexts, rows that index the same file, rows with no file, contexts that are not signals, and contexts whose stored URI is not the address of their path (`uri_differs_from_path`, repaired like the others).
  A context that sits in another folder than the keeper gets its suffixed address in its own folder; the file it had there is not removed, since it is not the kept file, and the plan counts it (`old_files_left_in_place`) so it can be tidied by hand.

**What a run does**, for each group, in this order:

1. The earliest active context keeps the address.
2. The others get the suffixed address, and their files are written from their rows, with their cross-reference copies.
3. The kept address's file is replaced by the keeper's own text only if its body is, byte for byte, the body of another context of the group. The old bytes are copied into the run's backups first.
4. In one transaction the rows move (`metadata.uri_repair` records the previous URI and path), the ACL rows of the shared URI are copied to each new URI, and the memories and open loops that name the context by id are moved to it.

Every file is written through a temporary file, a flush and a rename, so a crash leaves a whole file or none; the rows move last, so a group that has been separated has all its files, and a run that stopped is resumed by running it again.
A run writes `<root>/.system/uri-repair/<run id>/journal.jsonl` (an append-only line per step: the context, old and new URI and path, the SHA-256 of the old and the new text, the backup) and `backups/`, and logs each group.
A run takes `limit` groups (default 50, at most 100,000) and reports `groups_remaining`; run it again until that is 0.

**Records that name an address.**
The ACL rows, memories and open loops that carry a context id follow the context to its new URI.
`events.target_uri`, the closing source of an open loop and `{{cite: uri}}` in wiki pages carry no context id: after the repair they resolve to the context that keeps the address, and the plan counts them.
The old address is not redirected: it keeps resolving, to the context that keeps it.

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

`start`, `stop`, `restart`, `log`, `index`, `graph` and `reality-check` act on the Engine's process and store, so what they do depends on where the Engine is.

### A local Engine

When the URL's host is a loopback address (`localhost`, `::1`, `0.0.0.0`, or an IPv4 address in `127.0.0.0/8`, compared without regard to case), they act on a local process and store.
The host is read from the URL's authority, which ends at the first `/`, `?` or `#`, so `http://example.com#@localhost:4200` is remote.
They run only when the client runs from an Engine checkout (or `OPTIMAL_ENGINE_CHECKOUT` names one); otherwise they refuse with exit 78 and change nothing.

* `start` runs `scripts/run-engine.sh` on the URL's port, waits for an answer, and records the process in `.optimal/cli-engine.pid` with its log in `.optimal/cli-engine.log`.
  If an Engine already answers, it reports that and starts nothing.
* `stop` stops only the process in that pid file, after checking the pid still runs the same command.
  It never stops a process it did not start: with another Engine answering it refuses.
  It waits 30 seconds after SIGTERM; `--force` sends SIGKILL after that.
* `log [-n lines]` shows that log.
* `index`, `graph` and `reality-check` run the Mix task in the checkout with the store defaults of `scripts/run-engine.sh`.
  They refuse while any Engine answers at the URL, because they need the store to themselves.
  `reality-check` writes diagnostic fixtures and requires `--disposable`.

### A remote Engine

Against any other URL they never touch a local process.
The ones the Engine API can serve call its routes with the configured key; the maintenance routes need the `admin` scope.

| Command | Route |
| --- | --- |
| `index [-w ws]` | `POST /api/maintenance/index`: enqueues a `reindex` job for the workspace (the one named, or the implicit default the key may use), coalesced per workspace like `POST /api/reindex`, and prints it |
| `log [-n lines]` | `GET /api/maintenance/log?lines=<n>` (default 200): the Engine's newest log lines, printed as text; Engine operator only |
| `graph [-w ws]` | `GET /api/maintenance/graph`: one workspace's edge counts by relation, most connected entities, and newest edges |
| `graph hubs\|clusters\|triangles [-w ws] [-n]` | `GET /api/graph/hubs`, `/api/graph/clusters`, `/api/graph/triangles` |
| `graph backfill [-w ws]` | `POST /api/maintenance/graph/backfill`: queues the workspace's graph backfill job (coalesced per workspace) and prints it |

The Engine keeps its log lines in memory (`OptimalEngine.LogBuffer`): the newest 1,000 at `info` and above, one line each with a UTC timestamp and the level, at most 4,096 bytes; a longer line is redacted first and then cut, ending in `...`.
A line longer than 16,384 characters, which the Engine's formatter cuts before redaction, also loses its last, cut word, which could be the start of a secret too short to recognize.
Control characters other than tab are replaced with `?`: the Engine replaces C0 and C1 controls, DEL, the Unicode line and paragraph separators, and the bidi and invisible format characters when it keeps a line, and the client replaces C0 controls, DEL, C1 controls and the line and paragraph separators again when it prints one.
Before a line is kept, the Engine replaces these with `[redacted]`:

- PEM private key blocks;
- Engine API keys: any `oe_` token, generated or chosen by the operator, plain or URL-encoded;
- `Bearer` credentials, `Basic` credentials (any case, only followed by a credential, so "basic mode" stays), and the userinfo of a URL, with or without a password, including a password that holds `@`;
- the value after a credential-like name (`api_key`, `access_token`, `refresh_token`, `token`, `secret`, `password`, `passwd`, `passphrase`, `client_secret`, `secret_access_key`, `secret_key`, `private_key`, `access_key_id`, `signature`, `authorization`, `x-optimal-grant`, `bot_token`, `cookie`, `cookies`, `set-cookie`), also at the end of a longer name such as `AWS_SECRET_ACCESS_KEY`, `db_password` or `notion_token`, as the last word of a camelCase name such as `apiKey`, `accessToken` or `accessKeyId`, and after any name ending in `_key` or `-key` in any case, such as `backup_key`, `encryption-key` or `CONNECTOR_KEY`, in `name=value`, `name: value`, map, keyword, header-tuple, atom-tuple, Erlang binary (binary values and binary names), escaped-JSON and URL-encoded forms, also with a line break after the separator;
- a quoted value (double-quoted with its escapes, a charlist, an Erlang binary, single-quoted or backtick-quoted) is redacted to its closing quote, or to the end of the line without one, and an unquoted one to whitespace, a quote, or the `&` of the next query parameter (a cookie value runs on over the `; ` between its pairs), an auth scheme word included: any word after `authorization`, and one such as `Token`, `ApiKey`, `Digest` or `AWS4-HMAC-SHA256` after the other names;
- a bare name in prose ("the password: was reset") loses the word after it, so the rule fails closed;
- provider tokens with a known prefix (`sk-`, `sk-ant-`, `rk_`, `whsec_`, `msk_`, `mki_`, `xox?-`, `xapp-`, `gh?_`, `github_pat_`, `glpat-`, `ntn_`, `secret_`, `npm_`, `hf_`, `ya29.`, `AIza`), AWS access key ids (`AKIA` and `ASIA`), and JWTs.

A secret in any other shape is kept as logged.
Redaction covers only the lines this buffer keeps, which `optimal log` and `GET /api/maintenance/log` serve; the Engine's console output, and anything that captures its stdout, gets each line as it was logged.
The log covers every tenant on the Engine, so only the Engine operator reads it: an admin key of the default tenant whose workspace scope is `*`.
Any other key, including another tenant's admin key or a default-tenant admin key limited to some workspaces, gets 403 `operator_only` (exit 77).
The buffer starts empty when the Engine starts; the `:optimal_engine` settings `:log_buffer_capacity` and `:log_buffer_level` change its size and level.

`start`, `stop`, `restart` and `reality-check` exit 78 with one line that names the reason, and change nothing.
The Engine's process belongs to the platform that runs it, so starting, stopping and restarting it happen there.
`reality-check` writes fixtures that belong only in a disposable local store.
An Engine older than the maintenance routes answers 404, which the client reports as exit 78 with a hint to upgrade the Engine.

`backup [--name file]` calls `POST /api/backup` against any Engine, local or remote: it writes inside the Engine's own backup directory and needs the `admin` scope.

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

It names itself to the Engine as `User-Agent: optimal-mcp/<version>`.
When the Engine marks it as another minor release (`x-optimal-client-outdated`), it prints one warning line on stderr per Engine release it sees and carries on, so an Engine upgraded while the server runs is reported again.
When the Engine refuses it with 426, every tool fails with the upgrade hint, for example `the Engine (1.0.0) refuses MCP server 0.3.3; upgrade the MCP server to 1.0.0 (HTTP 426: client_incompatible)`.

Register it with a harness as a stdio server running `node <path>/apps/mcp/dist/index.js` with those environment variables.
From a release archive, `install-client.sh` installs a launcher, `optimal-engine-mcp`, and registers it as `optimal-engine` with Claude Code (user scope) and Codex 0.47.0 or newer (`[mcp_servers.optimal-engine]` in `$CODEX_HOME/config.toml`).
Codex gives a stdio server only a fixed environment, so the Codex table lists the Engine settings in `env_vars`; Claude Code passes its own environment.
`npm test` builds the server and checks tool listing, routes, bearer authentication, that keys never appear in results, and the version warning and 426 refusal.

## Verification

`scripts/tests/test_optimal_cli.py` checks the client against a fake HTTP server: route mapping, URL encoding and JSON escaping, configuration precedence, the bearer header, that the key never reaches a process argument list or any output, error codes, the version warning and the 426 refusal, operator refusals, the maintenance routes a remote Engine is reached through, the start and stop of a process the client started, a minimal tool PATH, other shells, and the release archives.
For the remote cases the fake server is curl's HTTP proxy, so the client sees a remote URL while nothing leaves the machine.
Run it with `python3 -m unittest discover -s scripts/tests -p 'test_optimal_cli.py'`; set `OPTIMAL_CLI_TEST_SHELL=dash` to run every case under another shell.
`scripts/tests/test_install_client.py` runs `install-client.sh` in a temporary home against release files and a fake Engine: exit codes, checksums, a tampered CLI or MCP archive or a full disk leaving the install untouched, a signal or a kill between the MCP renames, interrupted and concurrent installs (the lock, a sweep that keeps live runs' and foreign files), read-only package directories, an MCP server without the installer's marks or a program link that is not an Optimal link left alone, a required source, directory, HTTPS and pinned HTTP sources, the shared install found without a prefix, root never installing into its own home, the installer refreshed from the CLI archive, the profile and its modes, verification from the profile and the environment, a 0.3.2 release, harness registration with Codex `env_vars` (a symlinked, unreadable or unfilterable Codex config included, and as root a foreign, symlinked or group-writable `CODEX_HOME`, a symlinked config, or a foreign home refused), and that the key is never a program argument or in a harness configuration.
Set `OPTIMAL_CLIENT_TEST_RELEASE_DIR` to a directory of real release files to install those instead of a stand-in MCP archive.
Set `OPTIMAL_CLIENT_TEST_SHELL=dash` (or `bash`) to run every installer case under that shell instead of `sh`.
