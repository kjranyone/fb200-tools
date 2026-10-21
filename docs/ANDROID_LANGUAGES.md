# App languages — 0.10.7+21

The disconnected launch screen includes a language selector above the
connection card. Choices are always shown in their native names: **English**,
**日本語**, **简体中文**. The first launch defaults to English regardless of the
device locale. A saved selection is restored before the home page appears;
an unknown stored value or unavailable preferences falls back to English.

The choice is stored under `app_language` in the app's existing preferences.
The selector is available before connection and again after disconnecting.
Changing language recreates the disconnected home page, so retained messages
cannot remain in the previous language. It does not replace a live BLE
session while a transfer or pedal operation is in progress.

## Translation coverage and maintenance

- 446 app messages have English, Japanese and Simplified Chinese versions,
  covering the hub, controller, model/IR management, TONE3000 integration,
  QR scanner, dialogs, help, status messages and transport/model errors.
- Flutter's SDK `flutter_localizations` delegates provide the corresponding
  Material, Cupertino and widget locale behavior; Simplified Chinese uses
  `Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')`.
- `lib/localization.dart` supplies `tr(sourceKey, arguments)`. Japanese source
  messages serve as stable lookup keys in `lib/l10n/catalog.dart`; each key
  has English and Simplified Chinese values. Placeholders are numbered
  `{0}`, `{1}`, etc. and substituted once. This is an explicit call at an
  app-owned message, not matching/replacing arbitrary rendered text.
- User/device strings such as model names, IR names, preset names, creator
  names and file names are passed through unchanged. Product names, DSP
  algorithm names and conventional control abbreviations remain identifiable.
- The app has one language, including asynchronous service errors. Metadata
  getters build labels in that language instead of caching translated labels
  before the user has made a selection.

When adding a message, add both translations and preserve its placeholder
set. `test/localization_test.dart` checks all catalogue entries. Existing
behavioral tests explicitly use Japanese fixtures through
`test/flutter_test_config.dart`; dedicated language tests cover the production
English default and language persistence.

## Layout corrections

A shorter translated preset status could cross the old height threshold for
showing the signal chain on a narrow phone. Its wrapped rows then crowded out
the NAM controls. The editor now considers chain columns/rows as well as
height, using the existing module menu when needed. The main performance
panel remains fixed. Preset-management actions wrap when English labels need
more width; settings knobs share bounded columns. Long help text scrolls
inside its dialog.

## Verification — 2026-10-22

- All **211 Flutter tests** passed; static analysis reported no issues.
- Tests verify first launch in English on a Japanese device locale, switching
  all three languages, persistence after a full app remount, invalid-locale
  fallback, Material labels, catalogue placeholders and preservation of user
  names containing Unicode and placeholder-like text.
- Each language was exercised at 360×640, 640×360 and 1280×800: startup and
  selector, all seven effects, help, presets, drums, tuner, looper, IR and
  settings. These are widget tests with simulated pedal communication.
- Android debug APK built and installed on the Lenovo TB-J716F, Android 13.
  Installed versionName **0.10.7**, versionCode **21**.
- On the native app, English was shown with no language preference. Japanese,
  Simplified Chinese and English were selected in turn, each verified again
  after force-stopping and restarting the app. Final selection: English.
- App data was retained via `adb install -r`. No firmware update, preset save
  or model/IR transfer was performed for this change. The final process log
  contained no fatal exception or layout overflow.
- APK copied to `/sdcard/Download/fb200-studio-0.10.7-21-debug.apk`. Both local
  and transferred copies have SHA-256:
  `4b5c182c26437a16810b7b3a177881f6adb8efd4b32d25c99d5a400c3f4d2719`.

[Language selector](design/fb200-language-picker-v1.png) ·
[English](design/fb200-language-en-v1.png) ·
[Japanese](design/fb200-language-ja-v1.png) ·
[Simplified Chinese](design/fb200-language-zh-hans-v1.png)

Ignored local evidence: `out/localization-20261022/` contains native UI
snapshots, screenshots, runtime log and `verification.json`. Test, analysis
and build logs are `out/localization-all-tests.log`,
`out/localization-analyze.log` and `out/localization-build.log`.
