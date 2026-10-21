# Android tone controls — 0.10.6+20

## Changes

- NAM rotary controls preview the sound during dragging, at most once per
  80 ms. One serialized writer keeps only the latest queued value; it does
  not enqueue every pointer event. Releasing the control flushes the final
  value and reads it back. Preview never saves a preset.
- Other operations are disabled during an active NAM drag. Preset/model
  changes cancel pending previews. A disconnect retains the latest intended
  edit through the shared recovery draft; queued writes cannot cross to the
  replacement connection. Gesture cancellation restores the original value.
- A NAM bypass/OFF state disables the tone controls. The model card states
  that changes are live. Help describes pre-model drive, post-model EQ,
  the MID centre frequency and post-model output level.
- Algorithms/cabinets are named choices. Stock amp MID FREQ uses its actual
  five frequencies. MOD parameter names/units change with the algorithm:
  sweep/step width, feedback, pitch depth, chorus depth, tone or bandwidth.
- Controls the DSP does not read are excluded: CAB p1..p4, REV p1, MOD p5
  and the unused p4 for non-chorus types. The single implemented bass delay
  has no misleading algorithm selector. Hidden bytes remain in wire writes
  and presets, preserving existing records.
- Read-only IR metadata is loaded with the controller and after recovery.
  CAB choices show the real IR names, with type 11..19 mapping to IR1..IR9.
  Empty slots are identified and cannot be chosen as playable IRs. The IR
  tab shows the current CAB assignment and its ON/OFF state. IR metadata
  notifications update the displayed names without a full reconnect.

The fixed main editor layout is preserved. Named choices, including long IR
names, and every module were tested on phone portrait, short landscape and
large tablet layouts.

## Grounding

Names follow the manufacturer's [FB200 manual, pp.18–21](https://flammainnovation.com/file/pdf?fileName=FB200_Manual_EN.pdf&url=group1%2FM00%2F00%2F0F%2FwKgA0Ghcs82AOmZKABRLE2iOyS0799.pdf).
Actual field behavior follows [params.py](../src/fb200/params.py),
[mod.c](../firmware/audio/src/dsp/mod.c),
[reverb.h](../firmware/audio/src/dsp/reverb.h),
[engine.c](../firmware/audio/src/audio/engine.c), and
[nam_tone.c](../firmware/audio/src/dsp/nam_tone.c).
NAM's MID FREQ is the NAM EQ's 200–2000 Hz logarithmic control; it is
independent of the stock amp's five-step frequency selector.

## Physical NAM verification — 2026-10-22

The user confirmed instrument audio is connected to the pedal INPUT.
The running NAM firmware app-slot CRC matched the installed 2026-10-21 image
(`e5196354`, 215940 bytes); NAM model 1 was active and the amp stage enabled.
No firmware change was required.

With the analog DAC output temporarily muted, an internal sine source was
fed into the chain **before NAM** and the processed signal captured through
the FB200 WASAPI USB input, 48 kHz stereo. Other effects were temporarily
bypassed to isolate the NAM stage. Only the live edit buffer was changed;
all 256 original bytes were restored and verified, the generator stopped,
and the original output mute state restored. No audio recordings were saved.

| Control | Measurement | Observed change |
| --- | --- | --- |
| GAIN | 0→100, 440 Hz, current NAM capture | +5.82 dB fundamental (nonlinear model) |
| BASS | 0→100, 80 Hz | +17.07 dB |
| MID | 0→100, 800 Hz, centre ≈796 Hz | +23.91 dB |
| TREBLE | 0→100, 6 kHz | +22.93 dB |
| MID FREQ | 200→2000 Hz, +12 dB MID, 200 Hz signal | −11.74 dB |
| VOLUME | 25→50 | +6.02 dB; value 0 reduces capture to the noise floor |

All control values were read back before each measurement. No capture
overflows occurred. This measures the live DSP/USB path, not an external
analog-output loopback or a listening comparison of the user's instrument.
Android/BLE was also checked separately: dragging BASS changed the live
preset word from 49 to 80, then the complete original buffer was restored.

Artifacts: `out/controls-20261022/nam-measurements.json`,
`nam-response-summary.json`, `android-knob-write.json`, and the measurement
script and original live buffer in that directory.

## Windows verification transport correction

During the measurements, the Python Windows HID adapter was found to drop
one data byte from each full report: it prefixed report ID 0 while truncating
the actual report from 64 bytes to 63. Long frames could not be decoded, even
though small queries worked. The adapter now sends the ID plus all 64 bytes.
A regression test reconstructs a full 257-byte edit payload from the native
reports. Real live-buffer writes/readback succeeded after the correction.
This is a Windows host-tool issue, separate from Android BLE.

## Automated validation

- Flutter analysis: no issues; 197 Flutter tests passed.
- 35 Python transport/device tests passed.
- Coverage includes preview throttling/cancel, queued-value coalescing,
  final readback, no flash saves, physical-preset-change cancellation,
  loss during preview with no replay on the new connection, named choices,
  IR mapping/notifications, hidden fields preserved, and layout checks.
- Logs: `out/controls-tests.log`, `controls-analyze.log`, `controls-build.log`.


## Final Android deployment

Installed version 0.10.6 / code 20 and copied the APK to
`/sdcard/Download/fb200-studio-0.10.6-20-debug.apk`.
SHA-256 of both copies:
`b358c2ebe7cf99c6240900a4aa450c0ab362047d46e5868b2d35c6805df0c1b3`.

On the native Android controller, a DOWN/MOVE gesture was held without UP.
BASS changed **49→79 before release**, and an 80 Hz signal captured over USB
increased **4.31 dB while still held**. Releasing the pointer retained 79;
readback verified the final value. The original 256-byte live buffer was then
restored and verified, the generator stopped and analog mute released.
The app was explicitly resynchronized after this restoration.

Subsequent live reads differed from that test snapshot in GAIN, TREBLE and
NAM slot. Those later live changes were preserved, rather than rolling the
pedal back to the earlier snapshot. The recorded comparison is in
`out/controls-20261022/final-live-diff.json`.

The real IR list returned nine stored names. CAB displayed
`IR7 · 07_Ampeg_SVT-810E_by_Shift_Line`; the IR tab marked this as the current
CAB assignment with its OFF state. No IR, NAM model or preset was saved during
the checks. User-data CRC `c359d9c4` and NAM-store CRC `4a2d037c` remained
unchanged. No Android fatal exception or transport timeout was logged;
firmware reported `dma_errs=0`, `resets=0` and no crash dump.

[Live NAM editor](design/fb200-live-nam-v1.png) ·
[Named cabinet/IR](design/fb200-cab-ir-names-v1.png) ·
[IR assignments](design/fb200-ir-assignments-v1.png) ·
[Named modulation controls](design/fb200-mod-parameters-v1.png)

Machine-readable evidence: `out/controls-20261022/verification.json`,
`android-live-preview.json`, `device-before.json`, `device-after.json`, and
`android-logcat.txt`.
