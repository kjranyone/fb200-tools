/* Time-domain pitch shifter for the FX block (docs/NAM_FX_BLOCK.md). MIT.
 *
 * A delay line read at the pitch ratio. When the read head's delay leaves
 * its range, a second head starts at a jump that best continues the recent
 * waveform (normalised correlation, as in the H949's de-glitching) and the
 * output crossfades to it. No pitch detection: chords pass as a whole.
 * Latency is the head's delay, 2..33 ms depending on the shift and range.
 * Prototype and listening clips: out/pitch-proto-* (variant V2). */
#ifndef FB200_DSP_FX_PITCH_H
#define FB200_DSP_FX_PITCH_H
#include <stdint.h>

#define FX_PITCH_RING 4096u      /* int16 history, 85 ms at 48 kHz */

typedef struct {
    int16_t ring[FX_PITCH_RING];
    uint32_t w;                  /* next write index */
    float d, dq;                 /* delays (samples) of the head and the incoming head */
    unsigned fade;               /* crossfade step, 0: none */
    unsigned check;              /* down shifts: samples to the next early-splice try */
    float r, r_to, r_coef;       /* pitch ratio, its target, glide coefficient */
    float wet, dry;
    unsigned jmax;               /* longest jump, samples (range: guitar or bass) */
    unsigned splices;            /* statistics: count, the last jump and its match */
    unsigned last_j;
    float last_score;
    uint32_t searches, search_max, block_max;   /* cycles (DWT) on the pedal */
} fx_pitch_t;

/* Preset words (FX block parameters 0..4): shift 0..4800 (2400 = none, in
 * cents), mix 0..100 (% wet), level 0..100 (50 = 0 dB, +-18 dB), glide
 * 0..1000 ms, range 0 guitar / 1 bass. */
enum { FXP_SHIFT, FXP_MIX, FXP_LEVEL, FXP_GLIDE, FXP_RANGE };

void fx_pitch_init(fx_pitch_t *p, float fs);
void fx_pitch_set(fx_pitch_t *p, float fs, const uint16_t words[8]);
/* Mono in place. */
void fx_pitch_process(fx_pitch_t *p, float *x, unsigned n);
#endif
