#!/usr/bin/env python3
"""Audit the static fork's generated targets, permissions and packaged bundle."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path)
parser.add_argument('--signed', action='store_true')
parser.add_argument('--architectures', nargs='+', choices=['arm64', 'x86_64'])
args = parser.parse_args()
objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'WaifuX.xcodeproj/project.pbxproj')]))['objects']
project = next(v for v in objects.values() if v.get('isa') == 'PBXProject')
base = {objects[c]['name']: objects[c]['buildSettings'] for c in objects[project['buildConfigurationList']]['buildConfigurations']}
targets = {v['name']: v for v in objects.values() if v.get('isa') == 'PBXNativeTarget'}
assert set(targets) == {'WaifuX', 'WaifuXHelper'}, set(targets)
permissions = {'com.apple.security.network.client': True, 'com.apple.security.application-groups': ['group.com.waifux.app']}
required = {'WallpaperCachePaths.swift', 'StaticWallpaperApplyService.swift', 'DerivedStaticWallpaperService.swift', 'WallpaperLibraryPath.swift',
            'WallhavenContentPolicy.swift', 'WallpaperBoundedImageDecoder.swift', 'WallpaperSchedulerService.swift',
            'DownloadTaskService.swift', 'CloudSyncFileEngine.swift'}
for name, target in targets.items():
    expected_id = 'com.waifux.app' + ('.helper' if name == 'WaifuXHelper' else '')
    sources = {Path(objects[objects[f]['fileRef']]['path']).name
               for p in target['buildPhases'] if objects[p]['isa'] == 'PBXSourcesBuildPhase' for f in objects[p]['files']}
    assert required <= sources, (name, required - sources)
    for config in objects[target['buildConfigurationList']]['buildConfigurations']:
        values = base[objects[config]['name']] | objects[config]['buildSettings']
        assert values['PRODUCT_BUNDLE_IDENTIFIER'] == expected_id
        assert values['MACOSX_DEPLOYMENT_TARGET'] == '14.4'
        assert values['ENABLE_HARDENED_RUNTIME'] in ('YES', True)
        assert 'zip_data' not in str(values.get('OTHER_LDFLAGS', ''))
        if name == 'WaifuXHelper': assert 'WAIFUX_HELPER' in str(values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
    entitlement_path = 'WaifuX.entitlements' if name == 'WaifuX' else 'BackgroundAgent/BackgroundAgent.entitlements'
    assert plistlib.loads((ROOT / entitlement_path).read_bytes()) == permissions
for info in ('App/Info.plist', 'BackgroundAgent/Info.plist'):
    values = plistlib.loads((ROOT / info).read_bytes())
    assert not any(k.startswith('NS') and (k.endswith('UsageDescription') or 'ScreenCapture' in k) for k in values), info
host_info = plistlib.loads((ROOT / 'App/Info.plist').read_bytes())
assert host_info['SUFeedURL'] == 'https://jesusjodar.github.io/WaifuX/appcast.xml'
assert host_info['SUEnableAutomaticChecks'] is False
agents = [plistlib.loads((ROOT / ('BackgroundAgent/' + name)).read_bytes())
          for name in ('com.waifux.app.helper.plist', 'com.waifux.app.helper.relinked.plist')]
assert {k:v for k,v in agents[0].items() if k != 'Label'} == {k:v for k,v in agents[1].items() if k != 'Label'}
assert all(a['KeepAlive'] == {'SuccessfulExit': False} and a['RunAtLoad'] is True for a in agents)
for value in objects.values():
    if value.get('isa') == 'XCRemoteSwiftPackageReference':
        assert value['repositoryURL'] in {'https://github.com/onevcat/Kingfisher.git', 'https://github.com/hyperoslo/Cache.git', 'https://github.com/sparkle-project/Sparkle.git'}
if args.app:
    app = args.app.resolve()
    helper = app / 'Contents/Helpers/WaifuXHelper.app'
    assert helper.is_dir(), 'Embedded helper missing'
    forbidden = re.compile(r'wallpaperengine|wallpaper-wgpu|ffmpeg|steamservice|mobilepush|(?:^|/)dxc(?:/|$)|\.appex(?:/|$)|\.saver(?:/|$)|WallpaperPropertyEditor', re.I)
    for path in app.rglob('*'):
        assert not forbidden.search(str(path.relative_to(app))), path
    for bundle, executable in ((app, 'WaifuX'), (helper, 'WaifuXHelper')):
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        assert not any(k.endswith('UsageDescription') or 'ScreenCapture' in k for k in info), bundle
        if args.architectures:
            archs = subprocess.check_output(['lipo', '-archs', str(bundle / ('Contents/MacOS/' + executable))], text=True).split()
            assert set(archs) == set(args.architectures), (bundle, archs)
    host_icon = app / 'Contents/Resources/AppIcon.icns'
    helper_icon = helper / 'Contents/Resources/AppIcon.icns'
    assert hashlib.sha256(host_icon.read_bytes()).digest() == hashlib.sha256(helper_icon.read_bytes()).digest()
    if args.signed: subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print('PASS: static Wallhaven targets, dependencies, permissions, updater and helper boundaries' + ('; bundle audit passed' if args.app else ''))
