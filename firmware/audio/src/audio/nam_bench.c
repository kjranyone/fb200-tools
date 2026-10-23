/* Kernel cycle measurements for the NAM speed work (`nambench`). Flash only:
 * not on the audio path. MIT, see project LICENSE. */
#include <stdint.h>
#include "cold.h"
#include "audio/engine.h"
#include "debug/cdc_log.h"
#include "dsp/dsp.h"
#include "dsp/nam_a2.h"
#include "dsp/nam_a2_conv.h"
#include <string.h>
#include "fsl_device_registers.h"

nam_a2_t *engine_nam_borrow(unsigned *slot);

/* `nambench`: measurement only. Runs from flash (I-cache) and clobbers the
 * NAM state; the selected model is reloaded afterwards. */
static volatile float s_bench_sink;
#define FMA3(a, h0, h1, h2, x, y, z) a += x*h0; a += y*h1; a += z*h2
static COLD __attribute__((noinline)) uint32_t bench_regs(unsigned n)
{
    float a0 = .1f, a1 = .2f, a2 = .3f, b0 = .4f, b1 = .5f, b2 = .6f,
          c0 = .7f, c1 = .8f, c2 = .9f, e0 = 1.f, e1 = 1.1f, e2 = 1.2f;
    float h0 = .5f, h1 = .25f, h2 = .125f;
    float w0 = 1e-3f, w1 = 2e-3f, w2 = 3e-3f, w3 = 4e-3f, w4 = 5e-3f, w5 = 6e-3f,
          w6 = 7e-3f, w7 = 8e-3f, w8 = 9e-3f;
    __asm volatile("" : "+t"(h0), "+t"(h1), "+t"(h2), "+t"(w0), "+t"(w1), "+t"(w2),
                   "+t"(w3), "+t"(w4), "+t"(w5), "+t"(w6), "+t"(w7), "+t"(w8));
    uint32_t t = DWT->CYCCNT;
    for (unsigned i = 0; i < n; i++) {
        FMA3(a0, h0, h1, h2, w0, w1, w2); FMA3(a1, h0, h1, h2, w3, w4, w5); FMA3(a2, h0, h1, h2, w6, w7, w8);
        FMA3(b0, h0, h1, h2, w0, w1, w2); FMA3(b1, h0, h1, h2, w3, w4, w5); FMA3(b2, h0, h1, h2, w6, w7, w8);
        FMA3(c0, h0, h1, h2, w0, w1, w2); FMA3(c1, h0, h1, h2, w3, w4, w5); FMA3(c2, h0, h1, h2, w6, w7, w8);
        FMA3(e0, h0, h1, h2, w0, w1, w2); FMA3(e1, h0, h1, h2, w3, w4, w5); FMA3(e2, h0, h1, h2, w6, w7, w8);
        __asm volatile("" : "+t"(a0), "+t"(a1), "+t"(a2), "+t"(b0), "+t"(b1), "+t"(b2),
                       "+t"(c0), "+t"(c1), "+t"(c2), "+t"(e0), "+t"(e1), "+t"(e2));
    }
    t = DWT->CYCCNT - t;
    s_bench_sink = a0 + a1 + a2 + b0 + b1 + b2 + c0 + c1 + c2 + e0 + e1 + e2;
    return t;
}
/* conv4's tap body without index arithmetic: 9 weight + 12 history loads. */
static COLD __attribute__((noinline)) uint32_t bench_loads(const float *wt, const float *hist,
                                                           unsigned n)
{
    float a0 = 0, a1 = 0, a2 = 0, b0 = 0, b1 = 0, b2 = 0, c0 = 0, c1 = 0, c2 = 0,
          e0 = 0, e1 = 0, e2 = 0;
    uint32_t t = DWT->CYCCNT;
    for (unsigned i = 0; i < n; i++) {
        const float *w = wt + (i & 7u) * 9, *p = hist + (i & 255u) * 3;
        const float w0 = w[0], w1 = w[1], w2 = w[2], w3 = w[3], w4 = w[4], w5 = w[5],
                    w6 = w[6], w7 = w[7], w8 = w[8];
        FMA3(a0, p[0], p[1], p[2], w0, w1, w2); FMA3(a1, p[0], p[1], p[2], w3, w4, w5);
        FMA3(a2, p[0], p[1], p[2], w6, w7, w8);
        FMA3(b0, p[3], p[4], p[5], w0, w1, w2); FMA3(b1, p[3], p[4], p[5], w3, w4, w5);
        FMA3(b2, p[3], p[4], p[5], w6, w7, w8);
        FMA3(c0, p[6], p[7], p[8], w0, w1, w2); FMA3(c1, p[6], p[7], p[8], w3, w4, w5);
        FMA3(c2, p[6], p[7], p[8], w6, w7, w8);
        FMA3(e0, p[9], p[10], p[11], w0, w1, w2); FMA3(e1, p[9], p[10], p[11], w3, w4, w5);
        FMA3(e2, p[9], p[10], p[11], w6, w7, w8);
    }
    t = DWT->CYCCNT - t;
    s_bench_sink = a0 + a1 + a2 + b0 + b1 + b2 + c0 + c1 + c2 + e0 + e1 + e2;
    return t;
}
#undef FMA3

/* The assembly conv4 against the C one on the live model's rings: every
 * layer, ring starts at both ends and in the middle. Bit-identical or not. */
static COLD void bench_conv4(const nam_a2_t *nam)
{
#ifdef NAM_A2_ASM
    static const unsigned K[NAM_A2_LAYERS] = {6,6,6,6,6,6,6,6,6,6,6,6,6,6,15,15,6,6,6,6,6,6,6};
    static const unsigned D[NAM_A2_LAYERS] = {1,3,7,17,41,101,239,1,3,7,17,41,101,239,1,13,
                                              1,3,7,17,41,101,239};
    unsigned cases = 0, bad = 0;
    uint32_t tc = 0, ta = 0;
    const float *w = nam->weights + 3;
    unsigned off = 0;
    for (unsigned layer = 0; layer < NAM_A2_LAYERS; layer++) {
        unsigned k = K[layer], d = D[layer], R = (k-1)*d + NAM_A2_SUB;
        const float *hist = nam->history + off, *bias = w + 9*k;
        const unsigned starts[8] = {0, 1, 5, R/2, R-4, R-3, R-2, R-1};
        for (unsigned i = 0; i < 8; i++) {
            float zc[4][3], za[4][3];
            uint32_t t = DWT->CYCCNT;
            nam_a2_conv4_c(hist, R, starts[i], k, d, w, bias, zc);
            tc += DWT->CYCCNT - t;
            t = DWT->CYCCNT;
            nam_a2_conv4_asm(hist, R, starts[i], k, d, w, bias, za);
            ta += DWT->CYCCNT - t;
            cases++;
            if (memcmp(zc, za, sizeof zc)) bad++;
        }
        w += 9*k + 18;
        off += (R + NAM_A2_MIRROR)*3;
    }
    log_printf("nambench conv4: %u cases, %u mismatches; C %lu, asm %lu cycles\r\n",
               cases, bad, (unsigned long)tc, (unsigned long)ta);
    /* post: pseudo-random z/x/head/audio (both signs, zeros) per layer */
    cases = bad = 0;
    tc = ta = 0;
    w = nam->weights + 3;
    uint32_t seed = 12345u;
    for (unsigned layer = 0; layer < NAM_A2_LAYERS; layer++) {
        const float *mixlin = w + 9*K[layer] + 3;
        float z1[8][3], z2[8][3], x1[8][3], x2[8][3], h1[8][3], h2[8][3], a[8];
        for (unsigned j = 0; j < 8; j++) {
            for (unsigned c = 0; c < 3; c++) {
                seed = seed * 1664525u + 1013904223u;
                z1[j][c] = (seed % 7u == 0) ? 0.f : (float)(int32_t)seed * 1e-9f;
                seed = seed * 1664525u + 1013904223u;
                x1[j][c] = (float)(int32_t)seed * 1e-9f;
                seed = seed * 1664525u + 1013904223u;
                h1[j][c] = (float)(int32_t)seed * 1e-9f;
            }
            seed = seed * 1664525u + 1013904223u;
            a[j] = (float)(int32_t)seed * 4e-10f;
        }
        memcpy(z2, z1, sizeof z1);
        memcpy(x2, x1, sizeof x1);
        memcpy(h2, h1, sizeof h1);
        uint32_t t = DWT->CYCCNT;
        nam_a2_post_c(z1, x1, h1, a, mixlin, 8);
        tc += DWT->CYCCNT - t;
        t = DWT->CYCCNT;
        nam_a2_post_asm(z2, x2, h2, a, mixlin, 8);
        ta += DWT->CYCCNT - t;
        cases++;
        if (memcmp(x1, x2, sizeof x1) || memcmp(h1, h2, sizeof h1)) bad++;
        w += 9*K[layer] + 18;
    }
    log_printf("nambench post: %u cases, %u mismatches; C %lu, asm %lu cycles\r\n",
               cases, bad, (unsigned long)tc, (unsigned long)ta);
#else
    (void)nam;
    log_printf("nambench conv4: no assembly in this build\r\n");
#endif
}

#ifdef NAM_A2_ASM
/* One conv4 tap body, history from DTCM: VLDM pairs of frames versus LDRD
 * into core registers then VMOV (does the integer load overlap the VFMAs?). */
#define TAP36 \
    "vfma.f32 s20, s0, s9\n\t"  "vfma.f32 s21, s3, s9\n\t"  "vfma.f32 s22, s6, s9\n\t"  \
    "vfma.f32 s23, s0, s12\n\t" "vfma.f32 s24, s3, s12\n\t" "vfma.f32 s25, s6, s12\n\t" \
    "vfma.f32 s20, s1, s10\n\t" "vfma.f32 s21, s4, s10\n\t" "vfma.f32 s22, s7, s10\n\t" \
    "vfma.f32 s23, s1, s13\n\t" "vfma.f32 s24, s4, s13\n\t" "vfma.f32 s25, s7, s13\n\t" \
    "vfma.f32 s20, s2, s11\n\t" "vfma.f32 s21, s5, s11\n\t" "vfma.f32 s22, s8, s11\n\t" \
    "vfma.f32 s23, s2, s14\n\t" "vfma.f32 s24, s5, s14\n\t" "vfma.f32 s25, s8, s14\n\t"
static COLD __attribute__((noinline)) uint32_t bench_vldm(const float *w, const float *p, unsigned n)
{
    uint32_t t = DWT->CYCCNT;
    __asm volatile(
        "1:\n\t"
        "vldmia   %[w], {s0-s8}\n\t"
        "vldmia   %[p], {s9-s14}\n\t"
        TAP36
        "vldmia   %[p], {s9-s14}\n\t"
        TAP36
        "subs     %[n], %[n], #1\n\t"
        "bne      1b\n\t"
        : [n] "+r" (n)
        : [w] "r" (w), [p] "r" (p)
        : "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
          "s12", "s13", "s14", "s20", "s21", "s22", "s23", "s24", "s25", "cc", "memory");
    return DWT->CYCCNT - t;
}
static COLD __attribute__((noinline)) uint32_t bench_ldrd(const float *w, const float *p, unsigned n)
{
    uint32_t a0, a1, a2, a3, a4, a5;
    uint32_t t = DWT->CYCCNT;
    __asm volatile(
        "1:\n\t"
        "vldmia   %[w], {s0-s8}\n\t"
        "ldrd     %[a0], %[a1], [%[p]]\n\t"
        "ldrd     %[a2], %[a3], [%[p], #8]\n\t"
        "ldrd     %[a4], %[a5], [%[p], #16]\n\t"
        "vmov     s9, s10, %[a0], %[a1]\n\t"
        "vmov     s11, s12, %[a2], %[a3]\n\t"
        "vmov     s13, s14, %[a4], %[a5]\n\t"
        TAP36
        "ldrd     %[a0], %[a1], [%[p]]\n\t"
        "ldrd     %[a2], %[a3], [%[p], #8]\n\t"
        "ldrd     %[a4], %[a5], [%[p], #16]\n\t"
        "vmov     s9, s10, %[a0], %[a1]\n\t"
        "vmov     s11, s12, %[a2], %[a3]\n\t"
        "vmov     s13, s14, %[a4], %[a5]\n\t"
        TAP36
        "subs     %[n], %[n], #1\n\t"
        "bne      1b\n\t"
        : [n] "+r" (n), [a0] "=&r" (a0), [a1] "=&r" (a1), [a2] "=&r" (a2),
          [a3] "=&r" (a3), [a4] "=&r" (a4), [a5] "=&r" (a5)
        : [w] "r" (w), [p] "r" (p)
        : "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
          "s12", "s13", "s14", "s20", "s21", "s22", "s23", "s24", "s25", "cc", "memory");
    return DWT->CYCCNT - t;
}
#undef TAP36

/* Head: the assembly against the C at every ring start of the live ring. */
static COLD void bench_head(const nam_a2_t *nam)
{
    static const unsigned K[NAM_A2_LAYERS] = {6,6,6,6,6,6,6,6,6,6,6,6,6,6,15,15,6,6,6,6,6,6,6};
    static const unsigned D[NAM_A2_LAYERS] = {1,3,7,17,41,101,239,1,3,7,17,41,101,239,1,13,
                                              1,3,7,17,41,101,239};
    unsigned off = 0, wo = 3;
    for (unsigned layer = 0; layer < NAM_A2_LAYERS; layer++) {
        off += ((K[layer]-1)*D[layer] + NAM_A2_SUB + NAM_A2_MIRROR)*3;
        wo += 9*K[layer] + 18;
    }
    const unsigned R = 16 + NAM_A2_SUB - 1;
    const float *hist = nam->history + off, *w = nam->weights + wo;
    unsigned bad = 0;
    uint32_t tc = 0, ta = 0;
    for (unsigned f0 = 0; f0 < R; f0++) {
        float yc[4], ya[4];
        uint32_t t = DWT->CYCCNT;
        nam_a2_head4_c(hist, R, f0, w, yc);
        tc += DWT->CYCCNT - t;
        t = DWT->CYCCNT;
        nam_a2_head4_asm(hist, R, f0, w, ya);
        ta += DWT->CYCCNT - t;
        if (memcmp(yc, ya, sizeof yc)) bad++;
    }
    log_printf("nambench head: %u cases, %u mismatches; C %lu, asm %lu cycles\r\n",
               R, bad, (unsigned long)tc, (unsigned long)ta);
    const unsigned N = 1000;
    log_printf("nambench tap pair: vldm %lu, ldrd+vmov %lu cycles per 72 FMA\r\n",
               (unsigned long)(bench_vldm(nam->weights, nam->history, N) / N),
               (unsigned long)(bench_ldrd(nam->weights, nam->history, N) / N));
}
#endif

COLD void engine_nam_bench(void)
{
    unsigned slot;
    nam_a2_t *nam = engine_nam_borrow(&slot);   /* NAM is bypassed until the reload */
    if (!nam) { log_printf("nambench: select a model first\r\n"); return; }
    const unsigned N = 1000;
    log_printf("nambench regs: %lu cycles per 36 FMA\r\n", (unsigned long)(bench_regs(N) / N));
    log_printf("nambench loads: %lu cycles per 36 FMA + 21 loads\r\n",
               (unsigned long)(bench_loads(nam->weights, nam->history, N) / N));
    bench_conv4(nam);
#ifdef NAM_A2_ASM
    bench_head(nam);
#endif
    /* Interrupts stay on: masking them for whole blocks desynchronised the
     * SAI DMA for good (dma_errs climbing until reset). They cost ~2%. */
    float buf[DSP_BLOCK];
    uint32_t total = 0;
    for (unsigned b = 0; b < 32; b++) {
        for (unsigned i = 0; i < DSP_BLOCK; i++) buf[i] = 0.25f * (float)((i * 7u + b) % 9u) - 1.f;
        uint32_t t = DWT->CYCCNT;
        nam_a2_process(nam, buf, DSP_BLOCK);
        total += DWT->CYCCNT - t;
    }
    log_printf("nambench kernel: %lu cycles/block\r\n", (unsigned long)(total / 32));
    log_printf("nambench reload slot %u: %d\r\n", slot, engine_nam_select(slot));
}
