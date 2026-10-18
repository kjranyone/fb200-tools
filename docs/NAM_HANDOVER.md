# NAM A2-Lite port: agent handover

Prepared 2026-10-18. Repository: `kjranyone/fb200-tools`, upstream:
`w1ne/fb200-tools`, branch: `feat/nam-a2-lite-foundation`.

## Objective and authorization

Run user-supplied NAM A2-Lite captures on FLAMMA FB200 (i.MX RT1052) with model
changes at runtime. Firmware must not need rebuilding for each capture. Provide
a Flutter mobile model manager and preserve existing preset/protocol behavior
where possible. Do not present trained NAM weights as editable amp knobs.

**The user's standing constraint is no physical firmware or model writes.**
This handover does not authorize flashing, USB model upload to a pedal, BLE
commit/delete/preset-save, factory reset or destructive storage tests. Keep
working on code, builds, host tests and the offline demo. A later hardware-write
session requires a new, explicit user instruction. The original work did not
connect a pedal or install the phone app.

Use the existing fork/branch. Do not merge to `main`, tag a release, publish a
flasher or replace upstream artifacts as part of this handover. The README's
upstream web-flasher/`latest` commands do not install this branch's NAM profile.

## Commits already implemented

| Commit | Work |
| --- | --- |
| `945ef8f` | fixed A2-Lite kernel/validator, 48 kHz clocks and RAM-probe profile |
| `86580d9` | live restricted runtime, persistent slots, USB loader, preset binding |
| `969f833` | Flutter manager, framed BLE/HID RPC, legacy preset preservation, parallel build fix |

The handover documentation is committed after these milestones. Use `git log`
and `git rev-parse HEAD` for the final branch revision instead of resetting to
one of the milestone commits.

## What works in host tests

- Fixed 23-layer, 3-channel A2-Lite inference: 1871 weights, 19,110 history
  floats, 83,976-byte state, receptive field 6347 samples, 48 kHz only.
- Standalone and packed-container `.nam` validation. Exactly one matching
  3-channel submodel is required; rate must be explicitly 48 kHz or inherited
  from the container. Unknown active architecture features fail closed.
- Three persistent slots, each with two 8 KiB banks. Validate packet, write
  alternate bank, commit header last. Delete uses a tombstone.
- USB CDC `fb200 nam put/list/select/delete` and framed USB HID/BLE RPC.
- Shared upload staging lock, offset/token/source checks, duplicate handling,
  CRC validation and inactivity expiry. Raw CDC reception remains separate
  from framed reception, so the console does not consume model fragments.
- Selection copies weights into RAM, mutes during load/warmup while servicing
  audio/USB/watchdog, then fades in over 256 samples. It is not seamless switching.
- Upload does not change the running RAM model. Explicit selection/reload is
  required, including after overwriting the selected slot.
- Presets store a slot reference at bytes 0xDE..0xE1 (`NAM_MARK=0x414E`). Save is
  explicit; other presets referencing a replaced slot use new data on next load.
- Legacy full-preset writes without the NAM marker preserve the destination's
  binding. This does not establish physical official-app compatibility.
- Flutter import, slot management, progress/cancel, selection/reload, bypass,
  delete and preset save. The explicit demo never creates a BLE link or audio
  process. Python and Dart produce byte-identical FBNM for a synthetic fixture.

## Current boundaries

`PROFILE=stock` remains 44.1 kHz. `nam-probe` reserves memory and is not live
inference. `nam-runtime` is app-only, 48 kHz / 16-bit I2S and USB.

The NAM runtime keeps gate, compressor, EQ, delay (500 ms max), master gain,
USB audio and reamping. It excludes stock amp/tone, cab/IR, modulation, reverb,
tuner, drums, looper and Bluetooth audio. BLE control is still present.
There is **no cabinet stage** or NAM-specific front-panel editor. Input/output
calibration is pending. Do not restore effects without rate/CPU/RAM validation.

No physical BT201 Service/TX/RX UUIDs are known. The app discovers writable and
notify/indicate pairs in a service, asks for the measured pair when ambiguous,
then checks NAM capabilities/list before enabling mutations. Do not hardcode a
guessed UUID or claim that a demo upload verified radio transport.

The app does not synchronize unsolicited front-panel preset changes; refresh
is explicit. Keep it foreground during transfer and close other FB200 editors.
Android debug build passes. iOS 15+ source/purpose keys exist, but iOS has not
been compiled or signed. Launch icons remain Flutter template assets.

## Implementation map

| Area | Entry points |
| --- | --- |
| Kernel | `firmware/audio/src/dsp/nam_a2.{c,h}` |
| Clock/profile/RAM | `firmware/audio/Makefile`, `src/system_clock.c`, `src/audio/engine.c`, `src/tusb_config.h`, `linker.ld` under `firmware/audio/` |
| Runtime model selection | `engine_nam_select`, `engine_apply_preset` in `firmware/audio/src/audio/engine.c` |
| Persistent store / target port | `firmware/audio/src/namstore/namstore.{c,h}`, `namstore_port.c` |
| Framed RPC / UI glue | `firmware/audio/src/namstore/namrpc.{c,h}`, `namrpc_port.c` |
| Stock dispatcher / BLE UART | `firmware/audio/src/proto/proto.{c,h}`, `proto_port.c`, `src/bt/bt.c` |
| CDC binary ownership | `firmware/audio/src/debug/console.c` |
| PC parser / uploader | `src/fb200/nam_model.py`, `nam.py`, `nam_console.py`, CLI in `cli.py` |
| Flutter | `mobile/lib/nam_model.dart`, `protocol.dart`, `ble_link.dart`, `nam_client.dart`, `main.dart` |
| Native tests | `tests/test_nam_a2.py`, `test_nam_profile.py`, `test_nam_runtime.py`, `test_nam_rpc.py`, `test_proto_host.py` |
| Mobile tests | `mobile/test/`, shared synthetic model/packet in `mobile/test/fixtures/` |
| RAM/flash-busy checker | `firmware/tools/hot_path.py --nam-runtime` |

FBNM v1 is a private 7548-byte packet: 64-byte header + 1871 little-endian
float32 weights, rate/shape fields and CRCs. See [NAM_A2_LITE.md](NAM_A2_LITE.md)
and [NAM_BLE_PROTOCOL.md](NAM_BLE_PROTOCOL.md) for exact field layouts.

Flash offsets: models `0x502000..0x50DFFF`, unused guard sector
`0x50E000..0x50EFFF`, existing looper metadata at `0x50F000`. Preserve all other
regions. NAM state is in DTCM; staging is 8192 bytes in OCRAM. At `969f833`,
total OCRAM was 21,596 / 32,768 bytes. RAM fit is not a CPU deadline measurement.

RPC commands are E0/E1 over existing AA55 framing; operations 0..7 are caps,
list, begin, chunk, commit, abort, select/save and delete. Max chunk is 64 bytes;
tokens expire after 3 seconds of inactivity. Client retries the same request/ID
after 1 second, at most twice. Only the device's last reply is cached; concurrent
editors can evict it. If final ACK is lost, reconnect/list before retrying, since
commit might already have succeeded. Check protocol docs before changing timing.

## Reproduce without hardware

From a clean clone, select the development branch. Prefer Ubuntu/WSL for native
C and ARM checks. Install Python 3.10+, a host C/C++ compiler, GNU make, curl,
`gcc-arm-none-eabi`, `libnewlib-arm-none-eabi`; Eigen headers are needed only for
the optional official Core oracle. No vendor image/capture is needed for NAM tests.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[dev]' pytest-xdist
.venv/bin/ruff check .
.venv/bin/pytest -q -rs -n 4
make -C firmware/audio PROFILE=nam-runtime -j4 build layout
.venv/bin/python firmware/tools/hot_path.py \
  firmware/audio/build/nam-runtime/fb200-app.elf --nam-runtime
git diff --check
```

Default pytest configuration excludes `hardware`, `stock` and `fuzz` markers.
Do not override that exclusion for the handover. Toolchain/emulator/vendor-input
availability can cause additional skips; inspect `-rs`, rather than treating a
green run with skipped ARM tests as an ARM validation.

Without the optional oracle, its numerical comparison is skipped. To match the
original full result, build `tools/nam_core_reference.cpp` against official
Core commit `0b3d3c97b0859a3a8c92a8628c4dd89a25eb5842` and set
`FB200_NAM_CORE_REFERENCE` to the executable. Exact C++20/Eigen commands are in
[NAM_A2_LITE_INITIAL.md](NAM_A2_LITE_INITIAL.md#optional-official-core-comparison).
Do not distribute user-supplied captures or generated weights with the fork.

Keep build directories separate between `stock`, `nam-probe`, `nam-runtime`
and recovery. The Makefile's independent objcopy targets avoid concurrent
writers under `-j4`; do not reintroduce the former shared recipe.

Use Flutter **3.47.7 / Dart 3.13.5** and the committed `pubspec.lock`:

```sh
cd mobile
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
flutter build web
```

Android uses compile SDK 37, AGP 9.1.1, Gradle 9.3.1 and Java 17+. The APK is
`mobile/build/app/outputs/flutter-apk/app-debug.apk`, a debug-signed prototype,
not a store release. To review the UI, use `flutter run -d chrome` and select
**接続せず試す**. Web Bluetooth is not implemented. Import the synthetic fixture
only in demo mode; it is not intended as a musical model.

On a Mac with Xcode, `flutter build ios --no-codesign` is the next compile-only
check. Device signing is separate. Do not report iOS support as verified until
the build and phone tests have actually been performed.

## Evidence and next work

Recorded at `969f833` on 2026-10-17: **492 Python/C/ARM tests passed, 15 skipped**
with the optional official Core oracle enabled; **27 Flutter tests passed**;
Ruff, Flutter analyze, Android APK, web and compiled RAM/flash-busy checks passed.
The web demo was exercised through import -> upload -> select -> preset save.
All transfer/storage tests used host fakes. Prior results are snapshots, not a
claim that CI or hardware passed at every later revision.

Before hardware work, prioritize these gates:

1. Review this handover and reproduce host/ARM/mobile checks. Record skips and
   tool versions. Inspect current branch status before editing; preserve user work.
2. Confirm actual BLE Service/TX/RX properties and notification readiness in a
   separately arranged read-only hardware session. Record measured UUIDs and
   module/phone/OS details, then replace the provisional endpoint picker with
   a verified profile. Mock discovery is not physical evidence.
3. Prepare a recovery/backup and measurement plan. Do not flash to execute it
   under the current no-write constraint.
4. After explicit write authorization, measure PLL/codec/USB operation, model
   transfer/erase latency, expiry/retry under radio interruption, preset save/boot
   and physical power-cut recovery. Exercise read-only handshake before writes.
5. Measure worst-case Cortex-M7 cycles/underruns with a real capture. At 600 MHz,
   32 frames / 48 kHz allow 400,000 cycles for the complete audio path. Optimize
   only from measurements and keep the Core oracle and flash-busy checks green.
6. Validate levels, DC/noise, switching mute/fade and listening quality, then
   consider cab/IR, calibration, pre/post gain/EQ and front-panel/mobile polish.

Capture evidence in an incremental log: firmware commit/profile, model hash
(not redistributed model contents), device/phone/OS, measured endpoints, commands,
expected/observed result and whether any persistent write was authorized/performed.
Do not turn the upstream stock firmware's CPU figures into NAM performance claims.

## Suggested continuation prompt

> Continue work on kjranyone/fb200-tools, branch feat/nam-a2-lite-foundation.
> Read README.md, docs/NAM_HANDOVER.md, docs/NAM_A2_LITE.md,
> docs/NAM_BLE_PROTOCOL.md and mobile/README.md first. Reproduce the available
> no-hardware checks and report any missing tools/skipped gates. Preserve the
> runtime model-loading requirement and explicit demo. Do not flash firmware,
> write/delete a physical model or save a pedal preset without a new explicit
> user instruction. Physical BLE endpoints, Cortex-M7 deadlines/audio and iOS
> build/signing are still unverified. Use measurements to choose the next change;
> never mark a host fake or demo as hardware validation. Keep changes on this
> branch and document results and remaining work.
