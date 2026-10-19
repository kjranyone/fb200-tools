/* NAM tone controls: post-NAM gain/tone stack driven by the preset's own
 * amp-block fields (P_AMP_*). Under NAM the stock amp is replaced by the
 * model, so its GAIN/BASS/MIDDLE/MIDDLE-FREQ/TREBLE/VOLUME fields become
 * NAM-stage controls instead: GAIN is the pre-NAM drive (pushing the model
 * harder gets more breakup), BASS/MID/TREBLE a 3-band EQ after the model,
 * VOLUME the stage output level. Neutral: 50/50/50/~50/100. MIT; see
 * LICENSE and docs/NAM_A2_LITE.md. */
#ifndef FB200_DSP_NAM_TONE_H
#define FB200_DSP_NAM_TONE_H
#include <stdint.h>
#include "dsp/biquad.h"

typedef struct {
    biquad_t shelf;          /* bass (low shelf) + treble (high shelf) */
    biquad_t mid;            /* peaking EQ at the mid frequency */
    float drive;             /* pre-NAM gain, 1.0 at value 50 */
    float level;             /* post-NAM gain, 1.0 at value 100 */
    unsigned midfreq_word;   /* the raw preset word, for re-design on fs change */
} nam_tone_t;

void nam_tone_init(nam_tone_t *t, float fs);
void nam_tone_reset(nam_tone_t *t);
/* Knob values are the preset's 0..100 words. Redesigning on a change is
 * cheap (two biquad stages) and done from the apply path, not the audio
 * callback. */
void nam_tone_set(nam_tone_t *t, float fs,
                  unsigned gain, unsigned bass, unsigned mid, unsigned midfreq,
                  unsigned treble, unsigned volume);
void nam_tone_pre(nam_tone_t *t, float *x, unsigned n);   /* drive */
void nam_tone_post(nam_tone_t *t, float *x, unsigned n);  /* EQ + level */
#endif
