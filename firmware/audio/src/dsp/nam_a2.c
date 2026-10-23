/* Scalar, bounded-memory A2-Lite implementation for host-first research.
 * Architecture/weight layout follow Steven Atkinson's NeuralAmpModelerCore
 * NAM/wavenet/a2_fast.cpp (MIT). Attribution: docs/NAM_A2_LITE.md.
 * The stream weight order is repacked once at init into tap-major layout so
 * the per-tap inner loop reads sequential weights (the Cortex-M7 scalar
 * baseline measured 719k cycles/block; see docs/NAM_HARDWARE_2026-10-18.md),
 * and frames run layer-major in chunks (chunk() below). Both keep every
 * accumulator's addend sequence identical to the stream-order reference:
 * bit-identical output (tests/nam_a2_golden.f32). */
#include "cold.h"
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
static COLD void repack(nam_a2_t *s)
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

/* Runs from flash: only model selection (engine_nam_select, itself cold)
 * calls it, and ITCM has no room to spare. */
COLD int nam_a2_init(nam_a2_t *s, const float *weights, size_t count,
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

/* A hand-unrolled K=6 tap macro measured SLOWER on the M7 (339k vs 321k
 * cycles/block) than a runtime-K loop; see docs/NAM_HARDWARE_2026-10-18.md. */

/* Layer-major chunks: the convolutions are causal, so each layer can run over
 * up to NAM_A2_SUB frames before the next layer starts. Every accumulator
 * still adds bias, then taps ascending, inputs ascending: bit-identical to
 * the per-sample kernel. Four frames share each tap's nine weights and keep
 * twelve independent accumulators in flight (nam_a2_conv.h; assembly on the
 * Cortex-M7, C elsewhere). */
#define SUB NAM_A2_SUB

#include "nam_a2_conv.h"
#define wrap nam_a2_wrap
#ifdef NAM_A2_ASM
#define conv4 nam_a2_conv4_asm
#define post nam_a2_post_asm
#define head4 nam_a2_head4_asm
#else
#define conv4 nam_a2_conv4_c
#define post nam_a2_post_c
#define head4 nam_a2_head4_c
#endif

/* m (1..SUB) frames in place. A partial group of four also computes the
 * frames after m from stale ring data; those results are never used. */
static void chunk(nam_a2_t *s, float *audio, unsigned m)
{
    const float *w = s->weights;
    float x[SUB][3], head[SUB][3], z[SUB][3];
    _Static_assert(SUB % 4 == 0, "conv4 groups");
#pragma GCC unroll 1
    for (unsigned j = 0; j < m; j++) {
        for (unsigned c = 0; c < 3; c++) { x[j][c] = w[c] * audio[j]; head[j][c] = 0; }
    }
    unsigned offset = 0;
    w += 3;
    for (unsigned layer = 0; layer < NAM_A2_LAYERS; layer++) {
        unsigned k = kernels[layer], d = dilations[layer], R = (k-1)*d + SUB;
        unsigned pos = s->position[layer];
        float *hist = s->history + offset;
        nam_a2_ring_write(hist, R, pos, (const float (*)[3])x, m);
        const float *bias = w + 9*k, *mixlin = bias + 3;
        for (unsigned j = 0; j < m; j += 4) conv4(hist, R, wrap(pos+j, R), k, d, w, bias, z + j);
        post(z, x, head, audio, mixlin, m);
        s->position[layer] = (uint16_t)wrap(pos+m, R);
        offset += (R + NAM_A2_MIRROR)*3;
        w = mixlin + 15;
    }
    /* head: K=16 over the summed layer outputs, weights [tap][channel] */
    const unsigned R = 16 + SUB - 1;
    unsigned pos = s->position[NAM_A2_LAYERS];
    float *hist = s->history + offset;
    nam_a2_ring_write(hist, R, pos, (const float (*)[3])head, m);
    for (unsigned j = 0; j < m; j += 4) {
        float y[4];
        head4(hist, R, wrap(pos+j, R), w, y);
        memcpy(audio + j, y, (m - j < 4 ? m - j : 4) * sizeof *y);
    }
    s->position[NAM_A2_LAYERS] = (uint16_t)wrap(pos+m, R);
}

int nam_a2_process(nam_a2_t *s, float *audio, unsigned n)
{
    if (!s || !s->ready || n > DSP_BLOCK || (!audio && n)) return -1;
    for (unsigned i = 0; i < n; i++) if (!finite_float(audio[i])) return -1;
    for (unsigned i = 0; i < n; i += SUB) chunk(s, audio + i, n - i < SUB ? n - i : SUB);
    for (unsigned i = 0; i < n; i++) {
        if (!finite_float(audio[i])) {
            nam_a2_reset(s);
            memset(audio, 0, n * sizeof *audio);
            return -2;
        }
    }
    return 0;
}
