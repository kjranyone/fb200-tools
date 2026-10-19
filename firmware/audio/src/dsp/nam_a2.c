/* Scalar, bounded-memory A2-Lite implementation for host-first research.
 * Architecture/weight layout follow Steven Atkinson's NeuralAmpModelerCore
 * NAM/wavenet/a2_fast.cpp (MIT). Attribution: docs/NAM_A2_LITE.md.
 * The stream weight order is repacked once at init into tap-major layout so
 * the per-tap inner loop reads sequential weights (the Cortex-M7 scalar
 * baseline measured 719k cycles/block; see docs/NAM_HARDWARE_2026-10-18.md).
 * The repack keeps every accumulator's addend sequence identical to the
 * stream-order reference: bit-identical output (tests/nam_a2_golden.f32). */
#include "nam_a2.h"
#include <string.h>

static const unsigned kernels[NAM_A2_LAYERS] = {
    6,6,6,6,6,6,6,6,6,6,6,6,6,6,15,15,6,6,6,6,6,6,6
};
static const unsigned dilations[NAM_A2_LAYERS] = {
    1,3,7,17,41,101,239,1,3,7,17,41,101,239,1,13,1,3,7,17,41,101,239
};

/* Comparisons reject NaN/Inf without libc, including in the freestanding build. */
static int finite_float(float x)
{
    return x <= 3.402823466e38f && x >= -3.402823466e38f;
}

void nam_a2_reset(nam_a2_t *s)
{
    if (!s) return;
    memset(s->history, 0, sizeof s->history);
    memset(s->position, 0, sizeof s->position);
}

/* Repack the validated stream weights in place, history as scratch (76 kB
 * >= 7.5 kB). Per layer: conv [out][in][tap] -> [tap][out*3+in]; head
 * [channel][tap] -> [tap][channel]. bias/mix/linear keep their positions. */
static void repack(nam_a2_t *s)
{
    float *scratch = s->history;
    memcpy(scratch, s->weights, sizeof s->weights);
    unsigned src = 3, dst = 3;   /* past the input-expansion weights */
    for (unsigned layer = 0; layer < NAM_A2_LAYERS; layer++) {
        unsigned k = kernels[layer];
        for (unsigned tap = 0; tap < k; tap++)
            for (unsigned idx = 0; idx < 9; idx++)
                s->weights[dst + tap * 9 + idx] = scratch[src + idx * k + tap];
        src += 9 * k + 18;       /* conv + bias + mix + linear */
        dst += 9 * k + 18;
    }
    for (unsigned tap = 0; tap < 16; tap++)
        for (unsigned c = 0; c < 3; c++)
            s->weights[dst + tap * 3 + c] = scratch[src + c * 16 + tap];
}

int nam_a2_init(nam_a2_t *s, const float *weights, size_t count,
                unsigned model_rate, unsigned engine_rate)
{
    if (!s) return -1;
    s->ready = 0;
    if (!weights || count != NAM_A2_WEIGHTS || model_rate != NAM_A2_RATE ||
        engine_rate != NAM_A2_RATE) return -1;
    for (unsigned i = 0; i < NAM_A2_WEIGHTS; i++)
        if (!finite_float(weights[i])) return -1;
    memcpy(s->weights, weights, sizeof s->weights);
    repack(s);
    nam_a2_reset(s);
    s->ready = 1;
    return 0;
}

/* Fully unrollable tap loop kept as documentation of the measured dead end:
 * a hand-unrolled K=6 macro measured SLOWER on the M7 (339k vs 321k
 * cycles/block) than the runtime-K loop below - the scheduler does better
 * with its own loop. See docs/NAM_HARDWARE_2026-10-18.md. */

static float sample(nam_a2_t *s, float input)
{
    const float *w = s->weights;
    float x[3] = {w[0] * input, w[1] * input, w[2] * input};
    float head[3] = {0};
    unsigned offset = 0;
    w += 3;
    for (unsigned layer = 0; layer < NAM_A2_LAYERS; layer++) {
        unsigned k = kernels[layer], d = dilations[layer], len = (k-1)*d+1;
        unsigned pos = s->position[layer];
        float *hist = s->history + offset;
        memcpy(hist + pos*3, x, sizeof x);
        const float *bias = w + 9*k, *mix = bias + 3, *linear = mix + 3;
        float z0 = bias[0], z1 = bias[1], z2 = bias[2];
        /* Tap-major (oldest first), weights repacked [tap][out*3+in]: the
         * nine products of a tap read sequential weights, three history
         * values each. Each accumulator sees taps ascending, inputs
         * ascending - the reference addend order, bit-identical. */
        const float *wt = w;
        for (unsigned tap = 0; tap < k; tap++, wt += 9) {
            unsigned back = (k-1-tap)*d;
            unsigned at = pos >= back ? pos-back : pos+len-back;
            const float *h = hist + at*3;
            float h0 = h[0], h1 = h[1], h2 = h[2];
            z0 += wt[0]*h0; z0 += wt[1]*h1; z0 += wt[2]*h2;
            z1 += wt[3]*h0; z1 += wt[4]*h1; z1 += wt[5]*h2;
            z2 += wt[6]*h0; z2 += wt[7]*h1; z2 += wt[8]*h2;
        }
        float z[3] = {z0, z1, z2};
        for (unsigned c = 0; c < 3; c++) {
            z[c] += mix[c] * input;
            if (z[c] < 0) z[c] *= 0.01f;
            head[c] += z[c];
        }
        for (unsigned out = 0; out < 3; out++) {
            float residual = linear[9+out];
            for (unsigned in = 0; in < 3; in++) residual += linear[out*3+in] * z[in];
            x[out] += residual;
        }
        s->position[layer] = pos+1 == len ? 0 : pos+1;
        offset += len*3;
        w = linear + 12;
    }
    unsigned pos = s->position[NAM_A2_LAYERS];
    float *hist = s->history + offset;
    memcpy(hist + pos*3, head, sizeof head);
    /* head weights repacked [tap][channel], sequential per tap */
    float y = w[48];
    for (unsigned tap = 0; tap < 16; tap++) {
        unsigned at = (pos+1+tap) & 15u;
        const float *h = hist + at*3;
        y += w[tap*3+0] * h[0];
        y += w[tap*3+1] * h[1];
        y += w[tap*3+2] * h[2];
    }
    s->position[NAM_A2_LAYERS] = (pos+1) & 15u;
    return y * w[49]; /* trailing stream value overrides config.head_scale */
}

int nam_a2_process(nam_a2_t *s, float *audio, unsigned n)
{
    if (!s || !s->ready || n > DSP_BLOCK || (!audio && n)) return -1;
    for (unsigned i = 0; i < n; i++) if (!finite_float(audio[i])) return -1;
    for (unsigned i = 0; i < n; i++) {
        audio[i] = sample(s, audio[i]);
        if (!finite_float(audio[i])) {
            nam_a2_reset(s);
            memset(audio, 0, n * sizeof *audio);
            return -2;
        }
    }
    return 0;
}
