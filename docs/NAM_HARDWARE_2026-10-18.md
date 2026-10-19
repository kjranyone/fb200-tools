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

## App-only session: user IR management and Bluetooth naming (0.4.0+7)

A later session extended only the Android app; no pedal, tablet or firmware
write was performed or required. Flutter 3.47.7 / Dart 3.13.5 was installed
locally on Windows (SDK at `%LOCALAPPDATA%\flutter-sdk`, hash-verified release
archive).

- `mobile/lib/ir_wav.dart`: Dart port of `src/fb200/wav.py`'s official-editor
  conversion (RIFF parse incl. WAVE_FORMAT_EXTENSIBLE, PCM 8/16/24/32-bit and
  float32 decode, channel 0, Kaiser windowed-sinc resample to 44.1 kHz,
  truncate/zero-pad to 1024 float32). Shared fixtures regenerated by
  `mobile/tool/make_ir_fixtures.py` (48 kHz stereo and 44.1 kHz mono float32)
  are compared **byte-for-byte** between the Python reference and Dart.
- `PedalClient`: `irList` (`65`), `irRename`/`irDelete` (`67` op 2/1 with
  `68` ok verification), `irUpload` (`61`, one 50-byte name frame plus eight
  512-byte data frames, per-frame `62` index acknowledgement, progress; the
  client never retransmits a data frame because a duplicate would corrupt the
  device-side assembly) and `setBtName` (`B3`, exactly 20 printable-ASCII
  bytes; `B3` has no reply in the stock protocol). IR names are sanitized like
  `sanitize_ir_name`.
- `PedalPage`: new IR tab (list/取込み/rename/delete with confirm dialogs; a
  NAM-profile note states the current firmware has no cabinet stage, so stored
  IRs are played by the stock firmware) and a Bluetooth-name entry in settings.
- 83 Flutter tests and analyze pass (18 new: WAV decode/parity/errors, IR
  harness list/upload/rename/delete/invalid-input, Bluetooth-name validation,
  IR-tab and dialog widget flows). `dart format` clean. Debug APK 0.4.0+7
  built locally; not installed.

Unchanged: no physical IR transfer, no Bluetooth rename on the air, no model
or preset writes, no firmware installation (the pedal still runs the previous
`nam-manager` image, so the app hides the rename control until a separately
authorized firmware update). `docs/ANDROID_PARITY.md` was updated.

Firmware follow-up in the same session (host/ARM validated, not installed):
RPC op 9 renames a stored model slot by re-committing the unchanged packet to
the alternate bank (name rules 1..23 printable bytes, NUL-padded 24; header
CRC resealed; weights/payload CRC/sequence handling unchanged; running RAM
model untouched). Capability flags gain bit 4 (base 23, `nam-manager` 31), so
older installed firmware keeps hiding the control. Host tests cover op 9
argument validation, empty-slot refusal, alternate-bank sequencing, idempotent
cached retries, flash-cut preservation and staging exclusion; both NAM profiles
build for ARM with the strict RAM/flash-busy checks (`ARM_ALL_OK`). The app
demo implements op 9; 85 Flutter tests and analyze pass.

## 64-slot store: flash authorized and installed (2026-10-18, later session)

The user explicitly authorized flashing in this session. The long IR area
F:0x400000..0x4FFFFF (1 MiB, unused by the NAM audio chain) became the NAM
model store: 64 slots, two 8 KiB banks each, guard sector before the looper
metadata kept. NAM builds no longer compile the long IR store (`irput`/`irls`/
`irdel` absent from the console; the stock open profile keeps it). The list RPC
is paginated: op 1 takes a start byte, replies `[selected][start][count]` plus
records, capability bit 5; slot arguments accept 1..64 everywhere. `namls`
prints the real slot count. The app (0.5.0+8) reads the slot count from the
capabilities, pages the list and keeps the legacy unpaged path for the older
three-slot firmware. 91 host tests, 498 full-suite passes (1 known
toolchain-dependent checker self-test fails locally with arm-gcc 10.3, passes
in CI), 88 Flutter tests, ARM builds plus strict RAM/flash-busy checks pass.

Flashed over the USB console (`fb200.console.update`, app slot only —
recovery, stock data, presets and every other region untouched):
app slot 208320 bytes, CRC32 `c05b5407`, SHA256
`463f78cecc46b2abb90e97896ad05b28b31b4d326cf1dc62b541e9be90751c1e`
(`out/pack-nam64/fb200-app.slot`). `fw done crc=c05b5407 ok` in 2.0 s.
Read-only verification after reboot: `nam slots: 64`, active 0 (all empty),
`stock: flash ok, in use`; CRC32 unchanged for presets `afc6cf54`, settings
`b43bc742`, the abandoned three-slot area `485d974c` and the new store region
`956bac74` (pre-existing bytes there are rejected as non-FBNM, so every slot
lists empty). Full log: `out/nam64-flash/flash-64slots.log`.

A later verification script mistakenly sent the console's `crash` command
(a deliberate `__builtin_trap()` recovery test, not a dump reader): the pedal
faulted exactly as designed, saved crash #1 (UDF in `dispatch`,
console.c:1057), rebooted into recovery and booted the app cleanly again
from `reset`. The dump was cleared; this validated the fault→dump→recovery→
boot path on hardware and was not a firmware defect. A Python RPC-over-HID
probe found no E1 replies on this Windows host (the standard version command
also gets none); the framed RPC remains host-tested against the same C code
and awaits a physical BLE check with the app once the tablet reconnects. No
model, preset or IR write was performed.

CI follow-up: the first NAM validation of `0a58c80` failed its strict
hot-path check — removing the long IR objects shifted the link so the CI
toolchain emits `__proto_feed_veneer` and treats `tud_hid_set_report_cb` as
an address-taken callback, dragging the XIP protocol tree into the hot set.
`89e8af6` applies the existing runtime gates to the hot set as well (a
checker fix; the flashed image is unaffected).

## Physical model write test (2026-10-19, user authorized)

The user authorized writing actual models. The committed synthetic fixture
(not a musical model) was stored over the USB console with the PC tool and
exercised end to end. The first run exposed a real bug: `namuse <slot>`
succeeded but `namls` reported `nam active 0` — `preset_nam_slot()` still
capped the binding slot at the old `slot <= 3`, so the edit-buffer reapply
right after the selection reverted any slot above 3 to bypass.
`9d8d6c4` caps it with `NAMSTORE_SLOTS` (host preset-tail test extended to
4, 64 and 65). Fixed image re-flashed: app slot 208320 bytes, CRC32
`f614c078`, SHA256
`c2242630a6941e147a06463dc808d8d29926a61f763146104fc1c3c781f58151`,
`fw done ok`.

Verified on the pedal with the fixed image: `nam put` to slots 1, 42 and
60 (names LowSlot/TrackTest/HighSlot appear in `namls`); select 60 →
`nam use ok` and `nam active 60`; switch 1 → 60; selecting an empty slot
fails and keeps the current model; the selection survives a `reset` of the
*store* listing (models persist; the RAM selection itself resets to bypass
on reboot as designed); `namuse 42` → `nam active 42` with the engine
healthy (`dma_errs=0`, `resets=0`, no crash dump); bypass and `namdel`
return the store to empty. Preset (`afc6cf54`), settings (`b43bc742`) and
short-IR (`3dd74fc6`) CRCs were identical before and after every step. The
preset-binding save path (`namuse <slot> save`) was not exercised on the
pedal — a flash preset write — and remains covered by host tests. Logs:
`out/nam64-flash/model-write-test.log` and the session transcript.

## Looper restored and flashed (2026-10-19, `822d8ce`)

The user asked for everything the session could deliver. The looper returned
to `nam-manager` (audio path, panel D+C mode, the flash store at
F:0x510000.. intact all along); the base restricted runtime keeps its stubs
(`engine_loop` there answers code 2). New `D7`/`D8` protocol commands
expose status (state/level/length/undo/busy), the seven actions, level and
the two save slots; capability bit 6 advertises it. The app (0.6.0+9) gains
a looper section on the tools tab and a module-order editor (`A0`). The
fuzz harness needed the new engine symbols; the profile test asserts
`looper_process`/`lsio_program` presence per profile, and the stock-mode
hot-path negative control is now profile-dependent (nam-manager passes
outright; the restricted runtime still fails on the missing lsio writers).

Flashed (app slot only): 210368 bytes, CRC32 `0713e35a`, SHA256
`c8b1c56ae21554575ef1a64f0799a79b33f4d62c2b9d627e5d0683da3f98281c`,
`fw done ok`. Physical verification over the console: erase-ahead prepares
flash (prep_ms grows to 108 s worth), `loop rec` records (len 4.2 s over
3 s wall), `play` closes and cycles, `dub` layers with undo available,
`undo`/redo works, `clear` empties; presets CRC `afc6cf54` unchanged and
the stack stable throughout (log: `out/nam64-flash/looper-physical.log`).
The first record attempt answered "not ready" while erase-ahead was still
preparing — that is the documented retry path (code 3), not a defect.
No loop save/load was written to flash. APK 0.6.0+9 built
(`out/fb200-manager-0.6.0-debug.apk`, SHA256
`1a1efffc3953313867a1f2f1ccdd16fa3cda012b9990b3a46fc1eb75ba5f6728`), not
installed: the tablet is still disconnected.

## Chain restore + first real-time CPU measurement (2026-10-19, later)

`nam-manager` (0.7.0+10 era) returns cab/MOD/reverb to the chain after the
NAM stage (capability bit 7): reverb state back in ITCM (link ends
0x1FAE8 / 0x20000), 44.1 kHz stock/user IRs resampled to 48 kHz in place
descending (`cab_ir_441_to_48`, host-tested against an independent
computation; an earlier ascending draft read its own output and was caught
by exactly that test). Flashed: app slot 211008 bytes, CRC32 `fa179c22`,
`fw done ok`. Physical: module frames over USB HID enable all three stages
live; presets/settings CRCs unchanged. A Windows host needed a 0x00
report-ID prefix on HID writes (Linux strips it) — fixed in
`fb200.transport` so the PC tools now work on Windows too.

Clean-window `prof` on the pedal (DWT cycles/block, budget 400,000 for
32 frames @ 48 kHz @ 600 MHz): in ~1,013, tuner ~1,437, gate ~348,
comp ~6,790, **cab 10,916, mod 10,053, reverb 22,479** (the restored chain
costs ~43k, 10.8% of budget; with NAM bypassed the whole path is ~64k,
16%), loop ~976, mix ~1,601, drums ~2,005, out ~4,131. **The NAM inference
stage measured 719,152 cycles/block — 1.8x the entire budget — with the
synthetic fixture model; the cost is data-independent (fixed-size loops).
With a model selected the audio path exceeds real time (the engine's
`skips` counter climbs; `dma_errs` stays 0 through the SAI ring).** This
is the hardware measurement the handover deferred: the kernel
(`dsp/nam_a2.c`, history-buffer recurrence over 1,871 weights x 3 channels
x receptive field 6,347) needs optimisation (CMSIS-DSP/windowed form)
before NAM-with-effects can run glitch-free. NAM bypass + the full stock
chain, drums, tuner and looper are comfortably real-time. Logs:
`out/nam64-flash/nam-cpu-isolated.log`, `chain-cpu-clean.log`.

## Kernel optimisation: 719k -> 262k cycles/block (2026-10-19, same day)

The scalar kernel's inner loop read strided stream-order weights with a
runtime kernel size — a multiply per weight index and no sequential
access. Two changes, both bit-identical by construction (every
accumulator keeps the reference addend order; `tests/nam_a2_golden.f32`
compares against the pre-optimisation kernel output byte-for-byte, and
the Core oracle/double-reference tests still pass):

1. **Tap-major weight repack at init** (`nam_a2.c repack()`): per layer,
   conv `[out][in][tap]` -> `[tap][out*3+in]`, head `[channel][tap]` ->
   `[channel per tap]`; the history (76 kB) serves as scratch. The nine
   products of each tap then read sequential weights. 719k -> 321k
   cycles/block.
2. **-O3 for nam_a2.c** (per-object Makefile rule): the scheduler loads
   history values ahead of the FMA chains. 321k -> 262k.

A hand-unrolled K=6 macro measured SLOWER (339k) than the runtime-K loop
and was reverted — the comment in nam_a2.c records the dead end.

Measured with everything on (NAM + cab + MOD + reverb + tuner): total
**321,444 cycles/block = 80.4% of the 400k budget**, `dma_errs=0`
(`out/nam64-flash/full-chain-cpu.log`). NAM-only stage: 262k (65.5%).
The looper adds ~1k only while looping. This closes the real-time gate
for NAM-with-effects on this firmware; remaining margin ~20% per block.

## Bluetooth audio restored (2026-10-19, same session)

The last chain exclusion. SAI3, its DMA ring and the AT-command on/off
were already compiled and running in every NAM profile — the BT201 slaves
to the MCU-generated I2S clocks, so 48 kHz needs no resampling — the base
restricted runtime simply never pulled the ring. The restore is the
`bt_audio_pull` into the output mix (`nam-manager` only, capability bit 8,
flags 511) plus the app's Bluetooth-audio switch on the same bit
(0.7.1+11). Flashed: app slot 211008 bytes, CRC32 `3807fe9d`, `fw done ok`.
Verified read-only on the pedal: `btaudio` reports the DMA ring filling
(blocks 8844 after ~6 s, fill 64, peak 0 — no A2DP source was connected,
so silence), the BT module is up (`bt: init step 4/4`, responding to AT),
and the AT on/off hook was already wired. No physical Bluetooth stream has
been listened to; that needs a phone pairing and remains a listening test,
not a code gate.
