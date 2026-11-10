#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/waifux-queue-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 -D WAIFUX_HELPER -parse-as-library \
  "$repo_root/Models/Wallpaper.swift" "$repo_root/Models/FavoriteSource.swift" \
  "$repo_root/Models/WallhavenAPI.swift" "$repo_root/Models/WallhavenContentPolicy.swift" \
  "$repo_root/Models/MenuBarQuickWallpaperItem.swift" \
  "$repo_root/Models/DownloadTask.swift" "$repo_root/Utilities/LegacyRecordReader.swift" \
  "$repo_root/BackgroundAgent/BackgroundRuntimeRole.swift" \
  "$repo_root/BackgroundAgent/BackgroundAgentWire.swift" \
  "$repo_root/BackgroundAgent/WaifuXPreferences.swift" \
  "$repo_root/Services/DownloadTaskService.swift" \
  "$repo_root/Services/UserLibrary.swift" \
  "$repo_root/Tests/WallhavenDownloadQueueTests.swift" -o "$test_dir/queue-tests"
for mode in lifecycle migration corrupt; do
  WAIFUX_HELPER_TEST_ROOT="$test_dir/$mode" WAIFUX_HELPER_TEST_SUITE="waifux-queue-test-$(uuidgen)" \
    "$test_dir/queue-tests" "$mode"
done
