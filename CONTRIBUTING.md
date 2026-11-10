# Contributing to WaifuX Wallhaven

This fork is maintained at `jesusjodar/WaifuX` and retains the original WaifuX attribution and license. Please be respectful, report reproducible issues and keep contributions focused.

## Pull requests

1. Create a branch from the fork's `main` (or the active static-reduction branch when contributing to that work).
2. Explain the concrete problem and resulting behavior. Preserve Wallhaven image categories, original downloads and user data.
3. Add meaningful tests for behavior changes. Use `project.yml` as the source of truth and regenerate with XcodeGen.
4. Update documentation and all four localization catalogs when the interface changes.
5. Open the PR against `jesusjodar/WaifuX`, with exact validation results and any pending visual or device checks.

Keep unrelated files, generated products, credentials and local assistant instructions out of commits. Do not publish a release, announce an update or change another repository as a side effect of a PR.

## Validation

Use the build and test commands in [README.md](README.md). Required checks cover static policies, the production download queue, cloud files, localization and isolated helper integration. Build Debug and Release for Apple Silicon and Intel from clean products, then audit the package with `scripts/verify-project-configuration.py --app PATH --architectures arm64 x86_64`.

The helper tests use isolated preference suites and temporary files. Real wallpaper application must be tested explicitly; an isolated test must not change the user's desktop. Distinguish automated results from actual UI, Spaces, sleep and reconnection evidence.

Only the app and static helper are shipped. Do not reintroduce series playback/downloads, dynamic engines, alternate image providers or arbitrary local-directory scanning. Keep migration tolerant and preserve old personal media, original metadata and retired cloud objects.

## Distribution

Manual packaging creates local development artifacts. A public release additionally needs Developer ID signing, helper provisioning, notarization, matching Sparkle keys and hashes of the actual archives. Review the resulting feed and packages before publishing them.
