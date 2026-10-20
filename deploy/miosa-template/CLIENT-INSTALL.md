# Client install on MIOSA machines

Every MIOSA machine image (sandbox, computer, agent harness) carries the Engine client, so an agent uses its workspace's Engine with no setup.
One script does the Engine side: `deploy/miosa-template/install-client.sh`.
It installs the `optimal` CLI (alias `oe`) and the Engine MCP server from a pinned release, checks every archive's sha256, writes the client profile from the environment, registers the MCP server with Claude Code and Codex, and verifies the result.

## What it installs

| Path | What |
| --- | --- |
| `<prefix>/bin/optimal`, `<prefix>/bin/oe` | The client CLI: one POSIX shell program that needs `sh`, `curl` 7.55 or newer, and `awk`. |
| `<prefix>/bin/optimal-engine-mcp` | Launcher for the MCP server over stdio; needs Node.js 20 or newer. |
| `<prefix>/mcp/` | The MCP server with its production dependencies. |
| `<prefix>/VERSION` | The installed release. |
| `/usr/local/bin/{optimal,oe,optimal-engine-mcp}` | Links to the three programs (`OPTIMAL_CLIENT_BIN_DIR`). |

The prefix defaults to `/opt/optimal` when the script can write `/opt`, else `~/.local/share/optimal`.

## Release files

| File | Built by |
| --- | --- |
| `optimal-<version>-<os>-<arch>.tar.gz` for linux and darwin, amd64 and arm64 | `apps/cli/build.sh` |
| `optimal-engine-mcp-<version>.tar.gz`, one for every platform | `apps/mcp/build.sh` |
| `SHA256SUMS` | both builds |

CI builds them on every run and attaches them to the GitHub release of each `v*` tag.
A MIOSA image does not download from GitHub: the Engine release staging directory on the build host holds the same files, and its manifest records their sha256.
The script also accepts a flat MCP archive (`dist/`, `node_modules/`, `package.json` at its root), the layout staged for 0.3.2.

## Inputs

| Variable | Needed | Meaning |
| --- | --- | --- |
| `OPTIMAL_CLIENT_SOURCE` | yes, for an image | Absolute directory or `http(s)` base URL holding the release files. Default: the GitHub release. |
| `OPTIMAL_CLIENT_VERSION` | no | Release to install; default is the version the script ships with. |
| `OPTIMAL_CLI_SHA256` | recommended | sha256 of `optimal-<version>-linux-<arch>.tar.gz`, from the release manifest. |
| `OPTIMAL_MCP_SHA256` | recommended | sha256 of `optimal-engine-mcp-<version>.tar.gz`, from the release manifest. |
| `OPTIMAL_CLIENT_PREFIX` | no | Install root, for example a platform tools directory. |
| `OPTIMAL_CLIENT_BIN_DIR` | no | Where the programs are linked; `none` links nothing. |
| `OPTIMAL_CLIENT_SKIP_MCP` | no | `1` installs only the CLI. |
| `OPTIMAL_CLIENT_REGISTER_MCP` | no | `0` skips harness registration. |
| `OPTIMAL_ENGINE_URL` | at machine start | The workspace's Engine. Unset at image build: no profile is written and the Engine checks are skipped. |
| `OPTIMAL_ENGINE_API_KEY_FILE` or `OPTIMAL_ENGINE_API_KEY` | at machine start | The workspace-scoped key. |
| `OPTIMAL_WORKSPACE` | at machine start | The workspace id, for keys limited to named workspaces. |

Without the two sha256 variables the script takes them from `SHA256SUMS` in the source.
An archive with no expected sha256, or with a different one, is refused and nothing is installed.

## The one command

At image build, as root:

```bash
OPTIMAL_CLIENT_SOURCE=<release staging directory> \
OPTIMAL_CLI_SHA256=<cli sha256 from the manifest> \
OPTIMAL_MCP_SHA256=<mcp sha256 from the manifest> \
  deploy/miosa-template/install-client.sh
```

It runs `install configure register verify`.
`configure` and `register` act for the user running them, so register for each agent user too:

```bash
sudo -u <agent user> -H OPTIMAL_CLIENT_PREFIX=/opt/optimal deploy/miosa-template/install-client.sh register
```

A machine that gets `OPTIMAL_ENGINE_URL` and `OPTIMAL_ENGINE_API_KEY` in its environment needs nothing more: the CLI and the MCP server read them directly.
To leave a profile for processes that do not inherit that environment, and to prove the Engine answers, run at machine start:

```bash
deploy/miosa-template/install-client.sh configure verify
```

The commands can be run separately in any order: `install`, `configure`, `register`, `verify`.

## What success looks like

The script exits 0 and prints, for example:

```text
install-client: verified optimal-0.3.3-linux-amd64.tar.gz (<sha256>)
install-client: installed optimal 0.3.3 (alias oe) in /opt/optimal/bin
install-client: verified optimal-engine-mcp-0.3.3.tar.gz (<sha256>)
install-client: installed optimal-engine-mcp 0.3.3 in /opt/optimal/mcp
install-client: linked the programs into /usr/local/bin
install-client: registered optimal-engine with Claude Code (user scope)
install-client: registered optimal-engine with Codex (/root/.codex/config.toml)
install-client: ok: optimal 0.3.3 (oe 0.3.3)
install-client: ok: optimal-engine-mcp 0.3.3 answers initialize
install-client: ok: whoami against https://engine.example.com (authenticated: true, workspaces: ["default:sales"])
install-client: ok: search against https://engine.example.com
```

At image build the last two lines read `Engine checks skipped: no OPTIMAL_ENGINE_URL or profile on this machine yet`.
The key is never printed.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Every requested command succeeded. |
| 64 | Usage or input error: an unknown command, a bad `OPTIMAL_CLIENT_VERSION`, prefix, source, sha256 pin, or `OPTIMAL_ENGINE_URL`. |
| 65 | An archive was refused: no expected sha256, a mismatch, or wrong contents or version inside. Nothing is installed. |
| 66 | `OPTIMAL_ENGINE_API_KEY_FILE` cannot be read. |
| 69 | Something is unavailable: the source file, `curl` for an http source, a sha256 tool, Node.js 20 or newer, or the platform. |
| 70 | The installed CLI reports another version, or the MCP server did not answer `initialize`. |
| 73 | A harness registration failed, for example `claude mcp add`. |

The Engine checks in `verify` exit with the CLI's own code: 77 the key was refused, 69 the Engine is unreachable, 64 the key is limited to named workspaces and `OPTIMAL_WORKSPACE` is unset, 78 bad client configuration, 1 any other HTTP error.

## What it writes

* The profile `${XDG_CONFIG_HOME:-~/.config}/optimal/profile`, mode 0600 in a 0700 directory, with `url=`, `workspace=` and `key_file=` naming the key file, so a rotated key needs no new profile.
  An inline `OPTIMAL_ENGINE_API_KEY` is written as `key=`; a client older than `key_file=` support gets the key itself.
  A different earlier profile is kept as `profile.previous`.
* Claude Code: `claude mcp add --scope user optimal-engine -- <prefix>/bin/optimal-engine-mcp`, after removing an earlier `optimal-engine`.
* Codex: the `[mcp_servers.optimal-engine]` table in `$CODEX_HOME/config.toml` (default `~/.codex`) with `command` set to the launcher; other settings are kept.

The MCP server needs no environment in the harness configuration: it reads the same environment and profile as the CLI.

## Who does what

Engine side, in this repository:

* The CLI and MCP release files, their versions tied to `mix.exs`, built and attached to releases by CI.
* `install-client.sh`, its tests (`scripts/tests/test_install_client.py`), and this page.
* The CLI reads `OPTIMAL_ENGINE_URL` and `OPTIMAL_ENGINE_API_KEY` (and `OE_API`, `--api`, key files, profiles), sends the key as a bearer token, and never prints it.
* `optimal whoami` shows the key's scopes and workspaces, so a machine can confirm it holds a workspace key.

Image and platform side:

* Stage the release files with the Engine release and record their sha256 in the manifest.
* Call the script in the sandbox, computer and harness image builds, and register for each agent user.
* Inject `OPTIMAL_ENGINE_URL`, the workspace-scoped key and `OPTIMAL_WORKSPACE` into machines and runs of a workspace with an Engine, mint per-run keys and revoke them when the run ends.
* Register the MCP server in harnesses other than Claude Code and Codex, and add the default protocol block to agent instructions.
* `miosa engine connect` writing a profile on a laptop, and maintenance endpoints for operator commands on a managed Engine.
