"""Black-box checks for the packaged client CLI (apps/cli/optimal, alias oe).

Every test talks to a local fake HTTP server or to no server at all; no Engine
process or database is started, and nothing reaches a real Engine port.
"""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'apps' / 'cli' / 'optimal'
ALIAS = ROOT / 'apps' / 'cli' / 'oe'
BUILD = ROOT / 'apps' / 'cli' / 'build.sh'
KEY = 'fixture-key-7d1f0c9a5b'
# Resolved to a path, so tests that narrow PATH still find the shell under test.
SHELL = shutil.which(os.environ.get('OPTIMAL_CLI_TEST_SHELL', '/bin/sh')) or os.environ.get(
    'OPTIMAL_CLI_TEST_SHELL', '/bin/sh')
ACTOR_FIELDS = {'actor_id', 'verifier_id', 'created_by'}
REMOTE = 'http://engine.example.invalid'


def mix_version():
    return re.search(r'@version "([^"]+)"', (ROOT / 'mix.exs').read_text()).group(1)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class FakeEngine:
    """Records requests and answers from a table of canned responses."""

    def __init__(self, require_key=KEY):
        self.requests = []
        self.routes = {}
        self.headers = {}
        engine = self

        class Handler(BaseHTTPRequestHandler):
            def handle_any(self):
                raw = self.rfile.read(int(self.headers.get('Content-Length', 0) or 0))
                split = urlsplit(self.path)
                body = json.loads(raw) if raw else None
                engine.requests.append({
                    'method': self.command,
                    'host': split.netloc or None,
                    'path': split.path,
                    'query': {k: v[0] for k, v in parse_qs(split.query).items()},
                    'auth': self.headers.get('Authorization'),
                    'body': body,
                })
                # A route is (status, payload) or (status, payload, response headers).
                status, payload, *extra = engine.routes.get((self.command, split.path),
                                                            (200, {'ok': True, 'path': split.path}))
                if require_key and self.headers.get('Authorization') != f'Bearer {require_key}':
                    status, payload = 401, {'error': 'missing_api_key'}
                out = json.dumps(payload).encode() if payload is not None else b''
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(out)))
                for name, value in {**engine.headers, **(extra[0] if extra else {})}.items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(out)

            do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any

            def log_message(self, *_):
                pass

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.url = f'http://127.0.0.1:{self.server.server_port}'
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    @property
    def last(self):
        return self.requests[-1]


class CliTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.home = self.dir / 'home'
        self.home.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('OPTIMAL_', 'OE_')) and k != 'XDG_CONFIG_HOME'
                    and k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy')}
        self.env.update(HOME=str(self.home), NO_PROXY='*', no_proxy='*')

    def engine(self, **kwargs):
        engine = FakeEngine(**kwargs)
        self.addCleanup(engine.close)
        self.env['OPTIMAL_ENGINE_URL'] = engine.url
        return engine

    def remote_engine(self, **kwargs):
        """A fake Engine the client sees at a remote URL: curl reaches it as its HTTP proxy."""
        engine = FakeEngine(**kwargs)
        self.addCleanup(engine.close)
        for name in ('NO_PROXY', 'no_proxy'):
            self.env.pop(name, None)
        self.env['http_proxy'] = engine.url
        self.env['OPTIMAL_ENGINE_URL'] = REMOTE
        return engine

    def run_cli(self, *args, program=CLI, stdin=None, shell=None):
        return subprocess.run([shell or SHELL, str(program), *args], env=self.env, input=stdin,
                              capture_output=True, text=True, timeout=30)

    def ok(self, *args, **kwargs):
        result = self.run_cli(*args, **kwargs)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def write_profile(self, text, name=None):
        base = self.home / '.config' / 'optimal'
        path = base / 'profiles' / name if name else base / 'profile'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o600)
        return path


class VersionAndAliasTests(CliTestCase):
    def test_version_is_the_engine_version(self):
        self.assertEqual(self.ok('--version').stdout.strip(), f'optimal {mix_version()}')
        self.assertEqual(self.ok('--version', program=ALIAS).stdout.strip(), f'oe {mix_version()}')

    def test_oe_alias_behaves_identically(self):
        engine = self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.ok('search', 'pricing', 'default:sales')
        self.ok('search', 'pricing', 'default:sales', program=ALIAS)
        first, second = engine.requests
        self.assertEqual(first, second)

    def test_version_command_reports_client_and_engine(self):
        engine = self.engine()
        engine.routes[('GET', '/api/version')] = (200, {'version': mix_version()})
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        out = json.loads(self.ok('version').stdout)
        self.assertEqual(out['client']['version'], mix_version())
        self.assertEqual(out['engine']['version'], mix_version())

    def test_help_lists_every_client_and_operator_command(self):
        text = self.ok('help').stdout
        for command in ['boot', 'today', 'fires', 'brief', 'loops', 'protocol', 'search', 'find', 'grep',
                        'assemble', 'read', 'capture', 'aware', 'note', 'lesson', 'decision', 'task',
                        'close', 'memory', 'claims', 'review', 'routing', 'authority', 'status',
                        'version', 'start', 'stop', 'restart', 'log', 'index', 'graph',
                        'reality-check', 'backup', 'init', 'size', 'viability', 'chain', 'check', 'analyses', 'jobs',
                        'session', 'sessions', 'policy', 'org-section', 'whoami']:
            self.assertIn(command, text)


class RouteMappingTests(CliTestCase):
    def setUp(self):
        super().setUp()
        self.fake = self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY

    def check(self, args, method, path, query=None, body=None, stdin=None):
        self.fake.requests.clear()
        self.ok(*args, stdin=stdin)
        request = self.fake.requests[0]
        self.assertEqual((request['method'], request['path']), (method, path), args)
        self.assertEqual(request['auth'], f'Bearer {KEY}')
        for key, value in (query or {}).items():
            self.assertEqual(request['query'].get(key), value, (args, key))
        for key, value in (body or {}).items():
            self.assertEqual(request['body'].get(key), value, (args, key))
        return request

    def test_session_commands(self):
        ws = 'default:sales'
        self.check(['boot', ws], 'GET', '/api/boot', {'workspace': ws})
        self.check(['today', ws, '--cadence', 'weekly'], 'GET', '/api/rhythm/current',
                   {'workspace': ws, 'cadence': 'weekly'})
        self.check(['rhythm', ws], 'GET', '/api/rhythm/current', {'workspace': ws})
        self.check(['brief', '--workspaces', '*'], 'GET', '/api/brief', {'workspaces': '*'})
        self.check(['brief', ws], 'GET', '/api/brief', {'workspace': ws})
        self.check(['protocol', ws], 'GET', '/api/protocol', {'workspace': ws})
        self.check(['commitments', ws], 'GET', '/api/operating-projection', {'workspace': ws})

    def test_loop_commands(self):
        ws = 'default:sales'
        self.check(['loops', ws, '--state', 'closed'], 'GET', '/api/loops', {'workspace': ws, 'state': 'closed'})
        self.check(['loops', 'list', '--workspaces', '*'], 'GET', '/api/loops', {'workspaces': '*'})
        self.check(['loops', 'add', 'Send the deck', ws, '--owner', 'user:jane', '--due', '2026-10-20',
                    '--counterparty', 'Northwind'], 'POST', '/api/loops', body={
            'workspace': ws, 'title': 'Send the deck', 'owner': 'user:jane',
            'due_at': '2026-10-20', 'counterparty': 'Northwind'})
        for action in ['close', 'drop', 'reopen']:
            self.check(['loops', action, 'loop_abc-1', '-w', ws, '--reason', 'done'], 'POST',
                       f'/api/loops/loop_abc-1/{action}', body={'workspace': ws})
        self.check(['loops', 'extract', ws], 'POST', '/api/loops/extract', body={'workspace': ws})

    def test_chat_session_and_org_policy_commands(self):
        ws = 'default:sales'
        messages = [{'role': 'user', 'content': 'We decided to ship Friday.', 'at': '2026-10-18T09:00:00Z'},
                    {'role': 'assistant', 'content': 'Noted.'}]
        path = self.dir / 'chat.json'
        path.write_text(json.dumps(messages))
        request = self.check(['session', 'commit', str(path), ws, '--correlation-id', 'chat_1',
                              '--title', 'Launch'], 'POST', '/api/sessions/commit',
                             body={'workspace': ws, 'correlation_id': 'chat_1', 'title': 'Launch',
                                   'source': 'optimal-cli', 'messages': messages})
        self.assertNotIn('summary', request['body'])
        self.check(['session', 'commit', '-', ws, '--correlation-id', 'chat_2', '--summary', 'Ship Friday'],
                   'POST', '/api/sessions/commit', body={'summary': 'Ship Friday', 'messages': messages},
                   stdin=json.dumps(messages))
        self.check(['session', ws], 'GET', '/api/sessions', {'workspace': ws})
        self.check(['sessions', 'list', ws, '--correlation-id', 'chat_1'], 'GET', '/api/sessions',
                   {'workspace': ws, 'correlation_id': 'chat_1'})
        self.check(['session', 'show', 'ses_abc', ws, '--transcript'], 'GET', '/api/sessions/ses_abc',
                   {'workspace': ws, 'include': 'transcript'})
        request = self.check(['session', 'show', 'ses_abc', ws], 'GET', '/api/sessions/ses_abc')
        self.assertNotIn('include', request['query'])
        self.check(['policy', ws], 'GET', '/api/org-policy', {'workspace': ws})
        self.check(['org-policy', ws], 'GET', '/api/org-policy', {'workspace': ws})
        self.check(['org-section'], 'GET', '/api/org-section')
        self.check(['org-section', 'set', 'default:org'], 'PUT', '/api/org-section',
                   body={'workspace_id': 'default:org'})
        self.check(['org-section', 'clear'], 'DELETE', '/api/org-section')
        for args in [['session', 'commit', str(path), ws],
                     ['session', 'commit', '-', ws, '--correlation-id', 'c'],
                     ['session', 'show', 'bad id', ws],
                     ['org-section', 'set'],
                     ['org-section', 'move']]:
            result = self.run_cli(*args, stdin='{"role": "user"}')
            self.assertEqual(result.returncode, 64, (args, result.stderr))

    def test_subcommands_without_arguments_under_dash(self):
        dash = shutil.which('dash')
        if not dash:
            self.skipTest('dash is not installed')
        self.env['OPTIMAL_WORKSPACE'] = 'default:sales'
        for command, path in [('loops', '/api/loops'), ('session', '/api/sessions')]:
            self.fake.requests.clear()
            result = self.run_cli(command, shell=dash)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.fake.requests[0]['path'], path)

    def test_retrieval_commands(self):
        ws = 'default:sales'
        self.check(['search', 'pricing & terms', ws, '-n', '3'], 'GET', '/api/search',
                   {'q': 'pricing & terms', 'workspace': ws, 'limit': '3'})
        self.check(['find', 'pricing', ws], 'GET', '/api/search', {'q': 'pricing'})
        self.check(['grep', 'invoice', ws, '--literal'], 'GET', '/api/grep',
                   {'q': 'invoice', 'literal': 'true', 'workspace': ws})
        self.check(['assemble', 'renewal', ws], 'POST', '/api/assemble', body={'query': 'renewal', 'workspace': ws})
        self.check(['ask', 'what changed?', ws], 'POST', '/api/rag', body={'query': 'what changed?'})
        self.check(['reconstruct', 'why?', ws], 'POST', '/api/reconstruct', body={'query': 'why?'})
        self.check(['read', 'optimal://nodes/sales/context.md', ws, '--tier', 'full'], 'GET', '/api/read',
                   {'uri': 'optimal://nodes/sales/context.md', 'workspace': ws, 'tier': 'full'})
        self.check(['read', 'ctx123', ws], 'GET', '/api/read', {'id': 'ctx123'})
        self.check(['memory', ws, '--limit', '4'], 'GET', '/api/memory', {'workspace': ws, 'limit': '4'})
        self.check(['claims', ws], 'GET', '/api/memory-core/claims', {'workspace': ws, 'kind': 'actionable'})
        self.check(['review', ws], 'GET', '/api/memory', {'workspace': ws})
        self.assertEqual(self.fake.requests[1]['path'], '/api/memory-core/claim-review')

    def test_record_commands(self):
        ws = 'default:sales'
        request = self.check(['capture', 'Call notes', ws, 'transcript', '--title', 'Call'], 'POST',
                             '/api/ingest', body={'text': 'Call notes', 'workspace': ws,
                                                  'genre': 'transcript', 'title': 'Call'})
        self.assertIs(request['body']['extract_claims'], True)
        self.check(['signal', 'raw', ws], 'POST', '/api/ingest', body={'text': 'raw'})
        for command, label in [('note', 'Note'), ('lesson', 'Lesson'), ('decision', 'Decision'),
                               ('task', 'Task'), ('close', 'Close-loop')]:
            request = self.check([command, 'did the thing', ws, '--owner', 'user:jane'], 'POST',
                                 '/api/memory/remember',
                                 body={'content': f'{label}: did the thing', 'workspace': ws, 'force': True})
            self.assertEqual(request['body']['metadata'],
                             {'kind': command, 'source': 'optimal-cli', 'owner': 'user:jane'})
        self.check(['remember', 'durable', ws], 'POST', '/api/memory/remember', body={'content': 'durable'})

    def test_aware_captures_remembers_and_searches(self):
        out = json.loads(self.ok('aware', 'correction', 'default:sales').stdout)
        self.assertEqual(set(out), {'captured', 'remembered', 'related'})
        self.assertEqual([(r['method'], r['path']) for r in self.fake.requests],
                         [('POST', '/api/ingest'), ('POST', '/api/memory/remember'), ('GET', '/api/search')])

    def test_routing_and_authority_commands(self):
        ws = 'default:sales'
        self.check(['routing'], 'GET', '/api/review/routing')
        self.check(['routing', 'review', 'unresolved'], 'GET', '/api/review/routing', {'state': 'unresolved'})
        self.check(['routing', 'rules', ws], 'GET', '/api/routing/rules', {'workspace': ws})
        self.check(['routing', 'classify', '--sender', 'jane@northwind.example', '--label', 'Sales',
                    '--text', 'renewal'], 'POST', '/api/routing/classify',
                   body={'sender': 'jane@northwind.example', 'labels': ['Sales'], 'text': 'renewal'})
        self.check(['authority', 'effective', ws], 'GET', '/api/authority/effective', {'workspace_id': ws})
        self.check(['authority', 'decide', ws, '--action', 'read', '--resource', 'optimal://default:sales/**'],
                   'POST', '/api/authority/decide',
                   body={'workspace_id': ws, 'action': 'read', 'resource': 'optimal://default:sales/**'})
        request = self.check(['authority', 'request', ws, '--action', 'export', '--resource',
                              'optimal://default:sales/x', '--ttl', '600'], 'POST', '/api/authority/requests',
                             body={'action': 'export', 'ttl_seconds': 600})
        self.assertNotIn('subject', request['body'])

    def test_engine_commands(self):
        self.check(['status'], 'GET', '/api/status')
        self.check(['health'], 'GET', '/api/health')
        self.check(['whoami'], 'GET', '/api/auth/whoami')
        self.check(['workspaces'], 'GET', '/api/workspaces')
        self.check(['backup', '--name', 'nightly.db'], 'POST', '/api/backup', body={'name': 'nightly.db'})
        self.check(['api', 'GET', '/api/stats'], 'GET', '/api/stats')
        self.check(['api', 'post', '/api/memory', '{"content":"x"}'], 'POST', '/api/memory', body={'content': 'x'})

    def test_setup_and_health_commands(self):
        ws = 'default:sales'
        self.check(['init', '--for', 'business', '--slug', 'brain', '--name', 'Brain'], 'POST', '/api/init',
                   body={'for': 'business', 'slug': 'brain', 'name': 'Brain'})
        self.check(['size'], 'GET', '/api/storage')
        self.check(['analyses', ws, '--kind', 'promises'], 'GET', '/api/analyses', {'workspace': ws, 'kind': 'promises'})
        self.check(['analyses', 'run', 'storage_usage', ws], 'POST', '/api/analyses/run',
                   body={'workspace': ws, 'kind': 'storage_usage'})
        self.check(['jobs', ws, '--state', 'dead'], 'GET', '/api/jobs', {'workspace': ws, 'status': 'dead'})
        self.check(['viability', ws], 'GET', '/api/viability', {'workspace': ws})
        self.check(['viability', '--workspaces', '*'], 'GET', '/api/viability', {'workspaces': '*'})
        self.check(['viability', 'history', ws, '--days', '14'], 'GET', '/api/viability/history',
                   {'workspace': ws, 'days': '14'})
        self.check(['chain', 'act_1f2e', ws], 'GET', '/api/agent-actions/act_1f2e', {'workspace': ws})
        self.check(['check', 'Can you confirm by Friday?', ws, '--channel', 'whatsapp', '--type', 'direct'],
                   'POST', '/api/signals/check',
                   body={'workspace': ws, 'draft': 'Can you confirm by Friday?',
                         'receiver': {'channel': 'whatsapp'}, 'type': 'direct'})

    def test_stdin_text(self):
        self.check(['capture', '-', 'default:sales'], 'POST', '/api/ingest',
                   body={'text': 'from stdin\nsecond line'}, stdin='from stdin\nsecond line\n')

    def test_client_never_sends_an_actor(self):
        ws = 'default:sales'
        for args in [['capture', 'x', ws], ['aware', 'x', ws], ['note', 'x', ws], ['task', 'x', ws],
                     ['close', 'x', ws], ['remember', 'x', ws], ['loops', 'add', 'x', ws],
                     ['loops', 'close', 'loop_1', '-w', ws], ['loops', 'extract', ws],
                     ['authority', 'decide', '--action', 'read', '--resource', 'optimal://x'],
                     ['authority', 'request', '--action', 'read', '--resource', 'optimal://x'],
                     ['routing', 'classify', '--text', 'x'], ['assemble', 'x', ws], ['backup']]:
            self.ok(*args)
        bodies = [r['body'] for r in self.fake.requests if r['body']]
        self.assertTrue(bodies)
        for body in bodies:
            self.assertFalse(ACTOR_FIELDS & set(body), body)
            self.assertFalse(ACTOR_FIELDS & set(body.get('metadata') or {}), body)
        self.assertTrue(all('actor' not in json.dumps(r['query']) for r in self.fake.requests))


class JsonTests(CliTestCase):
    def setUp(self):
        super().setUp()
        self.fake = self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY

    def test_text_survives_json_encoding(self):
        text = 'He said "hi" \\ path C:\\tmp\n\ttab line\r\nunicode: café, 東京, 🙂 \x01\x1f end'
        title = 'quote " and backslash \\'
        self.ok('capture', text, 'default:sales', '--title', title)
        body = self.fake.last['body']
        self.assertEqual(body['text'], text)
        self.assertEqual(body['title'], title)

    def test_query_parameters_are_url_encoded(self):
        query = 'a&b=c #frag ?x+y 100% "q"'
        self.ok('search', query, 'default:sales & co')
        self.assertEqual(self.fake.last['query']['q'], query)
        self.assertEqual(self.fake.last['query']['workspace'], 'default:sales & co')

    def test_field_extraction(self):
        self.fake.routes[('GET', '/api/boot')] = (200, {
            'workspace_id': 'default:sales',
            'brief': {'items': [{'id': 'x', 'note': 'a, b {c}'}], 'counts': {'total': 1}},
            'fires': [{'id': 'loop_1', 'title': 'Send "deck", today'}],
            'protocol': {'content': 'Line one\nLine "two"\twith tab and café', 'hash': 'abc'},
        })
        fires = json.loads(self.ok('fires', 'default:sales').stdout)
        self.assertEqual(fires, [{'id': 'loop_1', 'title': 'Send "deck", today'}])
        content = self.ok('boot', '--field', 'protocol.content').stdout
        self.assertEqual(content, 'Line one\nLine "two"\twith tab and café\n')
        counts = json.loads(self.ok('boot', '--field', 'brief.counts').stdout)
        self.assertEqual(counts, {'total': 1})
        missing = self.run_cli('boot', '--field', 'nope')
        self.assertEqual(missing.returncode, 1)
        self.assertIn("no field 'nope'", missing.stderr)


class ConfigTests(CliTestCase):
    def test_url_precedence(self):
        flag, env, legacy = self.engine(), self.engine(), self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.env['OPTIMAL_ENGINE_URL'] = env.url
        self.env['OE_API'] = legacy.url
        self.ok('--api', flag.url, 'status')
        self.ok('status')
        del self.env['OPTIMAL_ENGINE_URL']
        self.ok('status')
        self.assertEqual([len(e.requests) for e in (flag, env, legacy)], [1, 1, 1])
        self.assertEqual(self.ok('url').stdout.strip(), legacy.url)

    def test_profile_supplies_url_key_and_workspace(self):
        engine = FakeEngine()
        self.addCleanup(engine.close)
        self.write_profile(f'# written by a platform tool\nurl={engine.url}/\nkey="{KEY}"\nworkspace=default:sales\n')
        self.ok('search', 'renewal')
        self.assertEqual(engine.last['auth'], f'Bearer {KEY}')
        self.assertEqual(engine.last['query']['workspace'], 'default:sales')

    def test_named_profile_beats_environment(self):
        named, env = FakeEngine(), self.engine(require_key=None)
        self.addCleanup(named.close)
        self.write_profile(f'OPTIMAL_ENGINE_URL={named.url}\nOPTIMAL_ENGINE_API_KEY={KEY}\n', name='cloud')
        self.ok('--profile', 'cloud', 'status')
        self.assertEqual(len(named.requests), 1)
        self.assertEqual(env.requests, [])

    def test_profile_key_never_goes_to_another_url(self):
        other = self.engine(require_key=None)
        self.write_profile(f'url=https://engine.example.invalid\nkey={KEY}\n')
        self.ok('status')
        self.assertIsNone(other.last['auth'])

    def test_profile_key_file_is_read_each_time_it_is_used(self):
        engine = FakeEngine()
        self.addCleanup(engine.close)
        key_file = self.dir / 'key'
        key_file.write_text(KEY + '\n')
        self.write_profile(f'url={engine.url}\nkey_file={key_file}\nworkspace=default:sales\n')
        self.ok('whoami')
        self.assertEqual(engine.last['auth'], f'Bearer {KEY}')
        self.assertIn(f'key_file {key_file}', self.ok('doctor').stdout)
        key_file.write_text('rotated-key\n')
        self.run_cli('status')
        self.assertEqual(engine.last['auth'], 'Bearer rotated-key')

    def test_profile_key_file_is_not_read_for_another_url(self):
        other = self.engine(require_key=None)
        self.write_profile(f'url=https://engine.example.invalid\nkey_file={self.dir / "missing"}\n')
        self.ok('status')
        self.assertIsNone(other.last['auth'])

    def test_key_file(self):
        engine = self.engine()
        key_file = self.dir / 'key'
        key_file.write_text(KEY + '\n')
        self.ok('--key-file', str(key_file), 'status')
        self.env['OPTIMAL_ENGINE_API_KEY_FILE'] = str(key_file)
        self.ok('status')
        self.assertTrue(all(r['auth'] == f'Bearer {KEY}' for r in engine.requests))

    def test_workspace_sources(self):
        engine = self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.env['OPTIMAL_WORKSPACE'] = 'default:env'
        self.ok('memory')
        self.assertEqual(engine.last['query']['workspace'], 'default:env')
        self.ok('-w', 'default:flag', 'memory')
        self.assertEqual(engine.last['query']['workspace'], 'default:flag')
        self.ok('memory', 'default:arg')
        self.assertEqual(engine.last['query']['workspace'], 'default:arg')
        clash = self.run_cli('-w', 'default:flag', 'memory', 'default:arg')
        self.assertEqual(clash.returncode, 64)
        self.assertIn('workspace given twice', clash.stderr)

    def test_usage_errors(self):
        self.engine()
        for args in [['search'], ['bogus'], ['search', 'x', '--nope'], ['-n', 'ten', 'search', 'x'],
                     ['loops', 'close', '../x'], ['authority', 'decide'], ['init'], ['chain'],
                     ['chain', '../x'], ['viability', 'history', '--days', 'ten'], ['analyses', 'run'],
                     ['analyses', 'run', '../x']]:
            with self.subTest(args=args):
                self.assertEqual(self.run_cli(*args).returncode, 64)


class AuthAndSecrecyTests(CliTestCase):
    def setUp(self):
        super().setUp()
        self.fake = self.engine()

    def assert_no_key(self, result):
        self.assertNotIn(KEY, result.stdout + result.stderr)

    def test_missing_key(self):
        result = self.run_cli('search', 'x')
        self.assertEqual(result.returncode, 77)
        self.assertIn('authentication required', result.stderr)
        self.assertIn('missing_api_key', result.stderr)
        self.assertIsNone(self.fake.last['auth'])

    def test_rejected_key_names_its_source_not_its_value(self):
        self.env['OPTIMAL_ENGINE_API_KEY'] = 'wrong-' + KEY
        self.fake.routes[('GET', '/api/search')] = (401, {'error': 'invalid_api_key'})
        result = self.run_cli('search', 'x', '--verbose')
        self.assertEqual(result.returncode, 77)
        self.assertIn('OPTIMAL_ENGINE_API_KEY', result.stderr)
        self.assertNotIn('wrong-' + KEY, result.stdout + result.stderr)

    def test_forbidden_shows_the_error_code(self):
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.fake.routes[('POST', '/api/backup')] = (403, {'error': 'permission_scope_denied'})
        result = self.run_cli('backup')
        self.assertEqual(result.returncode, 77)
        self.assertIn('HTTP 403: permission_scope_denied', result.stderr)
        self.fake.routes[('GET', '/api/memory')] = (403, {'error': 'workspace_scope_denied'})
        result = self.run_cli('memory', 'default:other')
        self.assertIn('workspace_scope_denied', result.stderr)
        self.assertIn('default:other', result.stderr)

    def test_error_body_is_shown_only_when_it_adds_detail(self):
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.fake.routes[('GET', '/api/search')] = (404, {'error': 'workspace not found'})
        result = self.run_cli('search', 'x', 'example:other')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), 'optimal: HTTP 404 from GET /api/search: workspace not found')
        self.fake.routes[('POST', '/api/authority/requests')] = (403, {'error': 'denied', 'decision': {'effect': 'deny'}})
        result = self.run_cli('authority', 'request', '--action', 'export', '--resource', 'optimal://x')
        self.assertIn('"effect": "deny"', result.stderr)
        self.assertIn('HTTP 403: denied', result.stderr)

    def test_workspace_required(self):
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.fake.routes[('GET', '/api/memory')] = (400, {'error': 'workspace_required'})
        result = self.run_cli('memory')
        self.assertEqual(result.returncode, 64)
        self.assertIn('workspace_required', result.stderr)
        self.assertIn('--workspace', result.stderr)

    def test_key_is_never_printed(self):
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.fake.routes[('GET', '/api/search')] = (500, {'error': 'boom', 'echo': f'Bearer {KEY}'})
        self.fake.routes[('GET', '/api/status')] = (200, {'status': 'ok', 'echo': KEY})
        for args in [['search', 'x', '--verbose'], ['status', '--verbose'], ['doctor', '--verbose'],
                     ['--api', f'http://user:{KEY}@127.0.0.1:{free_port()}', 'status', '-v'],
                     ['version', '-v']]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assert_no_key(result)
        self.assertIn('[redacted]', self.run_cli('status').stdout)

    def test_key_never_reaches_a_process_argument_list(self):
        log = self.dir / 'curl-argv'
        bindir = self.dir / 'bin'
        bindir.mkdir()
        real_curl = shutil.which('curl')
        wrapper = bindir / 'curl'
        wrapper.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> {log}\nexec {real_curl} "$@"\n')
        wrapper.chmod(0o755)
        self.env['PATH'] = f'{bindir}:{self.env["PATH"]}'
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.ok('capture', 'x', 'default:sales')
        argv = log.read_text()
        self.assertIn('-H @-', argv)
        self.assertNotIn(KEY, argv)
        self.assertEqual(self.fake.last['auth'], f'Bearer {KEY}')

    def test_unreachable_engine(self):
        self.env['OPTIMAL_ENGINE_URL'] = f'http://127.0.0.1:{free_port()}'
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        result = self.run_cli('search', 'x')
        self.assertEqual(result.returncode, 69)
        self.assertIn('cannot reach the Engine', result.stderr)
        self.assert_no_key(result)


def next_minor(version, step=1):
    major, minor, _patch = (int(part) for part in version.split('.')[:3])
    return f'{major}.{minor + step}.0'


class CompatibilityTests(CliTestCase):
    """The Engine marks a client of another minor release; it refuses another major (426)."""

    def setUp(self):
        super().setUp()
        self.fake = self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.client = mix_version()

    def test_outdated_client_warns_once_on_stderr(self):
        engine = next_minor(self.client)
        self.fake.headers['X-Optimal-Client-Outdated'] = f'client={self.client} engine={engine}'
        result = self.ok('boot', 'default:sales')
        self.assertEqual(json.loads(result.stdout)['path'], '/api/boot')
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 1, result.stderr)
        self.assertIn('warning', lines[0])
        self.assertIn(f'client {self.client} is outdated for Engine {engine}', lines[0])
        self.assertIn(f'upgrade the client to {engine}', lines[0])
        # One line per run, however many requests the command makes.
        aware = self.ok('aware', 'correction', 'default:sales')
        self.assertEqual(len(self.fake.requests), 4)
        self.assertEqual(len(aware.stderr.splitlines()), 1, aware.stderr)

    def test_newer_client_warns_that_the_engine_is_older(self):
        major, minor, _ = self.client.split('.')
        if minor == '0':
            self.skipTest('no older minor release to compare with')
        engine = f'{major}.{int(minor) - 1}.0'
        self.fake.headers['x-optimal-client-outdated'] = f'client={self.client} engine={engine}'
        line = self.ok('search', 'x').stderr.strip()
        self.assertIn(f'client {self.client} is newer than Engine {engine}', line)

    def test_a_matching_engine_prints_nothing_on_stderr(self):
        self.assertEqual(self.ok('boot').stderr, '')

    def test_refused_client_exits_78_with_an_upgrade_hint(self):
        engine = f'{int(self.client.split(".")[0]) + 1}.0.0'
        self.fake.routes[('GET', '/api/boot')] = (426, {
            'error': 'client_incompatible',
            'message': f'This client (optimal-cli/{self.client}) is not compatible with this Engine ({engine}).',
            'client': f'optimal-cli/{self.client}', 'engine': engine, 'required': f'major:{engine[0]}'})
        result = self.run_cli('boot')
        self.assertEqual(result.returncode, 78, result.stderr)
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 1, result.stderr)
        self.assertIn('HTTP 426: client_incompatible', lines[0])
        self.assertIn(f'the Engine ({engine}) refuses client {self.client}', lines[0])
        self.assertIn(f'upgrade the client to {engine}', lines[0])
        self.assertNotIn(KEY, result.stderr)


class OperatorTests(CliTestCase):
    OPERATOR = [['start'], ['stop'], ['restart'], ['log'], ['index'], ['graph', 'backfill'],
                ['graph'], ['reality-check', '--disposable']]
    NO_ROUTE = [['start'], ['stop'], ['restart'], ['graph', 'backfill'], ['reality-check', '--disposable']]

    def setUp(self):
        super().setUp()
        self.calls = self.dir / 'calls'
        bindir = self.dir / 'bin'
        bindir.mkdir()
        for tool in ['mix', 'kill', 'nohup']:
            fake = bindir / tool
            fake.write_text(f'#!/bin/sh\nprintf "{tool} %s\\n" "$*" >> {self.calls}\n')
            fake.chmod(0o755)
        self.env['PATH'] = f'{bindir}:{self.env["PATH"]}'

    def fake_checkout(self, engine_script=None):
        checkout = self.dir / 'checkout'
        (checkout / 'apps' / 'cli').mkdir(parents=True)
        (checkout / 'lib').mkdir()
        (checkout / 'scripts').mkdir()
        (checkout / 'mix.exs').write_text('')
        (checkout / 'lib' / 'optimal_engine.ex').write_text('')
        script = checkout / 'scripts' / 'run-engine.sh'
        script.write_text(engine_script or '#!/bin/sh\nexit 1\n')
        script.chmod(0o755)
        shutil.copy2(CLI, checkout / 'apps' / 'cli' / 'optimal')
        return checkout

    def test_remote_engine_refuses_commands_without_a_maintenance_route(self):
        self.env['OPTIMAL_ENGINE_URL'] = 'https://engine.example.invalid'
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        program = self.fake_checkout() / 'apps' / 'cli' / 'optimal'
        for args in self.NO_ROUTE:
            with self.subTest(args=args):
                result = self.run_cli(*args, program=program)
                self.assertEqual(result.returncode, 78, result.stderr)
                lines = result.stderr.splitlines()
                self.assertEqual(len(lines), 1, result.stderr)
                name = ' '.join(a for a in args if not a.startswith('--'))
                self.assertIn(f"'{name}' against the remote Engine at https://engine.example.invalid", lines[0])
                self.assertIn('nothing was changed', lines[0])
                self.assertNotIn(KEY, result.stderr)
        self.assertFalse(self.calls.exists(), 'an operator command touched a local process or task')

    def test_remote_operator_commands_call_the_maintenance_routes(self):
        engine = self.remote_engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        engine.routes[('GET', '/api/maintenance/log')] = (200, {
            'count': 2, 'capacity': 1000, 'text': '2026-10-20T09:00:00Z [info] up\n2026-10-20T09:00:01Z [warning] slow'})
        # From an Engine checkout, so only the remote URL keeps it off the local process.
        program = self.fake_checkout() / 'apps' / 'cli' / 'optimal'
        ws = 'default:ops'
        cases = [
            (['index', '-w', ws], 'POST', '/api/maintenance/index', {}, {'workspace': ws}),
            (['index'], 'POST', '/api/maintenance/index', {}, {}),
            (['log', '-n', '50'], 'GET', '/api/maintenance/log', {'lines': '50'}, None),
            (['logs'], 'GET', '/api/maintenance/log', {'lines': '200'}, None),
            (['graph', '-w', ws], 'GET', '/api/maintenance/graph', {'workspace': ws}, None),
            (['graph', 'hubs', '-w', ws], 'GET', '/api/graph/hubs', {'workspace': ws}, None),
            (['graph', 'clusters'], 'GET', '/api/graph/clusters', {}, None),
            (['graph', 'triangles', '-n', '5'], 'GET', '/api/graph/triangles', {'limit': '5'}, None),
        ]
        for args, method, path, query, body in cases:
            with self.subTest(args=args):
                engine.requests.clear()
                result = self.run_cli(*args, program=program)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(engine.requests), 1, engine.requests)
                request = engine.requests[0]
                self.assertEqual((request['host'], request['method'], request['path']),
                                 ('engine.example.invalid', method, path))
                self.assertEqual(request['auth'], f'Bearer {KEY}')
                self.assertEqual(request['query'], query)
                if body is not None:
                    self.assertEqual(request['body'] or {}, body)
        log = self.ok('log', program=program).stdout
        self.assertEqual(log, '2026-10-20T09:00:00Z [info] up\n2026-10-20T09:00:01Z [warning] slow\n')
        self.assertFalse(self.calls.exists(), 'a remote operator command touched a local process or task')

    def test_remote_engine_without_the_route_exits_78(self):
        engine = self.remote_engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        engine.routes[('POST', '/api/maintenance/index')] = (404, {'error': 'not found'})
        result = self.run_cli('index')
        self.assertEqual(result.returncode, 78, result.stderr)
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
        self.assertIn("has no route for 'index' (POST /api/maintenance/index)", result.stderr)
        self.assertIn('upgrade the Engine', result.stderr)
        engine.routes[('GET', '/api/maintenance/graph')] = (404, {'error': 'workspace not found'})
        result = self.run_cli('graph', '-w', 'default:gone')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('workspace not found', result.stderr)

    def test_remote_maintenance_needs_an_admin_key(self):
        engine = self.remote_engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        engine.routes[('GET', '/api/maintenance/log')] = (403, {'error': 'permission_scope_denied'})
        result = self.run_cli('log')
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertIn('permission_scope_denied', result.stderr)
        self.assertIn('GET /api/maintenance/log', result.stderr)

    def test_remote_operator_usage_errors(self):
        self.remote_engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        for args in [['index', 'extra'], ['log', 'extra'], ['graph', 'bogus'], ['graph', 'hubs', 'extra'],
                     ['restart', 'now']]:
            with self.subTest(args=args):
                self.assertEqual(self.run_cli(*args).returncode, 64)

    def test_local_url_outside_a_checkout_refuses(self):
        loose = self.dir / 'loose'
        loose.mkdir()
        shutil.copy2(CLI, loose / 'optimal')
        self.env['OPTIMAL_ENGINE_URL'] = f'http://127.0.0.1:{free_port()}'
        for args in self.OPERATOR:
            with self.subTest(args=args):
                result = self.run_cli(*args, program=loose / 'optimal')
                self.assertEqual(result.returncode, 78)
                self.assertIn('not running from an Engine checkout', result.stderr)
        self.assertFalse(self.calls.exists())

    def test_never_stops_or_bypasses_an_engine_it_did_not_start(self):
        engine = self.engine(require_key=None)
        checkout = self.fake_checkout()
        program = checkout / 'apps' / 'cli' / 'optimal'
        for args in [['stop'], ['restart'], ['index'], ['graph', 'backfill'], ['reality-check', '--disposable']]:
            with self.subTest(args=args):
                result = self.run_cli(*args, program=program)
                self.assertEqual(result.returncode, 78, result.stderr)
        start = self.ok('start', program=program)
        self.assertIn('not started by this CLI', start.stdout)
        self.assertFalse(self.calls.exists())
        self.assertTrue(all(r['path'] == '/api/health' for r in engine.requests))

    def test_reality_check_requires_disposable(self):
        self.env['OPTIMAL_ENGINE_URL'] = 'https://engine.example.invalid'
        result = self.run_cli('reality-check')
        self.assertEqual(result.returncode, 64)
        self.assertIn('--disposable', result.stderr)

    def test_start_and_stop_an_engine_it_started(self):
        # Use the real kill and nohup for this test.
        self.env['PATH'] = os.environ['PATH']
        port = free_port()
        stub = (
            f'#!/bin/sh\nexec {sys.executable} -c "'
            'import http.server, os\n'
            'class H(http.server.BaseHTTPRequestHandler):\n'
            '    def do_GET(self):\n'
            '        self.send_response(200); self.end_headers(); self.wfile.write(b\'{}\')\n'
            '    def log_message(self, *a): pass\n'
            'http.server.HTTPServer((os.environ[\'OPTIMAL_API_INTERFACE\'], '
            'int(os.environ[\'OPTIMAL_API_PORT\'])), H).serve_forever()"\n'
        )
        checkout = self.fake_checkout(stub)
        program = checkout / 'apps' / 'cli' / 'optimal'
        self.env['OPTIMAL_ENGINE_URL'] = f'http://127.0.0.1:{port}'
        started = self.ok('start', program=program)
        self.assertIn('Engine started', started.stdout)
        pid = int((checkout / '.optimal' / 'cli-engine.pid').read_text().split()[0])
        self.addCleanup(lambda: _kill_quietly(pid))
        self.assertIn('Engine already running', self.ok('start', program=program).stdout)
        self.assertIn('Engine stopped', self.ok('stop', program=program).stdout)
        time.sleep(0.2)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertFalse((checkout / '.optimal' / 'cli-engine.pid').exists())
        self.assertIn('No Engine started by this CLI', self.ok('stop', program=program).stdout)

    def test_backup_uses_the_server_endpoint_against_a_remote_engine(self):
        engine = self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        self.ok('backup')
        self.assertEqual((engine.last['method'], engine.last['path']), ('POST', '/api/backup'))


def _kill_quietly(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


class PortabilityTests(CliTestCase):
    def test_runs_with_only_posix_tools_and_curl(self):
        engine = self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        bindir = self.dir / 'minimal-bin'
        bindir.mkdir()
        for tool in ['sh', 'curl', 'awk', 'sed', 'tr', 'cat', 'mktemp', 'rm', 'find', 'dirname', 'readlink']:
            path = shutil.which(tool)
            self.assertIsNotNone(path, tool)
            (bindir / tool).symlink_to(path)
        self.env['PATH'] = str(bindir)
        self.ok('capture', 'quote " backslash \\ newline\nend', 'default:sales')
        self.assertEqual(engine.last['body']['text'], 'quote " backslash \\ newline\nend')
        self.ok('boot', '--field', 'path')

    def test_other_shells(self):
        engine = self.engine()
        self.env['OPTIMAL_ENGINE_API_KEY'] = KEY
        for shell in ['dash', 'bash', 'ksh', 'zsh', 'busybox']:
            path = shutil.which(shell)
            if not path:
                continue
            with self.subTest(shell=shell):
                argv = [path, 'sh'] if shell == 'busybox' else [path]
                if shell == 'zsh':
                    argv += ['--emulate', 'sh']
                result = subprocess.run([*argv, str(CLI), 'capture', 'a "b" \\c', 'default:sales'],
                                        env=self.env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(engine.last['body']['text'], 'a "b" \\c')


class BuildTests(unittest.TestCase):
    def test_build_produces_versioned_platform_archives(self):
        with tempfile.TemporaryDirectory() as out:
            subprocess.run(['sh', str(BUILD), out], check=True, capture_output=True, text=True, timeout=60)
            version = mix_version()
            platforms = ['linux-amd64', 'linux-arm64', 'darwin-amd64', 'darwin-arm64']
            names = sorted(p.name for p in Path(out).iterdir())
            self.assertEqual(names, sorted([f'optimal-{version}-{p}.tar.gz' for p in platforms] + ['SHA256SUMS']))
            sums = (Path(out) / 'SHA256SUMS').read_text()
            for platform in platforms:
                self.assertIn(f'optimal-{version}-{platform}.tar.gz', sums)
            archive = Path(out) / f'optimal-{version}-linux-arm64.tar.gz'
            with tarfile.open(archive) as tar:
                members = {m.name: m for m in tar.getmembers()}
                prefix = f'optimal-{version}-linux-arm64'
                self.assertTrue(members[f'{prefix}/oe'].issym())
                self.assertEqual(members[f'{prefix}/oe'].linkname, 'optimal')
                for name in ['optimal', 'install.sh', 'install-client.sh', 'LICENSE', 'VERSION']:
                    self.assertIn(f'{prefix}/{name}', members)
                tar.extractall(out, filter='tar') if sys.version_info >= (3, 12) else tar.extractall(out)
            bindir = Path(out) / 'prefix'
            subprocess.run(['sh', str(Path(out) / prefix / 'install.sh'), str(bindir)], check=True,
                           capture_output=True, text=True, timeout=30)
            result = subprocess.run([str(bindir / 'bin' / 'oe'), '--version'], capture_output=True,
                                    text=True, timeout=30)
            self.assertEqual(result.stdout.strip(), f'oe {version}')


if __name__ == '__main__':
    unittest.main()
