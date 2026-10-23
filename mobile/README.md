# FB200 NAM mobile manager

FB200 Studio: Flutter app for Android / iOS. Web provides the same explicit
offline demo; web Bluetooth is not implemented. On a physical FB200 running
`nam-manager`, the Android app has been used over BLE for preset and effect
editing, model selection, model kinds and level meters (Lenovo TB-J716F,
Android 16; see the [hardware log](../docs/NAM_HARDWARE_2026-10-18.md)).
iOS builds but has not been run on a phone.
This app has no firmware-update action. Review it through
the demo without connecting a pedal.

## Features

**0.10.7+21** adds a language selector to the disconnected launch screen:
English (default), Japanese and Simplified Chinese. The selected language is
saved locally and applies to controls, dialogs, help, connection/transfer
messages and errors. Model, IR and preset names remain as supplied. See
[language support and Android verification](../docs/ANDROID_LANGUAGES.md).

**0.10.6+20** adds live NAM knob preview with a coalesced BLE writer and final
readback, names effect algorithms and their audible parameters, and shows
actual IR names/assignments in the cabinet selector and IR tab. Unused DSP
fields are excluded from the controls. See [tone measurement and controls](../docs/ANDROID_EFFECT_CONTROLS.md).

**0.10.5+19** reduces unnecessary recovery: idle-only checks tolerate a missed
reply, NAM list replies have a suitable timeout, panel updates read only the
selection, and open routes share the recovered catalogue. Reconnect status is
an inline banner; automatic synchronization keeps the editor visible and fixed.


**0.10.4+18** adds shared connection recovery across the hub, controller and
model library: bounded reconnect, read-only resync, idle link checks and
unsaved-draft recovery without automatically replaying saves or uploads.
See [Android recovery and verification](../docs/ANDROID_RECOVERY.md).

**0.10.3+17** makes the performance editor a fixed surface: model and NAM
controls remain visible on tablets, and constrained screens use explicit
parameter pages. Preset save remains fixed; routing metadata and help move
to the editor menu. See [fixed-panel verification](../docs/design/NAM_STUDIO_FIXED_PANEL.md).

Latest: **0.10.2+16** adds the imagegen-prototyped model card, searchable
64-slot selection/transfer sheets, visible transfer progress and audition action,
vertical knob drag with fine adjustment, and numeric validation/reset.
The companion NAM firmware maps the physical AMP knob to stored NAM models.
See [UX design, implemented screens and deployment](../docs/design/NAM_STUDIO_UX.md).

- Bank/preset editor: ten banks / forty presets, read/select, rename/copy,
  explicit overwrite, lossless binary fields in JSON backup, CRC validation and
  verified restore. Unknown bytes and NAM bindings are retained; copying a
  non-NAM preset explicitly clears a destination NAM binding on NAM firmware.
- Legacy effect/settings controls and front-panel notification refresh share
  the same BLE connection with NAM. Stock firmware can use the editor without
  satisfying the NAM handshake. A base NAM runtime disables unsupported effects;
  `nam-manager` restores cab/MOD/reverb after the NAM stage (capability bit 7)
  with 44.1 kHz IRs resampled to 48 kHz, and mixes Bluetooth audio in
  (capability bit 8).
- Drum machine and tuner controls, with live pedal pitch on `nam-manager`:
  note name and a ±50 cent needle (±3 cents counts as in tune) above the
  numeric reading.
  Availability is gated by firmware capabilities. Full stock/NAM effect parity
  is still outstanding; see [ANDROID_PARITY.md](../docs/ANDROID_PARITY.md).
- **Studio editor (0.10.0+14)**: dark graphite surfaces, effect-specific colours,
  fixed audio signal-chain strip and a persistent preset sidebar on wide screens.
  The controller opens on the NAM/amp editor. Model audition, six tone controls,
  direct numeric entry, edited-state indication and explicit preset save share
  one screen. The model library opens directly from the NAM block and borrows
  the BLE connection; returning refreshes the active model and slot names.
- **Level meters**: the wide-layout sidebar shows IN (guitar, before input
  gain), NAM (the model's input) and OUT peak meters on one line, with a held
  peak and a 2 s clip mark, polled every 200 ms (capability bit 10); the exact
  dBFS is in each meter's tooltip. Without bit 10 the sidebar explains the
  missing meters. The global input gain stays in Settings, shown in dB
  (stock steps: -55..-5 dB in 5 dB steps, 0 dB, then +0.5 dB to +6 dB).
- **Pre NAM**: on firmware with capability bit 13 a second NAM runs before
  the first (a pedal capture into the amp). The NAM block shows a PRE line
  with its own picker (00 = none) and adds PRE GAIN / PRE LEVEL knobs
  (±18 dB); the choice lives in preset words 0xE2..0xE9 and is written with
  the edit buffer, like the delay. The same firmware plays delays up to
  300 ms, and the delay knob stops there. See
  [second NAM and FX block](../docs/NAM_FX_BLOCK.md).
- **FX block**: on firmware with capability bit 14 the chain shows an FX
  block, before the NAMs or after the cabinet (its position switch). Its
  modes and controls come from the pedal (NAM RPC op 14), so a new mode
  needs no app update; the first is a pitch shifter (SHIFT in semitones,
  ±2 octaves, MIX, LEVEL, GLIDE, RANGE). Switching it on writes the whole
  block with the edit buffer; each later change goes out live as one
  preset word (op 15). Nothing is saved until Save.
- **Model kinds**: each stored model carries what it captures (Amp + Cab,
  Amp, Cab, Pedal, Outboard, Space, Experimental) in its header on firmware
  with capability bit 12. TONE3000 transfers take the tone's gear, `.nam`
  files their `gear_type` metadata, and the kind can be changed before or
  after a transfer. The NAM block shows the kind and warns when the cabinet /
  IR stage doubles a full rig's cab or an amp-only model plays without one;
  the model picker filters by kind.
- **NAM tone controls**: GAIN is pre-model drive (50 = unity; -18..+18 dB on
  firmware with capability bit 11, 0.5..2x before),
  BASS/MID/TREBLE are ±12 dB shelves/peak after the model, MID FREQ sweeps
  200..2000 Hz, and VOLUME is post-model level (0..2x; **50 = unity**).
  Neutral preset words are 50/50/50/any/50/50. Firmware capability bit 9
  guarantees the tone EQ is connected. Earlier firmware applied GAIN/VOLUME
  but ignored the tone words; this app disables the four unsupported EQ
  controls on those devices. The companion firmware connects the existing
  NAM tone DSP without replacing the independent five-band cabinet EQ.
  Audition changes the edit buffer, and the visible Save action persists
  model binding and tone words together. Switching presets with unsaved
  edits asks before discarding them. Capture weights remain unchanged.
- Looper control (`D7`, our extension) on `nam-manager` and the stock open
  profile: tap/record/play/dub/stop/undo/clear, level, two save slots and a
  live status line. The base restricted runtime and the vendor firmware have
  no looper; the tab states that. The pedal's own looper mode (hold D+C) keeps
  working alongside the app.
- Module order (`A0`): edit the preset's order metadata with per-row arrows.
  Current firmware's audible processing order is fixed; the chain strip shows
  that actual order, and the order editor explicitly identifies the limitation.
- User IR management: list the nine slots, import a WAV (converted locally to
  the official 1024-sample 44.1 kHz float32 format, byte-identical to the PC
  tool's conversion), rename and delete. IR storage is shared with the stock
  firmware; the NAM runtime has no cabinet stage, which the UI states.
- Bluetooth device-name change (`B3`): the name cannot be read back over the
  protocol, so the app sends it once and asks the user to verify after
  reconnecting.
- Android: **TONE3000から探す** opens the TONE3000 library. Sign-in uses the
  official Select flow once and is kept on the device; favorites, download
  history, own tones, trending and latest are then listed in-app. Variants are
  bulk-downloaded into a device library (A2-Lite validated before saving) and
  transferred one at a time or as a batch into empty slots. Configure a public
  client ID once; no Secret Key is used. Setup and current boundaries:
  [TONE3000_ANDROID.md](../docs/TONE3000_ANDROID.md).
- **QRコードから入力** reads a QR containing the raw Publishable Key with the
  Android camera. It validates before filling the field and does not start OAuth.
- Import user-supplied `.nam`: standalone fixed A2-Lite or packed A2 with a unique
  3-channel submodel; validate 48 kHz/exact supported shape and convert locally
  to the same FBNM bytes as the PC tool.
- Discover BLE, confirm firmware capabilities, list the model slots (paged
  over BLE; 64 slots on current firmware, three on the older unpaged image),
  upload with progress/cancel, explicitly select/reload, bypass, delete and
  rename (firmware capability bit 4; the rename re-commits the stored packet
  under the new name without touching the running model).
- Save selection into the currently loaded pedal preset.
- **接続せず試す** simulates slots. It creates no BLE connection or audio process.

NAM weights are not exposed as Gain/Bass/Middle/Treble knobs on the model
itself. Captures have fixed trained behavior; choose another capture for
another amp character. The Studio tone controls shape the signal around the
fixed capture using the preset's amp words (see firmware support above).

## Build / verify

Validated toolchain: Flutter 3.47.7 / Dart 3.13.5, compile SDK 37, AGP 9.1.1,
Gradle 9.3.1, Java 17+. Check in `pubspec.lock`.

The SDK manager publishes API 37 as `platforms;android-37.0`. Current AGP/plugin
lookup can still request the `platforms/android-37` directory. The Linux CI
installs the published package and, when needed, aliases `android-37` to
`android-37.0`. It uses the actual API 37 platform, without lowering compileSdk.

```sh
cd mobile
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
flutter run -d chrome       # demo UI; no BLE
flutter build web
```

APK: `build/app/outputs/flutter-apk/app-debug.apk`. Debug prototype, not a store
release; no automatic installation. Android/iOS launch icons are still Flutter
template assets in this first version.

iOS source includes Bluetooth purpose keys and targets iOS 15+. Compile/sign on
macOS/Xcode (`flutter build ios --no-codesign` for a compile check, then configure
signing for a phone). iOS cannot be compiled locally on Windows; on 2026-10-18,
`flutter build ios --no-codesign` passed on a GitHub macOS runner. Signing,
installation and physical Bluetooth operation are still unverified. See
[handover evidence](../docs/NAM_HANDOVER.md#ci-and-handover-verification).
Permission-handler's Swift package enables Bluetooth from the Info.plist key.
No background transfer mode is enabled; keep the app foreground during upload.

## Device workflow, after separate physical validation

1. The pedal must already run this branch's `nam-runtime` firmware. The app
   cannot add NAM to stock firmware or install firmware.
2. Close other FB200 editors, enable Bluetooth and connect. Android requests
   nearby-device permissions (12+) or location for older BLE scans; iOS requests
   Bluetooth permission. If denied, change the phone's settings.
3. The measured BT201 UART route (FFF0 / TX FFF1 / RX FFF2) is selected
   automatically. The initial reads check capabilities and slots before enabling
   model controls. Unsupported devices show a message without a UUID picker.
4. Choose `.namファイルを選択`, then `ここへ転送`. Replacement is confirmed because
   other presets may use the same slot.
5. Select the slot, or `再読み込み` after replacing the selected slot. Upload keeps
   the running RAM model until explicit reload/preset change.
6. `現在の選択をプリセットに保存` persists the binding; selection alone is temporary.
   Refresh after front-panel preset changes. Automatic synchronization is pending.

On interruption, reconnect/refresh before retrying. A lost final ACK may leave
a successfully stored model despite an app error; the stored slot list is the
reference. Cancel works between chunks and is disabled during commit. Tokens
expire after 3 seconds of inactivity; partial data never reaches flash. Two-bank
storage preserves the previous model on failed update. These are host tests,
not physical power-cut tests.

## Code and tests

- `lib/nam_model.dart`: strict parser, float32 conversion, FBNM CRCs.
- `lib/protocol.dart`: stock framing and stop-and-wait RPC.
- `lib/ble_link.dart`: permissions, discovery, GATT.
- `lib/ble_profile.dart`: measured FB200 UART selection; excludes module control.
- `lib/pedal_client.dart`, `lib/pedal_page.dart`: legacy editor, tools, backup,
  user-IR slots and Bluetooth naming. `lib/pedal/` holds the controller's tab
  views, NAM model selector and editor dialogs; device writes stay in the page.
- `lib/ir_wav.dart`: WAV → user-IR conversion, a Dart port of `src/fb200/wav.py`
  (RIFF/PCM 8-24 bit/float32/extensible, Kaiser windowed-sinc resampler).
- `lib/tone_key_scanner.dart`: camera QR input with lifecycle/permission handling.
- `lib/nam_client.dart`: operations and explicit simulated transport.
- `lib/main.dart`: app shell and language setting. `lib/model_page.dart`:
  connection hub and NAM model management, narrow-screen demo tested at 360 px.
- `lib/widgets/dialogs.dart`: shared confirm and text-entry dialogs.
- `tool/make_ir_fixtures.py`: regenerates the shared WAV/float32 fixtures with
  the Python reference; `test/fixtures/ir*.f32` is compared byte-for-byte.
- `test/fixtures`: synthetic weights only, not a musical capture. `.fbnm` is
  Python's reference output and Dart compares byte-for-byte; Python verifies it.

See [NAM_BLE_PROTOCOL.md](../docs/NAM_BLE_PROTOCOL.md) for RPC/official-app limits,
and [NAM_A2_LITE.md](../docs/NAM_A2_LITE.md) for firmware restrictions and remaining
real-time/audio validation.
