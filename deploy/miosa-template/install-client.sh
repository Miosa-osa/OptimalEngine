#!/bin/sh
# Installs the Optimal Engine client on a machine: the `optimal` CLI (alias `oe`) and the
# Engine MCP server, from a pinned Engine release, with every archive's sha256 verified.
#
#   OPTIMAL_CLIENT_SOURCE=<dir or https base URL> deploy/miosa-template/install-client.sh
#
# Commands, run in the order given (default: install configure register verify):
#   install    fetch, check and unpack both archives in a scratch directory, copy them into
#              the prefix beside the installed files, then rename them all into place; the
#              installer itself goes to <prefix>/bin/install-client.sh (from 0.3.3 the copy
#              in the CLI archive, so an upgrade refreshes it). One install runs at a time
#              in a prefix (<prefix>/.install.lock, waited for, taken over once stale).
#              The MCP server and its launcher are replaced or removed only when they
#              carry this installer's marks, and a program link only where none exists,
#              a link is dangling, or a link points into an Optimal prefix.
#   configure  write the client profile from OPTIMAL_ENGINE_URL, OPTIMAL_ENGINE_API_KEY_FILE
#              (or OPTIMAL_ENGINE_API_KEY) and OPTIMAL_WORKSPACE; nothing when the URL is unset
#   register   register the MCP server with Claude Code and Codex when they are installed
#   verify     optimal --version, the MCP server's initialize answer, and with an Engine
#              configured: whoami and one search, from the profile and from the environment
#
# Inputs (environment):
#   OPTIMAL_CLIENT_VERSION   release to install (default: the version below); for the other
#                            commands, the installed <prefix>/VERSION
#   OPTIMAL_CLIENT_SOURCE    required for install: the absolute directory or https base URL
#                            holding optimal-<v>-<os>-<arch>.tar.gz,
#                            optimal-engine-mcp-<v>.tar.gz and SHA256SUMS, such as the
#                            Engine release staging directory; http:// only with both
#                            sha256 pins
#   OPTIMAL_CLI_SHA256, OPTIMAL_MCP_SHA256   expected sha256 of the two archives, from a
#                            manifest you trust. Without them SHA256SUMS from the same source
#                            decides, which catches a corrupt download but not a changed
#                            source. An archive with no expected sha256, or another one, is
#                            never installed.
#   OPTIMAL_CLIENT_PREFIX    install root: bin/optimal, bin/oe, bin/optimal-engine-mcp,
#                            bin/install-client.sh, mcp/, VERSION. Default: the prefix this
#                            script is installed in; else /opt/optimal
#                            (OPTIMAL_CLIENT_SYSTEM_PREFIX) for root, and for other users
#                            when it holds an install (or, for install, can be written);
#                            else ~/.local/share/optimal
#   OPTIMAL_CLIENT_BIN_DIR   where optimal, oe and optimal-engine-mcp are linked (default
#                            /usr/local/bin for root or when writable, else ~/.local/bin;
#                            "none" links nothing)
#   OPTIMAL_CLIENT_SKIP_MCP=1       install only the CLI (no Node.js needed); an MCP server
#                                   this installer put in the prefix is removed
#   OPTIMAL_CLIENT_REGISTER_MCP=0   do not register the MCP server with any harness
#   OPTIMAL_CLIENT_VERIFY_QUERY     the search verify runs (default "optimal")
#   OPTIMAL_CLIENT_LOCK_WAIT        seconds install waits for another install's lock
#                                   (default 60), then exits 75
#   OPTIMAL_CLIENT_BREAK_LOCK=1     take the lock over whoever holds it
#   OPTIMAL_MCP_NODE         read by the installed launcher: the node that runs the MCP
#                            server (default: the node found at install, else node on PATH)
#
# configure and register act for the user running them ($HOME, XDG_CONFIG_HOME, CODEX_HOME).
# The API key is never printed or passed as an argument. The profile is mode 0600 in a 0700
# directory. With OPTIMAL_ENGINE_API_KEY_FILE set it names that file (key_file=, for clients
# from 0.3.3 on) and OPTIMAL_ENGINE_API_KEY is not written; programs that read the
# environment use OPTIMAL_ENGINE_API_KEY first. As root, configure and register write only
# into a directory root owns that is not a symlink nor writable by others, whose parent
# root owns, and never through a symlinked Codex config.toml; run them as each agent user.
# Exit status: 0 when every requested command succeeded; 64 usage or input error; 65 an
# archive refused (no expected sha256, a mismatch, wrong contents or version); 66 the key
# file cannot be read; 69 something unavailable (the source, curl, a sha256 tool,
# Node.js 20+); 70 nothing installed, <prefix>/VERSION unreadable, or the installed client
# or MCP server failed its check; 73 the prefix, a program link or a harness registration
# could not be written, or a path is not this installer's to replace (the earlier install
# and harness settings stay as they were); 75 another install kept the prefix's lock
# past OPTIMAL_CLIENT_LOCK_WAIT.
# The Engine checks in verify exit with the CLI's code: 77 key refused, 69 Engine
# unreachable, 64 workspace required, 78 bad configuration, 1 other.
set -eu
umask 022

DEFAULT_VERSION=0.3.12
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
EX_TEMPFAIL=75

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

# is_version V: true when V is exactly three dot-separated numbers (1.2.3).
is_version() {
  case $1 in
    *[!0-9.]* | .* | *. | *..* | *.*.*.*) return 1 ;;
    *.*.*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- commands -------------------------------------------------------------------

[ $# -gt 0 ] || set -- install configure register verify
INSTALLING=
for _cmd in "$@"; do
  case $_cmd in
    install) INSTALLING=1 ;;
    configure | register | verify) ;;
    -h | --help | help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) die $EX_USAGE "unknown command '$_cmd' (install, configure, register, verify)" ;;
  esac
done

# --- prefix and version ---------------------------------------------------------

writable() { [ -w "$1" ] || { [ ! -e "$1" ] && [ -w "$(dirname "$1")" ]; }; }

SELF=$0
SELF_DIR=$(cd "$(dirname "$SELF")" 2>/dev/null && pwd) || SELF_DIR=
IS_ROOT=
[ "$(id -u 2>/dev/null)" != 0 ] || IS_ROOT=1

if [ -n "${OPTIMAL_CLIENT_PREFIX:-}" ]; then
  PREFIX=$OPTIMAL_CLIENT_PREFIX
elif [ -n "$SELF_DIR" ] && [ "${SELF_DIR##*/}" = bin ] && [ -f "$SELF_DIR/../VERSION" ] &&
  [ -f "$SELF_DIR/optimal" ]; then
  # This is the copy `install` put in <prefix>/bin.
  PREFIX=$(cd "$SELF_DIR/.." && pwd)
elif [ -n "$IS_ROOT" ]; then
  # root acts for the whole machine, never for its own home; install creates the prefix.
  PREFIX=$SYSTEM_PREFIX
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
  is_version "$VERSION" || die $EX_USAGE "OPTIMAL_CLIENT_VERSION must look like 1.2.3, not '$VERSION'"
elif [ -z "$INSTALLING" ] && [ -f "$PREFIX/VERSION" ]; then
  VERSION=$(sed -n 1p "$PREFIX/VERSION") || VERSION=
  is_version "$VERSION" ||
    die $EX_SOFTWARE "$PREFIX/VERSION does not hold a version like 1.2.3; install again, or set OPTIMAL_CLIENT_VERSION"
else
  VERSION=$DEFAULT_VERSION
fi

SOURCE=${OPTIMAL_CLIENT_SOURCE:-}
SOURCE=${SOURCE%/}

OPTIMAL=$PREFIX/bin/optimal
LAUNCHER=$PREFIX/bin/optimal-engine-mcp
# The launcher's first comment line, and the file in mcp/, that mark both as this
# installer's: only what carries one is replaced or removed.
LAUNCHER_MARK='# The Optimal Engine MCP server over stdio, installed by install-client.sh'
MCP_MARK_FILE=.install-client
MCP_MARK='optimal-engine-mcp, installed by install-client.sh'
# install copies into the prefix under this suffix, then renames; until the renames are
# done, an exit removes the copies and puts back an MCP server it had moved aside.
NEW=.new.$$
LOCK=$PREFIX/.install.lock
LOCK_OWNER=
LOCKED=
STAGING=
CODEX_TMP=

WORK=$(mktemp -d "${TMPDIR:-/tmp}/optimal-client.XXXXXX")

# remove PATH...: rm -rf, after making what is under PATH writable: a read-only
# directory (node_modules has them) would stop rm -rf partway.
remove() {
  for _r in "$@"; do
    [ -e "$_r" ] || [ -L "$_r" ] || continue
    [ -L "$_r" ] || chmod -R u+w "$_r" 2>/dev/null || :
    rm -rf "$_r" || return 1
  done
}

unstage() {
  remove "$PREFIX/mcp$NEW" "$PREFIX/bin/optimal$NEW" "$PREFIX/bin/oe$NEW" "$LAUNCHER$NEW" \
    "$PREFIX/bin/install-client.sh$NEW" "$PREFIX/VERSION$NEW" || :
}

cleanup() {
  if [ -n "$STAGING" ]; then
    # Interrupted between the two MCP renames: the installed server goes back.
    if [ ! -e "$PREFIX/mcp" ] && [ ! -L "$PREFIX/mcp" ] && [ -d "$PREFIX/mcp.old$NEW" ]; then
      mv "$PREFIX/mcp.old$NEW" "$PREFIX/mcp" ||
        warn "the earlier MCP server is in $PREFIX/mcp.old$NEW; move it back to $PREFIX/mcp"
    fi
    unstage
  fi
  unlock || :
  [ -z "$CODEX_TMP" ] || rm -f "$CODEX_TMP" || :
  remove "$WORK" || :
}
trap cleanup EXIT
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
    *[!0-9a-f]*) die "$_bad" "the expected sha256 for $1 is not 64 hex digits" ;;
  esac
  [ ${#_want} -eq 64 ] || die "$_bad" "the expected sha256 for $1 is not 64 hex digits"
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
  # From 0.3.3 the CLI archive carries the installer of its release; older ones get this copy.
  if [ -f "$CLI_DIR/install-client.sh" ]; then
    INSTALLER=$CLI_DIR/install-client.sh
  elif [ -f "$SELF" ] && [ -r "$SELF" ]; then
    INSTALLER=$SELF
  else
    INSTALLER=
    warn "cannot copy this script ($SELF) to $PREFIX/bin"
  fi
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

# cant_write PATH: ends the install when the prefix cannot take a file (a full disk, no
# permission). Before the renames the cleanup removes the copies, so nothing has changed.
cant_write() {
  die $EX_CANTCREAT "cannot write $1; the installed client is unchanged"
}

# cant_rename PATH: a rename failed after others were done.
cant_rename() {
  die $EX_CANTCREAT "cannot rename the new copy over $1; the install in $PREFIX is incomplete, run install again"
}

launcher() {
  _node=$(command -v node) || _node=node
  case $_node in /*) ;; *) _node=node ;; esac
  case $_node in *[\'\"\\\$\`[:space:]]*) _node=node ;; esac
  cat <<EOF
#!/bin/sh
$LAUNCHER_MARK ($VERSION).
# It reads OPTIMAL_ENGINE_URL, OPTIMAL_ENGINE_API_KEY(_FILE), OPTIMAL_WORKSPACE or the profile.
node=\${OPTIMAL_MCP_NODE:-$_node}
command -v "\$node" >/dev/null 2>&1 || node=node
exec "\$node" '$PREFIX/mcp/dist/index.js' "\$@"
EOF
}

# marked_launcher: true when the launcher is a file whose first comment line is this
# installer's.
marked_launcher() {
  [ -f "$LAUNCHER" ] && [ ! -L "$LAUNCHER" ] || return 1
  case $(sed -n 2p "$LAUNCHER" 2>/dev/null) in
    "$LAUNCHER_MARK ("*").") return 0 ;;
  esac
  return 1
}

# marked_mcp: true when mcp/ is a directory holding this installer's mark file.
marked_mcp() {
  [ -d "$PREFIX/mcp" ] && [ ! -L "$PREFIX/mcp" ] &&
    [ "$(sed -n 1p "$PREFIX/mcp/$MCP_MARK_FILE" 2>/dev/null)" = "$MCP_MARK" ]
}

foreign() {
  die $EX_CANTCREAT "$1 was not installed by install-client.sh, so it is neither replaced nor removed; move it away or set another OPTIMAL_CLIENT_PREFIX"
}

# check_mcp_owner: the MCP server and its launcher are replaced or removed only when this
# installer put them there. The launcher must carry its first comment line; mcp/ its mark
# file or that launcher beside it (an install from before the mark file has only the
# launcher's line). Each mark is written before its rename, so an interrupted install
# still owns what it left. Anything else is left alone, with exit 73.
check_mcp_owner() {
  if [ -e "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; then
    marked_launcher || foreign "$LAUNCHER"
  fi
  if [ -e "$PREFIX/mcp" ] || [ -L "$PREFIX/mcp" ]; then
    marked_mcp || marked_launcher || foreign "$PREFIX/mcp"
  fi
}

# pid_dead PID: true only when PID is provably not running. kill -0 also fails for
# another user's process, so /proc or ps decides, and anything unknown counts as alive.
pid_dead() {
  ! kill -0 "$1" 2>/dev/null || return 1
  if [ -d /proc/self ]; then
    [ ! -d "/proc/$1" ]
  elif _pids=$(ps -A -o pid= 2>/dev/null); then
    # shellcheck disable=SC2086 # one pid per word
    ! printf '%s\n' $_pids | grep -qx "$1"
  else
    return 1
  fi
}

# The lock is a symbolic link, <prefix>/.install.lock, whose target is its holder:
# "pid=<pid> host=<host> boot=<boot id> ns=<pid namespace> at=<epoch seconds>". ln -s
# creates it with its owner in one step, or fails because another install holds it, and
# readlink reads the owner in one step; no install ever sees a lock without its owner.
LOCK_MAX_AGE=900

# lock_field OWNER NAME: the value of NAME= in an owner string, or nothing.
lock_field() {
  printf ' %s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"
}

boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id
  else
    sysctl -n kern.bootsessionuuid 2>/dev/null || echo unknown
  fi
}

# lock_stale OWNER: true when a lock held by OWNER may be taken over, with the reason in
# STALE_WHY: it is older than 15 minutes, whoever holds it; or its holder ran on this
# host before the last boot; or its holder is on this host, boot and pid namespace and
# provably not running. Anything else (another host, another namespace, an owner that
# cannot be read, a pid that is not a number) counts as alive.
lock_stale() {
  _at=$(lock_field "$1" at)
  case $_at in
    '' | *[!0-9]*) _old=$(find "$LOCK" -prune -mmin +$((LOCK_MAX_AGE / 60)) 2>/dev/null) ;;
    *) _old=$([ $(($(date +%s) - _at)) -le "$LOCK_MAX_AGE" ] || echo old) ;;
  esac
  if [ -n "$_old" ]; then
    STALE_WHY="it is older than $((LOCK_MAX_AGE / 60)) minutes"
    return 0
  fi
  [ "$(lock_field "$1" host)" = "$HOST" ] || return 1
  _boot=$(lock_field "$1" boot)
  if [ -n "$_boot" ] && [ "$_boot" != unknown ] && [ "$BOOT" != unknown ] && [ "$_boot" != "$BOOT" ]; then
    STALE_WHY="its install ran before this machine last started"
    return 0
  fi
  [ "$(lock_field "$1" ns)" = "$PIDNS" ] || return 1
  _pid=$(lock_field "$1" pid)
  case $_pid in '' | *[!0-9]*) return 1 ;; esac
  pid_dead "$_pid" || return 1
  STALE_WHY="install $_pid is no longer running"
}

# A lock is removed, whether taken over or released, only under a second lock, the mutex
# <prefix>/.install.lock.takeover, held for the few steps of one removal. Under it the lock
# is read again and removed only while it is the one judged, and while the mutex is still
# this install's; a lock is never moved aside, so there is no moment in which a fresh
# holder's lock is gone and another install takes the prefix too. A mutex older than
# MUTEX_MAX_AGE seconds was left by an install killed while it held it, and is cleared.
MUTEX=$LOCK.takeover
MUTEX_MAX_AGE=30
MUTEX_OWNER=

# mutex: takes the mutex, trying for about three seconds; false when another install
# keeps it.
mutex() {
  MUTEX_OWNER="pid=$$ at=$(date +%s)"
  _tries=0
  while :; do
    if { [ ! -d "$MUTEX" ] || [ -L "$MUTEX" ]; } && ln -sn "$MUTEX_OWNER" "$MUTEX" 2>/dev/null; then
      return 0
    fi
    _tries=$((_tries + 1))
    [ "$_tries" -lt 30 ] || return 1
    if _m=$(readlink "$MUTEX" 2>/dev/null) && mutex_stale "$_m"; then
      clear_mutex "$_m"
    else
      sleep 0.1 2>/dev/null || sleep 1
    fi
  done
}

# mutex_stale OWNER: true when the mutex OWNER holds is older than MUTEX_MAX_AGE seconds.
mutex_stale() {
  _mat=$(lock_field "$1" at)
  case $_mat in
    '' | *[!0-9]*) [ -n "$(find "$MUTEX" -prune -mmin +1 2>/dev/null)" ] ;;
    *) [ $(($(date +%s) - _mat)) -gt "$MUTEX_MAX_AGE" ] ;;
  esac
}

# clear_mutex STALE: moves the mutex aside, under this install's own name, and removes it
# only when what moved is STALE, the mutex judged stale. A mutex another install cleared
# and took meanwhile is put back, so clearing a stale mutex never takes a fresh one from
# its holder (who checks it still holds it before removing anything).
clear_mutex() {
  _aside=$MUTEX.stale.$$
  mv "$MUTEX" "$_aside" 2>/dev/null || return 0
  _moved=$(readlink "$_aside" 2>/dev/null) || _moved=
  if [ -n "$_moved" ] && [ "$_moved" != "$1" ]; then
    ln -sn "$_moved" "$MUTEX" 2>/dev/null || :
  fi
  rm -f "$_aside" || :
}

# own_mutex: true while the mutex is still this install's.
own_mutex() {
  [ -n "$MUTEX_OWNER" ] && [ "$(readlink "$MUTEX" 2>/dev/null)" = "$MUTEX_OWNER" ]
}

# release_mutex: removes the mutex while it is this install's own.
release_mutex() {
  if own_mutex; then rm -f "$MUTEX" || :; fi
  MUTEX_OWNER=
}

# take_over HELD [FORCE]: removes the lock judged stale, HELD being its owner, under the
# mutex, while it is still HELD and still stale (with FORCE, while it is still HELD), and
# the mutex is still this install's. 1 when the lock changed meanwhile, 2 when the mutex
# stayed held.
take_over() {
  mutex || return 2
  _now=$(readlink "$LOCK" 2>/dev/null) || _now=
  _taken=1
  if [ "$_now" = "$1" ] && { [ -n "${2:-}" ] || lock_stale "$_now"; } && own_mutex &&
    rm -f "$LOCK"; then
    _taken=0
  fi
  release_mutex
  return $_taken
}

# lock: one install at a time in a prefix. A held lock is waited for, up to
# OPTIMAL_CLIENT_LOCK_WAIT seconds (default 60), then install exits 75. A stale one
# (lock_stale) is taken over with a warning; OPTIMAL_CLIENT_BREAK_LOCK=1 takes over any.
lock() {
  mkdir -p "$PREFIX" || cant_write "$PREFIX"
  HOST=$(hostname 2>/dev/null || uname -n)
  BOOT=$(boot_id)
  PIDNS=$(readlink "/proc/$$/ns/pid" 2>/dev/null) || PIDNS=unknown
  LOCK_OWNER="pid=$$ host=$HOST boot=$BOOT ns=$PIDNS at=$(date +%s)"
  _wait=${OPTIMAL_CLIENT_LOCK_WAIT:-60}
  case $_wait in '' | *[!0-9]*) die $EX_USAGE "OPTIMAL_CLIENT_LOCK_WAIT must be a whole number of seconds" ;; esac
  _break=${OPTIMAL_CLIENT_BREAK_LOCK:-0}
  _waited=0 _takeovers=0 _gone=0
  # Set first, so that an exit at any point releases a lock this install took (unlock
  # removes only its own).
  LOCKED=1
  while :; do
    # ln -s into an existing directory would create a link inside it.
    if { [ ! -d "$LOCK" ] || [ -L "$LOCK" ]; } && ln -sn "$LOCK_OWNER" "$LOCK" 2>/dev/null; then
      return 0
    fi
    if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then
      # Released since ln failed, so ln is tried again; a lock that is never there means
      # ln cannot write here.
      _gone=$((_gone + 1))
      [ "$_gone" -lt 5 ] || cant_write "$LOCK"
      continue
    fi
    _gone=0
    _held=$(readlink "$LOCK" 2>/dev/null) || _held=
    _why='' _force=''
    if [ "$_break" = 1 ]; then
      _why="OPTIMAL_CLIENT_BREAK_LOCK=1" _force=1
    elif lock_stale "$_held"; then
      _why=$STALE_WHY
    fi
    if [ -n "$_why" ] && [ "$_takeovers" -lt 3 ]; then
      _tr=0
      take_over "$_held" "$_force" || _tr=$?
      if [ "$_tr" = 0 ]; then
        warn "took over $LOCK (${_held:-no owner recorded}): $_why"
        _break=0
        continue
      fi
      # Only a takeover that found the lock changed counts against the cap; one that could
      # not take the mutex waits its turn below.
      if [ "$_tr" = 1 ]; then
        _takeovers=$((_takeovers + 1))
        continue
      fi
    fi
    if [ "$_waited" -ge "$_wait" ]; then
      die $EX_TEMPFAIL "another install holds $LOCK (${_held:-no owner recorded}); run install again when it ends, or set OPTIMAL_CLIENT_BREAK_LOCK=1 if it is gone"
    fi
    [ "$_waited" -gt 0 ] || say "waiting up to ${_wait}s for the install holding $LOCK"
    sleep 1
    _waited=$((_waited + 1))
  done
}

# unlock: removes the lock while it is this install's own, under the mutex, so that a lock
# another install took meanwhile is never removed. When the mutex stays held, the lock is
# left for the next install to take over as stale once this one has exited.
unlock() {
  release_mutex
  [ -n "$LOCKED" ] || return 0
  LOCKED=
  [ "$(readlink "$LOCK" 2>/dev/null)" = "$LOCK_OWNER" ] || return 0
  mutex || return 0
  if [ "$(readlink "$LOCK" 2>/dev/null)" = "$LOCK_OWNER" ] && own_mutex; then
    rm -f "$LOCK" || :
  fi
  release_mutex
}

# sweep: a run killed outright (SIGKILL, a power cut) leaves its copies behind, or the MCP
# server between its two renames. Under the lock, what provably dead runs left under this
# installer's own names is removed, and such a server is put back when the prefix has
# none; a server that cannot be put back is kept.
sweep() {
  for _left in "$PREFIX"/mcp.old.new.* "$PREFIX"/mcp.new.* "$PREFIX"/VERSION.new.* \
    "$PREFIX"/bin/optimal.new.* "$PREFIX"/bin/oe.new.* "$PREFIX"/bin/optimal-engine-mcp.new.* \
    "$PREFIX"/bin/install-client.sh.new.* "$MUTEX".stale.*; do
    [ -e "$_left" ] || [ -L "$_left" ] || continue
    _pid=${_left##*.}
    case $_pid in '' | *[!0-9]*) continue ;; esac
    [ "$_pid" != $$ ] || continue
    pid_dead "$_pid" || continue
    case $_left in
      "$PREFIX"/mcp.old.new.*)
        if [ ! -e "$PREFIX/mcp" ] && [ ! -L "$PREFIX/mcp" ]; then
          if mv "$_left" "$PREFIX/mcp"; then
            warn "put back $PREFIX/mcp, which an interrupted install had left as $_left"
          else
            warn "cannot put $_left back as $PREFIX/mcp; it is kept"
          fi
          continue
        fi
        ;;
    esac
    remove "$_left" || warn "cannot remove $_left, left by an interrupted install"
  done
}

# copy_in: copies everything into the prefix under the $NEW suffix, beside the installed
# files. This is the step that needs space; a failure leaves the install as it was.
copy_in() {
  lock
  sweep
  check_mcp_owner
  STAGING=1
  unstage
  mkdir -p "$PREFIX/bin" || cant_write "$PREFIX/bin"
  cp "$CLI_DIR/optimal" "$PREFIX/bin/optimal$NEW" && chmod 0755 "$PREFIX/bin/optimal$NEW" ||
    cant_write "$OPTIMAL"
  ln -s optimal "$PREFIX/bin/oe$NEW" || cant_write "$PREFIX/bin/oe"
  if [ -n "$MCP_DIR" ]; then
    cp -R "$MCP_DIR" "$PREFIX/mcp$NEW" && chmod u+w "$PREFIX/mcp$NEW" &&
      printf '%s\n%s\n' "$MCP_MARK" "$VERSION" >"$PREFIX/mcp$NEW/$MCP_MARK_FILE" ||
      cant_write "$PREFIX/mcp"
    launcher >"$LAUNCHER$NEW" && chmod 0755 "$LAUNCHER$NEW" || cant_write "$LAUNCHER"
  fi
  if [ -n "$INSTALLER" ]; then
    cp "$INSTALLER" "$PREFIX/bin/install-client.sh$NEW" &&
      chmod 0755 "$PREFIX/bin/install-client.sh$NEW" || cant_write "$PREFIX/bin/install-client.sh"
  fi
  printf '%s\n' "$VERSION" >"$PREFIX/VERSION$NEW" || cant_write "$PREFIX/VERSION"
}

# move_in: renames the copies over the installed files, the MCP server first and VERSION
# last. A rename in the same directory needs no space, so these fail only when something
# else changes the prefix meanwhile.
move_in() {
  if [ -n "$MCP_DIR" ]; then
    if [ -d "$PREFIX/mcp" ]; then
      mv "$PREFIX/mcp" "$PREFIX/mcp.old$NEW" || cant_write "$PREFIX/mcp"
      # Anything standing there now would take the new server inside it.
      if [ -e "$PREFIX/mcp" ] || [ -L "$PREFIX/mcp" ]; then
        cant_rename "$PREFIX/mcp"
      fi
      if ! mv "$PREFIX/mcp$NEW" "$PREFIX/mcp"; then
        mv "$PREFIX/mcp.old$NEW" "$PREFIX/mcp" && cant_write "$PREFIX/mcp"
        cant_rename "$PREFIX/mcp"
      fi
      # A failure here must not stop the renames halfway; the next install sweeps it.
      remove "$PREFIX/mcp.old$NEW" ||
        warn "cannot remove $PREFIX/mcp.old$NEW; the next install removes it"
    else
      mv "$PREFIX/mcp$NEW" "$PREFIX/mcp" || cant_rename "$PREFIX/mcp"
    fi
    mv -f "$LAUNCHER$NEW" "$LAUNCHER" || cant_rename "$LAUNCHER"
  elif [ -e "$LAUNCHER" ] || [ -L "$LAUNCHER" ] || [ -e "$PREFIX/mcp" ] || [ -L "$PREFIX/mcp" ]; then
    # A CLI-only install leaves no MCP server of another version behind. mcp/ goes first:
    # while it is left, the marked launcher still shows it is this installer's.
    if remove "$PREFIX/mcp" && rm -f "$LAUNCHER"; then
      say "removed the earlier MCP server from $PREFIX"
    else
      warn "cannot remove the earlier MCP server from $PREFIX; the next install tries again"
    fi
  fi
  mv -f "$PREFIX/bin/optimal$NEW" "$OPTIMAL" || cant_rename "$OPTIMAL"
  mv -f "$PREFIX/bin/oe$NEW" "$PREFIX/bin/oe" || cant_rename "$PREFIX/bin/oe"
  if [ -n "$INSTALLER" ]; then
    mv -f "$PREFIX/bin/install-client.sh$NEW" "$PREFIX/bin/install-client.sh" ||
      cant_rename "$PREFIX/bin/install-client.sh"
  fi
  mv -f "$PREFIX/VERSION$NEW" "$PREFIX/VERSION" || cant_rename "$PREFIX/VERSION"
  STAGING=
}

# replaceable_link PATH NAME: true when PATH is a link install may replace: a dangling
# one, or a link into an Optimal prefix. That is a link whose target (absolute, or
# relative to the link's directory) is a regular file <root>/bin/NAME, where
# <root>/VERSION holds a version like 1.2.3 and <root>/bin/optimal is the client CLI.
replaceable_link() {
  [ -L "$1" ] || return 1
  _target=$(readlink "$1") || return 1
  case $_target in
    /*) ;;
    *) _target=$(dirname "$1")/$_target ;;
  esac
  if [ ! -e "$_target" ]; then
    # Dangling only when that is known: the nearest directory above the target that
    # exists can be searched. Behind one that cannot, the target may well exist.
    _up=$(dirname "$_target")
    while [ ! -e "$_up" ] && [ "$_up" != / ] && [ "$_up" != . ]; do _up=$(dirname "$_up"); done
    [ -d "$_up" ] && [ -x "$_up" ]
    return
  fi
  [ -f "$_target" ] || return 1
  case $_target in
    */bin/"$2") _root=${_target%/bin/"$2"} ;;
    *) return 1 ;;
  esac
  is_version "$(sed -n 1p "$_root/VERSION" 2>/dev/null)" &&
    grep -q '^OPTIMAL_CLI_VERSION=' "$_root/bin/optimal" 2>/dev/null
}

link_programs() {
  if [ -n "${OPTIMAL_CLIENT_BIN_DIR:-}" ]; then
    BIN_DIR=$OPTIMAL_CLIENT_BIN_DIR
  elif [ -n "$IS_ROOT" ] || [ -w /usr/local/bin ]; then
    BIN_DIR=/usr/local/bin
  else
    BIN_DIR=${HOME:?HOME is not set}/.local/bin
  fi
  [ "$BIN_DIR" != none ] || return 0
  [ "$BIN_DIR" != "$PREFIX/bin" ] || return 0
  _where="the client is installed in $PREFIX/bin"
  mkdir -p "$BIN_DIR" || die $EX_CANTCREAT "cannot create $BIN_DIR; $_where"
  _linked='' _skipped=''
  for _p in optimal oe optimal-engine-mcp; do
    _link=$BIN_DIR/$_p
    if [ -e "$PREFIX/bin/$_p" ]; then
      # Short names such as oe can belong to another program: only an absent entry, a
      # dangling link or a link into an Optimal prefix is replaced.
      if [ -e "$_link" ] || [ -L "$_link" ]; then
        if ! replaceable_link "$_link" "$_p"; then
          warn "$_link exists and is not a link into an Optimal prefix; it is left as it is (run $PREFIX/bin/$_p)"
          _skipped="$_skipped $_p"
          continue
        fi
        # rm, then ln -s: ln -sf over a link to a directory would write inside it.
        rm -f "$_link" || die $EX_CANTCREAT "cannot replace $_link; $_where"
      fi
      ln -s "$PREFIX/bin/$_p" "$_link" || die $EX_CANTCREAT "cannot link $_link; $_where"
      _linked="$_linked $_p"
    elif [ -L "$_link" ] && [ "$(readlink "$_link")" = "$PREFIX/bin/$_p" ]; then
      rm -f "$_link"
    fi
  done
  if [ -n "$_linked" ]; then
    say "linked$_linked into $BIN_DIR"
  elif [ -n "$_skipped" ]; then
    warn "linked nothing into $BIN_DIR, whose entries belong to something else; run the programs from $PREFIX/bin, or set OPTIMAL_CLIENT_BIN_DIR"
  fi
  case :${PATH:-}: in
    *:"$BIN_DIR":*) ;;
    *) warn "$BIN_DIR is not on PATH" ;;
  esac
}

cmd_install() {
  [ -n "$SOURCE" ] ||
    die $EX_USAGE "OPTIMAL_CLIENT_SOURCE is required for install: the absolute directory or https base URL holding the release files, such as the Engine release staging directory"
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
  # Before anything is fetched; copy_in checks again under the lock.
  check_mcp_owner
  if [ -z "${OPTIMAL_CLI_SHA256:-}" ] || { [ -n "$_mcp" ] && [ -z "${OPTIMAL_MCP_SHA256:-}" ]; }; then
    load_sums
  fi

  stage_cli
  MCP_DIR=
  [ -z "$_mcp" ] || stage_mcp

  copy_in
  move_in
  unlock
  say "installed optimal $VERSION (alias oe) in $PREFIX/bin"
  if [ -n "$_mcp" ]; then
    say "installed optimal-engine-mcp $VERSION in $PREFIX/mcp"
  else
    say "MCP server skipped (OPTIMAL_CLIENT_SKIP_MCP=1)"
  fi
  [ -z "$INSTALLER" ] ||
    say "installed $PREFIX/bin/install-client.sh for configure, register and verify"
  link_programs
}

# --- configure ------------------------------------------------------------------

# root_guard WHAT DIR...: as root, WHAT writes under DIR only when DIR, if it exists, is a
# directory root owns, not a symlink and not writable by group or others, and DIR's
# parent is owned by root. Anything else another user could swap, or point anywhere,
# while root writes, so it exits 73. Higher ancestors are not checked: run configure and
# register as each agent user instead.
root_guard() {
  [ -n "$IS_ROOT" ] || return 0
  _what=$1
  shift
  for _d in "$@"; do
    [ -n "$_d" ] || continue
    # /var/ is /var: a trailing slash would make [ -L ] and ls look through a symlink.
    while [ "${_d%/}" != "$_d" ] && [ "$_d" != / ]; do _d=${_d%/}; done
    _parent=$(dirname "$_d")
    _pinfo=$(ls -ndL "$_parent" 2>/dev/null) || _pinfo=
    if [ -n "$_pinfo" ]; then
      _owner=$(printf '%s\n' "$_pinfo" | awk '{ print $3 }')
      [ "$_owner" = 0 ] ||
        die $EX_CANTCREAT "as root, $_what does not write under $_parent, which uid $_owner owns; run $_what as that user"
      # Others who can write the parent can swap DIR, unless the parent is sticky
      # (as /tmp is) and DIR already exists.
      case ${_pinfo%% *} in
        ?????w* | ????????w*)
          case ${_pinfo%% *} in
            ?????????[tT]*) [ -e "$_d" ] || [ -L "$_d" ] ||
              die $EX_CANTCREAT "as root, $_what does not create $_d under $_parent, which others can write" ;;
            *) die $EX_CANTCREAT "as root, $_what does not write under $_parent, which group or others can write" ;;
          esac
          ;;
      esac
    fi
    [ -e "$_d" ] || [ -L "$_d" ] || continue
    [ ! -L "$_d" ] ||
      die $EX_CANTCREAT "as root, $_what does not write through the symlink $_d; run $_what as the user it belongs to"
    _info=$(ls -nd "$_d" 2>/dev/null) || _info=
    _owner=$(printf '%s\n' "$_info" | awk '{ print $3 }')
    [ "$_owner" = 0 ] ||
      die $EX_CANTCREAT "as root, $_what does not write into $_d, which uid ${_owner:-unknown} owns; run $_what as that user"
    case ${_info%% *} in
      ?????w* | ????????w*)
        die $EX_CANTCREAT "as root, $_what does not write into $_d, which group or others can write"
        ;;
    esac
  done
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
  if [ -n "$_kf" ] && [ -n "${OPTIMAL_ENGINE_API_KEY:-}" ]; then
    warn "OPTIMAL_ENGINE_API_KEY and OPTIMAL_ENGINE_API_KEY_FILE are both set: the profile names the file, while programs that read the environment use OPTIMAL_ENGINE_API_KEY"
  fi

  # The installed client decides; clients before 0.3.3 do not read key_file=.
  _cv=$VERSION
  [ ! -f "$PREFIX/VERSION" ] || _cv=$(sed -n 1p "$PREFIX/VERSION")
  is_version "$_cv" || _cv=$VERSION

  _base=${XDG_CONFIG_HOME:-${HOME:?HOME is not set}/.config}
  _dir=$_base/optimal
  root_guard configure "$_base" "$_dir"
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
  # claude writes its user scope into ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json.
  root_guard register "${CLAUDE_CONFIG_DIR:-${HOME:-}}"
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

# resolve_link PATH: the file PATH ends at after its symlinks, so a symlinked config is
# rewritten where it lives and stays a symlink.
resolve_link() {
  _t=$1 _n=0
  while [ -L "$_t" ]; do
    _n=$((_n + 1))
    [ "$_n" -le 40 ] || return 1
    _l=$(readlink "$_t") || return 1
    case $_l in
      /*) _t=$_l ;;
      *) _t=$(dirname "$_t")/$_l ;;
    esac
  done
  printf '%s\n' "$_t"
}

# Codex reads [mcp_servers.<name>] tables from $CODEX_HOME/config.toml and gives a stdio
# server only a fixed environment plus the names in env_vars. The optimal-engine table
# (and its sub-tables, however spaced or quoted) is replaced; everything else is kept.
# Every step is checked: a config that cannot be read, filtered or replaced is left as
# it was and the script exits 73.
register_codex() {
  if [ -n "${CODEX_HOME:-}" ]; then
    _home=$CODEX_HOME
  elif [ -n "${HOME:-}" ]; then
    _home=$HOME/.codex
  else
    say "Codex skipped: neither CODEX_HOME nor HOME is set"
    return 0
  fi
  _cv=
  if command -v codex >/dev/null 2>&1; then
    _cv=$(codex_version)
  elif [ ! -d "$_home" ]; then
    say "Codex skipped: codex is not on PATH and $_home does not exist"
    return 0
  fi
  _env_vars=1
  if [ -n "$_cv" ] && ! version_ge "$_cv" "$CODEX_ENV_VARS_SINCE"; then
    _env_vars=
    warn "Codex $_cv predates env_vars ($CODEX_ENV_VARS_SINCE): the server gets only Codex's default environment and reads the profile"
  fi
  # As root: a CODEX_HOME root owns, and never a config.toml another user could point
  # anywhere.
  root_guard register "$_home"
  if [ -n "$IS_ROOT" ] && [ -L "$_home/config.toml" ]; then
    die $EX_CANTCREAT "as root, register does not write through the symlink $_home/config.toml; run register as the user it belongs to"
  fi
  if [ ! -d "$_home" ]; then
    (umask 077 && mkdir -p "$_home") || die $EX_CANTCREAT "cannot create $_home"
    chmod 0700 "$_home" || :
  fi
  _conf=$_home/config.toml
  _file=$(resolve_link "$_conf") || die $EX_CANTCREAT "cannot follow the symlink $_conf"
  if [ -e "$_file" ]; then
    [ -f "$_file" ] || die $EX_CANTCREAT "$_conf is not a regular file; it is unchanged"
    [ -r "$_file" ] && [ -w "$_file" ] ||
      die $EX_CANTCREAT "cannot read and write $_conf (check its owner and mode); it is unchanged"
  fi
  _tmp=$_file.tmp.$$
  CODEX_TMP=$_tmp
  _failed="could not write $_conf; it is unchanged"
  rm -f "$_tmp"
  # Private from the start: the kept settings may hold other servers' credentials.
  (umask 077 && : >"$_tmp") || die $EX_CANTCREAT "$_failed"
  if [ -f "$_file" ]; then
    awk '
      /^[[:space:]]*\[/ {
        skip = ($0 ~ /^[[:space:]]*\[[[:space:]]*"?mcp_servers"?[[:space:]]*\.[[:space:]]*"?optimal-engine"?[[:space:]]*(\]|\.)/)
      }
      skip { next }
      NF { for (; blank > 0; blank--) print ""; print; next }
      { blank++ }
    ' "$_file" >"$_tmp" || die $EX_CANTCREAT "$_failed"
    [ ! -s "$_tmp" ] || printf '\n' >>"$_tmp" || die $EX_CANTCREAT "$_failed"
  fi
  _table="[mcp_servers.optimal-engine]
command = \"$LAUNCHER\""
  [ -z "$_env_vars" ] || _table="$_table
env_vars = [$MCP_ENV_VARS]"
  printf '%s\n' "$_table" >>"$_tmp" || die $EX_CANTCREAT "$_failed"
  mv -f "$_tmp" "$_file" || die $EX_CANTCREAT "$_failed"
  CODEX_TMP=
  say "registered optimal-engine with Codex ($_conf)"
  [ -n "$_cv" ] ||
    warn "Codex version unknown (codex is not on PATH, or its --version names none): wrote env_vars, which Codex reads from $CODEX_ENV_VARS_SINCE"
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

# engine_check profile|environment: whoami, then one search. For the profile, the Engine
# settings in the environment are set aside, so the check proves what the profile holds;
# for the environment, the CLI runs as a process with this environment would.
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

  # Both, when both exist: later processes get one or the other.
  _cfg=${XDG_CONFIG_HOME:-${HOME:-}/.config}/optimal
  _checked=
  if [ -n "${OPTIMAL_PROFILE:-}" ] || [ -f "$_cfg/profile" ]; then
    engine_check profile
    _checked=1
  fi
  if [ -n "${OPTIMAL_ENGINE_URL:-}${OE_API:-}${OPTIMAL_ENGINE_API_URL:-}" ]; then
    engine_check environment
    _checked=1
  fi
  [ -n "$_checked" ] || say "Engine checks skipped: no OPTIMAL_ENGINE_URL or profile on this machine yet"
}

# --- main -----------------------------------------------------------------------

for _cmd in "$@"; do
  "cmd_$_cmd"
done
