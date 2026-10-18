# NAM runtime: first physical installation, 2026-10-18

The user explicitly requested installing the custom implementation on the
connected FB200, superseding the previous development-only no-write constraint
for this firmware installation. No model, model selection, or preset was written.

Base revision: `b37a4f8`, profile `nam-runtime`. The user entered the vendor
updater using A+D. All 6810 initial-install frames were acknowledged; recovery
provided a Windows USB serial console at COM7 (`AUDIO_0001`). The loader CRC
matched `80cbbac5`. The NAM app and format-2 stock assets passed device CRC
validation and rebooted successfully. `stock` reported `flash ok, in use`.

The first app had Windows USB Audio Code 10 (`0xc000028c`). Replugging did not
resolve it. Its 192-byte isochronous endpoints held exactly 48 stereo 16-bit
frames, without the additional frame reserved by TinyUSB's full-speed
`TUD_AUDIO_EP_SIZE` calculation. The endpoint capacity now follows that formula
and the software FIFOs hold four maximum packets. At 48 kHz this is 196 bytes
per endpoint and 784 bytes per FIFO.

After this change and an app-only update, Windows reported all CDC, HID and
USB Audio interfaces healthy, with both recording and playback endpoints.
An explicit FB200 WASAPI capture at 48 kHz, stereo 16-bit, collected 96,000
frames over two seconds without an input overflow. Peak was one integer count;
no musical input or generated test tone was used. No audio was saved.
Playback was enumerated but was not streamed or listened to.

Final app slot: 210112 bytes, CRC32 `6f83d22b`, SHA256
`af6a7bc245b02b0d2fd62e83572fc4164b51b4a12c36f8d771a198b75124a363`.
The device returned `fw done crc=6f83d22b ok`. Recovery and vendor bootloader
were not rewritten by this final app-only update.

`namls` reported three empty slots, active slot zero (NAM bypass), and no crash
dump was present. Idle engine CPU was about 4%; this does not measure live NAM
inference. Hardcoded application version/hardware strings are not independent
identification of the physical board.

Host NAM tests before installation: 154 passed, one optional Core-oracle test
skipped. After the USB change, both 44.1/48 kHz config cases, ARM profile builds,
and the strict runtime RAM/flash-busy checker were verified again. Actual model
inference, musical levels, listening, worst-case deadlines, Bluetooth model
transfer and power-cut recovery remain unverified.

Local installation logs, images, the Windows HID/CDC adapter, and capture
verification are under the main checkout's ignored `out/` directory. The
working source changes are in worktree `out/nam-usb-fix`, branch
`fix/nam-windows-usb-audio`; they have not been committed or published.

## Read-only Android BLE verification

On the attached Lenovo TB-J716F (Android 13 / API 33), the device advertised
`FB200KJFootSwitch`. Service FFF0 exposed writable/notify FFF1, read/notify FFF2,
and writable FFF3 (all UUIDs use the Bluetooth base UUID). The previous app
cross-producted these into four routes and asked the user to choose.

FFF1 writes with FFF1 notifications timed out after the three bounded
capabilities attempts. The USB console `bt` receive log confirmed that the
requests reached the pedal UART. Switching only RX to FFF2 returned NAM
capabilities (op 0) and the three empty slots (op 1). Thus the measured route is
FFF0 / phone TX FFF1 / phone RX FFF2. FFF3 was never written; it is reserved for
the Bluetooth module's control commands. The supplier's
[BT401/BT201 manual](https://core-electronics.com.au/attachments/uploads/DFR0781_english-translated-datasheet.pdf),
sections 7.2 and 7.6, also distinguishes UART endpoints from FFF3 control.

The app now selects only this route, requires the writable/notification
properties and rejects missing or duplicate endpoints. NAM capabilities and
slot reads still gate all model controls. No manual UUID selection remains.
All 52 Flutter tests and static analysis passed; Android debug 0.2.1+3 built.

APK: main checkout `out/fb200-nam-tone3000-0.2.1-debug.apk`, 162300611 bytes,
SHA256 `8974aca79c415255061c52e558936954ef78bfe8b807010d549028a51af8cd25`.
The APK was installed with `adb install -r`; package metadata confirmed
versionName 0.2.1 and versionCode 3. Choosing the device connected directly,
without a route dialog, and displayed three empty slots. Explicit list refresh
and disconnect/reconnect also succeeded. The final app is left connected to the
pedal. UI XML, screenshot and UART logs are in the main checkout's
`out/tone3000-evidence/ble-fixed-*`. No model, selection or preset was written.

## Manager firmware and Android editor

The user requested an Android superset of Flamma Manager, including all bank/
preset, drum-machine and tuner functions. The `nam-manager` profile adds drums
and tuner to the 48 kHz NAM runtime. The original restricted profile remains
available. NAM/stock-effect/audio interoperability remains incomplete.

Manager app slot: 211840 bytes, CRC32 `a92a5c2a`, SHA256
`2ff5f52b81bfc0b00aef2bc09ef53a4c111ec62aad78f5d79c0a1f7eb1f0013b`.
It passed ARM build, RAM/linker and flash-busy call-graph checks and was installed
using an app-only USB update (`fw done crc=a92a5c2a ok`). Recovery, stock assets,
models and preset storage were not rewritten. Before/after CRCs matched:

| Region | Bytes | CRC32 |
| --- | ---: | --- |
| Forty preset sectors, F:0x71000 | 20480 | afc6cf54 |
| Global/rhythm settings, F:0x80000 | 8192 | b43bc742 |
| NAM banks, F:0x502000 | 49152 | 485d974c |

Physical USB returned capabilities `(48000,1871,3,64,7548,15,0)`, an invalid/
silent tuner snapshot, and all forty 256-byte preset records. Console tuner
on/off worked with no input, no crash dump, zero DMA errors and DSP resets.
No model or preset was saved/changed. Selected NAM slot remains bypass (0).
This does not verify musical pitch detection or drum sound on the pedal.

Host tests verified 41.20344/110/440 Hz within two cents at both 44.1 and 48 kHz,
plus output matching independent 44.1→48 kHz drum interpolation. The related
NAM/protocol/drum suite passed 140 tests / 1 optional skip; a subsequent profile
test passed all five cases including both runtime profiles.

Android 0.3.0+5 was built, installed (`adb install -r`) and launched; 65 Flutter
tests and analyze passed. APK: `out/fb200-manager-0.3.0-debug.apk`, 180316473 bytes,
SHA256 `68e4392803c22eb7a7d6857f0f6f96cd6c46308267bb3797a6d1bd3ebea54a9c`.
The tablet was disconnected from USB before the new editor could be exercised
over BLE. Physical preset edits/copies/restores, new tool controls and actual
public-key QR scanning remain unverified. Evidence/artifacts are under the main
checkout's `out/nam-manager/` and `out/tone3000-evidence/`.

Final APK 0.3.1+6 corrects bank labels to match the physical display (BANK 0–9,
0A–9D). The eight targeted client/editor tests passed again. File:
`out/fb200-manager-0.3.1-debug.apk`, 180316349 bytes, SHA256
`ac4ce1f4e2087406df4a802476934d8e28340ebde8172d8bea358f5660480ef2`.
APK metadata confirmed versionName 0.3.1 / versionCode 6 and the camera
permission. This correction is built but not installed; the tablet is still
disconnected. The web build also passed before the bank-label-only correction.
