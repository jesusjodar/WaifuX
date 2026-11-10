#!/usr/bin/env python3
"""Validate catalog coverage/format tokens and exercise localization without app side effects.

Run from any directory: python3 scripts/verify-spanish-localization.py
Requires the macOS Swift toolchain; preferences are replaced with an in-memory stub.
"""
import json
from pathlib import Path
import re
import subprocess
import tempfile
from collections import Counter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Services/LocalizationService.swift"
text = SOURCE.read_text()
entry_pattern = r'^\s*"((?:[^"\\]|\\.)*)": "((?:[^"\\]|\\.)*)",?\s*$'
tables = {}
for language, body in re.findall(
    r'\.(spanish|english|chinese|japanese): \[(.*?)(?=\n\s*\.(?:spanish|english|chinese|japanese): \[|\n\s*\],?\n\s*\])',
    text, re.S,
):
    entries = re.findall(entry_pattern, body, re.M)
    duplicates = [key for key, count in Counter(k for k, _ in entries).items() if count > 1]
    assert not duplicates, (language, duplicates)
    tables[language] = dict(entries)
assert set(tables) == {"spanish", "english", "chinese", "japanese"}
assert tables["english"].keys() <= tables["spanish"].keys(), "Missing Spanish keys"
tokens = re.compile(r'%(?:\d+\$)?[-+0 #]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp%]|\{[^{}]+\}')
for key, english in tables["english"].items():
    assert tokens.findall(english) == tokens.findall(tables["spanish"][key]), key
for key, spanish in tables["spanish"].items():
    assert spanish.strip(), key
    assert not re.search(r'[\u4e00-\u9fff]', spanish), (key, spanish)
    if re.search(r'[\u4e00-\u9fff]', key):
        assert tokens.findall(key) == tokens.findall(spanish), key

# Literal app lookups must not expose an untranslated identifier in Spanish.
for folder in ["App", "Views", "Components", "Models", "ViewModels", "Services", "BackgroundAgent", "Utilities"]:
    for source in (ROOT / folder).rglob("*.swift"):
        if source == SOURCE:
            continue
        for key in re.findall(r'\bt\("((?:[^"\\]|\\.)*)"\)', source.read_text()):
            if "\\(" not in key:
                assert key in tables["spanish"], (source, key)

# Exercise the production Swift service with an in-memory preference stub.
# No application, helper, editor or retired feature is loaded.
harness = r'''
import Foundation
final class WaifuXPreferences {
    static let shared = WaifuXPreferences()
    private var values: [String: String] = [:]
    func set(_ value: String, forKey key: String) { values[key] = value }
    func string(forKey key: String) -> String? { values[key] }
}
let localization = LocalizationService.shared
assert(localization.currentLanguage == .spanish)
assert(LocalizationService.Language.spanish.displayName == "Español (España)")
var notified = false
let observer = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: nil) { _ in notified = true }
localization.setLanguage(.english)
assert(notified && t("nav.home") == "HOME")
WaifuXPreferences.shared.set("es", forKey: "app_language")
localization.restoreSavedSettings()
assert(localization.currentLanguage == .spanish && t("nav.home") == "INICIO")
assert(t("statusbar.cropAdjust") == "Ajustar área de recorte…")
assert(t("tutorial.wallhaven.l1").contains("imágenes estáticas de Wallhaven"))
assert(t("unknown.test.key") == "unknown.test.key")
assert(String(format: t("repairResult"), 1, 2, 3, 4, 5).contains("reparados: 2"))
localization.setLanguage(.japanese)
assert(t("nav.home") == "ホーム")
localization.setLanguage(.chinese)
assert(t("nav.home") == "首页")
NotificationCenter.default.removeObserver(observer)
print("LOCALIZATION_RUNTIME_PASSED")
'''
with tempfile.TemporaryDirectory(prefix="waifux-localization-") as directory:
    temp = Path(directory)
    (temp / "main.swift").write_text(harness)
    subprocess.run(["swiftc", str(SOURCE), str(temp / "main.swift"), "-o", str(temp / "check")], check=True)
    for locale in ["es-ES", "es-MX", "es"]:
        subprocess.run([str(temp / "check"), "-AppleLanguages", f"({locale})"], check=True)
assert all(set(table) == set(tables["spanish"]) for table in tables.values())
assert not any(key.startswith(("screensaver", "animeRules", "tutorial.we.", "tutorial.sceneWeb.", "tutorial.lockScreen.")) for key in tables["spanish"])
print(f"SPANISH_LOCALIZATION_PASSED static_keys={len(tables['spanish'])} languages=4")
