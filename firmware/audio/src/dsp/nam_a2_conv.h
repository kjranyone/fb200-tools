/* A2-Lite layer arithmetic shared by nam_a2.c and the on-pedal check in
 * audio/nam_bench.c. MIT.
 *
 * Rings: a layer's ring holds R frames of 3 floats plus NAM_A2_MIRROR frames
 * that repeat frames 0..2, so any four consecutive frames starting below R
 * are contiguous in memory.
 *
 * conv4: four consecutive frames of one layer. f0 is the first frame's ring
 * index; wt is k taps x 9 weights, tap-major [tap][out*3+in]; z[4][3] gets the
 * outputs. Every accumulator adds bias, then taps ascending (oldest first),
 * inputs ascending: the per-sample reference order.
 *
 * post: per frame, the condition mixin, LeakyReLU(0.01), the head sum and the
 * 1x1 residual, in the reference order. mixlin is mix[3] then linear[12]. */
#ifndef FB200_NAM_A2_CONV_H
#define FB200_NAM_A2_CONV_H
#include <string.h>

#define NAM_A2_MIRROR 3u

static inline unsigned nam_a2_wrap(unsigned i, unsigned n) { return i >= n ? i - n : i; }

static inline void nam_a2_conv4_c(const float *hist, unsigned R, unsigned f0, unsigned k,
                                  unsigned d, const float *wt, const float *bias,
                                  float z[][3])
{
    float a0 = bias[0], a1 = bias[1], a2 = bias[2];
    float b0 = a0, b1 = a1, b2 = a2, c0 = a0, c1 = a1, c2 = a2, e0 = a0, e1 = a1, e2 = a2;
    unsigned back = (k-1)*d;
    for (unsigned tap = 0; tap < k; tap++, wt += 9, back -= d) {
        unsigned q = f0 >= back ? f0-back : f0+R-back;
        unsigned q1 = nam_a2_wrap(q+1, R), q2 = nam_a2_wrap(q1+1, R), q3 = nam_a2_wrap(q2+1, R);
        const float *p = hist + q*3, *r = hist + q1*3, *t = hist + q2*3, *u = hist + q3*3;
        const float w0 = wt[0], w1 = wt[1], w2 = wt[2], w3 = wt[3], w4 = wt[4],
                    w5 = wt[5], w6 = wt[6], w7 = wt[7], w8 = wt[8];
        float h0 = p[0], h1 = p[1], h2 = p[2];
        a0 += w0*h0; a0 += w1*h1; a0 += w2*h2;
        a1 += w3*h0; a1 += w4*h1; a1 += w5*h2;
        a2 += w6*h0; a2 += w7*h1; a2 += w8*h2;
        h0 = r[0]; h1 = r[1]; h2 = r[2];
        b0 += w0*h0; b0 += w1*h1; b0 += w2*h2;
        b1 += w3*h0; b1 += w4*h1; b1 += w5*h2;
        b2 += w6*h0; b2 += w7*h1; b2 += w8*h2;
        h0 = t[0]; h1 = t[1]; h2 = t[2];
        c0 += w0*h0; c0 += w1*h1; c0 += w2*h2;
        c1 += w3*h0; c1 += w4*h1; c1 += w5*h2;
        c2 += w6*h0; c2 += w7*h1; c2 += w8*h2;
        h0 = u[0]; h1 = u[1]; h2 = u[2];
        e0 += w0*h0; e0 += w1*h1; e0 += w2*h2;
        e1 += w3*h0; e1 += w4*h1; e1 += w5*h2;
        e2 += w6*h0; e2 += w7*h1; e2 += w8*h2;
    }
    z[0][0] = a0; z[0][1] = a1; z[0][2] = a2;
    z[1][0] = b0; z[1][1] = b1; z[1][2] = b2;
    z[2][0] = c0; z[2][1] = c1; z[2][2] = c2;
    z[3][0] = e0; z[3][1] = e1; z[3][2] = e2;
}

static inline void nam_a2_post_c(float z[][3], float x[][3], float head[][3],
                                 const float *audio, const float *mixlin, unsigned m)
{
    const float *mix = mixlin, *linear = mixlin + 3;
    for (unsigned j = 0; j < m; j++) {
        for (unsigned c = 0; c < 3; c++) {
            z[j][c] += mix[c] * audio[j];
            if (z[j][c] < 0) z[j][c] *= 0.01f;
            head[j][c] += z[j][c];
        }
        for (unsigned out = 0; out < 3; out++) {
            float residual = linear[9+out];
            for (unsigned in = 0; in < 3; in++) residual += linear[out*3+in] * z[j][in];
            x[j][out] += residual;
        }
    }
}

/* Head: K=16 over the summed layer outputs for four frames. w: 16 taps x 3
 * channels, tap-major, then w[48] bias and w[49] the output scale. */
static inline void nam_a2_head4_c(const float *hist, unsigned R, unsigned f0,
                                  const float *w, float y[4])
{
    for (unsigned j = 0; j < 4; j++) {
        unsigned f = nam_a2_wrap(f0 + j, R);
        float acc = w[48];
        for (unsigned tap = 0; tap < 16; tap++) {
            unsigned back = 15 - tap;
            const float *h = hist + (f >= back ? f-back : f+R-back)*3;
            acc += w[tap*3+0] * h[0];
            acc += w[tap*3+1] * h[1];
            acc += w[tap*3+2] * h[2];
        }
        y[j] = acc * w[49];
    }
}

/* m frames of v into a ring at pos, then refresh the mirror frames. */
static inline void nam_a2_ring_write(float *hist, unsigned R, unsigned pos,
                                     const float (*v)[3], unsigned m)
{
    unsigned first = R - pos < m ? R - pos : m;
    memcpy(hist + pos*3, v, first * sizeof v[0]);
    if (first < m) memcpy(hist, v + first, (m - first) * sizeof v[0]);
    if (pos < NAM_A2_MIRROR || first < m)
        memcpy(hist + R*3, hist, NAM_A2_MIRROR * sizeof v[0]);
}

#if defined(__ARM_ARCH_7EM__) && defined(__ARM_FP)
#define NAM_A2_ASM 1
/* Cortex-M7 (measured with `nambench`): 36 FMA alone take 37 cycles, with 21
 * single FP loads 93. Weights arrive in one VLDM per tap and a pair of frames
 * in one VLDM (the mirror keeps four frames contiguous). Each frame pair
 * issues its h0, h1, h2 products in rounds of six, so dependent VFMAs are six
 * apart. The fused VFMA is what the compiled C uses (fp-contract): identical
 * results, checked on the pedal against the C above. */
static inline void nam_a2_conv4_asm(const float *hist, unsigned R, unsigned f0, unsigned k,
                                    unsigned d, const float *wt, const float *bias,
                                    float z[][3])
{
    unsigned back = (k-1)*d;
    unsigned q = f0 >= back ? f0-back : f0+R-back;
    const float *p = hist + q*3, *end = hist + R*3, *t;
    unsigned span = R*12u, step = d*12u;
    __asm volatile(
        "vldmia   %[bias], {s20-s22}\n\t"
        "vmov.f32 s23, s20\n\t" "vmov.f32 s24, s21\n\t" "vmov.f32 s25, s22\n\t"
        "vmov.f32 s26, s20\n\t" "vmov.f32 s27, s21\n\t" "vmov.f32 s28, s22\n\t"
        "vmov.f32 s29, s20\n\t" "vmov.f32 s30, s21\n\t" "vmov.f32 s31, s22\n"
        "1:\n\t"
        "vldmia   %[w]!, {s0-s8}\n\t"
        "vldmia   %[p], {s9-s14}\n\t"
        "vfma.f32 s20, s0, s9\n\t"  "vfma.f32 s21, s3, s9\n\t"  "vfma.f32 s22, s6, s9\n\t"
        "vfma.f32 s23, s0, s12\n\t" "vfma.f32 s24, s3, s12\n\t" "vfma.f32 s25, s6, s12\n\t"
        "vfma.f32 s20, s1, s10\n\t" "vfma.f32 s21, s4, s10\n\t" "vfma.f32 s22, s7, s10\n\t"
        "vfma.f32 s23, s1, s13\n\t" "vfma.f32 s24, s4, s13\n\t" "vfma.f32 s25, s7, s13\n\t"
        "vfma.f32 s20, s2, s11\n\t" "vfma.f32 s21, s5, s11\n\t" "vfma.f32 s22, s8, s11\n\t"
        "vfma.f32 s23, s2, s14\n\t" "vfma.f32 s24, s5, s14\n\t" "vfma.f32 s25, s8, s14\n\t"
        "add      %[t], %[p], #24\n\t"
        "vldmia   %[t], {s9-s14}\n\t"
        "vfma.f32 s26, s0, s9\n\t"  "vfma.f32 s27, s3, s9\n\t"  "vfma.f32 s28, s6, s9\n\t"
        "vfma.f32 s29, s0, s12\n\t" "vfma.f32 s30, s3, s12\n\t" "vfma.f32 s31, s6, s12\n\t"
        "vfma.f32 s26, s1, s10\n\t" "vfma.f32 s27, s4, s10\n\t" "vfma.f32 s28, s7, s10\n\t"
        "vfma.f32 s29, s1, s13\n\t" "vfma.f32 s30, s4, s13\n\t" "vfma.f32 s31, s7, s13\n\t"
        "vfma.f32 s26, s2, s11\n\t" "vfma.f32 s27, s5, s11\n\t" "vfma.f32 s28, s8, s11\n\t"
        "vfma.f32 s29, s2, s14\n\t" "vfma.f32 s30, s5, s14\n\t" "vfma.f32 s31, s8, s14\n\t"
        /* next tap: d frames newer */
        "adds     %[p], %[p], %[step]\n\t"
        "cmp      %[p], %[end]\n\t"
        "it       hs\n\t"
        "subhs    %[p], %[p], %[span]\n\t"
        "subs     %[k], %[k], #1\n\t"
        "bne      1b\n\t"
        "vstmia   %[z], {s20-s31}\n\t"
        : [w] "+r" (wt), [p] "+r" (p), [k] "+r" (k), [t] "=&r" (t)
        : [end] "r" (end), [span] "r" (span), [step] "r" (step), [bias] "r" (bias),
          [z] "r" (&z[0][0])
        : "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
          "s12", "s13", "s14", "s20", "s21", "s22", "s23", "s24", "s25", "s26", "s27",
          "s28", "s29", "s30", "s31", "cc", "memory");
}

static inline void nam_a2_head4_asm(const float *hist, unsigned R, unsigned f0,
                                    const float *w, float y[4])
{
    unsigned q = f0 >= 15u ? f0-15u : f0+R-15u;
    const float *p = hist + q*3, *end = hist + R*3;
    unsigned span = R*12u, k = 16;
    __asm volatile(
        "vldr     s20, [%[w], #192]\n\t"
        "vmov.f32 s21, s20\n\t" "vmov.f32 s22, s20\n\t" "vmov.f32 s23, s20\n"
        "1:\n\t"
        "vldmia   %[w]!, {s0-s2}\n\t"
        "vldmia   %[p], {s4-s15}\n\t"
        "vfma.f32 s20, s0, s4\n\t"  "vfma.f32 s21, s0, s7\n\t"
        "vfma.f32 s22, s0, s10\n\t" "vfma.f32 s23, s0, s13\n\t"
        "vfma.f32 s20, s1, s5\n\t"  "vfma.f32 s21, s1, s8\n\t"
        "vfma.f32 s22, s1, s11\n\t" "vfma.f32 s23, s1, s14\n\t"
        "vfma.f32 s20, s2, s6\n\t"  "vfma.f32 s21, s2, s9\n\t"
        "vfma.f32 s22, s2, s12\n\t" "vfma.f32 s23, s2, s15\n\t"
        "adds     %[p], %[p], #12\n\t"
        "cmp      %[p], %[end]\n\t"
        "it       hs\n\t"
        "subhs    %[p], %[p], %[span]\n\t"
        "subs     %[k], %[k], #1\n\t"
        "bne      1b\n\t"
        "vldr     s1, [%[w], #4]\n\t"
        "vmul.f32 s20, s20, s1\n\t"
        "vmul.f32 s21, s21, s1\n\t"
        "vmul.f32 s22, s22, s1\n\t"
        "vmul.f32 s23, s23, s1\n\t"
        "vstmia   %[y], {s20-s23}\n\t"
        : [w] "+r" (w), [p] "+r" (p), [k] "+r" (k)
        : [end] "r" (end), [span] "r" (span), [y] "r" (y)
        : "s0", "s1", "s2", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "s12",
          "s13", "s14", "s15", "s20", "s21", "s22", "s23", "cc", "memory");
}

/* LeakyReLU as max(z, 0.01*z): z when z >= 0 (also -0), the scaled value
 * when z < 0, the same product the C rounds. */
static inline void nam_a2_post_asm(float z[][3], float x[][3], float head[][3],
                                   const float *audio, const float *mixlin, unsigned m)
{
    float *zp = &z[0][0], *xp = &x[0][0], *hp = &head[0][0];
    const unsigned slope = 0x3c23d70au;   /* 0.01f */
    __asm volatile(
        "vldmia   %[ml], {s0-s14}\n\t"
        "vmov     s15, %[slope]\n"
        "1:\n\t"
        "vldmia   %[z]!, {s20-s22}\n\t"
        "vldmia   %[a]!, {s29}\n\t"
        "vfma.f32 s20, s0, s29\n\t"
        "vfma.f32 s21, s1, s29\n\t"
        "vfma.f32 s22, s2, s29\n\t"
        "vldmia   %[h], {s26-s28}\n\t"
        "vmul.f32 s16, s20, s15\n\t"
        "vmul.f32 s17, s21, s15\n\t"
        "vmul.f32 s18, s22, s15\n\t"
        "vmaxnm.f32 s20, s20, s16\n\t"
        "vmaxnm.f32 s21, s21, s17\n\t"
        "vmaxnm.f32 s22, s22, s18\n\t"
        "vadd.f32 s26, s26, s20\n\t"
        "vadd.f32 s27, s27, s21\n\t"
        "vadd.f32 s28, s28, s22\n\t"
        "vmov.f32 s16, s12\n\t"
        "vmov.f32 s17, s13\n\t"
        "vmov.f32 s18, s14\n\t"
        "vstmia   %[h]!, {s26-s28}\n\t"
        "vfma.f32 s16, s3, s20\n\t" "vfma.f32 s17, s6, s20\n\t" "vfma.f32 s18, s9, s20\n\t"
        "vfma.f32 s16, s4, s21\n\t" "vfma.f32 s17, s7, s21\n\t" "vfma.f32 s18, s10, s21\n\t"
        "vfma.f32 s16, s5, s22\n\t" "vfma.f32 s17, s8, s22\n\t" "vfma.f32 s18, s11, s22\n\t"
        "vldmia   %[x], {s23-s25}\n\t"
        "vadd.f32 s23, s23, s16\n\t"
        "vadd.f32 s24, s24, s17\n\t"
        "vadd.f32 s25, s25, s18\n\t"
        "vstmia   %[x]!, {s23-s25}\n\t"
        "subs     %[m], %[m], #1\n\t"
        "bne      1b\n\t"
        : [z] "+r" (zp), [x] "+r" (xp), [h] "+r" (hp), [a] "+r" (audio), [m] "+r" (m)
        : [ml] "r" (mixlin), [slope] "r" (slope)
        : "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
          "s12", "s13", "s14", "s15", "s16", "s17", "s18", "s20", "s21", "s22", "s23",
          "s24", "s25", "s26", "s27", "s28", "s29", "cc", "memory");
}
#endif

#endif
