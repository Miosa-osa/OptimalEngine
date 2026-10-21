"""Black-box checks for deploy/miosa-template/install-client.sh.

Each test runs the installer in a temporary HOME and prefix, from release files
built from this checkout (apps/cli/build.sh) and a minimal stand-in MCP server
archive, or from OPTIMAL_CLIENT_TEST_RELEASE_DIR when it names real release
files (apps/cli/build.sh and apps/mcp/build.sh output). The Engine is a local
fake; fake `claude` and `codex` programs record what registration does, and the
shared install location is a temporary directory. Nothing reaches a real
Engine, harness, /opt, or the network.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from test_optimal_cli import KEY, FakeEngine, mix_version

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / 'deploy' / 'miosa-template' / 'install-client.sh'
CLI = ROOT / 'apps' / 'cli' / 'optimal'
CLI_BUILD = ROOT / 'apps' / 'cli' / 'build.sh'
VERSION = mix_version()
MCP_ARCHIVE = f'optimal-engine-mcp-{VERSION}.tar.gz'
ENV_VARS = ('env_vars = ["OPTIMAL_ENGINE_URL", "OPTIMAL_ENGINE_API_KEY", "OPTIMAL_ENGINE_API_KEY_FILE", '
            '"OPTIMAL_WORKSPACE", "OPTIMAL_PROFILE", "XDG_CONFIG_HOME"]')


def node_ok():
    node = shutil.which('node')
    if not node:
        return False
    out = subprocess.run([node, '-p', 'process.versions.node.split(".")[0]'], capture_output=True, text=True)
    return out.returncode == 0 and int(out.stdout.strip() or 0) >= 20


NODE = node_ok()


def default_signals():
    """In the installer's process: HUP, INT and TERM at their defaults. A shell cannot
    trap a signal that was ignored when it started, as INT is under some runners."""
    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, signal.SIG_DFL)


def boot_id():
    try:
        return Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    except OSError:
        out = subprocess.run(['sysctl', '-n', 'kern.bootsessionuuid'], capture_output=True, text=True)
        return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else 'unknown'
# The shell that runs the installer: OPTIMAL_CLIENT_TEST_SHELL=dash (or bash) runs every case
# under that shell instead of sh.
INSTALL_SHELL = shutil.which(os.environ.get('OPTIMAL_CLIENT_TEST_SHELL', 'sh')) or 'sh'


def platform():
    system = subprocess.run(['uname', '-s'], capture_output=True, text=True).stdout.strip().lower()
    machine = subprocess.run(['uname', '-m'], capture_output=True, text=True).stdout.strip()
    return f"{system}-{ {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}[machine]}"


def stand_in_server(version):
    """Answers an MCP initialize the way the real server does, without npm."""
    return '''
const readline = require("node:readline");
const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const request = JSON.parse(line);
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: {
    protocolVersion: "2025-06-18", capabilities: {},
    serverInfo: { name: "optimal-engine", version: "%s" } } }) + "\\n");
});
''' % version


class QuietFiles(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_sums(out):
    lines = [f'{sha256(p)}  {p.name}' for p in sorted(Path(out).glob('*.tar.gz'))]
    (Path(out) / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')


def mcp_archive(out, version, reports=None, archive_version=None, flat=False, read_only=False):
    """A stand-in MCP server archive: one top directory, or flat like the 0.3.2 files; with
    read_only, node_modules holds a read-only package directory, as published packages may."""
    with tempfile.TemporaryDirectory() as stage:
        name = f'optimal-engine-mcp-{version}'
        root = Path(stage) if flat else Path(stage) / name
        (root / 'dist').mkdir(parents=True)
        (root / 'node_modules').mkdir()
        if read_only:
            package = root / 'node_modules' / 'read-only-package'
            package.mkdir()
            (package / 'index.js').write_text('module.exports = {};\n')
        (root / 'dist' / 'index.js').write_text(stand_in_server(reports or version))
        (root / 'package.json').write_text(json.dumps(
            {'name': 'stand-in', 'version': archive_version or version, 'type': 'commonjs'}, indent=2))
        if not flat:
            (root / 'VERSION').write_text((archive_version or version) + '\n')
        members = ['dist', 'node_modules', 'package.json'] if flat else [name]
        if read_only:
            (package / 'index.js').chmod(0o444)
            package.chmod(0o555)
        try:
            subprocess.run(['tar', '-C', str(root if flat else stage), '-czf',
                            str(Path(out) / f'{name}.tar.gz'), *members], check=True)
        finally:
            if read_only:
                package.chmod(0o755)


def cli_archive(out, version, installer=None):
    """This checkout's CLI, relabelled as another version, for this platform only; with
    installer, the archive carries that text as install-client.sh (0.3.3 and later do)."""
    with tempfile.TemporaryDirectory() as stage:
        name = f'optimal-{version}-{platform()}'
        root = Path(stage) / name
        root.mkdir()
        text = re.sub(r'^OPTIMAL_CLI_VERSION=.*$', f'OPTIMAL_CLI_VERSION={version}', CLI.read_text(), flags=re.M)
        (root / 'optimal').write_text(text)
        (root / 'optimal').chmod(0o755)
        (root / 'oe').symlink_to('optimal')
        (root / 'VERSION').write_text(version + '\n')
        if installer is not None:
            (root / 'install-client.sh').write_text(installer)
        subprocess.run(['tar', '-C', stage, '-czf', str(Path(out) / f'{name}.tar.gz'), name], check=True)


def build_release(out):
    """CLI archives from the checkout plus a stand-in MCP archive, with SHA256SUMS."""
    subprocess.run(['sh', str(CLI_BUILD), str(out)], check=True, capture_output=True, text=True, timeout=60)
    mcp_archive(out, VERSION)
    write_sums(out)


class InstallClientTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release_tmp = tempfile.TemporaryDirectory()
        given = os.environ.get('OPTIMAL_CLIENT_TEST_RELEASE_DIR')
        if given:
            cls.release = Path(given).resolve()
        else:
            cls.release = Path(cls.release_tmp.name) / 'release'
            cls.release.mkdir()
            build_release(cls.release)

    @classmethod
    def tearDownClass(cls):
        cls.release_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.home = self.dir / 'home'
        self.home.mkdir()
        self.prefix = self.dir / 'prefix'
        self.bin = self.dir / 'bin'
        self.fakes = self.dir / 'fakes'
        self.fakes.mkdir()
        (self.dir / 'opt').mkdir()
        self.system_prefix = self.dir / 'opt' / 'optimal'
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('OPTIMAL_', 'OE_', 'CODEX_')) and k != 'XDG_CONFIG_HOME'}
        self.env.update(
            HOME=str(self.home),
            CLAUDE_CONFIG_DIR=str(self.home / '.claude'),
            PATH=f'{self.fakes}:{self.bin}:{os.environ.get("PATH", "/usr/bin:/bin")}',
            NO_PROXY='*', no_proxy='*',
            OPTIMAL_CLIENT_SOURCE=str(self.release),
            OPTIMAL_CLIENT_PREFIX=str(self.prefix),
            OPTIMAL_CLIENT_SYSTEM_PREFIX=str(self.system_prefix),
            OPTIMAL_CLIENT_BIN_DIR=str(self.bin),
            OPTIMAL_CLIENT_REGISTER_MCP='0',
        )
        if not NODE:
            self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'

    def run_installer(self, *args, check=True, script=INSTALLER):
        result = subprocess.run([INSTALL_SHELL, str(script), *args], env=self.env, capture_output=True,
                                text=True, timeout=120, preexec_fn=default_signals)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def engine(self, require_key=KEY):
        engine = FakeEngine(require_key=require_key)
        self.addCleanup(engine.close)
        engine.routes[('GET', '/api/auth/whoami')] = (200, {
            'authenticated': True, 'key_id': 'key_1', 'scopes': ['read', 'write'],
            'workspace_scope': ['default:sales']})
        engine.routes[('GET', '/api/search')] = (200, {'results': [], 'count': 0})
        return engine

    def key_file(self, value=KEY):
        path = self.dir / 'engine-key'
        path.write_text(value + '\n')
        path.chmod(0o600)
        return path

    def copy_release(self):
        copy = self.dir / 'release-copy'
        shutil.copytree(self.release, copy)
        self.env['OPTIMAL_CLIENT_SOURCE'] = str(copy)
        return copy

    def fake_harnesses(self, claude_exit=0, codex_version='codex-cli 0.163.0'):
        """Fake claude and codex first on PATH; claude records its arguments."""
        calls = self.dir / 'claude-calls'
        claude = self.fakes / 'claude'
        claude.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >>"{calls}"\nexit {claude_exit}\n')
        claude.chmod(0o755)
        codex = self.fakes / 'codex'
        codex.write_text(f'#!/bin/sh\n[ "$1" = --version ] && echo "{codex_version}"\nexit 0\n')
        codex.chmod(0o755)
        self.env['OPTIMAL_CLIENT_REGISTER_MCP'] = '1'
        return calls

    def fake(self, name, body):
        """A program first on PATH, written as a shell script."""
        path = self.fakes / name
        path.write_text('#!/bin/sh\n' + body)
        path.chmod(0o755)
        return path

    def installed_state(self, paths):
        """What a refused install must not change: inode, mtime and bytes."""
        return {p: (p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes()) for p in paths}

    def fake_root_ls(self):
        """ls reports root ownership for any path, with FAKE_LS_MODE (default drwx------)
        for a directory and FAKE_LS_PARENT_MODE (default drwxr-xr-x) for its parent."""
        self.fake('ls', 'if [ "$1" = -ndL ]; then mode=${FAKE_LS_PARENT_MODE:-drwxr-xr-x}; '
                        'else mode=${FAKE_LS_MODE:-drwx------}; fi\nfor last; do :; done\n'
                        'printf "%s 2 0 0 64 Jan  1 00:00 %s\\n" "$mode" "$last"\n')

    def leftovers(self):
        return sorted(p.name for d in [self.prefix, self.prefix / 'bin'] if d.is_dir() for p in d.iterdir()
                      if '.new.' in p.name or '.old.' in p.name or p.name.startswith('.install.lock'))

    def dead_pid(self):
        process = subprocess.Popen(['true'])
        process.wait()
        return process.pid

    def serve(self, directory):
        server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietFiles, directory=str(directory)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f'http://127.0.0.1:{server.server_port}/'

    def pin(self, release):
        self.env['OPTIMAL_CLI_SHA256'] = sha256(Path(release) / f'optimal-{VERSION}-{platform()}.tar.gz')
        self.env['OPTIMAL_MCP_SHA256'] = sha256(Path(release) / MCP_ARCHIVE)


class InstallTests(InstallClientTestCase):
    def test_default_version_is_the_engine_version(self):
        pinned = re.search(r'^DEFAULT_VERSION=(\S+)$', INSTALLER.read_text(), re.M).group(1)
        self.assertEqual(pinned, VERSION)

    def test_installs_from_a_directory_links_the_programs_and_verifies(self):
        result = self.run_installer()
        self.assertIn(f'ok: optimal {VERSION} (oe {VERSION})', result.stdout)
        self.assertIn('Engine checks skipped', result.stdout)
        self.assertEqual((self.prefix / 'VERSION').read_text().strip(), VERSION)
        for program in ['optimal', 'oe']:
            out = subprocess.run([str(self.bin / program), '--version'], capture_output=True, text=True)
            self.assertEqual(out.stdout.strip(), f'{program} {VERSION}')
        copy = self.prefix / 'bin' / 'install-client.sh'
        self.assertEqual(copy.read_bytes(), INSTALLER.read_bytes())
        self.assertEqual(stat.S_IMODE(copy.stat().st_mode), 0o755)
        if NODE:
            self.assertIn(f'ok: optimal-engine-mcp {VERSION} answers initialize', result.stdout)
            self.assertTrue((self.prefix / 'mcp' / 'dist' / 'index.js').is_file())
            self.assertTrue((self.bin / 'optimal-engine-mcp').exists())
            launcher = (self.prefix / 'bin' / 'optimal-engine-mcp').read_text()
            self.assertIn(f"'{self.prefix}/mcp/dist/index.js'", launcher)

    def test_skip_mcp_installs_only_the_cli(self):
        self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'
        result = self.run_installer()
        self.assertIn('MCP server skipped', result.stdout)
        self.assertFalse((self.prefix / 'bin' / 'optimal-engine-mcp').exists())

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_a_cli_only_install_removes_an_earlier_mcp_server(self):
        self.run_installer('install')
        self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'
        result = self.run_installer('install', 'verify')
        self.assertIn('removed the earlier MCP server', result.stdout)
        self.assertFalse((self.prefix / 'mcp').exists())
        self.assertFalse((self.prefix / 'bin' / 'optimal-engine-mcp').exists())
        self.assertFalse(os.path.lexists(self.bin / 'optimal-engine-mcp'))
        self.assertTrue((self.bin / 'optimal').exists())

    def test_a_tampered_cli_archive_is_refused_and_nothing_is_installed(self):
        copy = self.copy_release()
        for archive in copy.glob(f'optimal-{VERSION}-*.tar.gz'):
            with archive.open('ab') as handle:
                handle.write(b'tampered')
        result = self.run_installer(check=False)
        self.assertEqual(result.returncode, 65)
        self.assertIn('sha256 mismatch', result.stderr)
        self.assertFalse((self.prefix / 'bin').exists())

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_a_tampered_mcp_archive_leaves_the_installed_client_untouched(self):
        self.run_installer('install')
        installed = {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in
                     [self.prefix / 'bin' / 'optimal', self.prefix / 'bin' / 'optimal-engine-mcp',
                      self.prefix / 'mcp' / 'dist' / 'index.js', self.prefix / 'VERSION']}
        copy = self.copy_release()
        with (copy / MCP_ARCHIVE).open('ab') as handle:
            handle.write(b'tampered')
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 65)
        self.assertIn(f'sha256 mismatch for {MCP_ARCHIVE}', result.stderr)
        for path, before in installed.items():
            self.assertEqual((path.stat().st_mtime_ns, path.read_bytes()), before, path)

        # On a fresh prefix the CLI is not installed either.
        self.env['OPTIMAL_CLIENT_PREFIX'] = str(self.dir / 'fresh')
        self.assertEqual(self.run_installer('install', check=False).returncode, 65)
        self.assertFalse((self.dir / 'fresh').exists())

    def test_a_failed_copy_into_the_prefix_changes_nothing(self):
        """A full disk during the copies: exit 73, no file replaced, no copy left behind."""
        self.run_installer('install')
        paths = [self.prefix / 'bin' / 'optimal', self.prefix / 'bin' / 'install-client.sh',
                 self.prefix / 'VERSION']
        # The MCP server is the large copy; install-client.sh is the last one.
        failing = ['install-client.sh.new.']
        if NODE:
            paths += [self.prefix / 'bin' / 'optimal-engine-mcp', self.prefix / 'mcp' / 'dist' / 'index.js']
            failing.insert(0, '/mcp.new.')
        before = self.installed_state(paths)
        oe = os.readlink(self.prefix / 'bin' / 'oe')
        real_cp = shutil.which('cp')
        for pattern in failing:
            with self.subTest(failing=pattern):
                self.fake('cp', f'case "$*" in *"{pattern}"*) echo "cp: No space left on device" >&2; exit 1 ;; esac\n'
                                f'exec "{real_cp}" "$@"\n')
                result = self.run_installer('install', check=False)
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                self.assertIn('No space left on device', result.stderr)
                self.assertIn('the installed client is unchanged', result.stderr)
                self.assertEqual(self.installed_state(paths), before)
                self.assertEqual(os.readlink(self.prefix / 'bin' / 'oe'), oe)
                leftovers = [p.name for d in [self.prefix, self.prefix / 'bin'] for p in d.iterdir()
                             if '.new.' in p.name or '.old.' in p.name]
                self.assertEqual(leftovers, [])
        (self.fakes / 'cp').unlink()
        self.run_installer('install', 'verify')

    def test_the_installed_installer_comes_from_the_cli_archive(self):
        release = self.dir / 'with-installer'
        release.mkdir()
        refreshed = INSTALLER.read_text() + '# refreshed from the archive\n'
        cli_archive(release, VERSION, installer=refreshed)
        mcp_archive(release, VERSION)
        write_sums(release)
        self.env['OPTIMAL_CLIENT_SOURCE'] = str(release)
        self.run_installer('install')
        copy = self.prefix / 'bin' / 'install-client.sh'
        self.assertEqual(copy.read_text(), refreshed)
        self.assertEqual(stat.S_IMODE(copy.stat().st_mode), 0o755)

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_the_mcp_version_is_checked_in_the_archive_and_in_its_answer(self):
        release = self.dir / 'wrong-archive'
        release.mkdir()
        subprocess.run(['sh', str(CLI_BUILD), str(release)], check=True, capture_output=True, timeout=60)
        mcp_archive(release, VERSION, archive_version='9.9.9')
        write_sums(release)
        self.env['OPTIMAL_CLIENT_SOURCE'] = str(release)
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 65)
        self.assertIn("MCP server version '9.9.9'", result.stderr)
        self.assertFalse(self.prefix.exists())

        release = self.dir / 'wrong-answer'
        release.mkdir()
        subprocess.run(['sh', str(CLI_BUILD), str(release)], check=True, capture_output=True, timeout=60)
        mcp_archive(release, VERSION, reports='9.9.9')
        write_sums(release)
        self.env['OPTIMAL_CLIENT_SOURCE'] = str(release)
        result = self.run_installer('install', 'verify', check=False)
        self.assertEqual(result.returncode, 70)
        self.assertIn("answers as version '9.9.9'", result.stderr)

    def test_an_archive_without_a_checksum_is_refused_unless_pinned(self):
        copy = self.copy_release()
        (copy / 'SHA256SUMS').unlink()
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 65)
        self.assertIn('no sha256', result.stderr)
        self.assertFalse(self.prefix.exists())
        self.pin(copy)
        self.run_installer('install', 'verify')

    def test_an_http_source_needs_both_pins(self):
        self.env['OPTIMAL_CLIENT_SOURCE'] = self.serve(self.release)
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn('needs OPTIMAL_CLI_SHA256 and OPTIMAL_MCP_SHA256', result.stderr)
        self.pin(self.release)
        result = self.run_installer('install', 'verify')
        self.assertIn(f'verified optimal-{VERSION}-', result.stdout)

    def test_an_unreachable_source_exits_69_and_a_404_means_missing(self):
        self.env['OPTIMAL_CLIENT_SOURCE'] = 'https://127.0.0.1:9/releases'
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 69)
        self.assertIn('cannot reach', result.stderr)

        empty = self.dir / 'empty'
        empty.mkdir()
        self.env['OPTIMAL_CLIENT_SOURCE'] = self.serve(empty)
        self.pin(self.release)
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 69)
        self.assertIn('does not exist (HTTP 404)', result.stderr)

    def test_input_errors_exit_64(self):
        self.assertEqual(self.run_installer('upgrade', check=False).returncode, 64)
        for version in ['0.3.3-rc1', '0.3', '1.2.3x', ' 0.3.3', '0.3.3\nx', '0..3', '1.2.3.4']:
            self.env['OPTIMAL_CLIENT_VERSION'] = version
            self.assertEqual(self.run_installer('install', check=False).returncode, 64, version)
        del self.env['OPTIMAL_CLIENT_VERSION']
        self.env['OPTIMAL_CLI_SHA256'] = 'not-a-sha'
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn('not 64 hex digits', result.stderr)
        del self.env['OPTIMAL_CLI_SHA256']
        self.env['OPTIMAL_CLIENT_PREFIX'] = 'relative/prefix'
        self.assertEqual(self.run_installer('install', check=False).returncode, 64)

    def test_a_missing_directory_source_exits_69(self):
        self.env['OPTIMAL_CLIENT_SOURCE'] = str(self.dir / 'no-such-release')
        self.env['OPTIMAL_CLI_SHA256'] = '0' * 64
        self.env['OPTIMAL_MCP_SHA256'] = '0' * 64
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 69)
        self.assertIn('does not exist', result.stderr)

    def test_reinstalling_is_idempotent(self):
        self.run_installer()
        links = {p.name: os.readlink(p) for p in self.bin.iterdir()}
        self.run_installer()
        self.assertEqual((self.prefix / 'VERSION').read_text().strip(), VERSION)
        self.assertEqual(self.leftovers(), [])
        self.assertEqual({p.name: os.readlink(p) for p in self.bin.iterdir()}, links)

    def test_install_needs_a_source(self):
        del self.env['OPTIMAL_CLIENT_SOURCE']
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn('OPTIMAL_CLIENT_SOURCE is required for install', result.stderr)
        self.assertFalse(self.prefix.exists())
        self.assertNotIn('github', (result.stdout + result.stderr).lower())
        self.assertNotIn('github.com', INSTALLER.read_text())

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_read_only_package_directories_never_stop_an_upgrade_or_the_cleanup(self):
        release = self.dir / 'read-only'
        release.mkdir()
        subprocess.run(['sh', str(CLI_BUILD), str(release)], check=True, capture_output=True, timeout=60)
        mcp_archive(release, VERSION, read_only=True)
        write_sums(release)
        scratch = self.dir / 'scratch'
        scratch.mkdir()
        self.env.update(OPTIMAL_CLIENT_SOURCE=str(release), TMPDIR=str(scratch))
        self.addCleanup(subprocess.run, ['chmod', '-R', 'u+w', str(self.dir)])
        self.run_installer('install')
        result = self.run_installer('install', 'verify')
        self.assertNotIn('cannot remove', result.stderr)
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(list(scratch.iterdir()), [])


class RecoveryTests(InstallClientTestCase):
    """Interrupted, killed and concurrent installs, and what an earlier one left."""

    def mv_signal(self, pattern, signal='TERM'):
        real_mv = shutil.which('mv')
        self.fake('mv', f'case "$*" in *"{pattern}"*) kill -{signal} $PPID; exit 1 ;; esac\n'
                        f'exec "{real_mv}" "$@"\n')

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_a_signal_between_the_mcp_renames_puts_the_server_back(self):
        self.run_installer('install')
        paths = [self.prefix / 'mcp' / 'dist' / 'index.js', self.prefix / 'bin' / 'optimal', self.prefix / 'VERSION']
        before = self.installed_state(paths)
        for signal, code in [('TERM', 143), ('HUP', 129), ('INT', 130)]:
            with self.subTest(signal=signal):
                # The second MCP rename: stopped after the first moved the server aside.
                self.mv_signal('/mcp.new.', signal)
                result = self.run_installer('install', check=False)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertEqual(self.installed_state(paths), before)
                self.assertEqual(self.leftovers(), [])
        (self.fakes / 'mv').unlink()
        self.run_installer('install', 'verify')

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_an_interrupted_first_install_still_owns_what_it_left(self):
        # Stopped after the MCP server was renamed in, before the launcher and VERSION.
        self.mv_signal('optimal-engine-mcp.new.')
        self.assertEqual(self.run_installer('install', check=False).returncode, 143)
        self.assertTrue((self.prefix / 'mcp' / 'dist' / 'index.js').is_file())
        self.assertFalse((self.prefix / 'VERSION').exists())
        self.assertFalse((self.prefix / 'bin' / 'optimal-engine-mcp').exists())
        (self.fakes / 'mv').unlink()
        self.run_installer('install', 'verify')

        # mcp/ without its mark file, beside a marked launcher, with no VERSION: an
        # install from before the mark file.
        (self.prefix / 'mcp' / '.install-client').unlink()
        (self.prefix / 'VERSION').unlink()
        self.run_installer('install', 'verify')

    def test_a_later_install_sweeps_only_what_dead_runs_left(self):
        self.run_installer('install')
        dead = self.dead_pid()
        (self.prefix / f'mcp.new.{dead}').mkdir()
        (self.prefix / 'bin' / f'optimal.new.{dead}').write_text('half a copy')
        (self.prefix / f'VERSION.new.{dead}').write_text(VERSION + '\n')
        kept = [
            # A run still going, as this test process; and another user's process (pid 1
            # answers kill -0 with EPERM when this is not root), both alive.
            self.prefix / 'bin' / f'oe.new.{os.getpid()}',
            self.prefix / f'mcp.old.new.{os.getpid()}',
            self.prefix / 'bin' / 'optimal.new.1',
            # Not a name this installer uses.
            self.prefix / 'bin' / f'rg.new.{dead}',
        ]
        for path in kept:
            path.mkdir() if path.name.startswith('mcp') else path.write_text('keep')
        if NODE:
            # Killed between the two MCP renames: the server was moved aside.
            (self.prefix / 'mcp').rename(self.prefix / f'mcp.old.new.{dead}')
        result = self.run_installer('install', 'verify')
        if NODE:
            self.assertIn(f'put back {self.prefix}/mcp', result.stderr)
            self.assertTrue((self.prefix / 'mcp' / 'dist' / 'index.js').is_file())
        self.assertEqual(self.leftovers(), sorted(p.name for p in kept if '.new.' in p.name or '.old.' in p.name))
        for path in kept:
            self.assertTrue(path.exists(), path)

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_a_server_that_cannot_be_put_back_is_kept(self):
        self.run_installer('install')
        dead = self.dead_pid()
        aside = self.prefix / f'mcp.old.new.{dead}'
        (self.prefix / 'mcp').rename(aside)
        real_mv = shutil.which('mv')
        self.fake('mv', f'case "$1" in *"/mcp.old.new.{dead}") echo "mv: refused" >&2; exit 1 ;; esac\n'
                        f'exec "{real_mv}" "$@"\n')
        result = self.run_installer('install')
        self.assertIn(f'cannot put {aside} back', result.stderr)
        self.assertTrue((aside / 'dist' / 'index.js').is_file())
        self.assertTrue((self.prefix / 'mcp' / 'dist' / 'index.js').is_file())

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_an_abort_after_the_sweep_keeps_the_server_it_put_back(self):
        self.run_installer('install')
        original = (self.prefix / 'mcp' / 'dist' / 'index.js').read_bytes()
        dead = self.dead_pid()
        (self.prefix / 'mcp').rename(self.prefix / f'mcp.old.new.{dead}')
        real_cp = shutil.which('cp')
        self.fake('cp', f'case "$*" in *"/mcp.new."*) echo "cp: No space left on device" >&2; exit 1 ;; esac\n'
                        f'exec "{real_cp}" "$@"\n')
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn('put back', result.stderr)
        self.assertEqual((self.prefix / 'mcp' / 'dist' / 'index.js').read_bytes(), original)
        self.assertEqual(self.leftovers(), [])

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_a_failed_removal_of_the_old_mcp_server_finishes_the_install(self):
        self.run_installer('install')
        before = self.installed_state([self.prefix / 'VERSION', self.prefix / 'bin' / 'optimal'])
        real_rm = shutil.which('rm')
        self.fake('rm', f'case "$*" in *"/mcp.old.new."*) echo "rm: Permission denied" >&2; exit 1 ;; esac\n'
                        f'exec "{real_rm}" "$@"\n')
        result = self.run_installer('install', 'verify')
        self.assertIn('the next install removes it', result.stderr)
        after = self.installed_state([self.prefix / 'VERSION', self.prefix / 'bin' / 'optimal'])
        for path in before:
            self.assertNotEqual(after[path][:2], before[path][:2], f'{path} was not replaced')
        self.assertEqual(len([n for n in self.leftovers() if n.startswith('mcp.old.new.')]), 1)
        (self.fakes / 'rm').unlink()
        self.run_installer('install')
        self.assertEqual(self.leftovers(), [])

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_a_failed_cli_only_removal_is_finished_by_the_next_install(self):
        self.run_installer('install')
        real_rm = shutil.which('rm')
        self.fake('rm', f'case "$*" in *"-rf {self.prefix}/mcp") echo "rm: busy" >&2; exit 1 ;; esac\n'
                        f'exec "{real_rm}" "$@"\n')
        self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'
        result = self.run_installer('install')
        self.assertIn('cannot remove the earlier MCP server', result.stderr)
        # The launcher stays while mcp/ does, so the next install can tell both are its own.
        self.assertTrue((self.prefix / 'bin' / 'optimal-engine-mcp').is_file())
        (self.fakes / 'rm').unlink()
        result = self.run_installer('install', 'verify')
        self.assertIn('removed the earlier MCP server', result.stdout)
        self.assertFalse((self.prefix / 'mcp').exists())
        self.assertFalse((self.prefix / 'bin' / 'optimal-engine-mcp').exists())



class LockTests(InstallClientTestCase):
    """One install at a time in a prefix: a symbolic link whose target is its holder."""

    def setUp(self):
        super().setUp()
        command = ['hostname'] if shutil.which('hostname') else ['uname', '-n']
        self.host = subprocess.run(command, capture_output=True, text=True).stdout.strip()
        self.boot = boot_id()
        self.ns = os.readlink('/proc/self/ns/pid') if os.path.exists('/proc/self/ns/pid') else 'unknown'
        self.lock = self.prefix / '.install.lock'
        self.run_installer('install')

    def owner(self, pid=None, host=None, boot=None, ns=None, at=None):
        return (f'pid={pid or os.getpid()} host={host or self.host} boot={boot or self.boot} '
                f'ns={ns or self.ns} at={int(time.time() if at is None else at)}')

    def held(self):
        return os.readlink(self.lock) if self.lock.is_symlink() else None

    def test_a_live_holder_is_waited_for_and_otherwise_exits_75(self):
        live = self.owner()
        self.lock.symlink_to(live)
        self.env['OPTIMAL_CLIENT_LOCK_WAIT'] = '0'
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertIn(f'another install holds {self.lock} ({live})', result.stderr)
        self.assertEqual(self.held(), live)

        # Released while waiting: install goes ahead.
        self.env['OPTIMAL_CLIENT_LOCK_WAIT'] = '20'
        release = threading.Timer(1.5, self.lock.unlink)
        release.start()
        self.addCleanup(release.cancel)
        result = self.run_installer('install')
        self.assertIn('waiting up to 20s', result.stdout)
        self.assertEqual(self.leftovers(), [])

    def test_stale_locks_are_taken_over_and_unknown_ones_are_not(self):
        self.env['OPTIMAL_CLIENT_LOCK_WAIT'] = '0'
        old = time.time() - 1_200
        cases = [
            ('a dead holder on this host', self.owner(pid=self.dead_pid()), 'is no longer running'),
            ('a holder from before the last boot', self.owner(boot='an-earlier-boot'),
             'before this machine last started'),
            ('a holder older than 15 minutes', self.owner(host='elsewhere', at=old),
             'older than 15 minutes'),
            ('a malformed owner, old', 'garbage', 'older than 15 minutes'),
            ('no owner, old', None, 'older than 15 minutes'),
        ]
        if self.boot == 'unknown':
            cases = [c for c in cases if 'boot' not in c[0]]
        for name, owner, why in cases:
            with self.subTest(name):
                if owner is None:
                    self.lock.write_text('')
                    os.utime(self.lock, (old, old))
                else:
                    self.lock.symlink_to(owner)
                    if owner == 'garbage':
                        os.utime(self.lock, (old, old), follow_symlinks=False)
                result = self.run_installer('install')
                self.assertIn(f'took over {self.lock}', result.stderr)
                self.assertIn(why, result.stderr)
                self.assertEqual(self.leftovers(), [])

        kept = [
            ('a live holder on another host', self.owner(host='elsewhere')),
            ('a holder in another pid namespace', self.owner(pid=self.dead_pid(), ns='pid:[1]')),
            ('a pid that is not a number', self.owner(pid='abc')),
            ('a malformed owner', 'garbage'),
            ('no owner', None),
        ]
        for name, owner in kept:
            with self.subTest(name):
                if owner is None:
                    self.lock.write_text('')
                else:
                    self.lock.symlink_to(owner)
                result = self.run_installer('install', check=False)
                self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
                self.assertTrue(os.path.lexists(self.lock))
                self.lock.unlink()

        # OPTIMAL_CLIENT_BREAK_LOCK=1 takes over even a live holder.
        self.lock.symlink_to(self.owner())
        self.env['OPTIMAL_CLIENT_BREAK_LOCK'] = '1'
        result = self.run_installer('install')
        self.assertIn('OPTIMAL_CLIENT_BREAK_LOCK=1', result.stderr)
        self.assertEqual(self.leftovers(), [])

    def concurrent_installs(self):
        """Two installs at once; the cp of each copy into the prefix is logged and slowed."""
        log = self.dir / 'copies'
        real_cp = shutil.which('cp')
        self.fake('cp', f'case "$*" in *".new."*) echo "$PPID" >>"{log}"; sleep 0.2 ;; esac\n'
                        f'exec "{real_cp}" "$@"\n')
        runs = [subprocess.Popen([INSTALL_SHELL, str(INSTALLER), 'install'], env=self.env, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=default_signals)
                for _ in range(2)]
        outputs = [run.communicate(timeout=120) for run in runs]
        for run, (out, err) in zip(runs, outputs):
            self.assertEqual(run.returncode, 0, out + err)
        writers = log.read_text().split()
        # Each install's copies run under the lock, so the log changes hands once.
        changes = sum(1 for a, b in zip(writers, writers[1:]) if a != b)
        self.assertEqual(changes, 1, writers)
        self.assertEqual(sorted(set(writers)), sorted(str(run.pid) for run in runs))
        self.assertEqual(self.leftovers(), [])
        (self.fakes / 'cp').unlink()
        log.unlink()
        return outputs

    def test_two_installs_at_once_take_turns(self):
        self.concurrent_installs()

    def test_two_installs_facing_one_stale_lock_take_it_over_once(self):
        self.lock.symlink_to(self.owner(pid=self.dead_pid()))
        outputs = self.concurrent_installs()
        took = [err for _out, err in outputs if 'took over' in err]
        self.assertEqual(len(took), 1, outputs)

    def test_many_installs_at_once_never_hold_the_lock_together(self):
        # Each copy into the prefix makes a witness directory that only one install can
        # hold. Holders exit while others wait, so a waiter that read a holder's lock
        # finds that holder gone as the next takes the prefix; a slowed readlink and date
        # widen the window between reading a lock and acting on it.
        log, overlaps, witness = self.dir / 'copies', self.dir / 'overlaps', self.dir / 'witness'
        real = {name: shutil.which(name) for name in ['cp', 'readlink', 'date']}
        self.fake('cp', f'case "$*" in *".new."*) mkdir "{witness}" 2>/dev/null || echo "$PPID" >>"{overlaps}"\n'
                        f'  echo "$PPID" >>"{log}"; sleep 0.05; rmdir "{witness}" 2>/dev/null ;; esac\n'
                        f'exec "{real["cp"]}" "$@"\n')
        self.fake('readlink', f'sleep 0.05\nexec "{real["readlink"]}" "$@"\n')
        self.fake('date', f'[ "$*" != +%s ] || sleep 0.05\nexec "{real["date"]}" "$@"\n')
        self.env['OPTIMAL_CLIENT_LOCK_WAIT'] = '100'
        for round_ in range(int(os.environ.get('OPTIMAL_CLIENT_TEST_LOCK_ROUNDS', '3'))):
            with self.subTest(round=round_):
                log.unlink(missing_ok=True)
                runs = [subprocess.Popen([INSTALL_SHELL, str(INSTALLER), 'install'], env=self.env, text=True,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         preexec_fn=default_signals)
                        for _ in range(6)]
                outputs = [run.communicate(timeout=150) for run in runs]
                for run, (out, err) in zip(runs, outputs):
                    self.assertEqual(run.returncode, 0, out + err)
                    self.assertNotIn('took over', err)
                self.assertFalse(overlaps.exists(), overlaps.read_text() if overlaps.exists() else '')
                writers = log.read_text().split()
                # Each install's copies run under the lock, so the log changes hands five times.
                self.assertEqual(sum(1 for a, b in zip(writers, writers[1:]) if a != b), 5, writers)
                self.assertEqual(sorted(set(writers)), sorted(str(run.pid) for run in runs))
                self.assertEqual(self.leftovers(), [])

    def test_an_install_never_removes_a_lock_that_is_not_its_own(self):
        foreign = self.owner(pid=1, host='elsewhere')
        real_cp = shutil.which('cp')
        for code in [73, 0]:
            with self.subTest(exit=code):
                # While this install holds the lock, another takes it (as a break would).
                fail = 'exit 1' if code else ':'
                self.fake('cp', f'case "$*" in *".new."*) rm -f "{self.lock}"; '
                                f'ln -s "{foreign}" "{self.lock}"; {fail} ;; esac\n'
                                f'exec "{real_cp}" "$@"\n')
                result = self.run_installer('install', check=False)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertEqual(self.held(), foreign)
                self.lock.unlink()
        (self.fakes / 'cp').unlink()


class OwnershipTests(InstallClientTestCase):
    """What install replaces: only its own MCP server and launcher, and only Optimal links."""

    def test_an_mcp_server_this_installer_did_not_put_there_is_left_alone(self):
        # A prefix with no earlier install: its mcp/ belongs to something else.
        foreign = self.prefix / 'mcp'
        foreign.mkdir(parents=True)
        (foreign / 'keep').write_text('not ours')
        for skip in ['0', '1']:
            with self.subTest(skip_mcp=skip):
                if skip == '1' or not NODE:
                    self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'
                result = self.run_installer('install', check=False)
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                self.assertIn(f'{foreign} was not installed by install-client.sh', result.stderr)
                self.assertEqual((foreign / 'keep').read_text(), 'not ours')
                self.assertFalse((self.prefix / 'bin').exists())

        # The check runs before anything is fetched.
        self.env['OPTIMAL_CLIENT_SOURCE'] = str(self.dir / 'nonexistent')
        self.assertEqual(self.run_installer('install', check=False).returncode, 73)
        self.env['OPTIMAL_CLIENT_SOURCE'] = str(self.release)
        self.env.pop('OPTIMAL_CLIENT_SKIP_MCP', None)
        if not NODE:
            self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'

        # An installed prefix whose launcher is not this installer's, even with the marked mcp/.
        shutil.rmtree(foreign)
        self.run_installer('install')
        launcher = self.prefix / 'bin' / 'optimal-engine-mcp'
        launcher.write_text('#!/bin/sh\n# installed by install-client.sh, it says\nexec something-else\n')
        for skip in ['0', '1']:
            with self.subTest(launcher=True, skip_mcp=skip):
                if skip == '1':
                    self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'
                result = self.run_installer('install', check=False)
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                self.assertIn(f'{launcher} was not installed by install-client.sh', result.stderr)
                self.assertIn('something-else', launcher.read_text())

    def optimal_root(self, name, version='0.3.2', cli='OPTIMAL_CLI_VERSION=0.3.2\n'):
        root = self.dir / name
        (root / 'bin').mkdir(parents=True)
        (root / 'VERSION').write_text(version + '\n')
        (root / 'bin' / 'optimal').write_text('#!/bin/sh\n' + cli)
        (root / 'bin' / 'oe').symlink_to('optimal')
        return root

    def test_program_links_replace_only_an_absent_entry_a_dangling_link_or_an_optimal_link(self):
        self.bin.mkdir()
        older = self.optimal_root('older-prefix')
        crafted = self.optimal_root('crafted', version='not a version')
        no_cli = self.optimal_root('no-cli', cli='echo something else\n')
        directory = self.optimal_root('directory')
        (directory / 'bin' / 'optimal-engine-mcp').mkdir()
        cases = {
            # Replaced: an older Optimal prefix, relative or absolute, and a dangling link.
            'optimal': os.path.relpath(older / 'bin' / 'optimal', self.bin),
            'oe': str(self.dir / 'gone' / 'bin' / 'oe'),
        }
        for name, target in cases.items():
            (self.bin / name).symlink_to(target)
        result = self.run_installer('install')
        for name in cases:
            self.assertEqual(os.readlink(self.bin / name), str(self.prefix / 'bin' / name))
        self.assertIn('linked optimal oe', result.stdout)

        # Kept: another program, a crafted root, a root with no client CLI, a directory.
        kept = {
            'optimal': str(crafted / 'bin' / 'optimal'),
            'oe': str(no_cli / 'bin' / 'oe'),
            'optimal-engine-mcp': str(directory / 'bin' / 'optimal-engine-mcp'),
        }
        for name, target in kept.items():
            (self.bin / name).unlink(missing_ok=True)
            (self.bin / name).symlink_to(target)
        result = self.run_installer('install')
        for name, target in kept.items():
            if name == 'optimal-engine-mcp' and not NODE:
                continue
            self.assertEqual(os.readlink(self.bin / name), target)
            self.assertIn(f'{self.bin / name} exists and is not a link into an Optimal prefix', result.stderr)
        self.assertEqual(list((directory / 'bin' / 'optimal-engine-mcp').iterdir()), [])
        self.assertIn(f'linked nothing into {self.bin}', result.stderr)

        other = self.bin / 'oe'
        other.unlink()
        other.write_text('#!/bin/sh\necho another oe\n')
        self.run_installer('install')
        self.assertEqual(other.read_text(), '#!/bin/sh\necho another oe\n')

        # Behind a directory that cannot be searched, a target is unknown, not dangling.
        if os.geteuid() != 0:
            hidden = self.optimal_root('hidden')
            other.unlink()
            other.symlink_to(hidden / 'bin' / 'oe')
            hidden.chmod(0)
            self.addCleanup(hidden.chmod, 0o755)
            result = self.run_installer('install')
            self.assertEqual(os.readlink(other), str(hidden / 'bin' / 'oe'))
            self.assertIn(f'{other} exists and is not a link into an Optimal prefix', result.stderr)


class PrefixTests(InstallClientTestCase):
    """The machine-start path: root installs once, then each agent user runs the copy."""

    def test_an_agent_user_finds_the_shared_install_without_a_prefix(self):
        del self.env['OPTIMAL_CLIENT_PREFIX']
        self.run_installer('install')
        shared = self.system_prefix
        self.assertEqual((shared / 'VERSION').read_text().strip(), VERSION)
        installed_script = shared / 'bin' / 'install-client.sh'
        self.assertEqual(stat.S_IMODE(installed_script.stat().st_mode), 0o755)

        # Another user: its own HOME, no prefix, no source, the Engine in its environment.
        agent_home = self.dir / 'agent'
        agent_home.mkdir()
        engine = self.engine()
        self.env.update(HOME=str(agent_home), CLAUDE_CONFIG_DIR=str(agent_home / '.claude'),
                        OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY_FILE=str(self.key_file()),
                        OPTIMAL_WORKSPACE='default:sales')
        del self.env['OPTIMAL_CLIENT_SOURCE']
        calls = self.fake_harnesses() if NODE else None
        result = self.run_installer('configure', 'register', 'verify', script=installed_script)
        self.assertIn('from the profile', result.stdout)
        profile = (agent_home / '.config' / 'optimal' / 'profile').read_text()
        self.assertIn(f'key_file={self.dir / "engine-key"}\n', profile)
        self.assertNotIn(KEY, profile)
        if NODE:
            launcher = shared / 'bin' / 'optimal-engine-mcp'
            self.assertIn(f'mcp add --scope user optimal-engine -- {launcher}', calls.read_text())
            self.assertIn(f'command = "{launcher}"', (agent_home / '.codex' / 'config.toml').read_text())

        # The repository copy finds the shared install too.
        self.run_installer('verify')

    def test_register_and_verify_without_an_install_exit_70(self):
        self.fake_harnesses()
        self.assertEqual(self.run_installer('register', check=False).returncode, 70)
        result = self.run_installer('verify', check=False)
        self.assertEqual(result.returncode, 70)
        self.assertIn('no client is installed', result.stderr)

    def test_root_installs_into_the_system_prefix_never_its_home(self):
        self.fake('id', 'echo 0\n')
        del self.env['OPTIMAL_CLIENT_PREFIX']
        own_home = self.home / '.local' / 'share' / 'optimal'

        # As root with no install anywhere, the other commands name the system prefix.
        result = self.run_installer('verify', check=False)
        self.assertEqual(result.returncode, 70)
        self.assertIn(f'no client is installed in {self.system_prefix}', result.stderr)

        # A system prefix that cannot be created fails; root's home is never the fallback.
        blocked = self.dir / 'blocked'
        blocked.write_text('a file, not a directory')
        self.env['OPTIMAL_CLIENT_SYSTEM_PREFIX'] = str(blocked / 'optimal')
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        self.assertFalse(own_home.exists())

        # A missing system prefix, parents and all, is created.
        system = self.dir / 'fresh-root' / 'opt' / 'optimal'
        self.env['OPTIMAL_CLIENT_SYSTEM_PREFIX'] = str(system)
        self.run_installer('install', 'verify')
        self.assertEqual((system / 'VERSION').read_text().strip(), VERSION)
        self.assertFalse(own_home.exists())

    def test_an_unreadable_version_file_is_named(self):
        self.run_installer('install')
        version_file = self.prefix / 'VERSION'
        for text in ['not a version\n', '']:
            with self.subTest(text=text):
                version_file.write_text(text)
                result = self.run_installer('verify', check=False)
                self.assertEqual(result.returncode, 70)
                self.assertIn(f'{version_file} does not hold a version', result.stderr)


class ConfigureAndVerifyTests(InstallClientTestCase):
    def test_profile_names_the_key_file_and_verify_proves_the_profile(self):
        engine = self.engine()
        key_file = self.key_file()
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY_FILE=str(key_file),
                        OPTIMAL_WORKSPACE='default:sales')
        result = self.run_installer()
        output = result.stdout + result.stderr
        self.assertNotIn(KEY, output)
        for source in ['profile', 'environment']:
            self.assertIn(f'ok: whoami against {engine.url} from the {source}', output)
            self.assertIn(f'ok: search against {engine.url} from the {source}', output)
        self.assertIn('authenticated: true', output)

        config = self.home / '.config' / 'optimal'
        profile = config / 'profile'
        self.assertEqual(stat.S_IMODE(profile.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o700)
        text = profile.read_text()
        self.assertIn(f'url={engine.url}\n', text)
        self.assertIn(f'key_file={key_file}\n', text)
        self.assertIn('workspace=default:sales\n', text)
        self.assertNotIn(KEY, text)

        paths = [(r['method'], r['path']) for r in engine.requests]
        self.assertIn(('GET', '/api/auth/whoami'), paths)
        self.assertIn(('GET', '/api/search'), paths)
        self.assertTrue(all(r['auth'] == f'Bearer {KEY}' for r in engine.requests))
        search = next(r for r in engine.requests if r['path'] == '/api/search')
        self.assertEqual(search['query']['workspace'], 'default:sales')

    def test_verify_checks_the_profile_and_the_environment(self):
        engine = self.engine()
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY_FILE=str(self.key_file()),
                        OPTIMAL_WORKSPACE='default:sales')
        self.run_installer()
        profile = self.home / '.config' / 'optimal' / 'profile'
        good = profile.read_text()
        # A broken profile fails verify even with a working environment.
        profile.write_text(good.replace('key_file=', 'key_file=/nonexistent'))
        result = self.run_installer('verify', check=False)
        self.assertEqual(result.returncode, 78)
        # A broken environment fails verify even with a working profile.
        profile.write_text(good)
        self.env['OPTIMAL_ENGINE_URL'] = 'http://127.0.0.1:9'
        result = self.run_installer('verify', check=False)
        self.assertEqual(result.returncode, 69)
        self.assertIn('ok: search against', result.stdout)
        self.assertIn('from the profile', result.stdout)

    def test_an_inline_key_is_written_only_to_a_private_profile(self):
        engine = self.engine()
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY=KEY,
                        OPTIMAL_WORKSPACE='default:sales')
        result = self.run_installer()
        self.assertNotIn(KEY, result.stdout + result.stderr)
        profile = self.home / '.config' / 'optimal' / 'profile'
        self.assertEqual(stat.S_IMODE(profile.stat().st_mode), 0o600)
        self.assertIn(f'key={KEY}\n', profile.read_text())

    def test_with_both_key_variables_the_profile_names_the_file(self):
        self.env.update(OPTIMAL_ENGINE_URL='https://engine.example.invalid', OPTIMAL_ENGINE_API_KEY=KEY,
                        OPTIMAL_ENGINE_API_KEY_FILE=str(self.key_file('file-key-0b8a7c')))
        result = self.run_installer('install', 'configure')
        self.assertIn('both set', result.stderr)
        self.assertNotIn(KEY, result.stdout + result.stderr)
        profile = (self.home / '.config' / 'optimal' / 'profile').read_text()
        self.assertIn(f'key_file={self.dir / "engine-key"}\n', profile)
        self.assertNotIn('key=', profile.replace('key_file=', ''))

    def test_a_changed_profile_keeps_the_earlier_one(self):
        engine = self.engine(require_key=None)
        self.env.update(OPTIMAL_ENGINE_URL=engine.url)
        self.run_installer('configure')
        again = self.run_installer('configure')
        self.assertIn('already current', again.stdout)
        self.env['OPTIMAL_WORKSPACE'] = 'default:ops'
        self.run_installer('configure')
        config = self.home / '.config' / 'optimal'
        self.assertIn('workspace=default:ops', (config / 'profile').read_text())
        self.assertNotIn('workspace=', (config / 'profile.previous').read_text())
        self.assertEqual(stat.S_IMODE((config / 'profile.previous').stat().st_mode), 0o600)

    def test_a_refused_key_fails_verify_without_printing_it(self):
        engine = self.engine()
        wrong = 'wrong-key-5c1e9b7d3a'
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY_FILE=str(self.key_file(wrong)),
                        OPTIMAL_WORKSPACE='default:sales')
        result = self.run_installer(check=False)
        self.assertEqual(result.returncode, 77)
        self.assertIn('whoami failed', result.stderr)
        self.assertNotIn(wrong, result.stdout + result.stderr)

    def test_a_0_3_2_release_installs_and_gets_the_key_itself(self):
        release = self.dir / 'release-0.3.2'
        release.mkdir()
        cli_archive(release, '0.3.2')
        mcp_archive(release, '0.3.2', reports='0.3.0', archive_version='0.3.0', flat=True)
        write_sums(release)
        engine = self.engine()
        self.env.update(OPTIMAL_CLIENT_SOURCE=str(release), OPTIMAL_CLIENT_VERSION='0.3.2',
                        OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY_FILE=str(self.key_file()),
                        OPTIMAL_WORKSPACE='default:sales')
        result = self.run_installer()
        self.assertIn('ok: optimal 0.3.2 (oe 0.3.2)', result.stdout)
        self.assertIn('predates key_file=', result.stdout)
        if NODE:
            self.assertIn("MCP server version '0.3.0'", result.stderr)
        self.assertNotIn(KEY, result.stdout + result.stderr)
        profile = (self.home / '.config' / 'optimal' / 'profile').read_text()
        self.assertIn(f'key={KEY}\n', profile)
        self.assertNotIn('key_file=', profile)
        self.assertTrue(all(r['auth'] == f'Bearer {KEY}' for r in engine.requests))
        # Its CLI archive carries no installer, so the running script is the installed copy.
        self.assertEqual((self.prefix / 'bin' / 'install-client.sh').read_bytes(), INSTALLER.read_bytes())

    def test_engine_check_failures_carry_the_cli_exit_code(self):
        self.run_installer('install')
        self.env['OPTIMAL_ENGINE_URL'] = 'http://127.0.0.1:9'
        self.assertEqual(self.run_installer('verify', check=False).returncode, 69)

        engine = self.engine()
        engine.routes[('GET', '/api/search')] = (400, {'error': 'workspace_required'})
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY_FILE=str(self.key_file()))
        result = self.run_installer('verify', check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn('search failed', result.stderr)

    def test_key_file_errors(self):
        self.env['OPTIMAL_ENGINE_URL'] = 'https://engine.example.invalid'
        self.env['OPTIMAL_ENGINE_API_KEY_FILE'] = str(self.dir / 'missing-key')
        self.assertEqual(self.run_installer('configure', check=False).returncode, 66)
        self.env['OPTIMAL_ENGINE_API_KEY_FILE'] = str(self.dir)
        self.assertEqual(self.run_installer('configure', check=False).returncode, 66)
        self.env['OPTIMAL_ENGINE_API_KEY_FILE'] = 'relative/key'
        self.assertEqual(self.run_installer('configure', check=False).returncode, 64)
        self.assertFalse((self.home / '.config' / 'optimal' / 'profile').exists())

    @unittest.skipIf(os.geteuid() == 0, 'needs directories another user than root owns')
    def test_as_root_configure_writes_only_under_a_home_root_owns(self):
        self.fake('id', 'echo 0\n')
        self.env['OPTIMAL_ENGINE_URL'] = 'https://engine.example.invalid'
        result = self.run_installer('configure', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'as root, configure does not write under {self.home}, which uid {os.getuid()} owns',
                      result.stderr)
        self.assertFalse((self.home / '.config').exists())

        # A symlinked config directory is refused even where root owns everything.
        self.fake_root_ls()
        elsewhere = self.dir / 'elsewhere'
        elsewhere.mkdir()
        (self.home / '.config').symlink_to(elsewhere)
        result = self.run_installer('configure', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'does not write through the symlink {self.home}/.config', result.stderr)
        self.assertEqual(list(elsewhere.iterdir()), [])
        (self.home / '.config').unlink()

        self.run_installer('configure')
        self.assertTrue((self.home / '.config' / 'optimal' / 'profile').is_file())

    def test_no_engine_url_writes_no_profile(self):
        result = self.run_installer('configure')
        self.assertIn('no profile written', result.stdout)
        self.assertFalse((self.home / '.config' / 'optimal' / 'profile').exists())


class SecretTests(InstallClientTestCase):
    def test_the_key_is_never_an_argument_or_in_a_harness_config(self):
        real_curl = shutil.which('curl')
        argv_log = self.dir / 'curl-argv'
        shim = self.fakes / 'curl'
        shim.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >>"{argv_log}"\nexec "{real_curl}" "$@"\n')
        shim.chmod(0o755)
        calls = self.fake_harnesses()
        engine = self.engine()
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY=KEY,
                        OPTIMAL_WORKSPACE='default:sales', OPTIMAL_CLIENT_SOURCE=self.serve(self.release))
        self.pin(self.release)
        result = self.run_installer()
        self.assertNotIn(KEY, result.stdout + result.stderr)
        self.assertTrue(engine.requests)
        logged = argv_log.read_text()
        self.assertIn('/api/auth/whoami', logged)
        self.assertNotIn(KEY, logged)
        if NODE:
            self.assertNotIn(KEY, calls.read_text())
            self.assertNotIn(KEY, (self.home / '.codex' / 'config.toml').read_text())


# What `register` runs besides the harness programs. The tests put only these and
# fakes on PATH, so a real `claude` or `codex` on the test machine is never run.
REGISTER_TOOLS = ['sh', 'awk', 'cat', 'chmod', 'cp', 'dirname', 'grep', 'head', 'id', 'ls', 'mkdir', 'mktemp',
                  'mv', 'readlink', 'rm', 'sed', 'uname']


class RegisterTests(InstallClientTestCase):
    def setUp(self):
        super().setUp()
        tools = self.dir / 'tools'
        tools.mkdir()
        for tool in REGISTER_TOOLS:
            (tools / tool).symlink_to(shutil.which(tool))
        self.env['PATH'] = f'{self.fakes}:{tools}'
        self.calls = self.fake_harnesses()
        # Registration only needs an install with a launcher, so they are put in place directly.
        launcher = self.prefix / 'bin' / 'optimal-engine-mcp'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('#!/bin/sh\nexit 0\n')
        launcher.chmod(0o755)
        (self.prefix / 'VERSION').write_text(VERSION + '\n')
        self.launcher = launcher

    def test_registers_with_claude_code_and_codex_and_keeps_other_codex_settings(self):
        codex_home = self.home / '.codex'
        codex_home.mkdir()
        (codex_home / 'config.toml').write_text(
            'model = "example-model"\n\n'
            '[ mcp_servers . "optimal-engine" ]\ncommand = "/old/optimal-engine-mcp"\n\n'
            '[mcp_servers."optimal-engine".env]\nOLD = "1"\n\n'
            '[mcp_servers.optimal-engine.tools]\nOLDER = "1"\n\n'
            '[mcp_servers.other]\ncommand = "other-server"\n')

        self.run_installer('register')
        self.run_installer('register')

        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls.count(f'mcp add --scope user optimal-engine -- {self.launcher}'), 2)
        self.assertIn('mcp remove --scope user optimal-engine', calls)

        config = codex_home / 'config.toml'
        toml = config.read_text()
        headers = [line for line in toml.splitlines() if line.lstrip().startswith('[')]
        self.assertEqual([h for h in headers if 'optimal-engine' in h], ['[mcp_servers.optimal-engine]'])
        self.assertIn(f'[mcp_servers.optimal-engine]\ncommand = "{self.launcher}"\n{ENV_VARS}\n', toml)
        self.assertNotIn('OLD', toml)
        self.assertIn('model = "example-model"', toml)
        self.assertIn('[mcp_servers.other]\ncommand = "other-server"', toml)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
        self.assertEqual(list(codex_home.glob('config.toml.tmp.*')), [])

    def test_codex_home_is_created_private_and_absent_harnesses_are_named(self):
        (self.fakes / 'claude').unlink()
        codex_home = self.dir / 'codex-home'
        self.env['CODEX_HOME'] = str(codex_home)
        result = self.run_installer('register')
        self.assertIn('Claude Code skipped: claude is not on PATH', result.stdout)
        self.assertEqual(stat.S_IMODE(codex_home.stat().st_mode), 0o700)
        self.assertIn(ENV_VARS, (codex_home / 'config.toml').read_text())
        self.assertFalse(self.calls.exists())

        (self.fakes / 'codex').unlink()
        self.env['CODEX_HOME'] = str(self.dir / 'no-codex')
        result = self.run_installer('register')
        self.assertIn('Codex skipped', result.stdout)

    def test_a_codex_older_than_env_vars_gets_the_table_without_them(self):
        self.fake_harnesses(codex_version='codex-cli 0.46.0')
        result = self.run_installer('register')
        self.assertIn('predates env_vars', result.stderr)
        toml = (self.home / '.codex' / 'config.toml').read_text()
        self.assertIn(f'command = "{self.launcher}"', toml)
        self.assertNotIn('env_vars', toml)

    def test_an_unknown_codex_version_gets_env_vars_and_a_warning(self):
        for case, codex in [('not on PATH', None), ('no version', 'codex development build')]:
            with self.subTest(case=case):
                codex_home = self.dir / f'codex-{len(case)}'
                codex_home.mkdir()
                self.env['CODEX_HOME'] = str(codex_home)
                if codex is None:
                    (self.fakes / 'codex').unlink(missing_ok=True)
                else:
                    self.fake_harnesses(codex_version=codex)
                result = self.run_installer('register')
                self.assertIn('Codex version unknown', result.stderr)
                self.assertIn(ENV_VARS, (codex_home / 'config.toml').read_text())

    def test_a_symlinked_codex_config_stays_a_symlink(self):
        codex_home = self.home / '.codex'
        codex_home.mkdir()
        dotfiles = self.dir / 'dotfiles'
        dotfiles.mkdir()
        (dotfiles / 'codex.toml').write_text('model = "example-model"\n')
        link = codex_home / 'config.toml'
        link.symlink_to('../../dotfiles/codex.toml')
        self.run_installer('register')
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), '../../dotfiles/codex.toml')
        toml = (dotfiles / 'codex.toml').read_text()
        self.assertIn('model = "example-model"', toml)
        self.assertIn(f'command = "{self.launcher}"', toml)
        self.assertEqual(stat.S_IMODE((dotfiles / 'codex.toml').stat().st_mode), 0o600)
        self.assertEqual([p.name for p in dotfiles.iterdir()], ['codex.toml'])

    @unittest.skipIf(os.geteuid() == 0, 'needs directories another user than root owns')
    def test_as_root_register_writes_only_where_root_owns_the_directory(self):
        self.fake('id', 'echo 0\n')
        uid = os.getuid()

        # Claude Code keeps its user scope in CLAUDE_CONFIG_DIR, here the test user's.
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'as root, register does not write under {self.home}, which uid {uid} owns',
                      result.stderr)
        self.assertFalse(self.calls.exists())
        (self.fakes / 'claude').unlink()

        # A CODEX_HOME, or the directory it is in, that another user owns.
        codex_home = self.dir / 'agent-codex'
        codex_home.mkdir()
        self.env['CODEX_HOME'] = str(codex_home)
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'which uid {uid} owns', result.stderr)
        self.assertEqual(list(codex_home.iterdir()), [])

        # Below, ls reports root as the owner of everything, so each other rule shows.
        self.fake_root_ls()
        target = self.dir / 'elsewhere.toml'
        target.write_text('model = "example-model"\n')
        (codex_home / 'config.toml').symlink_to(target)
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'does not write through the symlink {codex_home}/config.toml', result.stderr)
        self.assertEqual(target.read_text(), 'model = "example-model"\n')
        (codex_home / 'config.toml').unlink()

        linked = self.dir / 'linked-codex'
        linked.symlink_to(codex_home)
        self.env['CODEX_HOME'] = str(linked)
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'does not write through the symlink {linked}', result.stderr)

        # A trailing slash does not hide the symlink.
        self.env['CODEX_HOME'] = f'{linked}/'
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'does not write through the symlink {linked}', result.stderr)

        self.env.update(CODEX_HOME=str(codex_home), FAKE_LS_MODE='drwxrwxrwt')
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'into {codex_home}, which group or others can write', result.stderr)
        self.assertEqual(list(codex_home.iterdir()), [])
        del self.env['FAKE_LS_MODE']

        # A parent others can write: refused, unless it is sticky and CODEX_HOME exists.
        self.env['FAKE_LS_PARENT_MODE'] = 'drwxrwxrwx'
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'under {self.dir}, which group or others can write', result.stderr)
        self.env['FAKE_LS_PARENT_MODE'] = 'drwxrwxrwt'
        missing = self.dir / 'not-yet'
        self.env['CODEX_HOME'] = str(missing)
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'does not create {missing} under {self.dir}, which others can write', result.stderr)
        self.assertFalse(missing.exists())
        self.env['CODEX_HOME'] = str(codex_home)
        self.run_installer('register')
        self.assertIn(f'command = "{self.launcher}"', (codex_home / 'config.toml').read_text())
        (codex_home / 'config.toml').unlink()
        del self.env['FAKE_LS_PARENT_MODE']

        # A CODEX_HOME root owns, or creates, is written.
        self.run_installer('register')
        self.assertIn(f'command = "{self.launcher}"', (codex_home / 'config.toml').read_text())
        fresh = self.dir / 'root-codex'
        self.env['CODEX_HOME'] = str(fresh)
        self.run_installer('register')
        self.assertIn(f'command = "{self.launcher}"', (fresh / 'config.toml').read_text())

    def test_a_codex_config_that_cannot_be_rewritten_is_left_alone(self):
        codex_home = self.home / '.codex'
        codex_home.mkdir()
        config = codex_home / 'config.toml'
        original = 'model = "example-model"\n\n[mcp_servers.other]\ncommand = "other-server"\n'
        config.write_text(original)

        # The filter fails (here: awk exits 2): exit 73, the config as it was, no temporary file.
        self.fake('awk', 'exit 2\n')
        result = self.run_installer('register', check=False)
        self.assertEqual(result.returncode, 73)
        self.assertIn(f'could not write {config}; it is unchanged', result.stderr)
        self.assertEqual(config.read_text(), original)
        self.assertEqual([p.name for p in codex_home.iterdir()], ['config.toml'])
        (self.fakes / 'awk').unlink()

        # A config this user cannot read, like a root-owned 0600 file in an agent's home.
        if os.geteuid() != 0:
            config.chmod(0o200)
            self.addCleanup(config.chmod, 0o600)
            result = self.run_installer('register', check=False)
            self.assertEqual(result.returncode, 73)
            self.assertIn(f'cannot read and write {config}', result.stderr)
            config.chmod(0o600)
            self.assertEqual(config.read_text(), original)

    def test_a_registration_that_cannot_be_written_exits_73(self):
        self.fake_harnesses(claude_exit=1)
        self.assertEqual(self.run_installer('register', check=False).returncode, 73)

        (self.fakes / 'claude').unlink()
        blocked = self.dir / 'codex-file'
        blocked.write_text('not a directory')
        self.env['CODEX_HOME'] = str(blocked)
        self.assertEqual(self.run_installer('register', check=False).returncode, 73)

    def test_register_needs_no_home_when_codex_home_is_set(self):
        del self.env['HOME']
        self.env['CODEX_HOME'] = str(self.dir / 'codex-home')
        result = self.run_installer('register')
        self.assertIn('registered optimal-engine with Codex', result.stdout)

    def test_registration_can_be_turned_off(self):
        self.env['OPTIMAL_CLIENT_REGISTER_MCP'] = '0'
        result = self.run_installer('register')
        self.assertIn('MCP registration skipped', result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertFalse((self.home / '.codex').exists())


if __name__ == '__main__':
    unittest.main()
