# Android app parity requirement

The user's requirement on 2026-10-18 is a superset of Flamma Manager, including
**all** bank/preset management, drum-machine and tuner functions, with NAM and
TONE3000 added. NAM-only management is not the finished product.

Baseline evidence: [STOCK_FEATURES.md](STOCK_FEATURES.md),
[PROTOCOL.md](PROTOCOL.md). Firmware parity is separately recorded in
[PARITY.md](PARITY.md); stock-profile parity does not establish NAM-profile parity.

Release requirements:

- Ten banks / forty presets: select, read/edit, save to another slot, rename,
  copy, lossless backup and restore preserving unknown bytes and NAM bindings.
- All stock effect blocks and model/parameter choices; live front-panel changes
  reflected in the app, with sound behavior checked for the running profile.
- Forty drum patterns, start/stop, 40–260 BPM, level and tap tempo. NAM's 48 kHz
  path must preserve drum pitch and timing from 44.1 kHz source samples.
- Tuner on/off, mute, A4 reference and live pitch display from the pedal input.
  Restore the engine's tuner at 48 kHz; a phone-microphone tuner is not parity.
- Settings, battery, Bluetooth naming/audio, light-ring color/level and user IR
  management. Cloud/file import complements these controls.
- Stock firmware remains connectable; NAM-only operations are capability gated.
- Android physical checks, protocol/host tests and firmware RAM/flash-busy/audio
  checks are separate evidence. An unimplemented function must not appear usable.

The original restricted 48 kHz NAM firmware excluded stock amp/cab/MOD/reverb,
tuner, drums, looper and Bluetooth audio from its processing path. This is an
explicit gap, not a completed superset. The previous NAM branch was designed as
a restricted runtime prototype; restoring these requires firmware work and
performance validation as well as app screens.

QR setup in Android 0.2.2+4 adds a camera reader for a raw Publishable Key QR.
Public identifier validation is shared with manual setup, Secret Keys/URLs are
refused, cancellation leaves the previous value intact, and OAuth still starts
only after the user chooses to browse. Camera images/QR contents are not logged
or transmitted by the scanner. 57 Flutter tests and analysis passed before the
legacy editor work. Camera startup/return were checked on Lenovo TB-J716F;
physical scanning of a real public-key QR remains to be checked.

## Current implementation: 0.4.0+7 / nam-manager

The integrated app now implements bank/preset read/select/save/rename/copy,
whole-bank backup/restore, legacy effect and global-setting controls,
front-panel preset refresh, drum/tuner controls and capability-gated live pitch.
Legacy exchanges are serialized with NAM RPC; mutations are never automatically
retried. Preset saves check the acknowledgement and compare the readback. Backup
restore validates all records/CRCs before writing, explicitly confirms the whole
overwrite and restores the original selected preset after successful completion.
Backups contain preset records, not NAM weights or IR sample data.

0.4.0 adds user IR management (stock `61`/`65`/`67` protocol): slot list,
WAV import converted locally with a Dart port of the PC `wav.py` conversion
(byte-identical output on shared fixtures), rename and delete with explicit
acknowledgement checks. Upload sends one name frame plus eight 512-byte data
frames; nothing is committed unless all frames are acknowledged in order.
The NAM runtime has no cabinet stage, so the IR tab states that stored IRs are
played by the stock firmware. A Bluetooth device-name control (`B3`, 20 bytes,
no reply) is also included; the name cannot be read back, so the app asks the
user to verify after reconnecting.

Model slot renaming (firmware RPC op 9, capability flags bit 4) is implemented
in firmware and app: the stored packet is re-committed under the new name to
the alternate bank with weights and payload CRC untouched, and the running RAM
model is not disturbed. Host C tests cover name validation, alternate-bank
sequencing, flash-failure preservation, retry caching and staging exclusion;
both NAM profiles build for ARM with the strict RAM/flash-busy checks. The app
shows the control only when the firmware advertises bit 4, so already-installed
firmware keeps its current behavior until a separately authorized update.

`PROFILE=nam-manager` restores the drum machine and tuner to the 48 kHz NAM
engine. Drums retain a 44.1 kHz source sequencer/sample clock and interpolate to
48 kHz; the tuner uses the actual input rate. YIN analysis services audio/USB
between lag groups. Feature flag 8 enables these tools and read-only RPC op 8.
This is still a restricted NAM audio chain: stock amp/cab/MOD/reverb, Bluetooth
audio and the looper are not restored. Unsupported controls stay disabled.

The model store was extended from three to 64 slots (firmware 0.5-era, app
0.5.0+8): NAM profiles reuse the long IR area F:0x400000..0x4FFFFF and no
longer compile the long IR store (the stock open profile keeps it); the list
RPC is paginated (op 1 start byte, capability bit 5). Older app builds cannot
manage the new firmware and vice versa.

0.6.0+9 restores the looper to `nam-manager` (the audio path, the panel's
D+C looper mode and our new `D7` app control; capability bit 6) and adds the
module-order editor (`A0`) to the app. 0.7.0+10 returns the stock
cab/MOD/reverb to the `nam-manager` chain after the NAM stage (capability
bit 7): the reverb's 46.9 kB state back in ITCM (link ends 0x1FAE8 of the
0x20000 limit), 44.1 kHz cab/user IRs linearly resampled to 48 kHz in place
descending (`cab_ir_441_to_48`, host-tested against an independent
computation), and the app enables those controls plus the global-cab switch
on bit 7. 0.7.1+11 mixes Bluetooth audio back in (capability bit 8): SAI3,
the DMA ring and the AT-command on/off already ran in every profile — the
module slaves to our I2S clock, so 48 kHz needs no resampling — so the
restore is the pull into the output mix plus the app switch. The base
restricted runtime keeps all of these stubs. Physical measurement: the restored chain costs ~43k
cycles/block of the 400k budget (bypass total ~16%), while the NAM
inference measured 719k cycles/block — 1.8x the whole budget. Optimised
the same day to 262k (tap-major weight repack at init plus -O3,
bit-identical by a committed golden fixture): the everything-on total is
321k = 80.4% of budget with `dma_errs=0`. Further kernel work (windowed
form, CMSIS-DSP) is optional headroom, not a gate
(see NAM_HARDWARE_2026-10-18.md).

Bluetooth audio returned in the same session (0.7.1+11, capability bit 8):
SAI3, its DMA ring and the AT-command on/off were already compiled and
running in every profile — the module slaves to the MCU's I2S clock, so
48 kHz needs no resampling — and the restore is the `bt_audio_pull` into
the output mix (`nam-manager` only) plus the app's Bluetooth-audio switch
on bit 8. No physical Bluetooth stream has been listened to yet; `btaudio`
console stats and the mix path are the evidence so far.

85 Flutter tests and analyze pass (WAV decode/resampler parity against shared
Python fixtures, IR list/rename/delete/upload harness, Bluetooth-name
validation, model-rename gating, IR tab and dialog flows). ARM build, RAM
placement, flash-busy checks, 44.1/48 kHz pitch and drum-rate host tests pass.
The manager firmware and the previous app were installed. Physical USB
verified flags 15, tuner on/off/no-signal, forty preset reads, no crash dump
and unchanged preset/settings/NAM flash CRCs. The tablet's USB connection
disappeared immediately after 0.3.0 installation; the new legacy editor/BLE
controls, physical IR transfer, model rename and Bluetooth naming therefore
still require physical UI validation. 0.3.1+6 corrected bank labels to the
pedal's BANK 0–9 / presets 0A–9D; that APK was not installed because the
tablet remained disconnected.

Remaining parity work includes the complete NAM audio chain, IR auditioning,
Bluetooth naming/audio read-back, model labels on already-installed firmware
(needs a separately authorized firmware update) and all advanced settings,
physical stock firmware operation, musical audio/deadline checks and real
TONE3000 OAuth/download. The stock cab/MOD/reverb chain is restored in
`nam-manager` (0.7.0+10); Bluetooth audio and a NAM-side cab stage before
the model remain future work.
