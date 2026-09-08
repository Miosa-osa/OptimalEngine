"""Black-box wrapper routing checks; no Engine process or database is started."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WRAPPER = Path(__file__).resolve().parents[2] / 'bin' / 'optimal'


class WrapperRoutingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'bin').mkdir()
        self.wrapper = self.root / 'bin' / 'optimal'
        shutil.copy2(WRAPPER, self.wrapper)
        self.marker = self.root / 'mix-calls'
        mix = self.root / 'bin' / 'mix'
        mix.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FAKE_MIX_LOG"\n')
        mix.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.root / "bin"}:{os.environ["PATH"]}',
                        FAKE_MIX_LOG=str(self.marker), NO_PROXY='127.0.0.1')
        self.env.pop('OPTIMAL_ENGINE_API_KEY', None)
        self.env.pop('OPTIMAL_ENGINE_API_URL', None)
        self.requests = []

    def serve(self, *, health_status=200, action_status=200):
        requests = self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.respond(health_status)

            def do_POST(self):
                self.respond(action_status)

            def respond(self, status):
                body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                requests.append((self.command, self.path, self.headers.get('Authorization'), body))
                if self.headers.get('Authorization') != 'Bearer fixture-token':
                    status = 401
                output = json.dumps({'status': status}).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(output)))
                self.end_headers()
                self.wfile.write(output)

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.env['OPTIMAL_ENGINE_API_URL'] = f'http://127.0.0.1:{server.server_port}'

    def run_wrapper(self, *args):
        return subprocess.run([str(self.wrapper), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_valid_credential_is_used_for_probe_and_capture(self):
        self.serve()
        self.env['OPTIMAL_ENGINE_API_KEY'] = 'fixture-token'
        result = self.run_wrapper('capture', 'synthetic evidence', '--workspace', 'default:fixture')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.marker.exists(), 'authenticated API call fell back to local Mix')
        self.assertEqual([(r[0], r[1]) for r in self.requests],
                         [('GET', '/api/health'), ('POST', '/api/ingest')])
        self.assertTrue(all(r[2] == 'Bearer fixture-token' for r in self.requests))
        self.assertEqual(json.loads(self.requests[-1][3])['workspace'], 'default:fixture')

    def test_missing_or_invalid_credential_never_falls_back_to_local_writes(self):
        self.serve()
        for token in [None, 'invalid-fixture-token']:
            with self.subTest(token=token):
                if token:
                    self.env['OPTIMAL_ENGINE_API_KEY'] = token
                result = self.run_wrapper('capture', 'must not be stored')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.marker.exists())
        self.assertTrue(all(r[0] == 'GET' for r in self.requests))

    def test_reachable_forbidden_or_unhealthy_server_never_falls_back(self):
        for status in [403, 503]:
            with self.subTest(status=status):
                self.serve(health_status=status)
                self.env['OPTIMAL_ENGINE_API_KEY'] = 'fixture-token'
                result = self.run_wrapper('capture', 'must not be stored')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.marker.exists())

    def test_operation_denial_is_a_failed_command_without_local_fallback(self):
        self.serve(action_status=403)
        self.env['OPTIMAL_ENGINE_API_KEY'] = 'fixture-token'
        result = self.run_wrapper('capture', 'denied evidence')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_explicit_unreachable_api_never_falls_back(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.env['OPTIMAL_ENGINE_API_URL'] = f'http://127.0.0.1:{port}'
        result = self.run_wrapper('capture', 'must not be stored')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def simulate_unavailable_default_api(self):
        # Never contact the developer's real localhost service.
        curl = self.root / 'bin' / 'curl'
        curl.write_text('#!/bin/sh\nprintf 000\nexit 7\n')
        curl.chmod(0o755)

    def test_api_credential_prevents_unreachable_default_fallback(self):
        self.simulate_unavailable_default_api()
        self.env['OPTIMAL_ENGINE_API_KEY'] = 'fixture-token'
        result = self.run_wrapper('capture', 'must not be stored')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_unconfigured_local_development_retains_fallback(self):
        self.simulate_unavailable_default_api()
        result = self.run_wrapper('capture', 'local fixture')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('optimal.ingest local fixture', self.marker.read_text())


if __name__ == '__main__':
    unittest.main()
