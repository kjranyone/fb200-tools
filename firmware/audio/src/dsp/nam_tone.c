/* NAM tone controls (nam_tone.h): the DSP. The pre/post process functions
 * run in the audio callback (ITCM); the set/init/reset and the knob-mapping
 * helpers run from the apply path (COLD/XIP). */
#include "cold.h"
#include "dsp/nam_tone.h"
#include "dsp/dsp.h"
#include "dsp/math.h"
#include <string.h>

COLD void nam_tone_init(nam_tone_t *t, float fs)
{
    biquad_init(&t->shelf, 2);
    biquad_init(&t->mid, 1);
    t->drive = 1.0f;
    t->level = 1.0f;
    t->midfreq_word = 50;
    t->tone_active = 0;
    nam_tone_set(t, fs, 50, 50, 50, 50, 50, 50);
}

void nam_tone_reset(nam_tone_t *t)
{
    memset(t->shelf.state, 0, sizeof t->shelf.state);
    memset(t->mid.state, 0, sizeof t->mid.state);
}

/* 0..100 knob -> -12..+12 dB, 50 = 0 dB */
static COLD float knob_db(unsigned v)
{
    if (v > 100) v = 100;
    return ((int)v - 50) * (24.0f / 100.0f);
}

/* 0..100 knob -> log-scaled 200..2000 Hz, 50 = ~632 Hz.
 * 200 * 10^(v/100) = 200 * 2^(v * log2(10)/100). */
static COLD float mid_hz(unsigned v)
{
    if (v > 100) v = 100;
    return 200.0f * dsp_exp2f((float)v * 0.033212f);  /* log2(10)/100 */
}

/* 0..100 knob -> 0.5..2.0x drive, 50 = 1.0x (exponential around unity) */
static COLD float drive_gain(unsigned v)
{
    if (v > 100) v = 100;
    return dsp_exp2f(((int)v - 50) * 0.02f);   /* +-1 octave over 0..100 */
}

/* 0..100 knob -> 0..2.0x level, 50 = 1.0x */
static COLD float level_gain(unsigned v)
{
    if (v > 100) v = 100;
    return v * (2.0f / 100.0f);
}

COLD void nam_tone_set(nam_tone_t *t, float fs,
                  unsigned gain, unsigned bass, unsigned mid, unsigned midfreq,
                  unsigned treble, unsigned volume)
{
    t->drive = drive_gain(gain);
    t->level = level_gain(volume);
    t->midfreq_word = midfreq;
    unsigned active = bass != 50 || mid != 50 || treble != 50;
    if (active != t->tone_active) nam_tone_reset(t);
    t->tone_active = active;
    biquad_design(&t->shelf, 0, BQ_LOWSHELF, fs, 100.0f, 0.7f, knob_db(bass));
    biquad_design(&t->shelf, 1, BQ_HIGHSHELF, fs, 3200.0f, 0.7f, knob_db(treble));
    biquad_design(&t->mid, 0, BQ_PEAK, fs, mid_hz(midfreq), 1.0f, knob_db(mid));
}

void nam_tone_pre(nam_tone_t *t, float *x, unsigned n)
{
    if (t->drive == 1.0f) return;
    for (unsigned i = 0; i < n; i++) x[i] *= t->drive;
}

/* The target's ITCM also holds reverb delay lines. A compact DF2T loop
 * avoids retaining CMSIS's unrolled DF2T kernel just for these three
 * stages. Coefficient/state layout is identical to biquad_t/CMSIS. */
static void tone_filter(biquad_t *b, float *x, unsigned n)
{
    for (unsigned stage = 0; stage < b->stages; stage++) {
        const float *c = b->coeffs + 5 * stage;
        float d1 = b->state[2 * stage], d2 = b->state[2 * stage + 1];
        for (unsigned i = 0; i < n; i++) {
            float in = x[i];
            float out = c[0] * in + d1;
            d1 = c[1] * in + c[3] * out + d2;
            d2 = c[2] * in + c[4] * out;
            x[i] = out;
        }
        b->state[2 * stage] = d1; b->state[2 * stage + 1] = d2;
    }
}

void nam_tone_post(nam_tone_t *t, float *x, unsigned n)
{
    if (t->tone_active) {
        tone_filter(&t->shelf, x, n);
        tone_filter(&t->mid, x, n);
    }
    if (t->level != 1.0f) {
        for (unsigned i = 0; i < n; i++) x[i] *= t->level;
    }
}
