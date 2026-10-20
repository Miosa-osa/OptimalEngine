# Client install on MIOSA machines

Every MIOSA machine image (sandbox, computer, agent harness) carries the Engine client, so an agent uses its workspace's Engine with no setup.
One script does the Engine side: `deploy/miosa-template/install-client.sh`.
It installs the `optimal` CLI (alias `oe`) and the Engine MCP server from a pinned release, checks every archive's sha256, writes the client profile from the environment, registers the MCP server with Claude Code and Codex, and verifies the result.
`install` also puts the script in `<prefix>/bin/install-client.sh`, so every user of the machine can run `configure`, `register` and `verify` later.
From 0.3.3 that copy comes from the CLI archive, so an upgrade refreshes it; for an older release it is the running script.
`install-client.sh --help` prints the full reference.

## What it installs

| Path | What |
| --- | --- |
| `<prefix>/bin/optimal`, `<prefix>/bin/oe` | The client CLI: one POSIX shell program that needs `sh`, `curl` 7.55 or newer, and `awk`. |
| `<prefix>/bin/optimal-engine-mcp` | Launcher for the MCP server over stdio; needs Node.js 20 or newer. It runs `OPTIMAL_MCP_NODE` when that is set, else the `node` found at install, else `node` on `PATH`. |
| `<prefix>/bin/install-client.sh` | The installer, mode 0755, for the machine-start commands. |
| `<prefix>/mcp/` | The MCP server with its production dependencies. |
| `<prefix>/VERSION` | The installed release. |
| `/usr/local/bin/{optimal,oe,optimal-engine-mcp}` | Links to the three programs. Root creates `/usr/local/bin` when it is missing; another user who cannot write it gets the links in `~/.local/bin`. `OPTIMAL_CLIENT_BIN_DIR` sets the directory, `none` links nothing. An entry is written only where none exists or where a link into an Optimal prefix is; anything else there, such as another program called `oe`, is left as it is with a warning. |

The prefix is `OPTIMAL_CLIENT_PREFIX` when set.
Otherwise it is the prefix the running copy is installed in (`<prefix>/bin/install-client.sh`).
Otherwise root uses `/opt/optimal`, which `install` creates; root never installs into its own home.
Another user uses `/opt/optimal` for `install` when it can be written, and for the other commands when it holds an install (`/opt/optimal/VERSION`).
Otherwise it is `~/.local/share/optimal`.

## Release files

| File | Built by |
| --- | --- |
| `optimal-<version>-<os>-<arch>.tar.gz` for linux and darwin, amd64 and arm64, each with the release's `install-client.sh` | `apps/cli/build.sh` |
| `optimal-engine-mcp-<version>.tar.gz`, one for every platform | `apps/mcp/build.sh` |
| `SHA256SUMS` | both builds |

CI builds and tests them on every run; release files are built on the release build host from the tagged source, not published from CI.
A MIOSA image installs from the Engine release staging directory on the build host, which holds these files, and its manifest records their sha256.
The script also accepts a flat MCP archive (`dist/`, `node_modules/`, `package.json` at its root), the layout staged for 0.3.2.

## Inputs

| Variable | Needed | Meaning |
| --- | --- | --- |
| `OPTIMAL_CLIENT_SOURCE` | yes, for `install` | Absolute directory or `https` base URL holding the release files, such as the Engine release staging directory. There is no default: `install` without it exits 64. An `http://` URL is accepted only with both sha256 pins. |
| `OPTIMAL_CLIENT_VERSION` | no | Release to install; default is the version the script ships with. The other commands default to the installed `<prefix>/VERSION`. Digits and dots only (`0.3.3`). |
| `OPTIMAL_CLI_SHA256` | yes, for an image | sha256 of `optimal-<version>-linux-<arch>.tar.gz`, from the release manifest. |
| `OPTIMAL_MCP_SHA256` | yes, for an image | sha256 of `optimal-engine-mcp-<version>.tar.gz`, from the release manifest. |
| `OPTIMAL_CLIENT_PREFIX` | no | Install root, for example a platform tools directory. |
| `OPTIMAL_CLIENT_BIN_DIR` | no | Where the programs are linked; `none` links nothing. |
| `OPTIMAL_CLIENT_SKIP_MCP` | no | `1` installs only the CLI, and removes an MCP server already in the prefix. |
| `OPTIMAL_CLIENT_REGISTER_MCP` | no | `0` skips harness registration. |
| `OPTIMAL_ENGINE_URL` | at machine start | The workspace's Engine. Unset at image build: no profile is written and the Engine checks are skipped. |
| `OPTIMAL_ENGINE_API_KEY_FILE` or `OPTIMAL_ENGINE_API_KEY` | at machine start | The workspace-scoped key; a key file must be an absolute path to a readable file. |
| `OPTIMAL_WORKSPACE` | at machine start | The workspace id, for keys limited to named workspaces. |
| `OPTIMAL_MCP_NODE` | no | Read by the installed launcher when the MCP server starts: the `node` program to run. |

The two sha256 pins are what make the install trustworthy: they come from the manifest, not from the place that serves the archives.
Without them the script takes the sha256 from `SHA256SUMS` in the same source, which catches a corrupt download but not a source that was changed, archives and `SHA256SUMS` together.
An archive with no expected sha256, or with a different one, is refused.
Downloads use `https` only (TLS 1.2 or newer, no redirect to another protocol), unless the source is `http://` with both pins.

When both key variables are set, `configure` writes the file (`key_file=`) and not the key itself, while the CLI and the MCP server reading the environment use `OPTIMAL_ENGINE_API_KEY` first; the script warns, and `verify` checks both.

## How install replaces files

Both archives are fetched, checked and unpacked in a scratch directory first, so a refused archive changes nothing.
Then every file is copied into the prefix beside the installed one, under a temporary name: this is the step that needs disk space.
Only when every copy succeeded are they renamed into place, the MCP server first and `VERSION` last.
A full disk or a missing permission during the copies exits 73 with the temporary files removed and the installed client unchanged.
A signal between the MCP server's two renames puts the installed server back on the way out.
A run killed outright (SIGKILL, a power cut) can leave its temporary copies, or the MCP server moved aside; the next `install` removes what runs no longer alive left and puts such a server back.
If the old MCP server cannot be removed after the renames, the install still finishes and warns, and the next `install` removes it.

`<prefix>/mcp/` and the launcher are replaced, or removed by `OPTIMAL_CLIENT_SKIP_MCP=1`, only when an earlier install put them there: `<prefix>/VERSION` existed before the run and the launcher carries the line `installed by install-client.sh`.
Otherwise `install` exits 73, names the path, and changes nothing.

## The one command

At image build, as root:

```bash
OPTIMAL_CLIENT_SOURCE=<release staging directory> \
OPTIMAL_CLI_SHA256=<cli sha256 from the manifest> \
OPTIMAL_MCP_SHA256=<mcp sha256 from the manifest> \
  deploy/miosa-template/install-client.sh
```

It runs `install configure register verify` and installs into `/opt/optimal`.
`configure` and `register` act for the user running them, so each agent user runs the installed copy, which finds `/opt/optimal` by itself.
Run it in the agent user's login shell, so its own `PATH` (where `claude` and `codex` are installed, such as `~/.local/bin` or an npm prefix) applies:

```bash
sudo -iu <agent user> /opt/optimal/bin/install-client.sh register
```

`sudo -u` without `-i` replaces `PATH` with its `secure_path`, and `env "PATH=$PATH"` would pass root's `PATH`, not the agent's.
When the agent's login shell does not put the harnesses on `PATH`, name their directory explicitly:

```bash
sudo -u <agent user> -H env "PATH=/home/<agent user>/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  /opt/optimal/bin/install-client.sh register
```

A harness that is not found is named in the output (`Claude Code skipped: claude is not on PATH`).

A machine that gets `OPTIMAL_ENGINE_URL` and `OPTIMAL_ENGINE_API_KEY` in its environment needs nothing more: the CLI and the MCP server read them directly.
To leave a profile for processes that do not inherit that environment, and to prove the Engine answers, each user runs at machine start:

```bash
/opt/optimal/bin/install-client.sh configure verify
```

`verify` checks the Engine from the profile, with the Engine variables of the environment set aside, and then from the environment, when each exists: later processes get one or the other.

## What success looks like

The script exits 0 and prints, for example, on a machine with the Engine settings in its environment:

```text
install-client: verified optimal-0.3.5-linux-amd64.tar.gz (<sha256>)
install-client: verified optimal-engine-mcp-0.3.5.tar.gz (<sha256>)
install-client: installed optimal 0.3.5 (alias oe) in /opt/optimal/bin
install-client: installed optimal-engine-mcp 0.3.5 in /opt/optimal/mcp
install-client: installed /opt/optimal/bin/install-client.sh for configure, register and verify
install-client: linked optimal oe optimal-engine-mcp into /usr/local/bin
install-client: wrote /root/.config/optimal/profile (mode 0600)
install-client: registered optimal-engine with Claude Code (user scope)
install-client: registered optimal-engine with Codex (/root/.codex/config.toml)
install-client: ok: optimal 0.3.5 (oe 0.3.5)
install-client: ok: optimal-engine-mcp 0.3.5 answers initialize
install-client: ok: whoami against https://engine.example.com from the profile (authenticated: true, workspaces: ["default:sales"])
install-client: ok: search against https://engine.example.com from the profile
install-client: ok: whoami against https://engine.example.com from the environment (authenticated: true, workspaces: ["default:sales"])
install-client: ok: search against https://engine.example.com from the environment
```

At image build, with no `OPTIMAL_ENGINE_URL`, the profile line reads `no profile written: OPTIMAL_ENGINE_URL is not set (the client reads the environment directly)`, and the four Engine lines are one: `Engine checks skipped: no OPTIMAL_ENGINE_URL or profile on this machine yet`.
The key is never printed and never passed as a program argument.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Every requested command succeeded. |
| 64 | Usage or input error: an unknown command, a bad `OPTIMAL_CLIENT_VERSION`, prefix, source, sha256 pin, key file path, or `OPTIMAL_ENGINE_URL`; an `http://` source without both pins. |
| 65 | An archive was refused: no expected sha256, a mismatch, or wrong contents or version inside. Nothing is replaced. |
| 66 | `OPTIMAL_ENGINE_API_KEY_FILE` is not a readable file. |
| 69 | Something is unavailable: the source does not answer, answers 404 for an archive, or answers another error; `curl`, a sha256 tool, Node.js 20 or newer, or the platform is missing. |
| 70 | No client is installed in the prefix, `<prefix>/VERSION` does not hold a version (the error names the file), the installed CLI reports another version, or the MCP server did not answer `initialize` as the installed version. |
| 73 | Something could not be written or is not this installer's: the prefix (nothing is replaced), an MCP server or launcher an earlier install did not put there, a program link, `claude mcp add`, or the Codex config, including one this user cannot read and write and, as root, a symlinked `config.toml` or a `CODEX_HOME` another user owns. The Codex config is then unchanged. |

The Engine checks in `verify` exit with the CLI's own code: 77 the key was refused, 69 the Engine is unreachable, 64 the key is limited to named workspaces and `OPTIMAL_WORKSPACE` is unset, 78 bad client configuration, 1 any other HTTP error.
From 0.3.3 the MCP server is versioned with the Engine and a different version is refused; for 0.3.2 and earlier a different MCP server version is only a warning.

## What it writes

* The profile `${XDG_CONFIG_HOME:-~/.config}/optimal/profile`, mode 0600 in a 0700 directory, with `url=`, `workspace=` and `key_file=` naming the key file.
  The CLI reads that file each time it uses the key; the MCP server reads it when it starts, so restart the harness's MCP server after the key rotates.
  An inline `OPTIMAL_ENGINE_API_KEY` is written as `key=`, and so is the key from a key file for a client older than 0.3.3, which does not read `key_file=`.
  A different earlier profile is kept as `profile.previous`.
* Claude Code: `claude mcp add --scope user optimal-engine -- <prefix>/bin/optimal-engine-mcp`, after removing an earlier `optimal-engine`.
  Claude Code passes its own environment to the server.
* Codex: the `[mcp_servers.optimal-engine]` table in `$CODEX_HOME/config.toml` (default `~/.codex`), with `command` set to the launcher and `env_vars = ["OPTIMAL_ENGINE_URL", "OPTIMAL_ENGINE_API_KEY", "OPTIMAL_ENGINE_API_KEY_FILE", "OPTIMAL_WORKSPACE", "OPTIMAL_PROFILE", "XDG_CONFIG_HOME"]`.
  Codex gives a stdio server only a fixed environment (`HOME`, `PATH` and a few more) plus the names in `env_vars`, so this list is what lets the server see the injected Engine settings; with only `HOME` it still finds the default profile.
  `env_vars` needs Codex 0.47.0 or newer: an older Codex gets the table without it, with a warning, and when the version is unknown (`codex` not on `PATH`, or no version in its `--version`) the table has it and the script warns.
  Any earlier `optimal-engine` table and its sub-tables are replaced, however their headers are spaced or quoted; every other setting is kept.
  The file is rewritten atomically with mode 0600, through a symlink when `config.toml` is one, so the link stays; a `~/.codex` the script creates is mode 0700.
  A config this user cannot read and write (for example one owned by root in the agent's home) is left alone and the script exits 73.
  As root, `register` writes only into a `CODEX_HOME` root owns (or creates) and never through a symlinked `config.toml`, which another user could point at any file; register as the agent user instead.

No key is written into a harness configuration.

## Who does what

Engine side, in this repository:

* The CLI and MCP release files, their versions tied to `mix.exs`, built by CI and attached to tag releases by a job without a checkout.
* `install-client.sh`, its tests (`scripts/tests/test_install_client.py`), and this page.
* The CLI reads `OPTIMAL_ENGINE_URL` and `OPTIMAL_ENGINE_API_KEY` (and `OE_API`, `--api`, key files, profiles), sends the key as a bearer token, and never prints it.
* `optimal whoami` shows the key's scopes and workspaces, so a machine can confirm it holds a workspace key.

Image and platform side:

* Stage the release files with the Engine release and record their sha256 in the manifest.
* Call the script with both pins in the sandbox, computer and harness image builds, and run the installed copy's `register` (and, at machine start, `configure verify`) for each agent user, in that user's login shell.
* Inject `OPTIMAL_ENGINE_URL`, the workspace-scoped key and `OPTIMAL_WORKSPACE` into machines and runs of a workspace with an Engine, mint per-run keys and revoke them when the run ends.
* Register the MCP server in harnesses other than Claude Code and Codex, and add the default protocol block to agent instructions.
* `miosa engine connect` writing a profile on a laptop, and maintenance endpoints for operator commands on a managed Engine.
