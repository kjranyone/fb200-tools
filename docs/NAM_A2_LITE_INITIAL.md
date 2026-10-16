# NAM A2-Lite: initial host-first milestone, 2026-10-17

Historical milestone. See [NAM_A2_LITE.md](NAM_A2_LITE.md) for the subsequent
runtime model transfer/storage/selection implementation.

This branch starts a port; it is **not a playable NAM firmware release**.
Nothing was written to a pedal. The default firmware remains the 44.1 kHz
stock-compatible configuration. `PROFILE=nam-probe` is a compile-only experiment:
48 kHz clocks and reserved RAM, with **no NAM inference in `engine_task`**.
Do not use this experimental image as a stock-feature-compatible 48 kHz release.

## What is implemented

- `audio_config.h` selects 44.1 or 48 kHz. SAI PLL4, MCLK, TinyUSB's maximum
  sample rate, UAC2 clock controls (already using `AUDIO_FS`), DSP initialization,
  and delay capacity share that setting. Unsupported rates fail compilation.
  The codec remains a 256*Fs clock slave with the existing 16-bit I2S format.
  No 24-bit format or runtime rate switching is introduced.
- `dsp/nam_a2.c` is a scalar float32, caller-owned A2-Lite inference baseline:
  23 layers, 3 channels, the fixed 6/15 tap kernels and dilations, LeakyReLU
  0.01, condition mixins, residual 1x1 layers, summed head and k=16 output head.
  The trailing weight supplies head scale. No heap, JSON, C++ runtime, libm,
  flash access, or whole-history rewind in the processing routine.
- `tools/nam_fixed.py` validates a user-supplied `.nam`, selects exactly one
  3-channel model from a packed SlimmableContainer, and emits fixed C weights.
  Bare models and inherited packed rates must explicitly specify 48 kHz.
  Wrong shapes/rates, active unsupported features, unknown architecture keys,
  wrong counts and non-finite/out-of-float32 weights are rejected before writing.
- `nam_a2_init` copies weights into the player's RAM; tests link the generated
  C asset and run inference. These are **host prototype integrations**, not a
  firmware model slot, preset or console command. No trained model is included.
- The `nam-probe` app replaces the long-IR tail allocation with a complete NAM
  working-set reservation. The existing physical linker limits and 8 KiB stack
  reserve remain in force. An overflow fails the build.

The kernel follows the architecture and serialization documented by
[NeuralAmpModelerCore, pinned at 0b3d3c97](https://github.com/sdatkinson/NeuralAmpModelerCore/blob/0b3d3c97b0859a3a8c92a8628c4dd89a25eb5842/NAM/wavenet/a2_fast.cpp).
It uses compact exact-length per-sample rings instead of Core's larger
block-oriented power-of-two rings. This prioritizes fitting RAM and verifying
correctness; it is not a claim of sufficient Cortex-M7 speed. Core code is not
vendored. The attribution and MIT notice are in [NAM_LICENSE.md](NAM_LICENSE.md).
The [Pico demo](https://github.com/oyama/pico-neural-amp-modeler-demo/tree/6859450be19577002cfd24b830accb6313aca565)
was reviewed for comparison; its dual-core implementation is not used.

## RAM and timing budget

The existing firmware's linker/memory map was reviewed against
[FIRMWARE_BRINGUP.md](FIRMWARE_BRINGUP.md#memory-map-audio-app). The device has
128 KiB ITCM, 352 KiB DTCM and 32 KiB OCRAM under the existing FlexRAM split.
There is no extra OCRAM at 0x20208000. No FlexRAM remap is attempted.

| Fixed player's storage | Bytes |
| --- | ---: |
| 1,871 float32 weights, in RAM | 7,484 |
| Layer and head histories (19,110 float32 values) | 76,440 |
| 24 ring positions + ready flag | 52 |
| **Total `sizeof(nam_a2_t)` on host and ARM** | **83,976** |

The receptive field is 6,347 samples including the k=16 head, about 132.23 ms
at 48 kHz. This is causal history, not added output latency. There is no
additional block delay in this baseline. At 600 MHz, a 32-frame 48 kHz block
has 400,000 cycles (12,500/sample) for **all** processing. CPU usage is unmeasured.
The original roadmap CPU estimate is not a measurement of this implementation.

`PROFILE=nam-probe` selects 512-tap IR capacity (no ~96 KiB long-IR tail),
500 ms delay at 48 kHz (48,008 bytes), and an 83,976-byte volatile NAM reservation
in `.dtcm_lo`. The probe reservation is zeroed at boot by the existing startup
region clearing. Only its endpoints are touched in `engine_init`; it is never
passed to inference. Defaults remain 4096 taps and 1000 ms at 44.1 kHz.
Separate build directories keep the default and experimental objects apart.
Do not override `BUILD` to share a directory between profiles.

Observed `nam-probe` link with GNU Arm 10.3.1 (these are build results, not
hardware measurements):

| Region | End of allocation | Remaining to existing limit |
| --- | --- | ---: |
| Low DTCM, including NAM and looper audio state | `0x20015044` | 14,780 bytes to crash reserve |
| High DTCM, including delay | `0x2004C2CC` | 40,244 bytes to 8 KiB stack reserve |
| ITCM, including reverb state | `0x0001FCD8` | 808 bytes |
| OCRAM | `0x2020345C` | 19,364 bytes |

The small ITCM margin is a further reason to keep inference disconnected until
code placement has been measured. Fitting the state does not mean the complete
future player fits in its final section layout.

## Reproduce without hardware

Use the toolchain/dependencies in [INSTALL.md](INSTALL.md). On Linux/WSL:

```sh
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
make -C firmware/audio deps
make -C firmware/audio -j4 build layout
make -C firmware/audio PROFILE=nam-probe -j4 build layout
.venv/bin/pytest -q tests/test_nam_a2.py tests/test_nam_profile.py
.venv/bin/pytest -q
.venv/bin/ruff check .
```

Default/recovery behavior, USB descriptors, image layout, real RAM sections,
stack bounds, DSP behavior and parser/transport tests remain part of the suite.
Hardware, vendor-stock emulation and long fuzz tests retain their existing
opt-in requirements. This work did not use a vendor firmware image.

The existing flash-safety checker misidentified const data in executable output
sections as Thumb callbacks under GNU Arm 10.3. This also reproduced on untouched
upstream. It now uses ELF `STT_FUNC` symbols instead of `nm` section letters.
Regression coverage verifies const tables are excluded while genuine SAI
callbacks and cold-code negative controls remain checked.

Convert a model you have rights to use (keep outputs outside version control):

```sh
python3 tools/nam_fixed.py /path/to/your-capture.nam -o /tmp/nam_fixed.c
```

The emitted symbols are `nam_fixed_weights` and `nam_fixed_rate`. Link this C
asset with `dsp/nam_a2.c` in a host harness and call:

```c
static nam_a2_t player;  /* large: never put this on the stack */
extern const float nam_fixed_weights[NAM_A2_WEIGHTS];
extern const unsigned nam_fixed_rate;
/* Check both return values. Init is outside the processing callback. */
nam_a2_init(&player, nam_fixed_weights, NAM_A2_WEIGHTS, nam_fixed_rate, 48000);
nam_a2_process(&player, mono_block, frames); /* frames <= 32, in place */
```

Only the fixed profile is represented by these weights: the raw C init API
cannot identify architecture from an untyped 1,871-value array. Run the validator
first. Model license/attribution and input/output calibration are separate from
the engine license. Generated C is a host asset; placing it in firmware without
RAM relocation could consume scarce ITCM or introduce forbidden flash reads.

### Optional official Core comparison

This oracle compares identical zero-state starts, rather than Core's usual
silence prewarm. It needs a host C++20 compiler and Eigen headers. No dependency
is fetched automatically by pytest. For Debian/Ubuntu, `libeigen3-dev` supplies
`/usr/include/eigen3`:

```sh
git clone https://github.com/sdatkinson/NeuralAmpModelerCore.git /tmp/nam-core
git -C /tmp/nam-core checkout 0b3d3c97b0859a3a8c92a8628c4dd89a25eb5842
g++ -std=c++20 -O2 -ffp-contract=off -ffunction-sections -fdata-sections \
  -DNAM_ENABLE_A2_FAST -I /tmp/nam-core -I /tmp/nam-core/NAM \
  -I /tmp/nam-core/Dependencies/nlohmann -I /usr/include/eigen3 \
  tools/nam_core_reference.cpp /tmp/nam-core/NAM/wavenet/a2_fast.cpp \
  /tmp/nam-core/NAM/dsp.cpp -Wl,--gc-sections -o /tmp/nam-core-reference
FB200_NAM_CORE_REFERENCE=/tmp/nam-core-reference .venv/bin/pytest -q tests/test_nam_a2.py
```

Tests cover a 7,001-sample signal beyond the receptive field, every kernel and
dilation, odd block splits, single-sample processing, reset/repeat, an analytic
1,210-sample oldest-tap delay, invalid arguments, non-finite inference recovery,
model rejection and exact generated-float roundtripping. Numerical tolerance is
2e-7 absolute versus an independent whole-signal double-precision reference and
the optional official float32 Core oracle. No audio quality claim follows from
synthetic numerical equivalence.

Validation on 2026-10-17 also used the Pico demo's `example.nam` locally:
16,001 random/zero samples produced bit-identical output to the pinned official
Core (maximum absolute error 0.0). That capture and generated weights are not
included in this repository. A manual ASan/UBSan run processed 12,800 synthetic
samples through ring wraps and rejected oversized blocks without diagnostics.

Final validation (WSL Ubuntu, Python 3.10.12, GNU Arm 10.3.1): full pytest suite
with the optional Core oracle enabled, **409 passed / 15 skipped** (120.53 s,
four workers); focused NAM/clock/RAM suite **23 passed**; image/safety suite
**18 passed / 2 skipped**. Ruff and `git diff --check` passed. Default app,
recovery and `nam-probe` were cross-built. Missing optional emulator/vendor
inputs caused skips; hardware/stock/fuzz markers retained their default exclusions.
No pedal connection, firmware flashing or hardware benchmark was performed.

## Remaining gates before firmware inference

1. Measure/verify PLL, codec MCLK/BCLK/LRCLK and USB rate controls on hardware
   in a separately authorized session. A compile proves neither clock stability
   nor USB streaming quality. Keep recovery unchanged.
2. Resolve 44.1 kHz dependencies: stock amp/tone/cab coefficients and IR uploads,
   drum assets/tempo, tuner timing, looper rates/storage, Bluetooth input. The
   probe still contains the existing chain; these features are **not validated
   at 48 kHz**. Use an explicit restricted NAM preset/profile in the next step.
3. Integrate one licensed, fixed real capture: RAM-resident model image, state
   initialization/prewarm, input/output gain and DC behavior, amp replacement
   (avoid a second tone stack), cab policy, preset bypass, reset and fades.
4. Optimize and measure Cortex-M7 worst-case cycles including USB/interrupts
   and ring wraps. Host timings are not MCU timings. No guarantee that this
   scalar baseline meets a 400,000-cycle full-chain deadline.
5. Recheck ITCM, stack high-water, crash recovery, flash-busy audio safety and
   sustained underrun counts after connecting inference. The reservation proves
   a working-set fit; future code/weights placement and transient load buffers
   must also fit. No JSON or model allocation in the audio loop.

Runtime `.nam`/`.namb` loading, downloadable model slots, A2-Full and multiple
instances are outside this first change.
