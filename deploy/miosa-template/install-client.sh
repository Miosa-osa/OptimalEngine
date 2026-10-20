#!/bin/sh
# Installs the Optimal Engine client on a machine: the `optimal` CLI (alias `oe`) and the
# Engine MCP server, from a pinned Engine release, with every archive's sha256 verified.
#
#   OPTIMAL_CLIENT_SOURCE=<dir or https base URL> deploy/miosa-template/install-client.sh
#
# Commands, run in the order given (default: install configure register verify):
#   install    fetch, verify and install the CLI and the MCP server
#   configure  write the client profile from OPTIMAL_ENGINE_URL, OPTIMAL_ENGINE_API_KEY_FILE
#              (or OPTIMAL_ENGINE_API_KEY) and OPTIMAL_WORKSPACE; nothing when the URL is unset
#   register   register the MCP server with Claude Code and Codex when they are installed
#   verify     optimal --version, the MCP server's initialize answer, and with an Engine
#              configured: optimal whoami and one search
#
# Inputs (environment):
#   OPTIMAL_CLIENT_VERSION   release to install (default: the version below)
#   OPTIMAL_CLIENT_SOURCE    directory or http(s) base URL holding optimal-<v>-<os>-<arch>.tar.gz,
#                            optimal-engine-mcp-<v>.tar.gz and SHA256SUMS
#                            (default: the GitHub release v<version>)
#   OPTIMAL_CLI_SHA256, OPTIMAL_MCP_SHA256   expected sha256 of the two archives; without
#                            them SHA256SUMS from the source decides. An archive with no
#                            expected sha256 is never installed.
#   OPTIMAL_CLIENT_PREFIX    install root (default /opt/optimal when writable, else
#                            ~/.local/share/optimal): bin/optimal, bin/oe,
#                            bin/optimal-engine-mcp, mcp/, VERSION
#   OPTIMAL_CLIENT_BIN_DIR   where the three programs are linked (default /usr/local/bin when
#                            writable, else ~/.local/bin; "none" links nothing)
#   OPTIMAL_CLIENT_SKIP_MCP=1       install only the CLI (no Node.js needed)
#   OPTIMAL_CLIENT_REGISTER_MCP=0   do not register the MCP server with any harness
#   OPTIMAL_CLIENT_VERIFY_QUERY     the search verify runs (default "optimal")
#
# configure and register act for the user running them ($HOME, XDG_CONFIG_HOME, CODEX_HOME).
# The API key is never printed. The profile is mode 0600 in a 0700 directory, and with
# OPTIMAL_ENGINE_API_KEY_FILE it names the file (key_file=) instead of copying the key,
# unless the installed client is older than key_file= support.
# Exit status: 0 when every requested command succeeded; 64 usage or input error; 65 an
# archive refused (no expected sha256, a mismatch, wrong contents); 66 the key file cannot
# be read; 69 something unavailable (source, curl, a sha256 tool, Node.js 20+); 70 the
# installed client or MCP server failed its check; 73 a harness registration failed. The
# Engine checks in verify exit with the CLI's code: 77 key refused, 69 Engine unreachable,
# 64 workspace required, 78 bad configuration, 1 other.
set -eu
umask 022

DEFAULT_VERSION=0.3.3
RELEASES=https://github.com/Miosa-osa/OptimalEngine/releases/download

VERSION=${OPTIMAL_CLIENT_VERSION:-$DEFAULT_VERSION}
SOURCE=${OPTIMAL_CLIENT_SOURCE:-$RELEASES/v$VERSION}
SOURCE=${SOURCE%/}

say() { printf 'install-client: %s\n' "$*"; }
warn() { printf 'install-client: warning: %s\n' "$*" >&2; }
EX_USAGE=64
EX_DATAERR=65
EX_NOINPUT=66
EX_UNAVAILABLE=69
EX_SOFTWARE=70
EX_CANTCREAT=73

# die CODE MESSAGE...: prints the message and exits with CODE.
die() {
  _code=$1
  shift
  printf 'install-client: %s\n' "$*" >&2
  exit "$_code"
}

case $VERSION in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die $EX_USAGE "OPTIMAL_CLIENT_VERSION must look like 1.2.3, not '$VERSION'" ;;
esac

if [ -n "${OPTIMAL_CLIENT_PREFIX:-}" ]; then
  PREFIX=$OPTIMAL_CLIENT_PREFIX
elif [ -w /opt ] || [ -w /opt/optimal ]; then
  PREFIX=/opt/optimal
else
  PREFIX=${HOME:?HOME is not set}/.local/share/optimal
fi
case $PREFIX in
  /*) ;;
  *) die $EX_USAGE "OPTIMAL_CLIENT_PREFIX must be an absolute path" ;;
esac
# The prefix is written into a launcher and a TOML string, so it stays plain.
case $PREFIX in
  *[\'\"\\\$\`]*) die $EX_USAGE "OPTIMAL_CLIENT_PREFIX must not contain quotes, backslashes, \$ or backticks" ;;
esac

if [ -n "${OPTIMAL_CLIENT_BIN_DIR:-}" ]; then
  BIN_DIR=$OPTIMAL_CLIENT_BIN_DIR
elif [ -w /usr/local/bin ]; then
  BIN_DIR=/usr/local/bin
else
  BIN_DIR=${HOME:?HOME is not set}/.local/bin
fi

OPTIMAL=$PREFIX/bin/optimal
LAUNCHER=$PREFIX/bin/optimal-engine-mcp

WORK=$(mktemp -d "${TMPDIR:-/tmp}/optimal-client.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- platform and checksums -----------------------------------------------------

platform() {
  case $(uname -s) in
    Linux) _os=linux ;;
    Darwin) _os=darwin ;;
    *) die $EX_UNAVAILABLE "unsupported operating system $(uname -s)" ;;
  esac
  case $(uname -m) in
    x86_64 | amd64) _arch=amd64 ;;
    aarch64 | arm64) _arch=arm64 ;;
    *) die $EX_UNAVAILABLE "unsupported architecture $(uname -m)" ;;
  esac
  printf '%s-%s' "$_os" "$_arch"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die $EX_UNAVAILABLE "need sha256sum or shasum to verify the release"
  fi
}

# fetch NAME: copies or downloads NAME from the source into $WORK.
fetch() {
  case $SOURCE in
    https://* | http://*)
      command -v curl >/dev/null 2>&1 || die $EX_UNAVAILABLE "curl is required to download from $SOURCE"
      curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/$1" "$SOURCE/$1" ||
        die $EX_UNAVAILABLE "cannot download $SOURCE/$1"
      ;;
    /*)
      [ -f "$SOURCE/$1" ] || die $EX_UNAVAILABLE "$SOURCE/$1 does not exist"
      cp "$SOURCE/$1" "$WORK/$1" || die $EX_UNAVAILABLE "cannot copy $SOURCE/$1"
      ;;
    *) die $EX_USAGE "OPTIMAL_CLIENT_SOURCE must be an absolute directory or an http(s) URL" ;;
  esac
}

# expected_sha NAME OVERRIDE: the override, else the SHA256SUMS line for NAME.
expected_sha() {
  if [ -n "$2" ]; then
    printf '%s' "$2" | tr 'A-F' 'a-f'
    return
  fi
  if [ ! -f "$WORK/SHA256SUMS" ]; then
    case $SOURCE in
      /*) [ -f "$SOURCE/SHA256SUMS" ] && cp "$SOURCE/SHA256SUMS" "$WORK/SHA256SUMS" ;;
      *) curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/SHA256SUMS" "$SOURCE/SHA256SUMS" 2>/dev/null || true ;;
    esac
  fi
  [ -f "$WORK/SHA256SUMS" ] || return 0
  awk -v f="$1" '$2 == f || $2 == "*" f { print tolower($1); exit }' "$WORK/SHA256SUMS"
}

# fetch_verified NAME OVERRIDE VARIABLE: fetches NAME and refuses it unless its sha256
# matches. A malformed pin in VARIABLE is an input error; a malformed SHA256SUMS line is
# a refused archive.
fetch_verified() {
  case $2 in
    '') _bad=$EX_DATAERR ;;
    *) _bad=$EX_USAGE ;;
  esac
  _want=$(expected_sha "$1" "$2")
  case $_want in
    '') die $EX_DATAERR "no sha256 for $1: provide SHA256SUMS in the source or set $3" ;;
    *[!0-9a-f]*) die $_bad "the expected sha256 for $1 is not 64 hex digits" ;;
  esac
  [ ${#_want} -eq 64 ] || die $_bad "the expected sha256 for $1 is not 64 hex digits"
  fetch "$1"
  _have=$(sha256_of "$WORK/$1")
  [ "$_have" = "$_want" ] || die $EX_DATAERR "sha256 mismatch for $1: expected $_want, got $_have; nothing installed"
  say "verified $1 ($_have)"
}

# --- install --------------------------------------------------------------------

install_cli() {
  _plat=$(platform)
  _name=optimal-$VERSION-$_plat
  fetch_verified "$_name.tar.gz" "${OPTIMAL_CLI_SHA256:-}" OPTIMAL_CLI_SHA256
  mkdir -p "$WORK/cli"
  tar -xzf "$WORK/$_name.tar.gz" -C "$WORK/cli" || die $EX_DATAERR "cannot unpack $_name.tar.gz"
  _dir=$WORK/cli/$_name
  [ -f "$_dir/optimal" ] || die $EX_DATAERR "$_name.tar.gz holds no $_name/optimal"
  [ "$(cat "$_dir/VERSION" 2>/dev/null)" = "$VERSION" ] || die $EX_DATAERR "$_name.tar.gz is not version $VERSION"

  mkdir -p "$PREFIX/bin"
  cp "$_dir/optimal" "$PREFIX/bin/optimal.tmp.$$"
  chmod 0755 "$PREFIX/bin/optimal.tmp.$$"
  mv -f "$PREFIX/bin/optimal.tmp.$$" "$OPTIMAL"
  ln -sf optimal "$PREFIX/bin/oe"
  say "installed optimal $VERSION (alias oe) in $PREFIX/bin"
}

node_ok() {
  command -v node >/dev/null 2>&1 &&
    node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' 2>/dev/null
}

install_mcp() {
  node_ok || die $EX_UNAVAILABLE "the MCP server needs Node.js 20 or newer on PATH (OPTIMAL_CLIENT_SKIP_MCP=1 installs only the CLI)"
  _name=optimal-engine-mcp-$VERSION
  fetch_verified "$_name.tar.gz" "${OPTIMAL_MCP_SHA256:-}" OPTIMAL_MCP_SHA256
  mkdir -p "$WORK/mcp"
  tar -xzf "$WORK/$_name.tar.gz" -C "$WORK/mcp" || die $EX_DATAERR "cannot unpack $_name.tar.gz"
  # Archives from apps/mcp/build.sh hold one top directory; accept a flat one too.
  if [ -f "$WORK/mcp/$_name/dist/index.js" ]; then
    _root=$WORK/mcp/$_name
  elif [ -f "$WORK/mcp/dist/index.js" ]; then
    _root=$WORK/mcp
  else
    die $EX_DATAERR "$_name.tar.gz holds no dist/index.js"
  fi
  [ -d "$_root/node_modules" ] || die $EX_DATAERR "$_name.tar.gz holds no node_modules"

  mkdir -p "$PREFIX/bin"
  rm -rf "$PREFIX/mcp.new" "$PREFIX/mcp.old"
  cp -R "$_root" "$PREFIX/mcp.new"
  [ ! -d "$PREFIX/mcp" ] || mv "$PREFIX/mcp" "$PREFIX/mcp.old"
  mv "$PREFIX/mcp.new" "$PREFIX/mcp"
  rm -rf "$PREFIX/mcp.old"

  _node=$(command -v node)
  case $_node in /*) ;; *) _node=node ;; esac
  case $_node in *[\'\"\\\$\`[:space:]]*) _node=node ;; esac
  cat >"$LAUNCHER.tmp.$$" <<EOF
#!/bin/sh
# The Optimal Engine MCP server over stdio, installed by install-client.sh ($VERSION).
# It reads OPTIMAL_ENGINE_URL, OPTIMAL_ENGINE_API_KEY(_FILE), OPTIMAL_WORKSPACE or the profile.
node=\${OPTIMAL_MCP_NODE:-$_node}
command -v "\$node" >/dev/null 2>&1 || node=node
exec "\$node" '$PREFIX/mcp/dist/index.js' "\$@"
EOF
  chmod 0755 "$LAUNCHER.tmp.$$"
  mv -f "$LAUNCHER.tmp.$$" "$LAUNCHER"
  say "installed optimal-engine-mcp $VERSION in $PREFIX/mcp"
}

link_programs() {
  [ "$BIN_DIR" != none ] || return 0
  [ "$BIN_DIR" != "$PREFIX/bin" ] || return 0
  mkdir -p "$BIN_DIR"
  for _p in optimal oe optimal-engine-mcp; do
    [ -e "$PREFIX/bin/$_p" ] || continue
    ln -sf "$PREFIX/bin/$_p" "$BIN_DIR/$_p"
  done
  say "linked the programs into $BIN_DIR"
  case :${PATH:-}: in
    *:"$BIN_DIR":*) ;;
    *) warn "$BIN_DIR is not on PATH" ;;
  esac
}

cmd_install() {
  command -v curl >/dev/null 2>&1 || warn "curl is not installed; optimal needs curl 7.55 or newer"
  install_cli
  if [ "${OPTIMAL_CLIENT_SKIP_MCP:-0}" = 1 ]; then
    say "MCP server skipped (OPTIMAL_CLIENT_SKIP_MCP=1)"
  else
    install_mcp
  fi
  printf '%s\n' "$VERSION" >"$PREFIX/VERSION"
  link_programs
}

# --- configure ------------------------------------------------------------------

# True when the installed CLI and MCP server read key_file= from a profile.
reads_key_file() {
  [ -f "$OPTIMAL" ] && grep -q 'key_file' "$OPTIMAL" || return 1
  [ ! -f "$PREFIX/mcp/dist/config.js" ] || grep -q 'key_file' "$PREFIX/mcp/dist/config.js"
}

cmd_configure() {
  _url=${OPTIMAL_ENGINE_URL:-}
  if [ -z "$_url" ]; then
    say "no profile written: OPTIMAL_ENGINE_URL is not set (the client reads the environment directly)"
    return 0
  fi
  case $_url in
    http://?* | https://?*) ;;
    *) die $EX_USAGE "OPTIMAL_ENGINE_URL must start with http:// or https://" ;;
  esac
  for _v in "$_url" "${OPTIMAL_ENGINE_API_KEY_FILE:-}" "${OPTIMAL_WORKSPACE:-}"; do
    case $_v in *'
'*) die $EX_USAGE "OPTIMAL_ENGINE_URL, OPTIMAL_ENGINE_API_KEY_FILE and OPTIMAL_WORKSPACE must be single lines" ;; esac
  done

  _dir=${XDG_CONFIG_HOME:-${HOME:?HOME is not set}/.config}/optimal
  (umask 077 && mkdir -p "$_dir")
  chmod 0700 "$_dir"
  _new=$_dir/profile.new.$$
  (
    umask 077
    {
      printf '# Written by install-client.sh. A key_file is read each time the key is used.\n'
      printf 'url=%s\n' "$_url"
      if [ -n "${OPTIMAL_ENGINE_API_KEY_FILE:-}" ]; then
        [ -r "$OPTIMAL_ENGINE_API_KEY_FILE" ] || die $EX_NOINPUT "cannot read OPTIMAL_ENGINE_API_KEY_FILE $OPTIMAL_ENGINE_API_KEY_FILE"
        if reads_key_file; then
          printf 'key_file=%s\n' "$OPTIMAL_ENGINE_API_KEY_FILE"
        else
          # A client that predates key_file= needs the key itself in its profile.
          printf 'key=%s\n' "$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$OPTIMAL_ENGINE_API_KEY_FILE")"
        fi
      elif [ -n "${OPTIMAL_ENGINE_API_KEY:-}" ]; then
        case $OPTIMAL_ENGINE_API_KEY in *'
'*) die $EX_USAGE "OPTIMAL_ENGINE_API_KEY contains a line break" ;; esac
        printf 'key=%s\n' "$OPTIMAL_ENGINE_API_KEY"
      fi
      [ -z "${OPTIMAL_WORKSPACE:-}" ] || printf 'workspace=%s\n' "$OPTIMAL_WORKSPACE"
    } >"$_new"
  ) || {
    _rc=$?
    rm -f "$_new"
    exit "$_rc"
  }
  chmod 0600 "$_new"

  _profile=$_dir/profile
  if [ -f "$_profile" ] && cmp -s "$_new" "$_profile"; then
    rm -f "$_new"
    say "profile $_profile is already current"
    return 0
  fi
  if [ -f "$_profile" ]; then
    mv -f "$_profile" "$_profile.previous"
    chmod 0600 "$_profile.previous"
    say "kept the earlier profile as $_profile.previous"
  fi
  mv -f "$_new" "$_profile"
  say "wrote $_profile (mode 0600)"
}

# --- register -------------------------------------------------------------------

register_claude() {
  command -v claude >/dev/null 2>&1 || return 0
  claude mcp remove --scope user optimal-engine >/dev/null 2>&1 || true
  if claude mcp add --scope user optimal-engine -- "$LAUNCHER" >"$WORK/claude.out" 2>&1; then
    say "registered optimal-engine with Claude Code (user scope)"
  else
    sed 's/^/  /' "$WORK/claude.out" >&2
    die $EX_CANTCREAT "could not register optimal-engine with Claude Code"
  fi
}

# Codex reads [mcp_servers.<name>] tables from $CODEX_HOME/config.toml. The table for
# optimal-engine (and any sub-table of it) is replaced; everything else is kept.
register_codex() {
  _home=${CODEX_HOME:-${HOME:?HOME is not set}/.codex}
  command -v codex >/dev/null 2>&1 || [ -d "$_home" ] || return 0
  mkdir -p "$_home"
  _conf=$_home/config.toml
  [ -f "$_conf" ] || : >"$_conf"
  awk '
    /^[[:space:]]*\[/ { skip = ($0 ~ /^[[:space:]]*\[mcp_servers\.("optimal-engine"|optimal-engine)(\]|\.)/) }
    !skip { print }
  ' "$_conf" >"$WORK/codex.toml"
  # Drop trailing blank lines before appending the table.
  awk 'NF { for (; blank > 0; blank--) print ""; print; next } { blank++ }' "$WORK/codex.toml" >"$WORK/codex.trim"
  {
    cat "$WORK/codex.trim"
    [ ! -s "$WORK/codex.trim" ] || printf '\n'
    printf '[mcp_servers.optimal-engine]\ncommand = "%s"\n' "$LAUNCHER"
  } >"$WORK/codex.new"
  cat "$WORK/codex.new" >"$_conf"
  say "registered optimal-engine with Codex ($_conf)"
}

cmd_register() {
  if [ "${OPTIMAL_CLIENT_REGISTER_MCP:-1}" = 0 ]; then
    say "MCP registration skipped (OPTIMAL_CLIENT_REGISTER_MCP=0)"
    return 0
  fi
  if [ ! -x "$LAUNCHER" ]; then
    say "MCP registration skipped: $LAUNCHER is not installed"
    return 0
  fi
  register_claude
  register_codex
}

# --- verify ---------------------------------------------------------------------

engine_configured() {
  [ -n "${OPTIMAL_ENGINE_URL:-}${OE_API:-}${OPTIMAL_ENGINE_API_URL:-}${OPTIMAL_PROFILE:-}" ] ||
    [ -f "${XDG_CONFIG_HOME:-${HOME:-}/.config}/optimal/profile" ]
}

verify_mcp() {
  _init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"install-client","version":"'$VERSION'"}}}'
  # A FIFO keeps the server's stdin open until its answer is read.
  mkfifo "$WORK/mcp.in"
  "$LAUNCHER" <"$WORK/mcp.in" >"$WORK/mcp.out" 2>"$WORK/mcp.err" &
  _pid=$!
  exec 3>"$WORK/mcp.in"
  printf '%s\n' "$_init" >&3
  _i=0
  while [ $_i -lt 150 ]; do
    grep -q '"serverInfo"' "$WORK/mcp.out" 2>/dev/null && break
    kill -0 "$_pid" 2>/dev/null || break
    sleep 0.1 2>/dev/null || sleep 1
    _i=$((_i + 1))
  done
  exec 3>&-
  kill "$_pid" 2>/dev/null || true
  wait "$_pid" 2>/dev/null || true
  if grep -q '"serverInfo":{"name":"optimal-engine"' "$WORK/mcp.out"; then
    _mv=$(sed -nE 's/.*"serverInfo":\{"name":"optimal-engine","version":"([^"]*)".*/\1/p' "$WORK/mcp.out" | head -1)
    say "ok: optimal-engine-mcp ${_mv:-?} answers initialize"
  else
    tail -n 5 "$WORK/mcp.err" | sed 's/^/  /' >&2
    die $EX_SOFTWARE "optimal-engine-mcp did not answer initialize"
  fi
}

cmd_verify() {
  [ -x "$OPTIMAL" ] || die $EX_SOFTWARE "$OPTIMAL is not installed"
  _v=$("$OPTIMAL" --version) || die $EX_SOFTWARE "optimal --version failed"
  [ "$_v" = "optimal $VERSION" ] || die $EX_SOFTWARE "optimal --version says '$_v', expected 'optimal $VERSION'"
  _v=$("$PREFIX/bin/oe" --version) || die $EX_SOFTWARE "oe --version failed"
  [ "$_v" = "oe $VERSION" ] || die $EX_SOFTWARE "oe --version says '$_v', expected 'oe $VERSION'"
  say "ok: optimal $VERSION (oe $VERSION)"

  if [ -x "$LAUNCHER" ]; then
    verify_mcp
  fi

  if ! engine_configured; then
    say "Engine checks skipped: no OPTIMAL_ENGINE_URL or profile on this machine yet"
    return 0
  fi
  # The Engine checks exit with the CLI's own code (77 key refused, 69 unreachable, ...).
  _url=$("$OPTIMAL" url) || die $? "the client configuration is invalid"
  # `api` rather than `whoami`, so a client older than the whoami command verifies too.
  "$OPTIMAL" api GET /api/auth/whoami --raw >"$WORK/whoami.json" ||
    die $? "optimal whoami failed against $_url (see the message above)"
  _auth=$(sed -nE 's/.*"authenticated":[[:space:]]*(true|false).*/\1/p' "$WORK/whoami.json" | head -1)
  _scope=$(sed -nE 's/.*"workspace_scope":[[:space:]]*(\[[^]]*\]).*/\1/p' "$WORK/whoami.json" | head -1)
  say "ok: whoami against $_url (authenticated: ${_auth:-unknown}, workspaces: ${_scope:-unknown})"
  "$OPTIMAL" search "${OPTIMAL_CLIENT_VERIFY_QUERY:-optimal}" --limit 1 --raw >/dev/null ||
    die $? "optimal search failed against $_url (see the message above)"
  say "ok: search against $_url"
}

# --- main -----------------------------------------------------------------------

[ $# -gt 0 ] || set -- install configure register verify
for _cmd in "$@"; do
  case $_cmd in
    install | configure | register | verify) ;;
    -h | --help | help)
      sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die $EX_USAGE "unknown command '$_cmd' (install, configure, register, verify)" ;;
  esac
done
for _cmd in "$@"; do
  "cmd_$_cmd"
done
