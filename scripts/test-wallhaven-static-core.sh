#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/waifux-static-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library \
  "$repo_root/Models/WallhavenContentPolicy.swift" \
  "$repo_root/Models/WallhavenAPI.swift" \
  "$repo_root/Utilities/WallpaperSnapshotPixelBudget.swift" \
  "$repo_root/Utilities/LegacyRecordReader.swift" \
  "$repo_root/Models/SchedulerConfig.swift" \
  "$repo_root/Models/StaticWallpaperRotationState.swift" \
  "$repo_root/Utilities/NSScreen+Wallpaper.swift" \
  "$repo_root/Tests/WallhavenStaticCoreTests.swift" \
  -o "$test_dir/static-core-tests"
"$test_dir/static-core-tests" "$@"
