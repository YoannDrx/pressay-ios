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
| `App/*.xcstrings`       | `InfoPlist` and `AppShortcuts` catalogs, generated: do not edit by hand  |
| `Translations/`         | Sources of the string catalog                                            |

The keyboard links only `PressayShared`: an extension's memory budget leaves no room
for engines, and it cannot use the microphone. FluidAudio (the Fast engine) is linked by
the app target alone.

## How a dictation runs

`ToggleDictationIntent` (Action button, Control Center, Siri) or the app's Dictate button →
`DictationController` → `AudioCaptureService` writes 16 kHz mono samples to
`Captures/<id>.f32` in the App Group while `SilenceDetector` watches for the end →
`EngineStore` transcribes with Fast (Parakeet, CPU and Neural Engine, never the GPU) or
Apple (`SpeechAnalyzer`) → the text goes to `ResultQueue` for the keyboard, with
`PressaySignal.resultReady`, and to the local history. A capture left behind by a killed
process is transcribed into the history at the next launch.

The Fast model (483 MB) is downloaded on demand from a pinned Hugging Face commit; each
file is checked against the size and SHA-256 in `ModelManifest.parakeetTDTv3`, compiled into
the app, before it is used. Downloads resume with HTTP Range.

## The keyboard

`Keyboard/` is UIKit, not SwiftUI: one view per key and a single touch handler give
multi-finger rollover, taps between keys and the accents popup without loading SwiftUI in a
process iOS caps in memory. Typing rules live in `PressayShared/Keyboard` and are unit tested:
AZERTY (French) or QWERTY (English) from the app's layout setting or the system language,
automatic capitals, caps lock on a double tap, double space for a full stop, held delete
(character, then word), no autocorrection (decision D10). `ContextTracker` works around hosts
that report the text before the cursor one edit late.

`DictationLink` follows `SessionStore`, inserts results from `ResultQueue` (only the visible
instance, one Darwin observer per process, results younger than 2 minutes) and offers "Undo
insertion" while the cursor still follows the text. The microphone button writes a request
time and posts `PressaySignal.keyboardRequestsToggle`; the app acts only on a request younger
than 2 seconds. The keyboard never opens the app (App Review 4.4.1): when nothing answers
(the app is not running, or iOS suspended it), the bar suggests the Action button. Without
Full Access, typing works and the bar explains how to allow it. The keyboard logs a memory
sample (`keyboard.memory`, numbers only) every 15 s while visible.

To try it in the simulator: Settings > General > Keyboard > Keyboards > Add New Keyboard >
Pressay, then Allow Full Access. After reinstalling the app, quit the host app (Messages)
so it loads the new keyboard.

## Develop

Requirements: Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
[SwiftLint](https://github.com/realm/SwiftLint) (`brew install xcodegen swiftlint`).

```bash
xcodegen generate                                  # Pressay.xcodeproj is not committed
open Pressay.xcodeproj
swift test --package-path Packages/PressayKit      # unit tests (Swift Testing)
swiftlint lint --strict
```

### Dictate in the simulator

Debug builds accept a file in place of the microphone, played at real-time pace and then
followed by silence, so the stop on silence and the whole pipeline run without speaking:

```bash
xcodebuild build -project Pressay.xcodeproj -scheme Pressay -destination 'id=<simulator>' \
  -derivedDataPath .build-sim CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
xcrun simctl install <simulator> .build-sim/Build/Products/Debug-iphonesimulator/Pressay.app
xcrun simctl launch <simulator> fr.yodev.pressay -PressayCaptureFile /path/to/speech.wav
```

Ad hoc signing (`CODE_SIGN_IDENTITY=-`) keeps the App Group entitlement, so the result lands
in `pending-results.json` of the group container (`xcrun simctl get_app_container <simulator>
fr.yodev.pressay groups`). Download the Fast model from the app first: `SpeechAnalyzer` is
not available in the simulator.

## Translations

Strings shared with the Mac app come from its `src/i18n/locales/{en,fr}` files, listed in
`Translations/reused-keys.json`; iPhone-only strings live in `Translations/ios-strings.json`,
permission prompts in `Translations/infoplist-strings.json` and Siri phrases in
`Translations/app-shortcuts.json`.
After editing either file, regenerate the catalog with the desktop repository next to this
one (or `PRESSAY_DESKTOP_DIR` pointing to it):

```bash
scripts/build-string-catalog.py
scripts/build-string-catalog.py --check            # what CI runs
```

## Release

Pushing a `v*` tag runs `.github/workflows/testflight.yml`, which archives the app and
uploads it to TestFlight with an App Store Connect API key.
