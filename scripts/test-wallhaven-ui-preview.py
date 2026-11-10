#!/usr/bin/env python3
"""Open the real Debug UI against a temporary helper for interactive validation.

Close the preview window or interrupt this runner to remove the temporary service.
No production login item, preference suite, keychain service or desktop is used.
"""
from pathlib import Path
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import uuid

app = Path(sys.argv[1]).resolve()
full_startup = '--full-startup' in sys.argv[2:]
assert app.name == 'WaifuX.app'
assert plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('WaifuXBuildConfiguration') == 'Debug', 'A Debug development bundle is required'
helper = app / 'Contents/Helpers/WaifuXHelper.app/Contents/MacOS/WaifuXHelper'
assert helper.is_file()
service = 'com.waifux.test.helper.' + str(uuid.uuid4())
suite = service + '.preferences'
domain = f'gui/{os.getuid()}'
with tempfile.TemporaryDirectory(prefix='waifux-static-ui-') as directory:
    root = Path(directory)
    env = os.environ | {'WAIFUX_HELPER_TEST_SERVICE': service, 'WAIFUX_HELPER_TEST_SUITE': suite,
                       'WAIFUX_HELPER_TEST_ROOT': str(root), 'WAIFUX_UI_STATIC_PREVIEW': '1',
                       'WAIFUX_HELPER_TEST_ENFORCE_HOST_IDENTITY': '1'}
    if full_startup: env['WAIFUX_UI_FULL_STARTUP'] = '1'
    # Production service names and desktop opt-in must never leak into this mode.
    env.pop('WAIFUX_HELPER_TEST_ALLOW_DESKTOP_RENDERING', None)
    service_env = {k:v for k,v in env.items() if k.startswith('WAIFUX_')}
    agent = root / 'helper.plist'
    agent.write_bytes(plistlib.dumps({'Label': service, 'ProgramArguments': [str(helper)],
        'MachServices': {service: True}, 'RunAtLoad': True, 'KeepAlive': False,
        'EnvironmentVariables': service_env, 'StandardOutPath': str(root / 'helper.log'),
        'StandardErrorPath': str(root / 'helper.log')}))
    child = None
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
        print(f'ISOLATED_UI_SERVICE={service} ROOT={root} HOST_IDENTITY_ENFORCED=1', flush=True)
        child = subprocess.Popen([str(app / 'Contents/MacOS/WaifuX')] + ([] if full_startup else ['--helper-ui-exit-probe']), env=env)
        result = child.wait()
        if result: raise RuntimeError(f'Preview exited with {result}; helper log: {(root / "helper.log").read_text()[-6000:]}')
    except KeyboardInterrupt:
        pass
    finally:
        if child and child.poll() is None:
            child.terminate()
            try: child.wait(timeout=15)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
        subprocess.run(['launchctl', 'bootout', domain, str(agent)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for name in (suite, suite + '.legacy'):
            subprocess.run(['defaults', 'delete', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print('ISOLATED_UI_CLEANED', flush=True)
