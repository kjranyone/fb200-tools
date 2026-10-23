# Second NAM and the FX block (nam-manager)

Status: the second NAM is implemented and measured on the pedal
([hardware log](NAM_HARDWARE_2026-10-18.md)); the FX block is being built,
starting with the time-domain pitch shifter.

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

The app does not hard-code modes. NAM RPC (capability bit 14, planned):

- op 14 *describe* `[mode]` → name, flags (heavy), and for each parameter
  its name, minimum, maximum, default and unit. The app builds the controls
  from it, so a new mode needs no app update.
- op 15 *set* `[param, value u16]` → writes the edit buffer word and applies
  it at once (live control without resending the 256-byte preset).

## Modes

| Mode | Kind | State |
| --- | --- | --- |
| Pitch (time-domain, correlation splice) | light | offline prototype (`out/pitch-proto-*`), then C |
| Polyphonic pitch (frequency domain) | heavy | later, if there is a use for it |
