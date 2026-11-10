#!/bin/bash
# Explicit version update only. Never stages files or generates a release feed.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$repo_root/VERSION" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
version = path.read_text().strip()
assert re.fullmatch(r'\d+(?:\.\d+)+', version), 'Invalid VERSION'
parts = version.split('.')
parts[-1] = str(int(parts[-1]) + 1)
path.write_text('.'.join(parts) + '\n')
PY
bash "$repo_root/scripts/sync-version.sh"
