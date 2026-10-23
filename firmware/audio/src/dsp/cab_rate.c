/* Copyright (C) 2026 Andrii Shylenko
 *
 * This software is released under the MIT License.
 * See the LICENSE file in the project root for full license information.
 */

/* 44.1 -> 48 kHz IR resampling (declared in cab.h), standalone so host
 * tests compile it without the convolver or CMSIS headers. */
#include <stdint.h>

/* Stock and user IRs are 44.1 kHz designs. A 48 kHz build plays them
 * resampled, the same linear interpolation the drums use for their output
 * rate. In place, DESCENDING: output i reads inputs idx = floor(i*44100/48000)
 * and idx+1, both <= i, so positions below i are still original when i is
 * written (ascending would read already-resampled taps). `taps` output
 * samples cover the source's first taps * 44100/48000: the resampled tail
 * lands past the buffer and is cut, like the wav.py conversion truncating a
 * longer source. */
void cab_ir_441_to_48(float *ir, unsigned taps)
{
    for (unsigned i = taps; i-- > 0;) {
        unsigned num = i * 44100u;
        unsigned idx = num / 48000u;
        if (idx >= taps) { ir[i] = 0.0f; continue; }
        float frac = (float)(num % 48000u) * (1.0f / 48000.0f);
        float a = ir[idx];
        float b = idx + 1u < taps ? ir[idx + 1u] : 0.0f;
        ir[i] = a + (b - a) * frac;
    }
}
