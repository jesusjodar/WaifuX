#!/usr/bin/env python3
"""Generate a fork-only Sparkle item from an already signed universal ZIP.

No release is uploaded. Configure the fork's SUPublicEDKey in App/Info.plist,
then obtain --signature with Sparkle's sign_update using the matching private key.
"""
from pathlib import Path
import argparse
import base64
from email.utils import formatdate
import plistlib
import re
import subprocess
import tempfile
from urllib.parse import quote
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--version', required=True)
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--signature', required=True)
parser.add_argument('--changelog-file', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert re.fullmatch(r'\d+(?:\.\d+)+', args.version), 'Invalid version'
assert args.archive.is_file() and args.archive.suffix == '.zip', 'A signed universal ZIP is required'
assert len(base64.b64decode(args.signature, validate=True)) == 64, 'Invalid Ed25519 signature'
info = plistlib.loads((ROOT / 'App/Info.plist').read_bytes())
assert info.get('SUPublicEDKey'), 'Configure the fork-owned SUPublicEDKey before enabling signed updates'
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32, 'Invalid fork public key'
# Verify the archive bytes before advertising them. Only the public key and
# signature are passed to CryptoKit; this script never reads a private key.
with tempfile.TemporaryDirectory(prefix='waifux-feed-verification-') as directory:
    verifier = Path(directory) / 'verify.swift'
    verifier.write_text(r'''
import Foundation
import CryptoKit
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[1])!)
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard key.isValidSignature(Data(base64Encoded: args[2])!, for: archive) else {
    fputs("Archive signature does not match the configured fork key\n", stderr)
    exit(1)
}
''')
    subprocess.run(['swift', str(verifier), info['SUPublicEDKey'], args.signature, str(args.archive.resolve())], check=True)

assert args.archive.name == f'WaifuX-Wallhaven-{args.version}-universal.zip', 'Archive name must match package.sh'
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
rss = ET.Element('rss', {'version': '2.0'})
channel = ET.SubElement(rss, 'channel')
for tag, value in [('title', 'WaifuX Wallhaven'), ('link', 'https://jesusjodar.github.io/WaifuX/appcast.xml'),
                   ('description', 'Actualizaciones del fork de fondos estáticos de Wallhaven'), ('language', 'es')]:
    ET.SubElement(channel, tag).text = value
item = ET.SubElement(channel, 'item')
for tag, value in [('title', args.version), ('pubDate', formatdate(usegmt=True)),
                   ('description', args.changelog_file.read_text()),
                   (f'{{{ns}}}version', args.version), (f'{{{ns}}}shortVersionString', args.version),
                   (f'{{{ns}}}minimumSystemVersion', '14.4')]:
    ET.SubElement(item, tag).text = value
ET.SubElement(item, 'enclosure', {
    'url': f'https://github.com/jesusjodar/WaifuX/releases/download/v{args.version}/' + quote(args.archive.name),
    'length': str(args.archive.stat().st_size), 'type': 'application/octet-stream', f'{{{ns}}}edSignature': args.signature})
args.output.parent.mkdir(parents=True, exist_ok=True)
ET.indent(rss)
ET.ElementTree(rss).write(args.output, encoding='utf-8', xml_declaration=True)
print(args.output)
