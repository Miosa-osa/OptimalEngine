#!/bin/sh
# Installs the Optimal Engine client on a machine: the `optimal` CLI (alias `oe`) and the
# Engine MCP server, from a pinned Engine release, with every archive's sha256 verified.
#
#   OPTIMAL_CLIENT_SOURCE=<dir or https base URL> deploy/miosa-template/install-client.sh
#
# Commands, run in the order given (default: install configure register verify):
#   install    fetch, check and stage both archives, then put them in place together, and
#              copy this script to <prefix>/bin/install-client.sh
#   configure  write the client profile from OPTIMAL_ENGINE_URL, OPTIMAL_ENGINE_API_KEY_FILE
#              (or OPTIMAL_ENGINE_API_KEY) and OPTIMAL_WORKSPACE; nothing when the URL is unset
#   register   register the MCP server with Claude Code and Codex (0.47.0 or newer) when
#              they are installed
#   verify     optimal --version, the MCP server's initialize answer, and with an Engine
#              configured: whoami and one search, from the profile when there is one
#
# Inputs (environment):
#   OPTIMAL_CLIENT_VERSION   release to install (default: the version below); for the other
#                            commands, the installed <prefix>/VERSION
#   OPTIMAL_CLIENT_SOURCE    absolute directory or https base URL holding
#                            optimal-<v>-<os>-<arch>.tar.gz, optimal-engine-mcp-<v>.tar.gz
#                            and SHA256SUMS (default: the GitHub release v<version>);
#                            http:// only with both sha256 pins
#   OPTIMAL_CLI_SHA256, OPTIMAL_MCP_SHA256   expected sha256 of the two archives; without
#                            them SHA256SUMS from the source decides. An archive with no
#                            expected sha256, or another one, is never installed.
#   OPTIMAL_CLIENT_PREFIX    install root: bin/optimal, bin/oe, bin/optimal-engine-mcp,
#                            bin/install-client.sh, mcp/, VERSION. Default: the prefix this
#                            script is installed in; else /opt/optimal
#                            (OPTIMAL_CLIENT_SYSTEM_PREFIX) when it holds an install (or,
#                            for install, can be written); else ~/.local/share/optimal
#   OPTIMAL_CLIENT_BIN_DIR   where optimal, oe and optimal-engine-mcp are linked (default
#                            /usr/local/bin when writable, else ~/.local/bin; "none" links nothing)
#   OPTIMAL_CLIENT_SKIP_MCP=1       install only the CLI (no Node.js needed)
#   OPTIMAL_CLIENT_REGISTER_MCP=0   do not register the MCP server with any harness
#   OPTIMAL_CLIENT_VERIFY_QUERY     the search verify runs (default "optimal")
#
# configure and register act for the user running them ($HOME, XDG_CONFIG_HOME, CODEX_HOME).
# The API key is never printed or passed as an argument. The profile is mode 0600 in a 0700
# directory; with OPTIMAL_ENGINE_API_KEY_FILE it names the file (key_file=) instead of
# copying the key, for clients from 0.3.3 on.
# Exit status: 0 when every requested command succeeded; 64 usage or input error; 65 an
# archive refused (no expected sha256, a mismatch, wrong contents or version); 66 the key
# file cannot be read; 69 something unavailable (the source, curl, a sha256 tool,
# Node.js 20+); 70 nothing installed, or the installed client or MCP server failed its
# check; 73 a harness registration could not be written. The Engine checks in verify exit
# with the CLI's code: 77 key refused, 69 Engine unreachable, 64 workspace required,
# 78 bad configuration, 1 other.
set -eu
umask 022

DEFAULT_VERSION=0.3.3
RELEASES=https://github.com/Miosa-osa/OptimalEngine/releases/download
SYSTEM_PREFIX=${OPTIMAL_CLIENT_SYSTEM_PREFIX:-/opt/optimal}
# The first release whose CLI and MCP server read key_file= and report the Engine version.
VERSIONED_SINCE=0.3.3
# The first Codex release that forwards env_vars to a stdio MCP server.
CODEX_ENV_VARS_SINCE=0.47.0
MCP_ENV_VARS='"OPTIMAL_ENGINE_URL", "OPTIMAL_ENGINE_API_KEY", "OPTIMAL_ENGINE_API_KEY_FILE", "OPTIMAL_WORKSPACE", "OPTIMAL_PROFILE", "XDG_CONFIG_HOME"'

EX_USAGE=64
EX_DATAERR=65
EX_NOINPUT=66
EX_UNAVAILABLE=69
EX_SOFTWARE=70
EX_CANTCREAT=73

say() { printf 'install-client: %s\n' "$*"; }
warn() { printf 'install-client: warning: %s\n' "$*" >&2; }

# die CODE MESSAGE...: prints the message and exits with CODE.
die() {
  _code=$1
  shift
  printf 'install-client: %s\n' "$*" >&2
  exit "$_code"
}

# version_ge A B: true when version A is B or newer (both are N.N.N).
version_ge() {
  _a1=${1%%.*} _ar=${1#*.}
  _b1=${2%%.*} _br=${2#*.}
  _a2=${_ar%%.*} _a3=${_ar#*.}
  _b2=${_br%%.*} _b3=${_br#*.}
  [ "$_a1" -ne "$_b1" ] && { [ "$_a1" -gt "$_b1" ]; return; }
  [ "$_a2" -ne "$_b2" ] && { [ "$_a2" -gt "$_b2" ]; return; }
  [ "$_a3" -ge "$_b3" ]
}

is_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

# --- commands -------------------------------------------------------------------

[ $# -gt 0 ] || set -- install configure register verify
INSTALLING=
for _cmd in "$@"; do
  case $_cmd in
    install) INSTALLING=1 ;;
    configure | register | verify) ;;
    -h | --help | help)
      sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die $EX_USAGE "unknown command '$_cmd' (install, configure, register, verify)" ;;
  esac
done

# --- prefix and version ---------------------------------------------------------

writable() { [ -w "$1" ] || { [ ! -e "$1" ] && [ -w "$(dirname "$1")" ]; }; }

SELF=$0
SELF_DIR=$(cd "$(dirname "$SELF")" 2>/dev/null && pwd) || SELF_DIR=

if [ -n "${OPTIMAL_CLIENT_PREFIX:-}" ]; then
  PREFIX=$OPTIMAL_CLIENT_PREFIX
elif [ -n "$SELF_DIR" ] && [ "${SELF_DIR##*/}" = bin ] && [ -f "$SELF_DIR/../VERSION" ] &&
  [ -f "$SELF_DIR/optimal" ]; then
  # This is the copy `install` put in <prefix>/bin.
  PREFIX=$(cd "$SELF_DIR/.." && pwd)
elif [ -n "$INSTALLING" ] && writable "$SYSTEM_PREFIX"; then
  PREFIX=$SYSTEM_PREFIX
elif [ -z "$INSTALLING" ] && [ -f "$SYSTEM_PREFIX/VERSION" ]; then
  PREFIX=$SYSTEM_PREFIX
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

if [ -n "${OPTIMAL_CLIENT_VERSION:-}" ]; then
  VERSION=$OPTIMAL_CLIENT_VERSION
elif [ -z "$INSTALLING" ] && [ -f "$PREFIX/VERSION" ]; then
  VERSION=$(sed -n 1p "$PREFIX/VERSION")
else
  VERSION=$DEFAULT_VERSION
fi
is_version "$VERSION" || die $EX_USAGE "OPTIMAL_CLIENT_VERSION must look like 1.2.3, not '$VERSION'"

SOURCE=${OPTIMAL_CLIENT_SOURCE:-$RELEASES/v$VERSION}
SOURCE=${SOURCE%/}

OPTIMAL=$PREFIX/bin/optimal
LAUNCHER=$PREFIX/bin/optimal-engine-mcp

WORK=$(mktemp -d "${TMPDIR:-/tmp}/optimal-client.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# --- platform, source and checksums ---------------------------------------------

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

# download NAME DEST: 0 when fetched, 1 when the source answers 404. Anything else (no
# answer, another status) means the source is unavailable.
download() {
  case $SOURCE in
    https://*) set -- "$1" "$2" --proto =https --proto-redir =https --tlsv1.2 ;;
    *) set -- "$1" "$2" --proto =http,https --proto-redir =http,https ;;
  esac
  _dl_name=$1 _dl_dest=$2
  shift 2
  _dl_status=$(curl -sS -L "$@" --retry 3 --retry-delay 2 -o "$_dl_dest" -w '%{http_code}' \
    "$SOURCE/$_dl_name") || die $EX_UNAVAILABLE "cannot reach $SOURCE for $_dl_name"
  case $_dl_status in
    200) return 0 ;;
    404)
      rm -f "$_dl_dest"
      return 1
      ;;
    *) die $EX_UNAVAILABLE "$SOURCE/$_dl_name answered HTTP $_dl_status" ;;
  esac
}

# fetch NAME: copies or downloads NAME from the source into $WORK.
fetch() {
  case $SOURCE in
    https://* | http://*)
      download "$1" "$WORK/$1" || die $EX_UNAVAILABLE "$SOURCE/$1 does not exist (HTTP 404)"
      ;;
    *)
      [ -f "$SOURCE/$1" ] || die $EX_UNAVAILABLE "$SOURCE/$1 does not exist"
      cp "$SOURCE/$1" "$WORK/$1" || die $EX_UNAVAILABLE "cannot copy $SOURCE/$1"
      ;;
  esac
}

# load_sums: SHA256SUMS from the source into $WORK, when the source has one.
load_sums() {
  case $SOURCE in
    https://* | http://*) download SHA256SUMS "$WORK/SHA256SUMS" || : ;;
    *) [ ! -f "$SOURCE/SHA256SUMS" ] || cp "$SOURCE/SHA256SUMS" "$WORK/SHA256SUMS" ;;
  esac
}

# fetch_verified NAME PIN VARIABLE: fetches NAME and refuses it unless its sha256 is the
# pin or its SHA256SUMS line. A malformed pin is an input error; a malformed line refuses.
fetch_verified() {
  if [ -n "$2" ]; then
    _want=$(printf '%s' "$2" | tr 'A-F' 'a-f')
    _bad=$EX_USAGE
  elif [ -f "$WORK/SHA256SUMS" ]; then
    _want=$(awk -v f="$1" '$2 == f || $2 == "*" f { print tolower($1); exit }' "$WORK/SHA256SUMS")
    _bad=$EX_DATAERR
  else
    _want=
  fi
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

node_ok() {
  command -v node >/dev/null 2>&1 &&
    node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' 2>/dev/null
}

# stage_cli: the CLI archive, verified and unpacked in $WORK; sets CLI_DIR.
stage_cli() {
  _name=optimal-$VERSION-$(platform)
  fetch_verified "$_name.tar.gz" "${OPTIMAL_CLI_SHA256:-}" OPTIMAL_CLI_SHA256
  mkdir -p "$WORK/cli"
  tar -xzf "$WORK/$_name.tar.gz" -C "$WORK/cli" 2>/dev/null || die $EX_DATAERR "cannot unpack $_name.tar.gz"
  CLI_DIR=$WORK/cli/$_name
  [ -f "$CLI_DIR/optimal" ] || die $EX_DATAERR "$_name.tar.gz holds no $_name/optimal"
  [ "$(cat "$CLI_DIR/VERSION" 2>/dev/null)" = "$VERSION" ] || die $EX_DATAERR "$_name.tar.gz is not version $VERSION"
  _v=$(sh "$CLI_DIR/optimal" --version 2>/dev/null) || _v=
  [ "$_v" = "optimal $VERSION" ] || die $EX_DATAERR "the optimal in $_name.tar.gz says '$_v', not 'optimal $VERSION'"
}

# stage_mcp: the MCP server archive, verified and unpacked in $WORK; sets MCP_DIR.
stage_mcp() {
  _name=optimal-engine-mcp-$VERSION
  fetch_verified "$_name.tar.gz" "${OPTIMAL_MCP_SHA256:-}" OPTIMAL_MCP_SHA256
  mkdir -p "$WORK/mcp"
  tar -xzf "$WORK/$_name.tar.gz" -C "$WORK/mcp" 2>/dev/null || die $EX_DATAERR "cannot unpack $_name.tar.gz"
  # Archives from apps/mcp/build.sh hold one top directory; accept a flat one too.
  if [ -f "$WORK/mcp/$_name/dist/index.js" ]; then
    MCP_DIR=$WORK/mcp/$_name
  elif [ -f "$WORK/mcp/dist/index.js" ]; then
    MCP_DIR=$WORK/mcp
  else
    die $EX_DATAERR "$_name.tar.gz holds no dist/index.js"
  fi
  [ -d "$MCP_DIR/node_modules" ] || die $EX_DATAERR "$_name.tar.gz holds no node_modules"
  if [ -f "$MCP_DIR/VERSION" ]; then
    _v=$(sed -n 1p "$MCP_DIR/VERSION")
  else
    _v=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$MCP_DIR/package.json" 2>/dev/null | head -1)
  fi
  if [ "$_v" != "$VERSION" ]; then
    # Before 0.3.3 the MCP server kept a version of its own.
    version_ge "$VERSION" "$VERSIONED_SINCE" &&
      die $EX_DATAERR "$_name.tar.gz holds MCP server version '$_v', not $VERSION"
    warn "$_name.tar.gz holds MCP server version '${_v:-unknown}' (versioned with the Engine from $VERSIONED_SINCE)"
  fi
}

# put_cli, put_mcp, put_self: move the staged files into the prefix.
put_cli() {
  cp "$CLI_DIR/optimal" "$PREFIX/bin/optimal.tmp.$$"
  chmod 0755 "$PREFIX/bin/optimal.tmp.$$"
  mv -f "$PREFIX/bin/optimal.tmp.$$" "$OPTIMAL"
  ln -sf optimal "$PREFIX/bin/oe"
  say "installed optimal $VERSION (alias oe) in $PREFIX/bin"
}

put_mcp() {
  rm -rf "$PREFIX/mcp.new" "$PREFIX/mcp.old"
  cp -R "$MCP_DIR" "$PREFIX/mcp.new"
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

put_self() {
  if [ -f "$SELF" ] && [ -r "$SELF" ]; then
    cp "$SELF" "$PREFIX/bin/install-client.sh.tmp.$$"
    chmod 0755 "$PREFIX/bin/install-client.sh.tmp.$$"
    mv -f "$PREFIX/bin/install-client.sh.tmp.$$" "$PREFIX/bin/install-client.sh"
    say "installed $PREFIX/bin/install-client.sh for configure, register and verify"
  else
    warn "cannot copy this script ($SELF) to $PREFIX/bin"
  fi
}

link_programs() {
  if [ -n "${OPTIMAL_CLIENT_BIN_DIR:-}" ]; then
    BIN_DIR=$OPTIMAL_CLIENT_BIN_DIR
  elif [ -w /usr/local/bin ]; then
    BIN_DIR=/usr/local/bin
  else
    BIN_DIR=${HOME:?HOME is not set}/.local/bin
  fi
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
  _mcp=1
  [ "${OPTIMAL_CLIENT_SKIP_MCP:-0}" != 1 ] || _mcp=
  # Everything that can refuse the install runs before anything is replaced.
  if [ -n "$_mcp" ]; then
    node_ok || die $EX_UNAVAILABLE "the MCP server needs Node.js 20 or newer on PATH (OPTIMAL_CLIENT_SKIP_MCP=1 installs only the CLI)"
  fi
  case $SOURCE in
    https://*) ;;
    http://*)
      [ -n "${OPTIMAL_CLI_SHA256:-}" ] && { [ -z "$_mcp" ] || [ -n "${OPTIMAL_MCP_SHA256:-}" ]; } ||
        die $EX_USAGE "an http:// source needs OPTIMAL_CLI_SHA256 and OPTIMAL_MCP_SHA256"
      ;;
    /*) ;;
    *) die $EX_USAGE "OPTIMAL_CLIENT_SOURCE must be an absolute directory or an https URL" ;;
  esac
  case $SOURCE in
    http://* | https://*)
      command -v curl >/dev/null 2>&1 || die $EX_UNAVAILABLE "curl is required to download from $SOURCE"
      ;;
  esac
  command -v curl >/dev/null 2>&1 || warn "curl is not installed; optimal needs curl 7.55 or newer"
  if [ -z "${OPTIMAL_CLI_SHA256:-}" ] || { [ -n "$_mcp" ] && [ -z "${OPTIMAL_MCP_SHA256:-}" ]; }; then
    load_sums
  fi

  stage_cli
  [ -z "$_mcp" ] || stage_mcp

  mkdir -p "$PREFIX/bin"
  put_cli
  if [ -n "$_mcp" ]; then
    put_mcp
  else
    say "MCP server skipped (OPTIMAL_CLIENT_SKIP_MCP=1)"
  fi
  put_self
  printf '%s\n' "$VERSION" >"$PREFIX/VERSION"
  link_programs
}

# --- configure ------------------------------------------------------------------

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
  _kf=${OPTIMAL_ENGINE_API_KEY_FILE:-}
  if [ -n "$_kf" ]; then
    case $_kf in
      /*) ;;
      *) die $EX_USAGE "OPTIMAL_ENGINE_API_KEY_FILE must be an absolute path" ;;
    esac
    [ -f "$_kf" ] && [ -r "$_kf" ] || die $EX_NOINPUT "cannot read OPTIMAL_ENGINE_API_KEY_FILE $_kf (it must be a readable file)"
  fi
  case ${OPTIMAL_ENGINE_API_KEY:-} in *'
'*) die $EX_USAGE "OPTIMAL_ENGINE_API_KEY contains a line break" ;; esac

  # The installed client decides; clients before 0.3.3 do not read key_file=.
  _cv=$VERSION
  [ ! -f "$PREFIX/VERSION" ] || _cv=$(sed -n 1p "$PREFIX/VERSION")
  is_version "$_cv" || _cv=$VERSION

  _dir=${XDG_CONFIG_HOME:-${HOME:?HOME is not set}/.config}/optimal
  (umask 077 && mkdir -p "$_dir")
  chmod 0700 "$_dir"
  _new=$_dir/profile.new.$$
  (
    umask 077
    {
      printf '# Written by install-client.sh.\n'
      printf 'url=%s\n' "$_url"
      if [ -n "$_kf" ]; then
        if version_ge "$_cv" "$VERSIONED_SINCE"; then
          printf 'key_file=%s\n' "$_kf"
        else
          printf 'key=%s\n' "$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$_kf")"
        fi
      elif [ -n "${OPTIMAL_ENGINE_API_KEY:-}" ]; then
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
  if [ -n "$_kf" ] && ! version_ge "$_cv" "$VERSIONED_SINCE"; then
    say "wrote $_profile (mode 0600) with the key itself: optimal $_cv predates key_file="
  else
    say "wrote $_profile (mode 0600)"
  fi
}

# --- register -------------------------------------------------------------------

register_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    say "Claude Code skipped: claude is not on PATH"
    return 0
  fi
  claude mcp remove --scope user optimal-engine >/dev/null 2>&1 || :
  if claude mcp add --scope user optimal-engine -- "$LAUNCHER" >"$WORK/claude.out" 2>&1; then
    say "registered optimal-engine with Claude Code (user scope)"
  else
    sed 's/^/  /' "$WORK/claude.out" >&2
    die $EX_CANTCREAT "could not register optimal-engine with Claude Code"
  fi
}

codex_version() {
  codex --version 2>/dev/null | sed -n 's/.*[^0-9.]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1
}

# Codex reads [mcp_servers.<name>] tables from $CODEX_HOME/config.toml and gives a stdio
# server only a fixed environment plus the names in env_vars. The optimal-engine table
# (and its sub-tables, however spaced or quoted) is replaced; everything else is kept.
register_codex() {
  if [ -n "${CODEX_HOME:-}" ]; then
    _home=$CODEX_HOME
  elif [ -n "${HOME:-}" ]; then
    _home=$HOME/.codex
  else
    say "Codex skipped: neither CODEX_HOME nor HOME is set"
    return 0
  fi
  if ! command -v codex >/dev/null 2>&1 && [ ! -d "$_home" ]; then
    say "Codex skipped: codex is not on PATH and $_home does not exist"
    return 0
  fi
  _env_vars=1
  if command -v codex >/dev/null 2>&1; then
    _cv=$(codex_version)
    if [ -n "$_cv" ] && ! version_ge "$_cv" "$CODEX_ENV_VARS_SINCE"; then
      _env_vars=
      warn "Codex $_cv predates env_vars ($CODEX_ENV_VARS_SINCE): the server gets only Codex's default environment and reads the profile"
    fi
  fi
  if [ ! -d "$_home" ]; then
    (umask 077 && mkdir -p "$_home") || die $EX_CANTCREAT "cannot create $_home"
    chmod 0700 "$_home" || :
  fi
  _conf=$_home/config.toml
  _tmp=$_home/config.toml.tmp.$$
  (
    umask 077
    {
      if [ -f "$_conf" ]; then
        awk '
          /^[[:space:]]*\[/ {
            skip = ($0 ~ /^[[:space:]]*\[[[:space:]]*"?mcp_servers"?[[:space:]]*\.[[:space:]]*"?optimal-engine"?[[:space:]]*(\]|\.)/)
          }
          !skip { print }
        ' "$_conf" | awk 'NF { for (; blank > 0; blank--) print ""; print; next } { blank++ }'
        printf '\n'
      fi
      printf '[mcp_servers.optimal-engine]\ncommand = "%s"\n' "$LAUNCHER"
      [ -z "$_env_vars" ] || printf 'env_vars = [%s]\n' "$MCP_ENV_VARS"
    } >"$_tmp"
  ) && chmod 0600 "$_tmp" && mv -f "$_tmp" "$_conf" || {
    rm -f "$_tmp"
    die $EX_CANTCREAT "could not write $_conf"
  }
  say "registered optimal-engine with Codex ($_conf)"
}

cmd_register() {
  if [ "${OPTIMAL_CLIENT_REGISTER_MCP:-1}" = 0 ]; then
    say "MCP registration skipped (OPTIMAL_CLIENT_REGISTER_MCP=0)"
    return 0
  fi
  [ -f "$PREFIX/VERSION" ] ||
    die $EX_SOFTWARE "no client is installed in $PREFIX (run install, or set OPTIMAL_CLIENT_PREFIX)"
  if [ ! -x "$LAUNCHER" ]; then
    say "MCP registration skipped: $PREFIX was installed without the MCP server"
    return 0
  fi
  register_claude
  register_codex
}

# --- verify ---------------------------------------------------------------------

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
  kill "$_pid" 2>/dev/null || :
  wait "$_pid" 2>/dev/null || :
  if ! grep -q '"serverInfo":{"name":"optimal-engine"' "$WORK/mcp.out"; then
    tail -n 5 "$WORK/mcp.err" | sed 's/^/  /' >&2
    die $EX_SOFTWARE "optimal-engine-mcp did not answer initialize"
  fi
  _mv=$(sed -nE 's/.*"serverInfo":\{"name":"optimal-engine","version":"([^"]*)".*/\1/p' "$WORK/mcp.out" | head -1)
  if [ "$_mv" != "$VERSION" ]; then
    version_ge "$VERSION" "$VERSIONED_SINCE" &&
      die $EX_SOFTWARE "optimal-engine-mcp answers as version '$_mv', not $VERSION"
    warn "optimal-engine-mcp answers as version '${_mv:-unknown}' (versioned with the Engine from $VERSIONED_SINCE)"
  fi
  say "ok: optimal-engine-mcp ${_mv:-?} answers initialize"
}

# engine_check: whoami, then one search. With a profile, the Engine settings in the
# environment are set aside, so the check proves what the profile holds.
engine_check() {
  (
    if [ "$1" = profile ]; then
      unset OPTIMAL_ENGINE_URL OE_API OPTIMAL_ENGINE_API_URL OPTIMAL_ENGINE_API_KEY \
        OPTIMAL_ENGINE_API_KEY_FILE OPTIMAL_API_KEY OPTIMAL_WORKSPACE
    fi
    _url=$("$OPTIMAL" url) || die $? "the client configuration is invalid"
    # `api` rather than `whoami`, so a client older than the whoami command verifies too.
    "$OPTIMAL" api GET /api/auth/whoami --raw >"$WORK/whoami.json" ||
      die $? "optimal whoami failed against $_url (see the message above)"
    _auth=$(sed -nE 's/.*"authenticated":[[:space:]]*(true|false).*/\1/p' "$WORK/whoami.json" | head -1)
    _scope=$(sed -nE 's/.*"workspace_scope":[[:space:]]*(\[[^]]*\]).*/\1/p' "$WORK/whoami.json" | head -1)
    say "ok: whoami against $_url from the $1 (authenticated: ${_auth:-unknown}, workspaces: ${_scope:-unknown})"
    "$OPTIMAL" search "${OPTIMAL_CLIENT_VERIFY_QUERY:-optimal}" --limit 1 --raw >/dev/null ||
      die $? "optimal search failed against $_url (see the message above)"
    say "ok: search against $_url from the $1"
  )
}

cmd_verify() {
  [ -f "$PREFIX/VERSION" ] && [ -x "$OPTIMAL" ] ||
    die $EX_SOFTWARE "no client is installed in $PREFIX (run install, or set OPTIMAL_CLIENT_PREFIX)"
  _v=$("$OPTIMAL" --version) || die $EX_SOFTWARE "optimal --version failed"
  [ "$_v" = "optimal $VERSION" ] || die $EX_SOFTWARE "optimal --version says '$_v', expected 'optimal $VERSION'"
  _v=$("$PREFIX/bin/oe" --version) || die $EX_SOFTWARE "oe --version failed"
  [ "$_v" = "oe $VERSION" ] || die $EX_SOFTWARE "oe --version says '$_v', expected 'oe $VERSION'"
  say "ok: optimal $VERSION (oe $VERSION)"

  if [ -x "$LAUNCHER" ]; then
    verify_mcp
  fi

  _cfg=${XDG_CONFIG_HOME:-${HOME:-}/.config}/optimal
  if [ -n "${OPTIMAL_PROFILE:-}" ] || [ -f "$_cfg/profile" ]; then
    engine_check profile
  elif [ -n "${OPTIMAL_ENGINE_URL:-}${OE_API:-}${OPTIMAL_ENGINE_API_URL:-}" ]; then
    engine_check environment
  else
    say "Engine checks skipped: no OPTIMAL_ENGINE_URL or profile on this machine yet"
  fi
}

# --- main -----------------------------------------------------------------------

for _cmd in "$@"; do
  "cmd_$_cmd"
done
