"""Black-box checks for deploy/miosa-template/install-client.sh.

Each test runs the installer in a temporary HOME and prefix, from release files
built from this checkout (apps/cli/build.sh) and a minimal stand-in MCP server
archive, or from OPTIMAL_CLIENT_TEST_RELEASE_DIR when it names real release
files (apps/cli/build.sh and apps/mcp/build.sh output). The Engine is a local
fake; fake `claude` and `codex` programs record what registration does. Nothing
reaches a real Engine, harness, or the network.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import threading
import unittest
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from test_optimal_cli import KEY, FakeEngine, mix_version

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / 'deploy' / 'miosa-template' / 'install-client.sh'
CLI_BUILD = ROOT / 'apps' / 'cli' / 'build.sh'
VERSION = mix_version()
MCP_ARCHIVE = f'optimal-engine-mcp-{VERSION}.tar.gz'


def node_ok():
    node = shutil.which('node')
    if not node:
        return False
    out = subprocess.run([node, '-p', 'process.versions.node.split(".")[0]'], capture_output=True, text=True)
    return out.returncode == 0 and int(out.stdout.strip() or 0) >= 20


NODE = node_ok()

# Answers an MCP initialize the way the real server does, so the installer's
# check can be exercised without npm.
STAND_IN_SERVER = '''
const readline = require("node:readline");
const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const request = JSON.parse(line);
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: {
    protocolVersion: "2025-06-18", capabilities: {},
    serverInfo: { name: "optimal-engine", version: "%s" } } }) + "\\n");
});
''' % VERSION


class QuietFiles(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build_release(out):
    """CLI archives from the checkout plus a stand-in MCP archive, with SHA256SUMS."""
    subprocess.run(['sh', str(CLI_BUILD), str(out)], check=True, capture_output=True, text=True, timeout=60)
    with tempfile.TemporaryDirectory() as stage:
        root = Path(stage) / f'optimal-engine-mcp-{VERSION}'
        (root / 'dist').mkdir(parents=True)
        (root / 'node_modules').mkdir()
        (root / 'dist' / 'index.js').write_text(STAND_IN_SERVER)
        # The installer checks the server's config for key_file= support, as in the real one.
        (root / 'dist' / 'config.js').write_text('// profiles: url=, key= or key_file=, workspace=\n')
        (root / 'package.json').write_text(json.dumps({'name': 'stand-in', 'type': 'commonjs'}))
        (root / 'VERSION').write_text(VERSION + '\n')
        subprocess.run(['tar', '-C', stage, '-czf', str(Path(out) / MCP_ARCHIVE), root.name], check=True)
    sums = Path(out) / 'SHA256SUMS'
    lines = [line for line in sums.read_text().splitlines() if not line.endswith(MCP_ARCHIVE)]
    lines.append(f'{sha256(Path(out) / MCP_ARCHIVE)}  {MCP_ARCHIVE}')
    sums.write_text('\n'.join(sorted(lines, key=lambda l: l.split()[1])) + '\n')


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
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('OPTIMAL_', 'OE_', 'CODEX_')) and k != 'XDG_CONFIG_HOME'}
        self.env.update(
            HOME=str(self.home),
            CLAUDE_CONFIG_DIR=str(self.home / '.claude'),
            PATH=f'{self.fakes}:{self.bin}:{os.environ.get("PATH", "/usr/bin:/bin")}',
            NO_PROXY='*', no_proxy='*',
            OPTIMAL_CLIENT_SOURCE=str(self.release),
            OPTIMAL_CLIENT_PREFIX=str(self.prefix),
            OPTIMAL_CLIENT_BIN_DIR=str(self.bin),
            OPTIMAL_CLIENT_REGISTER_MCP='0',
        )
        if not NODE:
            self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'

    def run_installer(self, *args, check=True):
        result = subprocess.run(['sh', str(INSTALLER), *args], env=self.env, capture_output=True,
                                text=True, timeout=120)
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
        self.assertTrue(os.access(self.prefix / 'bin' / 'optimal', os.X_OK))
        if NODE:
            self.assertIn(f'ok: optimal-engine-mcp {VERSION} answers initialize', result.stdout)
            self.assertTrue((self.prefix / 'mcp' / 'dist' / 'index.js').is_file())
            self.assertTrue((self.bin / 'optimal-engine-mcp').exists())

    @unittest.skipUnless(NODE, 'needs Node.js 20 or newer')
    def test_the_mcp_launcher_names_the_installed_server(self):
        self.run_installer('install')
        launcher = (self.prefix / 'bin' / 'optimal-engine-mcp').read_text()
        self.assertIn(f"'{self.prefix}/mcp/dist/index.js'", launcher)

    def test_skip_mcp_installs_only_the_cli(self):
        self.env['OPTIMAL_CLIENT_SKIP_MCP'] = '1'
        result = self.run_installer()
        self.assertIn('MCP server skipped', result.stdout)
        self.assertFalse((self.prefix / 'bin' / 'optimal-engine-mcp').exists())

    def test_a_tampered_archive_is_refused_and_nothing_is_installed(self):
        copy = self.copy_release()
        for archive in copy.glob(f'optimal-{VERSION}-*.tar.gz'):
            with archive.open('ab') as handle:
                handle.write(b'tampered')
        result = self.run_installer(check=False)
        self.assertEqual(result.returncode, 65)
        self.assertIn('sha256 mismatch', result.stderr)
        self.assertFalse((self.prefix / 'bin' / 'optimal').exists())

    def test_an_archive_without_a_checksum_is_refused_unless_pinned(self):
        copy = self.copy_release()
        (copy / 'SHA256SUMS').unlink()
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 65)
        self.assertIn('no sha256', result.stderr)
        self.assertFalse((self.prefix / 'bin' / 'optimal').exists())

        platform = subprocess.run(['uname', '-s'], capture_output=True, text=True).stdout.strip().lower()
        machine = subprocess.run(['uname', '-m'], capture_output=True, text=True).stdout.strip()
        arch = {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}[machine]
        self.env['OPTIMAL_CLI_SHA256'] = sha256(copy / f'optimal-{VERSION}-{platform}-{arch}.tar.gz')
        self.env['OPTIMAL_MCP_SHA256'] = sha256(copy / MCP_ARCHIVE)
        self.run_installer('install', 'verify')

    def test_installs_from_an_http_source(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietFiles, directory=str(self.release)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.env['OPTIMAL_CLIENT_SOURCE'] = f'http://127.0.0.1:{server.server_port}/'
        result = self.run_installer('install', 'verify')
        self.assertIn(f'verified optimal-{VERSION}-', result.stdout)

    def test_input_errors_exit_64(self):
        self.assertEqual(self.run_installer('upgrade', check=False).returncode, 64)
        self.env['OPTIMAL_CLI_SHA256'] = 'not-a-sha'
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 64)
        self.assertIn('not 64 hex digits', result.stderr)
        del self.env['OPTIMAL_CLI_SHA256']
        self.env['OPTIMAL_CLIENT_PREFIX'] = 'relative/prefix'
        self.assertEqual(self.run_installer('install', check=False).returncode, 64)

    def test_a_missing_source_exits_69(self):
        self.env['OPTIMAL_CLIENT_SOURCE'] = str(self.dir / 'no-such-release')
        self.env['OPTIMAL_CLI_SHA256'] = '0' * 64
        result = self.run_installer('install', check=False)
        self.assertEqual(result.returncode, 69)
        self.assertIn('does not exist', result.stderr)

    def test_reinstalling_is_idempotent(self):
        self.run_installer()
        self.run_installer()
        self.assertEqual((self.prefix / 'VERSION').read_text().strip(), VERSION)
        self.assertFalse((self.prefix / 'mcp.old').exists())


class ConfigureAndVerifyTests(InstallClientTestCase):
    def test_profile_names_the_key_file_and_verify_reaches_the_engine(self):
        engine = self.engine()
        key_file = self.key_file()
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY_FILE=str(key_file),
                        OPTIMAL_WORKSPACE='default:sales')
        result = self.run_installer()
        output = result.stdout + result.stderr
        self.assertNotIn(KEY, output)
        self.assertIn('ok: whoami', output)
        self.assertIn('authenticated: true', output)
        self.assertIn('ok: search', output)

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

        # Later runs need no environment: the profile carries the configuration.
        for name in ['OPTIMAL_ENGINE_URL', 'OPTIMAL_ENGINE_API_KEY_FILE', 'OPTIMAL_WORKSPACE']:
            del self.env[name]
        engine.requests.clear()
        self.run_installer('verify')
        self.assertTrue(engine.requests)
        self.assertTrue(all(r['auth'] == f'Bearer {KEY}' for r in engine.requests))

    def test_an_inline_key_is_written_only_to_a_private_profile(self):
        engine = self.engine()
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY=KEY,
                        OPTIMAL_WORKSPACE='default:sales')
        result = self.run_installer()
        self.assertNotIn(KEY, result.stdout + result.stderr)
        profile = self.home / '.config' / 'optimal' / 'profile'
        self.assertEqual(stat.S_IMODE(profile.stat().st_mode), 0o600)
        self.assertIn(f'key={KEY}\n', profile.read_text())

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

    def test_a_client_without_key_file_support_gets_the_key_itself(self):
        old_cli = self.prefix / 'bin' / 'optimal'
        old_cli.parent.mkdir(parents=True)
        old_cli.write_text('#!/bin/sh\necho "optimal 0.3.1"\n')
        old_cli.chmod(0o755)
        engine = self.engine()
        self.env.update(OPTIMAL_ENGINE_URL=engine.url, OPTIMAL_ENGINE_API_KEY_FILE=str(self.key_file()))
        result = self.run_installer('configure')
        self.assertNotIn(KEY, result.stdout + result.stderr)
        profile = (self.home / '.config' / 'optimal' / 'profile').read_text()
        self.assertIn(f'key={KEY}\n', profile)
        self.assertNotIn('key_file=', profile)

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

    def test_an_unreadable_key_file_exits_66(self):
        self.env.update(OPTIMAL_ENGINE_URL='https://engine.example.invalid',
                        OPTIMAL_ENGINE_API_KEY_FILE=str(self.dir / 'missing-key'))
        self.assertEqual(self.run_installer('configure', check=False).returncode, 66)
        self.assertFalse((self.home / '.config' / 'optimal' / 'profile').exists())

    def test_no_engine_url_writes_no_profile(self):
        result = self.run_installer('configure')
        self.assertIn('no profile written', result.stdout)
        self.assertFalse((self.home / '.config' / 'optimal' / 'profile').exists())


# What `register` runs besides the harness programs. The tests put only these and
# fakes on PATH, so a real `claude` or `codex` on the test machine is never run.
REGISTER_TOOLS = ['sh', 'awk', 'cat', 'cp', 'grep', 'mkdir', 'mktemp', 'mv', 'rm', 'sed', 'uname']


class RegisterTests(InstallClientTestCase):
    def setUp(self):
        super().setUp()
        tools = self.dir / 'tools'
        tools.mkdir()
        for tool in REGISTER_TOOLS:
            (tools / tool).symlink_to(shutil.which(tool))
        self.env['PATH'] = f'{self.fakes}:{tools}'
        self.env['OPTIMAL_CLIENT_REGISTER_MCP'] = '1'
        self.calls = self.dir / 'claude-calls'
        claude = self.fakes / 'claude'
        claude.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >>"{self.calls}"\n')
        claude.chmod(0o755)
        codex = self.fakes / 'codex'
        codex.write_text('#!/bin/sh\nexit 0\n')
        codex.chmod(0o755)
        # Registration only needs the launcher, so it is put in place directly.
        launcher = self.prefix / 'bin' / 'optimal-engine-mcp'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('#!/bin/sh\nexit 0\n')
        launcher.chmod(0o755)
        self.launcher = launcher

    def test_registers_with_claude_code_and_codex_and_keeps_other_codex_settings(self):
        codex_home = self.home / '.codex'
        codex_home.mkdir()
        (codex_home / 'config.toml').write_text(
            'model = "example-model"\n\n'
            '[mcp_servers.optimal-engine]\ncommand = "/old/optimal-engine-mcp"\n\n'
            '[mcp_servers.optimal-engine.env]\nOLD = "1"\n\n'
            '[mcp_servers.other]\ncommand = "other-server"\n')

        self.run_installer('register')
        self.run_installer('register')

        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls.count(f'mcp add --scope user optimal-engine -- {self.launcher}'), 2)
        self.assertIn('mcp remove --scope user optimal-engine', calls)

        toml = (codex_home / 'config.toml').read_text()
        self.assertEqual(toml.count('[mcp_servers.optimal-engine]'), 1)
        self.assertIn(f'[mcp_servers.optimal-engine]\ncommand = "{self.launcher}"\n', toml)
        self.assertNotIn('/old/optimal-engine-mcp', toml)
        self.assertNotIn('OLD = "1"', toml)
        self.assertIn('model = "example-model"', toml)
        self.assertIn('[mcp_servers.other]\ncommand = "other-server"', toml)

    def test_codex_home_is_honoured_and_absent_harnesses_are_skipped(self):
        (self.fakes / 'claude').unlink()
        codex_home = self.dir / 'codex-home'
        self.env['CODEX_HOME'] = str(codex_home)
        result = self.run_installer('register')
        self.assertNotIn('Claude Code', result.stdout)
        self.assertIn(f'command = "{self.launcher}"', (codex_home / 'config.toml').read_text())
        self.assertFalse(self.calls.exists())

    def test_registration_can_be_turned_off(self):
        self.env['OPTIMAL_CLIENT_REGISTER_MCP'] = '0'
        result = self.run_installer('register')
        self.assertIn('MCP registration skipped', result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertFalse((self.home / '.codex').exists())


if __name__ == '__main__':
    unittest.main()
