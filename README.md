# Pressay for iPhone

Local-first dictation for iPhone. Press the Action button, speak, and the Pressay
keyboard inserts the transcription in the field you were typing in. Audio and text
stay on the device.

The plan, the spike results and the decisions behind this repository live in the
desktop repository: `docs/IOS_LAUNCH_PLAN.md`.

## Layout

| Path                    | Role                                                                     |
| ----------------------- | ------------------------------------------------------------------------ |
| `App/`                  | The app: onboarding, settings, history, capture, engines, App Intents    |
| `Keyboard/`             | The keyboard extension: typing, session state, insertion                 |
| `Widgets/`              | The Control for the Action button, and the Live Activity                 |
| `Shared/`               | Sources compiled into the app and the widget extension (App Intents)     |
| `Packages/PressayKit/`  | `PressayShared` (App Group, result queue, signals, journal), `PressayCore` |
| `Resources/`            | `Localizable.xcstrings`, generated: do not edit by hand                  |
| `Translations/`         | Sources of the string catalog                                            |

The keyboard links only `PressayShared`: an extension's memory budget leaves no room
for engines, and it cannot use the microphone.

## Develop

Requirements: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
[SwiftLint](https://github.com/realm/SwiftLint) (`brew install xcodegen swiftlint`).

```bash
xcodegen generate                                  # Pressay.xcodeproj is not committed
open Pressay.xcodeproj
swift test --package-path Packages/PressayKit      # unit tests (Swift Testing)
swiftlint lint --strict
```

## Translations

Strings shared with the Mac app come from its `src/i18n/locales/{en,fr}` files, listed in
`Translations/reused-keys.json`; iPhone-only strings live in `Translations/ios-strings.json`.
After editing either file, regenerate the catalog with the desktop repository next to this
one (or `PRESSAY_DESKTOP_DIR` pointing to it):

```bash
scripts/build-string-catalog.py
scripts/build-string-catalog.py --check            # what CI runs
```

## Release

Pushing a `v*` tag runs `.github/workflows/testflight.yml`, which archives the app and
uploads it to TestFlight with an App Store Connect API key.
