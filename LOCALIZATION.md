# Localization

`Services/LocalizationService.swift` owns the static app's four catalogs: Spanish (Spain), English, Simplified Chinese and Japanese. Set the language in Settings → General; a system locale beginning with `es` selects Spanish on first launch.

Add every new interface key to all four catalogs. Preserve format tokens such as `%@`, `%d`, `%%` and named placeholders exactly. API tags, stored enum values, paths, user content and protocol messages are independent of the interface language. Existing Chinese literal keys are retained where they are still used; new text should use semantic keys.

Help and GuideKit describe the static Wallhaven app. Tour content versions must be advanced when instructions change. Catalog entries for retired features, the property editor and the standalone screen saver have been removed.

Run `python3 scripts/verify-spanish-localization.py`. It checks literal lookup coverage, duplicate keys, catalog parity and format tokens, then compiles the real service with in-memory preferences. Runtime tests cover Spanish locale detection, saved language, notifications, switching and fallback. It does not launch the app or touch its real preferences. Actual UI layout still needs visual review.
