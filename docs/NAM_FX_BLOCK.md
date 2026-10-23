# Second NAM and the FX block (nam-manager)

Status: the second NAM and the FX block's first mode, a time-domain pitch
shifter, are implemented and measured on the pedal
([hardware log](NAM_HARDWARE_2026-10-18.md)); the app builds the FX controls
from the descriptors (`mobile/lib/pedal/fx_panel.dart`).

## Resources

The i.MX RT1052 has 512 kB of FlexRAM: 128 kB ITCM (code and the reverb
state), 352 kB DTCM, 32 kB OCRAM. Everything new has to fit in what the
NAM profiles freed:

| Freed | How |
| --- | --- |
| 19.6 kB DTCM | NAM builds copy only the cab and drum tables of the stock data (`STOCK_LEAN`): no stock amp or tone stack runs there |
| 12 kB DTCM | console log ring 16 → 4 kB |
| 19.2 kB DTCM | longest delay 500 → 300 ms (presets keep their time and play clamped) |
| 2.7 kB ITCM | a DSP fault reset runs in the main loop instead of the audio path, so module inits run from flash |

The NAM kernel itself went from 263,660 to 130,771 cycles per 32-frame block
(budget 400,000), which is what leaves room for two NAMs.

## The arena: one heavy user at a time

A union above the delay line (`s_arena`, `.dtcm_hi`, 86,856 bytes) holds
either the second NAM's state or a heavy FX mode's buffers. `s_arena_owner`
says which. A request for the arena while the other owner holds it is
refused (`engine_nam2_select` returns -2), so a second NAM and a heavy mode
can never run together: the exclusivity is the memory itself, not a rule
the app has to remember. Light modes use their own pool (DTCM below
`dtcm_lo`'s limit, about 11 kB) and always coexist with both NAMs.

A heavy mode must also cost no more CPU than a NAM (≈131k cycles per block),
so either occupant stays inside the measured 75 % peak.

## Preset words (the unused tail)

All words are little-endian u16, after the EQ record and the first NAM's
marker and slot (`0xDE`, `0xE0`). Stock presets and the official app leave
the tail at 0, which reads as "off".

| Offset | Field |
| --- | --- |
| `0xE2` | `"N2"` (0x324E): the second NAM is configured |
| `0xE4` | its slot, 0..64 (0: none) |
| `0xE6` | input gain, 0..100 (50 = 0 dB, ±18 dB) |
| `0xE8` | output level, 0..100 (50 = 0 dB, ±18 dB) |
| `0xEA` | `"FX"` (0x5846): the FX block is configured |
| `0xEC` | mode (0: off) |
| `0xEE` | flags: bit 0 on, bit 1 position (0 before the NAMs, 1 after the cabinet) |
| `0xF0`..`0xFE` | eight mode parameters |

If a preset asks for a second NAM and a heavy mode, the NAM wins and the
block falls back to off.

## Modes are described by the pedal

The app does not hard-code modes. NAM RPC, capability bit 14:

- op 14 *describe* `[mode 1..]` → `[mode][heavy][name 16][count]`, then per
  parameter `{name 12, min, max, def i16 LE, unit u8, labels 24}` (43
  bytes; `src/dsp/fx.h`). Status 1 past the last mode, so the app finds the
  modes by asking 1, 2, … The app builds the controls from it, so a new
  mode needs no app update.
- op 15 *set* `[offset 0xE2..0xFE even][value u16]` → writes that tail
  word of the edit buffer and applies it at once (live control without
  resending the 256-byte preset). Nothing is saved.

Units: none, percent, DB18 (50 = 0 dB, ±18 dB), ms, cents (value − 2400),
choice (labels `"A|B"` for min..max).

## Modes

| Mode | Kind | State |
| --- | --- | --- |
| Pitch (time-domain, correlation splice) | light | firmware, measured on the pedal |
| Polyphonic pitch (frequency domain) | heavy | later, if there is a use for it |

## Pitch (mode 1)

| Parameter | Range | Default |
| --- | --- | --- |
| SHIFT | 0..4800 cents (2400 = none, ±2 octaves) | 3600 (+12) |
| MIX | 0..100 % | 50 |
| LEVEL | DB18 (wet) | 50 |
| GLIDE | 0..1000 ms (one pole) | 0 |
| RANGE | Guitar (14 ms longest period) / Bass (26 ms) | Bass |

The H910/H949 idea in software: the output reads an int16 history (4096
samples, `.dtcm_lo`) at the new rate, and when the read point runs into the
write point (up) or too far behind (down) it jumps by whole periods, with a
4 ms crossfade. The jump is the correlation peak of a 6 ms window: a coarse
pass on every 4th sample and every 8th lag, then ±4 lags at full rate and a
parabola for the fraction. Among peaks within 0.05 of the best it takes the
one that keeps the delay short, so chords splice where the waveform repeats
and the latency stays low. Down shifts also try optional splices every
~10 ms and take them only on a clear peak (score ≥ 0.92).

Latency (offline, `out/pitch-proto-20261023/latency-c.json`): 7 ms mean up,
15 ms down in the guitar range; 8.5–9 ms up, 18 ms down for bass.

CPU (`fxstat` on the pedal, cycles of a 400,000-cycle block): at most one
search per block; a block that searches costs up to 33k (guitar) / 58k
(bass). Worst engine peaks with both NAMs: 82 % (guitar), 87 % (bass); no
skips or DMA errors.
