# WaifuX · Wallhaven

A fork of [jipika/WaifuX](https://github.com/jipika/WaifuX) dedicated exclusively to static Wallhaven images. [Español](README.md) · [日本語](README.ja.md)

The `feat/wallhaven-static-only` branch is under development. No stable release of this reduction has been published. Build and automated test results do not replace visual and physical-display validation.

The app retains Wallhaven search and filters (including its Anime image category), original downloads, favorites, folders and locks, cancellation/retry, per-display or global wallpaper application, sequential/random rotation, static crop, portrait blur fill and local/WebDAV sync. It does not play or download series or use other wallpaper providers. Legacy documents, personal media and retired cloud objects are preserved.

macOS 14.4+ is required. Local validation uses Xcode 27.3 and XcodeGen. Generate the project with `xcodegen generate`, run `python3 scripts/verify-project-configuration.py`, then build the `WaifuX` scheme. The two targets are the app and `WaifuXHelper`; signing and a valid helper identity are required to validate an installed build.

See the [Spanish README](README.md) for exact build, test and packaging commands. The core, production download queue, cloud-file and localization checks are standalone scripts. The Debug helper integration runner uses temporary preference suites and files with desktop rendering disabled; it never registers the installed service or changes the personal wallpaper. Live API credentials, UI, Spaces, sleep and display reconnection need separate validation.

`scripts/package.sh` creates audited universal Debug ZIP/DMG artifacts with ad-hoc signing for local use. It does not install or launch the app. Public distribution requires Developer ID signing, helper provisioning, notarization and fork-owned Sparkle keys. Release helpers require an authenticated signing team and cannot be used with ad-hoc signatures. Automatic checks are disabled and the fork feed initially contains no releases. CI never publishes releases or updates another repository automatically.

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [LOCALIZATION.md](LOCALIZATION.md). Changes to this fork target `jesusjodar/WaifuX`, independently of upstream localization contributions. Original attribution and the [license](LICENSE) are retained. Code licensing does not grant rights to Wallhaven images.
