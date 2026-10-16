# FB200 NAM mobile manager

Flutter prototype for Android / iOS. Web provides the same explicit offline demo;
web Bluetooth is not implemented. **Physical FB200 Bluetooth and audio behavior
remain unverified.** This app has no firmware-update action. Review it through
the demo without connecting a pedal.

## Features

- Import user-supplied `.nam`: standalone fixed A2-Lite or packed A2 with a unique
  3-channel submodel; validate 48 kHz/exact supported shape and convert locally
  to the same FBNM bytes as the PC tool.
- Discover BLE, confirm firmware capabilities, list three model slots, upload
  with progress/cancel, explicitly select/reload, bypass and delete.
- Save selection into the currently loaded pedal preset.
- **接続せず試す** simulates slots. It creates no BLE connection or audio process.

NAM weights are not exposed as Gain/Bass/Middle/Treble knobs. Captures have fixed
trained behavior; choose another capture for another amp setting. Separate
pre/post gain or EQ could be added later but are not included in this version.

## Build / verify

Validated toolchain: Flutter 3.47.7 / Dart 3.13.5, compile SDK 37, AGP 9.1.1,
Gradle 9.3.1, Java 17+. Check in `pubspec.lock`.

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
signing for a phone). iOS compilation/signing cannot be validated on Windows.
Permission-handler's Swift package enables Bluetooth from the Info.plist key.
No background transfer mode is enabled; keep the app foreground during upload.

## Device workflow, after separate physical validation

1. The pedal must already run this branch's `nam-runtime` firmware. The app
   cannot add NAM to stock firmware or install firmware.
2. Close other FB200 editors, enable Bluetooth and connect. Android requests
   nearby-device permissions (12+) or location for older BLE scans; iOS requests
   Bluetooth permission. If denied, change the phone's settings.
3. The BT201 Service/TX/RX UUIDs have not been measured. Multiple discovered pairs
   require a confirmed selection; do not choose arbitrarily. The initial reads
   check capabilities and slots before enabling model controls.
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
- `lib/ble_link.dart`: permissions, discovery, GATT; no invented fixed UUIDs.
- `lib/nam_client.dart`: operations and explicit simulated transport.
- `lib/main.dart`: Japanese UI, narrow-screen demo tested at 360 px.
- `test/fixtures`: synthetic weights only, not a musical capture. `.fbnm` is
  Python's reference output and Dart compares byte-for-byte; Python verifies it.

See [NAM_BLE_PROTOCOL.md](../docs/NAM_BLE_PROTOCOL.md) for RPC/official-app limits,
and [NAM_A2_LITE.md](../docs/NAM_A2_LITE.md) for firmware restrictions and remaining
real-time/audio validation.
