#!/usr/bin/env python3
"""Builds the string catalogs of the app and its extensions.

Resources/Localizable.xcstrings, shared by every target, has two sources:
- Translations/reused-keys.json maps iOS keys to keys of the desktop app's
  src/i18n/locales/{en,fr}/translation.json, so shared wording stays identical;
- Translations/ios-strings.json holds the iPhone-only strings;
- Translations/sync-strings.json holds the strings of encrypted sync, which is left out of
  shipped builds: they join the catalog only with --with-sync.

Two more catalogs belong to the app target only:
- App/InfoPlist.xcstrings, from Translations/infoplist-strings.json (permission prompts);
- App/AppShortcuts.xcstrings, from Translations/app-shortcuts.json (Siri phrases, keyed by
  the English phrase with ${applicationName}, as the AppShortcutsProvider declares it).

Usage:
  scripts/build-string-catalog.py            regenerate the catalog
  scripts/build-string-catalog.py --with-sync   regenerate it with the sync strings
  scripts/build-string-catalog.py --check    fail if a key misses a language, if
                                             placeholders differ between languages, or
                                             if the committed catalog is out of date

The desktop repository defaults to ../Pressay; set PRESSAY_DESKTOP_DIR to override it.
Without it, --check still validates the committed catalog, but not its freshness.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
REUSED = ROOT / "Translations" / "reused-keys.json"
IOS_ONLY = ROOT / "Translations" / "ios-strings.json"
SYNC_ONLY = ROOT / "Translations" / "sync-strings.json"
# Catalogs built from one iPhone-only source each: (catalog, source).
STANDALONE = (
    (ROOT / "App" / "InfoPlist.xcstrings", ROOT / "Translations" / "infoplist-strings.json"),
    (ROOT / "App" / "AppShortcuts.xcstrings", ROOT / "Translations" / "app-shortcuts.json"),
)
APP_NAME_PLACEHOLDER = "${applicationName}"
LANGUAGES = ("en", "fr")
SOURCE_LANGUAGE = "en"

I18NEXT_PLACEHOLDER = re.compile(r"\{\{\s*(\w+)\s*\}\}")
FORMAT_SPECIFIER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|%)")


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def lookup(tree: dict, dotted: str):
    node = tree
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node if isinstance(node, str) else None


def to_format_string(value: str) -> str:
    """i18next `{{name}}` placeholders become positional `%1$@` specifiers."""
    names: list[str] = []

    def replace(match: re.Match) -> str:
        name = match.group(1)
        if name not in names:
            names.append(name)
        return f"%{names.index(name) + 1}$@"

    return I18NEXT_PLACEHOLDER.sub(replace, value)


def desktop_dir() -> Path:
    return Path(os.environ.get("PRESSAY_DESKTOP_DIR", ROOT.parent / "Pressay"))


def collect_strings(errors: list[str], with_sync: bool = False) -> dict[str, dict[str, str]]:
    strings: dict[str, dict[str, str]] = {}
    locales = desktop_dir() / "src" / "i18n" / "locales"
    desktop = {lang: load_json(locales / lang / "translation.json") for lang in LANGUAGES}

    for ios_key, desktop_key in load_json(REUSED).items():
        strings[ios_key] = {}
        for lang in LANGUAGES:
            value = lookup(desktop[lang], desktop_key)
            if value is None:
                errors.append(f"{ios_key}: desktop key {desktop_key} has no {lang} string")
                continue
            strings[ios_key][lang] = to_format_string(value)

    for source in (IOS_ONLY, SYNC_ONLY) if with_sync else (IOS_ONLY,):
        for key, values in load_json(source).items():
            if key in strings:
                errors.append(f"{key}: defined twice, the last time in {source.name}")
                continue
            strings[key] = {lang: values[lang] for lang in LANGUAGES if values.get(lang)}

    return strings


def collect_standalone(source: Path) -> dict[str, dict[str, str]]:
    return {key: {lang: values[lang] for lang in LANGUAGES if values.get(lang)} for key, values in load_json(source).items()}


def render(strings: dict[str, dict[str, str]]) -> str:
    catalog = {
        "sourceLanguage": SOURCE_LANGUAGE,
        "strings": {
            key: {
                "extractionState": "manual",
                "localizations": {
                    lang: {"stringUnit": {"state": "translated", "value": strings[key][lang]}}
                    for lang in sorted(strings[key])
                },
            }
            for key in sorted(strings)
        },
        "version": "1.0",
    }
    # Same layout as Xcode writes, so opening the catalog in Xcode leaves no diff.
    return json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n"


def strings_from_catalog(text: str) -> dict[str, dict[str, str]]:
    catalog = json.loads(text)
    return {
        key: {
            lang: unit["stringUnit"]["value"]
            for lang, unit in entry.get("localizations", {}).items()
        }
        for key, entry in catalog["strings"].items()
    }


def validate(strings: dict[str, dict[str, str]], errors: list[str]) -> None:
    for key, values in sorted(strings.items()):
        for lang in LANGUAGES:
            if not values.get(lang, "").strip():
                errors.append(f"{key}: missing {lang}")
        specifiers = {lang: sorted(FORMAT_SPECIFIER.findall(values.get(lang, ""))) for lang in LANGUAGES}
        if len({tuple(found) for found in specifiers.values()}) > 1:
            errors.append(f"{key}: placeholders differ between languages {specifiers}")
        if APP_NAME_PLACEHOLDER in key and not all(APP_NAME_PLACEHOLDER in values.get(lang, "") for lang in LANGUAGES):
            errors.append(f"{key}: every phrase must contain {APP_NAME_PLACEHOLDER}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--with-sync", action="store_true")
    args = parser.parse_args()
    errors: list[str] = []
    has_desktop = (desktop_dir() / "src" / "i18n" / "locales").is_dir()

    for catalog, source in STANDALONE:
        expected = render(collect_standalone(source))
        name = catalog.relative_to(ROOT)
        if args.check:
            if not catalog.exists():
                errors.append(f"{name} is missing")
                continue
            committed_standalone = catalog.read_text(encoding="utf-8")
            validate(strings_from_catalog(committed_standalone), errors)
            if committed_standalone != expected:
                errors.append(f"{name} is out of date: run scripts/build-string-catalog.py")
        else:
            validate(collect_standalone(source), errors)
            if not errors:
                catalog.write_text(expected, encoding="utf-8")
                print(f"wrote {name}")

    if args.check:
        committed = CATALOG.read_text(encoding="utf-8") if CATALOG.exists() else None
        if committed is None:
            errors.append(f"{CATALOG.relative_to(ROOT)} is missing")
        else:
            validate(strings_from_catalog(committed), errors)
            if has_desktop:
                if render(collect_strings(errors, args.with_sync)) != committed:
                    errors.append("the catalog is out of date: run scripts/build-string-catalog.py")
                # Kept valid even while it stays out of the catalog.
                validate(collect_standalone(SYNC_ONLY), errors)
                collect_strings(errors, with_sync=True)
            else:
                print(f"note: {desktop_dir()} not found, freshness not checked")
    else:
        if not has_desktop:
            print(f"error: desktop repository not found at {desktop_dir()}", file=sys.stderr)
            return 1
        strings = collect_strings(errors, args.with_sync)
        validate(strings, errors)
        if not errors:
            CATALOG.parent.mkdir(parents=True, exist_ok=True)
            CATALOG.write_text(render(strings), encoding="utf-8")
            print(f"wrote {len(strings)} keys to {CATALOG.relative_to(ROOT)}")

    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if args.check and not errors:
        print("translations OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
