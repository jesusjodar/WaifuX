#!/usr/bin/env python3
"""Validate the static fork template or render it from an actual release ZIP."""
from pathlib import Path
import argparse
import hashlib
import re
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
parser.add_argument('--version')
parser.add_argument('--archive', type=Path)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
text = (ROOT / 'packaging/homebrew/waifux.rb.in').read_text()
assert 'https://github.com/jesusjodar/WaifuX/' in text
assert '__VERSION__' in text and '__SHA256__' in text
assert not any(value in text for value in ('pluginkit', 'killall', 'zap ', 'jipika/', 'Steam', '.dmg'))
if not args.check:
    assert args.version and re.fullmatch(r'\d+(?:\.\d+)+', args.version)
    assert args.archive and args.archive.name == f'WaifuX-Wallhaven-{args.version}-universal.zip'
    assert args.archive.is_file() and args.output
    checksum = hashlib.sha256(args.archive.read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text.replace('__VERSION__', args.version).replace('__SHA256__', checksum))
print('PASS: fork-only static Homebrew cask')
