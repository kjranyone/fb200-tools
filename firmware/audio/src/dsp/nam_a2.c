/* Scalar, bounded-memory A2-Lite implementation for host-first research.
 * Architecture/weight layout follow Steven Atkinson's NeuralAmpModelerCore
 * NAM/wavenet/a2_fast.cpp (MIT). Attribution: docs/NAM_A2_LITE.md.
 * This is a correctness baseline; Cortex-M7 real-time cost is unmeasured. */
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
    nam_a2_reset(s);
    s->ready = 1;
    return 0;
}

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
        float z[3];
        for (unsigned out = 0; out < 3; out++) z[out] = bias[out];
        /* Tap order: oldest first; weights are [out][in][tap]. Matches
         * Core's tap-major accumulation, without padded power-of-two rings. */
        for (unsigned tap = 0; tap < k; tap++) {
            unsigned back = (k-1-tap)*d;
            unsigned at = pos >= back ? pos-back : pos+len-back;
            for (unsigned in = 0; in < 3; in++)
                for (unsigned out = 0; out < 3; out++)
                    z[out] += w[(out*3+in)*k+tap] * hist[at*3+in];
        }
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
    float y = w[48];
    for (unsigned tap = 0; tap < 16; tap++) {
        unsigned at = (pos+1+tap) & 15u;
        for (unsigned c = 0; c < 3; c++) y += w[c*16+tap] * hist[at*3+c];
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
