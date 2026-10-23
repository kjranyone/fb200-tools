/* Time-domain pitch shifter (fx_pitch.h). MIT; see LICENSE.
 * At most one splice search per block keeps a block's cost bounded; on the
 * pedal (`fxstat`) a block that searches takes up to ~33k cycles in the
 * guitar range and ~58k in the bass range (of 400k). */
#include "cold.h"
#include "dsp/fx_pitch.h"
#include "dsp/math.h"
#include <stdbool.h>
#include <string.h>

#define MASK (FX_PITCH_RING - 1u)
#define FADE 192u          /* 4 ms crossfade */
#define MARGIN 48u         /* 1 ms between the head and the newest sample */
#define WIN 288u           /* 6 ms match window */
#define JMIN 96u           /* 2 ms shortest jump */
#define SCALE 16384.0f     /* int16 history: 6 dB headroom above full scale */
#define EARLY 512u         /* down shifts: try an early splice every ~10 ms */

COLD void fx_pitch_init(fx_pitch_t *p, float fs)
{
    (void)fs;
    memset(p, 0, sizeof *p);
    p->r = p->r_to = 1.0f;
    p->r_coef = 1.0f;
    p->wet = 0.5f;
    p->dry = 0.5f;
    p->jmax = 1248u;       /* 26 ms: the low E of a bass */
    p->d = (float)(MARGIN + 600u);
    p->check = EARLY;
}

COLD void fx_pitch_set(fx_pitch_t *p, float fs, const uint16_t w[8])
{
    unsigned shift = w[FXP_SHIFT] > 4800u ? 4800u : w[FXP_SHIFT];
    unsigned mix = w[FXP_MIX] > 100u ? 100u : w[FXP_MIX];
    unsigned level = w[FXP_LEVEL] > 100u ? 100u : w[FXP_LEVEL];
    unsigned glide = w[FXP_GLIDE] > 1000u ? 1000u : w[FXP_GLIDE];
    p->r_to = dsp_exp2f(((float)shift - 2400.0f) * (1.0f / 1200.0f));
    float gain = dsp_exp2f(((float)level - 50.0f) * 0.0597947f);      /* +-18 dB */
    p->wet = (float)mix * 0.01f * gain;
    p->dry = 1.0f - (float)mix * 0.01f;
    /* one pole reaching ~63 % of a ratio change in the glide time */
    p->r_coef = glide == 0u ? 1.0f : 1.0f - dsp_exp2f(-1.442695f * 1000.0f / ((float)glide * fs));
    p->jmax = w[FXP_RANGE] ? 1248u : 672u;         /* 26 ms bass, 14 ms guitar */
}

static inline float at(const fx_pitch_t *p, unsigned delay)
{
    return (float)p->ring[(p->w - 1u - delay) & MASK];
}

/* Linear interpolation, delay 0 = the newest sample. */
static inline float read(const fx_pitch_t *p, float d)
{
    unsigned i = (unsigned)d;
    float f = d - (float)i;
    float a = at(p, i), b = at(p, i + 1u);
    return a + (b - a) * f;
}

#if defined(__arm__)
#define CYCLES() (*(volatile uint32_t *)0xE0001004u)   /* DWT->CYCCNT */
#else
#define CYCLES() 0u
#endif

static inline float root(float v)
{
#if defined(__ARM_FP)
    float r;
    __asm("vsqrt.f32 %0, %1" : "=t"(r) : "t"(v));   /* no libm, no errno */
    return r;
#else
    return __builtin_sqrtf(v);
#endif
}

static float search_(const fx_pitch_t *p, unsigned d, int dir, unsigned jmin, unsigned jmax,
                     bool edge_ok, float *score);

static float search(fx_pitch_t *p, unsigned d, int dir, unsigned jmin, unsigned jmax,
                    bool edge_ok, float *score)
{
    uint32_t t = CYCLES();
    float J = search_(p, d, dir, jmin, jmax, edge_ok, score);
    t = CYCLES() - t;
    p->searches++;
    if (t > p->search_max) p->search_max = t;
    return J;
}

/* Sum of a[k]*b[k] over int16 pairs: SMLALD on the M7 (two products per
 * instruction into 64 bits, one 32-bit load per operand pair). 64 bits:
 * 288 products of full-scale samples overflow 32. */
static __attribute__((noinline)) int64_t dot16(const int16_t *a, const int16_t *b, unsigned n)
{
    int64_t s0 = 0, s1 = 0;
    unsigned k = 0;
#if defined(__ARM_FEATURE_DSP)
    for (; k + 4u <= n; k += 4u) {
        uint32_t a0, a1, b0, b1;
        __builtin_memcpy(&a0, a + k, 4); __builtin_memcpy(&b0, b + k, 4);
        __builtin_memcpy(&a1, a + k + 2u, 4); __builtin_memcpy(&b1, b + k + 2u, 4);
        __asm("smlald %Q0, %R0, %1, %2" : "+r"(s0) : "r"(a0), "r"(b0));
        __asm("smlald %Q0, %R0, %1, %2" : "+r"(s1) : "r"(a1), "r"(b1));
    }
#endif
    for (; k < n; k++) s0 += (int32_t)a[k] * b[k];
    return s0 + s1;
}

/* int64 to float in two conversions, without the libgcc call */
static inline float f64(int64_t v)
{
    return (float)(int32_t)(v >> 32) * 4294967296.0f + (float)(uint32_t)v;
}

static inline float ncorr(int64_t ab, int64_t aa, int64_t bb)
{
    float den = f64(aa) * f64(bb);
    return den > 0.0f ? f64(ab) / root(den) : 0.0f;
}

#define DEC 4u                         /* coarse pass: every 4th sample */
#define CW (WIN / DEC)                 /* 72 points per coarse window */
#define CN ((1248u + WIN) / DEC + 2u)  /* longest jump + a window, decimated */
#define FN (WIN + 8u)                  /* fine pass: a window and +-4 lags */

/* The jump (jmin..jmax samples; a longer delay when dir > 0, a shorter one
 * when dir < 0) whose window best matches the window just older than the
 * head, to a fraction of a sample. Among the correlation peaks within 0.05
 * of the best it takes the one that keeps the delay short: the shortest
 * jump when the delay grows, the longest when it shrinks. A peak, not just
 * a high value: beside a peak the phase is off and every splice would bend
 * the pitch. *score: the match, -1 when an optional splice (!edge_ok) has
 * no peak inside the range.
 * Cost: the coarse pass copies the history once, decimated, into a
 * word-aligned int16 array and correlates with SMLALD, sliding the
 * candidate energy; the fine pass copies a window and +-4 lags at full rate
 * and slides their energy too. */
static float search_(const fx_pitch_t *p, unsigned d, int dir, unsigned jmin, unsigned jmax,
                     bool edge_ok, float *score)
{
    int16_t h[CN] __attribute__((aligned(8)));
    /* shorter delays: start a multiple of 2 DEC below the head, so the
     * head's window and every candidate's sit exactly on decimated points,
     * and at even (word-aligned) indices in h */
    unsigned jm4 = (jmax + 2u * DEC - 1u) & ~(2u * DEC - 1u);
    unsigned base = dir > 0 ? d : d - jm4;
    unsigned span = (jm4 + WIN) / DEC + 1u;
    if (span > CN) span = CN;
    unsigned i0 = p->w - 1u - base;
    for (unsigned k = 0; k < span; k++) h[k] = p->ring[(i0 - DEC * k) & MASK];
    unsigned ref = dir > 0 ? 0u : jm4 / DEC;       /* the head's window in h */
    int64_t aa = dot16(h + ref, h + ref, CW);

    float c8[160];                     /* (26 ms - 2 ms) / 8 lags, rounded up */
    unsigned count = 0;
    float best = -2.0f;
    unsigned bestJ = jmin;
    /* candidate windows start at idx(J); consecutive lags move by 2 points */
    unsigned J0 = jmin & ~7u;
    if (J0 < jmin) J0 += 8u;
    unsigned s = dir > 0 ? J0 / DEC : (jm4 - J0) / DEC;
    int64_t bb = dot16(h + s, h + s, CW);
    for (unsigned J = J0; J <= jmax && count < sizeof c8 / sizeof c8[0]; J += 8u, count++) {
        if (s + CW > span) break;
        float c = ncorr(dot16(h + ref, h + s, CW), aa, bb);
        c8[count] = c;
        if (c > best) { best = c; bestJ = J; }
        /* slide the candidate window by two points */
        if (dir > 0) {
            if (s + CW + 1u >= span) { count++; break; }
            bb += (int64_t)(h[s + CW] * h[s + CW]) + h[s + CW + 1u] * h[s + CW + 1u]
                - h[s] * h[s] - h[s + 1u] * h[s + 1u];
            s += 2u;
        } else {
            if (s < 2u) { count++; break; }
            bb += (int64_t)(h[s - 1u] * h[s - 1u]) + h[s - 2u] * h[s - 2u]
                - h[s + CW - 1u] * h[s + CW - 1u] - h[s + CW - 2u] * h[s + CW - 2u];
            s -= 2u;
        }
    }
    bool found = false;
    for (unsigned k = 0; k < count && !found; k++) {
        unsigned i = dir > 0 ? k : count - 1u - k;
        bool peak = (i == 0 || c8[i] >= c8[i-1]) &&
                    (i + 1 == count ? edge_ok : c8[i] >= c8[i+1]);
        if (peak && c8[i] >= best - 0.05f && c8[i] > 0.5f) { bestJ = J0 + i * 8u; found = true; }
    }
    if (!found && !edge_ok) { *score = -1.0f; return (float)bestJ; }

    /* fine: the head's window and the candidates' span at full rate */
    unsigned lo = bestJ > jmin + 4u ? bestJ - 4u : jmin, hi = bestJ + 4u > jmax ? jmax : bestJ + 4u;
    int16_t a[WIN] __attribute__((aligned(8))), b[FN] __attribute__((aligned(8)));
    unsigned ia = p->w - 1u - d;
    for (unsigned k = 0; k < WIN; k++) a[k] = p->ring[(ia - k) & MASK];
    /* b[k] = the sample at delay e0 + k, e0 the nearest candidate start */
    unsigned e0 = dir > 0 ? d + lo : d - hi;
    unsigned nb = WIN + (hi - lo);
    unsigned ib = p->w - 1u - e0;
    for (unsigned k = 0; k < FN; k++) b[k] = p->ring[(ib - k) & MASK];
    aa = dot16(a, a, WIN);
    /* e[o]: the energy of the candidate window b[o..o+WIN), slid along */
    int64_t e[FN - WIN + 1u];
    e[0] = dot16(b, b, WIN);
    for (unsigned o = 0; o + WIN < nb; o++)
        e[o + 1u] = e[o] + b[o + WIN] * b[o + WIN] - b[o] * b[o];
    float top = -2.0f, prev = -2.0f, before = -2.0f, after = -2.0f;
    unsigned topJ = bestJ;
    for (unsigned J = lo; J <= hi; J++) {
        unsigned off = dir > 0 ? J - lo : hi - J;
        float c = ncorr(dot16(a, b + off, WIN), aa, e[off]);
        if (J == topJ + 1u) after = c;
        if (c > top) { top = c; topJ = J; before = prev; after = -2.0f; }
        prev = c;
    }
    if (!edge_ok && topJ == hi && hi == jmax) { *score = -1.0f; return (float)topJ; }
    *score = top;
    /* parabola through the peak and its neighbours: the period is rarely a
     * whole number of samples, and the remainder would add up per splice */
    float J = (float)topJ;
    if (before > -2.0f && after > -2.0f) {
        float den = before - 2.0f * top + after;
        if (den < 0.0f) {
            float off = 0.5f * (before - after) / den;
            if (off > -0.5f && off < 0.5f) J += off;
        }
    }
    return J;
}

void fx_pitch_process(fx_pitch_t *p, float *x, unsigned n)
{
    uint32_t t0 = CYCLES();
    bool searched = false;                 /* one search per block: bounded cost */
    for (unsigned i = 0; i < n; i++) {
        float in = x[i];
        float s = in * SCALE;
        s = s > 32767.0f ? 32767.0f : s < -32768.0f ? -32768.0f : s;
        p->ring[p->w & MASK] = (int16_t)s;
        p->w++;
        float r = p->r += (p->r_to - p->r) * p->r_coef;
        float up = r > 1.0f ? (r - 1.0f) * (float)FADE : 0.0f;
        float dmin = (float)MARGIN + up;
        float dmax = dmin + (float)(p->jmax + FADE);
        if (!p->fade) {
            float score;
            if (r > 1.0f && p->d < dmin + 1.0f && !searched) {
                searched = true;
                /* the jump has to outrun the head's approach during the fade */
                unsigned jmin = (unsigned)up + MARGIN + 1u;
                if (jmin < JMIN) jmin = JMIN;
                float J = search(p, (unsigned)p->d, 1, jmin, p->jmax, true, &score);
                p->dq = p->d + J;
                p->fade = 1;
                p->splices++;
                p->last_j = (unsigned)(J + 0.5f);
                p->last_score = score;
            } else if (r < 1.0f) {
                float room = p->d - dmin - (1.0f - r) * (float)FADE - 1.0f;
                bool due = p->d > dmax;
                bool early = !due && --p->check == 0u;
                if (early) p->check = EARLY;
                if ((due || early) && room > (float)(JMIN + 8u) && !searched) {
                    searched = true;
                    unsigned lim = (unsigned)room < p->jmax ? (unsigned)room : p->jmax;
                    float J = search(p, (unsigned)p->d, -1, JMIN, lim, due, &score);
                    if (due || score >= 0.92f) {
                        p->dq = p->d - J;
                        p->fade = 1;
                        p->splices++;
                        p->last_j = (unsigned)(J + 0.5f);
                        p->last_score = score;
                    }
                }
            }
        }
        float y = read(p, p->d);
        if (p->fade) {
            float b = read(p, p->dq);
            y += (b - y) * ((float)(p->fade - 1u) * (1.0f / (float)FADE));
            p->dq += 1.0f - r;
            if (++p->fade > FADE) {
                p->d = p->dq;
                p->fade = 0;
            }
        }
        p->d += 1.0f - r;
        /* never read ahead of the write point or past the history */
        if (p->d < 0.0f) p->d = 0.0f;
        if (p->d > (float)(FX_PITCH_RING - WIN - 4u)) p->d = (float)(FX_PITCH_RING - WIN - 4u);
        x[i] = in * p->dry + y * (1.0f / SCALE) * p->wet;
    }
    uint32_t t = CYCLES() - t0;
    if (t > p->block_max) p->block_max = t;
}
