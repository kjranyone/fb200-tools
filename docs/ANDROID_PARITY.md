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

`PROFILE=nam-manager` restores the drum machine and tuner to the 48 kHz NAM
engine. Drums retain a 44.1 kHz source sequencer/sample clock and interpolate to
48 kHz; the tuner uses the actual input rate. YIN analysis services audio/USB
between lag groups. Feature flag 8 enables these tools and read-only RPC op 8.
This is still a restricted NAM audio chain: stock amp/cab/MOD/reverb, Bluetooth
audio and the looper are not restored. Unsupported controls stay disabled.

83 Flutter tests and analyze pass (WAV decode/resampler parity against shared
Python fixtures, IR list/rename/delete/upload harness, Bluetooth-name
validation, IR tab and dialog flows). ARM build, RAM placement, flash-busy
checks, 44.1/48 kHz pitch and drum-rate host tests pass. The manager firmware
and the previous app were installed. Physical USB verified flags 15, tuner
on/off/no-signal, forty preset reads, no crash dump and unchanged
preset/settings/NAM flash CRCs. The tablet's USB connection disappeared
immediately after 0.3.0 installation; the new legacy editor/BLE controls,
physical IR transfer and Bluetooth naming therefore still require physical UI
validation. 0.3.1+6 corrected bank labels to the pedal's BANK 0–9 / presets
0A–9D; that APK was not installed because the tablet remained disconnected.

Remaining parity work includes the complete NAM audio chain, IR auditioning,
Bluetooth naming/audio read-back, model labels and all advanced settings,
physical stock firmware operation, musical audio/deadline checks and real
TONE3000 OAuth/download.
