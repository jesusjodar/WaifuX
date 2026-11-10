#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/waifux-cloud-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$repo_root/Models/WallhavenContentPolicy.swift" \
  "$repo_root/Models/WallhavenLibraryFilePolicy.swift" \
  "$repo_root/Utilities/LegacyRecordReader.swift" \
  "$repo_root/Services/Sync/CloudSyncModels.swift" \
  "$repo_root/Services/Sync/CloudSyncError.swift" \
  "$repo_root/Services/Sync/CloudSyncFileEngine.swift" \
  "$repo_root/Tests/WallhavenCloudFileTests.swift" -o "$test_dir/cloud-files"
"$test_dir/cloud-files"
