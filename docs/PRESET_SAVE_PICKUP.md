# Preset save and knob pickup — 2026-10-22

Knob LED blinking indicates **pickup pending**, not an unsaved preset. An
enabled module's knob blinks until its physical position reaches the live
parameter value; a caught knob stays lit. Saving must not force pickup or
silently adopt the physical position, since that could jump the sound.

The Android save path sends a full record using `0x97`. Previously the
firmware wrote the record and unconditionally called `ui_select`, even when
the current live record was being saved to its own slot. That recalled the
same preset and reset every knob's pickup, including the NAM model selector.
Thus a knob that had already been caught started blinking again after save.

The firmware now skips recall when a successful write saves the identical
live record to its current slot. Existing caught/pending states are retained;
the acknowledgement, selected-index reply and flash readback remain available.
Different records or destinations still follow the normal recall path. A
failed save returns failure without changing the live edit or selected slot.
No Android update is required; the installed app remains 0.10.6+20.

## Validation

- The new regression failed on the old implementation for both stock and
  NAM builds: a previously caught GAIN LED went dark in the blink-off phase.
- 85 protocol, NAM panel and NAM RPC tests passed after the fix. They cover
  steady LED state across save, continued physical adjustment, pending BASS
  pickup retained, pickup rearmed for a changed record, a caught NAM selector
  retained without another model load, and failed writes preserving RAM and
  flash.
- The `nam-manager` ARM build and `hot_path.py --nam-runtime` passed.
- The app-only image was installed on the physical FB200. The device's app
  CRC matched `bcd1632b` for 216004 bytes. SHA-256:
  `5671af634bc0483298c82f4f364a0629b22d8fe181db469cf67e086b6284ec66`.
- Recovery, stock data, user-data and NAM-store CRCs were unchanged across
  deployment. All 40 saved preset records and settings matched. The live
  RAM edit was captured immediately before flashing, restored after reboot
  and read back byte for byte; no preset was saved during deployment.
- Firmware reported `dma_errs=0`, `resets=0` and no crash dump after restart.

LED behavior was verified with the real protocol/UI code in the host
harness, using simulated knob inputs. Physical installation and data
preservation were verified over USB; external visual observation of the
knob LEDs was not automated.

Local deployment evidence: `out/save-led-20261022/` contains the packed app,
metadata, install log, before/after snapshots and deployment helper. These
artifacts contain device state and remain outside version control.
