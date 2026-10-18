# NAM A2-Lite: runtime model slots

Model changes must not require a firmware rebuild. The `nam-runtime` research
profile implements **model upload -> persistent model slot -> RAM load -> inference**.
The firmware's fixed A2-Lite engine is installed once; subsequent captures are
data transfers. `.nam` parsing and packed-model extraction happen on the PC or
in the [Flutter app](../mobile/README.md). The device validates the resulting
binary packet again. USB CDC and the [BLE/HID extension](NAM_BLE_PROTOCOL.md)
share the same persistent store.

**Status:** implemented and host-tested, ARM cross-built, not flashed or tested
on a real FB200. This is not a production firmware release. Real-time CPU cost,
hardware clocks, audio quality and uninterrupted USB streaming are unmeasured.
The default `PROFILE=stock` remains the existing 44.1 kHz firmware. The earlier
fixed-model prototype is recorded in [NAM_A2_LITE_INITIAL.md](NAM_A2_LITE_INITIAL.md).

## User workflow

After installing a tested `nam-runtime` firmware, model management uses:

```sh
fb200 nam put 1 /path/to/capture.nam --name MyAmp --port COM5
fb200 nam list --port COM5
fb200 nam select 1 --save --port COM5
fb200 nam select 0 --port COM5        # dry NAM bypass
fb200 nam delete 1 --port COM5
```

These commands are implemented. They have been tested with simulated storage
and USB and are not yet verified on a pedal. No write was performed in this work.
`--port COM5` is an example: use the actual USB console port. Linux/macOS use the
existing CDC console transport; native Windows uses pyserial (`pip install -e
'.[nam]'` from this checkout, or the equivalent editable install on Windows).
Windows automatic discovery accepts exactly one AUDIO serial identifier;
otherwise an explicit port is required. The existing firmware updater's Windows
support is separate from this NAM model-management transport.

`put` validates a 48 kHz A2-Lite or packed A2 `.nam` and uploads it to slot 1..3.
It does not change the currently running model, rewrite the firmware, reboot,
or automatically select the new contents. `select` loads a valid slot into RAM,
warms it with silence while servicing audio and the watchdog, then fades in over
256 samples. There is a brief mute during load/warmup; seamless live model
switching is not claimed. The AMP enable/stomp flag bypasses the NAM stage.

`select --save` also saves the slot choice in the current preset. Without it,
the selection edits the current preset in RAM; the normal panel save also stores
it. Preset offsets 0xDE..0xE1 hold a "NA" marker and slot (after the EQ record).
Old/erased/unmarked presets bypass NAM. Missing, corrupt or deleted referenced
models bypass NAM when a preset loads. Deleting the active slot also bypasses
it immediately. Presets refer to slot numbers: replacing slot 1 changes the
capture used by every preset referring to slot 1 on its next load.

The model itself remains in flash across power-off. The most recently saved
preset supplies the model selection at boot. Firmware updates must continue
preserving the dedicated model area; this uses the existing app-only updater's
separate app region.

## Restricted audio profile

`PROFILE=nam-runtime` runs at 48 kHz, 16-bit I2S/USB with the fixed 23-layer,
3-channel A2-Lite player. Gate, compressor, our EQ, delay (maximum 500 ms),
master gain, USB audio and reamping remain connected. Stock amp/tone, cab IRs,
modulation, reverb, tuner, drums, looper and Bluetooth audio are excluded from
the processing path. Looper record/load/save/erase entry points are disabled.
Their UI/control scaffolding is not a completed NAM-oriented front panel.

In particular there is currently **no cab/IR stage** in this profile. A capture
including a cabinet or an external cabinet stage is needed for a complete amp
sound. The existing stock amp GAIN/tone knobs do not become NAM drive/EQ controls.
Input/output calibration and listening tests remain necessary.

The old 512-tap cab allocation and some unused module state remain in the image;
they can be removed later. Removing reverb's ITCM state and inactive processing
code frees room for the live kernel. `nam-probe` remains available as the original
memory-only experiment, with no live NAM inference.

## Storage and interrupted writes

Three logical slots use two independent 8 KiB banks each:

| Area (flash offsets) | Use |
| --- | --- |
| below `0x502000` | existing IR store, unchanged |
| `0x502000..0x50DFFF` | NAM: 3 slots x 2 banks x 8192 bytes |
| `0x50E000..0x50EFFF` | unused guard sector |
| `0x50F000..` | existing looper metadata and audio, unchanged |

Offsets are relative to flash base 0x60000000. Capacity is checked before every
store operation; a chip smaller than 0x50E000 refuses the store. The NAM write
range is enabled only in `nam-runtime`. Neither bootloader, recovery, application,
stock assets, presets, IRs nor looper data are used as model storage.

Each bank contains a 64-byte header and 7,484-byte float32 weight payload. CRC32
covers the header and payload separately. Upload framing also has a whole-packet
CRC. The header specifies magic, format version, fixed architecture, sample rate,
weight count, sequence, name and deletion flag. Wrong shape/rate/count, non-finite
weights or CRC failure is rejected before flash writes.

On replacement, data is written to the alternate bank with an invalid header.
The new header, including its CRC and incremented sequence, is committed last.
Every operation scans both banks and selects the newest fully valid record;
there is no volatile index required after reboot. A deletion writes a tombstone
so an older model is not resurrected by a normal reboot. Previously valid model
data remains in the other bank during an interrupted replacement. This is
power-loss recovery under the NOR model tested here, not immunity to arbitrary
flash hardware faults.

Flash erases/programming use the existing `flash_store`/RAM-only audio pump.
The running player uses RAM-resident weights/history, so it does not read the
model flash while flash is busy. A rejected update leaves the current model's
RAM untouched. Transfer inactivity aborts after 3 seconds without committing.

### FBNM v1 packet (little endian, 7548 bytes)

| Offset | Field |
| --- | --- |
| 0 | magic `FBNM`, u32 |
| 4 / 6 | version 1 / fixed A2-Lite shape ID 2, u16 each |
| 8 / 12 | rate 48000 / weight count 1871, u32 each |
| 16 / 20 | payload CRC32 / sequence, u32 each |
| 24 | printable non-space name, NUL-padded 24 bytes |
| 48 / 52 | flags (0=model, 1=stored deletion) / reserved zeros |
| 60 | CRC32 of header bytes 0..59 |
| 64 | 1871 float32 weights, original validated `.nam` stream order |

This is a private transport/storage format, not a claim of compatibility with
other projects' `.namb` files. The host imports `.nam`; no packet file management
is required by the user. Core license attribution is in [NAM_LICENSE.md](NAM_LICENSE.md).

Console protocol: `namput <1-3> 7548 <packet-crc>` -> `nam ready` -> raw packet ->
`nam done ok slot N` (or FAILED/timeout); `namls`; `namuse <0-3> [save]`;
`namdel <1-3>`. A binary transfer owns the console until completion/timeout;
the line reader stops immediately on accepting the upload command, preserving
coalesced binary bytes.

## Build and verification (no hardware)

```sh
make -C firmware/audio PROFILE=nam-runtime -j4 build layout
python3 firmware/tools/hot_path.py \
  firmware/audio/build/nam-runtime/fb200-app.elf --nam-runtime
pytest -q tests/test_nam_runtime.py tests/test_nam_rpc.py tests/test_nam_profile.py tests/test_nam_a2.py tests/test_proto_host.py
pytest -q
ruff check .
```

Use separate output directories per profile. The safety check's explicit
`--nam-runtime` mode requires the NAM entry points and checks the real live
kernel/audio/flash-busy call graph; only absent disabled looper writers are
removed from the mandatory roots. The default stock checks remain strict.

Storage tests run the actual C store against fake NOR, inject 54 interrupted
updates at sector/page/header boundaries, verify CRC/rate/shape/NaN/capacity/range
rejection, chunked USB reception and timeout, persistent tombstones, and feed
stored weights through the actual C kernel. Additional tests cover the host
uploader, native-Windows transport with a fake serial device, preset markers,
actual flash-RMW capacity/boundary guards and audio pumping, and the ARM image's
model/staging allocation and RAM-only live path. Numerical Core-reference tests
from the initial milestone remain in place.

USB runtime milestone on 2026-10-17: full suite **475 passed / 15 skipped** with the optional
official Core oracle enabled; runtime store/client/preset/RMW/Windows-mock tests
**65 passed**; the final runtime image and flash-busy safety check also passed
after the watchdog-service change. Ruff and diff whitespace checks passed.
Hardware/stock/fuzz markers retain their existing default exclusions.

After the mobile/RPC implementation at `969f833`, the full suite passed
**492 tests / 15 skipped**, and Flutter passed **27 tests**. Android debug APK
and web builds, Flutter analyze, Ruff and the ARM image/safety checks passed.
iOS was unbuilt at that milestone; its unsigned macOS CI compile passed on
2026-10-18. See [NAM_HANDOVER.md](NAM_HANDOVER.md) for reproducible checks,
current CI evidence and the remaining hardware gates.

## Remaining before pedal use

The [Flutter manager](../mobile/README.md) now implements model import, BLE slot
transfer and preset binding with the matching [RPC extension](NAM_BLE_PROTOCOL.md).
Measured BT201 endpoints and read-only Android capabilities/slot listing are
verified; physical model transfer and audio tests remain outstanding. See
[hardware evidence](NAM_HARDWARE_2026-10-18.md). The USB console workflow is still available.

- Measure worst-case Cortex-M7 cycles and underruns. The complete 32-frame
  48 kHz path has 400,000 cycles; this scalar kernel may require optimization.
- Verify PLL/codec/USB behavior and model switching on actual hardware, and
  listen for DC, gain, noise and switching artifacts. Host tests cannot establish
  real-time performance or audio quality.
- Verify physical power-cut recovery and flash wear behavior, preset save/boot,
  battery critical-write refusal, and long-duration USB transfer/streaming.
- Add a suitable 48 kHz cabinet/IR stage, front-panel model selection and controls,
  calibration, and finish physical validation of the mobile editor. Restore
  other effects only after their rate and resource requirements are validated.

No real pedal access or firmware/model write was performed during development.
