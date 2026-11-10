#!/usr/bin/env python3
"""Run the Debug helper's real cloud and migration services against isolated fixtures."""
import functools
import http.server
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import uuid


def run(helper, mode):
    suite = ('waifux-migration-integration-' if mode == 'migration' else 'waifux-cloud-integration-') + str(uuid.uuid4())
    requests = []
    server = None
    server_thread = None
    with tempfile.TemporaryDirectory(prefix='waifux-cloud-integration-') as root:
        env = dict(os.environ, WAIFUX_HELPER_TEST_ROOT=root, WAIFUX_HELPER_TEST_SUITE=suite)
        if mode == 'webdav':
            directory = Path(root) / 'cloud'
            directory.mkdir()

            class Handler(http.server.SimpleHTTPRequestHandler):
                def log_message(self, *_args):
                    pass

                def do_GET(self):
                    requests.append(('GET', self.path))
                    super().do_GET()

                def do_PUT(self):
                    requests.append(('PUT', self.path))
                    target = Path(self.translate_path(self.path))
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(self.rfile.read(int(self.headers['Content-Length'])))
                    self.send_response(201)
                    self.send_header('Content-Length', '0')
                    self.end_headers()

                def do_MKCOL(self):
                    requests.append(('MKCOL', self.path))
                    target = Path(self.translate_path(self.path))
                    if target.exists():
                        self.send_response(405)
                    else:
                        target.mkdir(parents=True)
                        self.send_response(201)
                    self.send_header('Content-Length', '0')
                    self.end_headers()

                def do_DELETE(self):
                    requests.append(('DELETE', self.path))
                    self.send_error(403)

            server = http.server.ThreadingHTTPServer(
                ('127.0.0.1', 0), functools.partial(Handler, directory=str(directory)))
            server_thread = threading.Thread(target=server.serve_forever, daemon=True)
            server_thread.start()
            env['WAIFUX_TEST_WEBDAV_URL'] = f'http://127.0.0.1:{server.server_port}/'
        try:
            command = '--wallhaven-migration-regression' if mode == 'migration' else '--wallhaven-cloud-regression'
            result = subprocess.run([str(helper), command], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, timeout=90)
            print(f'[{mode}] {result.stdout.strip()}', flush=True)
            if result.returncode:
                raise RuntimeError(f'{mode} helper exited {result.returncode}')
            if mode == 'webdav':
                assert requests, 'No real HTTP operations were exercised'
                assert all(method != 'DELETE' for method, _ in requests), requests
                assert not any('/Media/' in path or '/objects/bb/' in path for _, path in requests), requests
                print(f'PASS: WebDAV HTTP fixture exercised {len(requests)} requests; no retired object read or deletion', flush=True)
        finally:
            if server:
                server.shutdown()
                server.server_close()
                server_thread.join()
            subprocess.run(['/usr/bin/defaults', 'delete', suite],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('Usage: test-wallhaven-helper-integration.py /path/to/Debug/WaifuXHelper.app/Contents/MacOS/WaifuXHelper')
    helper = Path(sys.argv[1]).resolve(strict=True)
    for mode in ['local', 'webdav', 'migration']:
        run(helper, mode)
