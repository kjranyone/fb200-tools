/* Fixed A2-Lite research kernel. MIT; see LICENSE and docs/NAM_A2_LITE.md.
 * No parser, heap, flash reads, resampling or level calibration in process(). */
#ifndef FB200_NAM_A2_H
#define FB200_NAM_A2_H
#include <stddef.h>
#include <stdint.h>
#include "dsp.h"

#define NAM_A2_RATE 48000u
#define NAM_A2_LAYERS 23u
#define NAM_A2_WEIGHTS 1871u
#define NAM_A2_HISTORY 19110u /* 3 * (sum((K-1)*D+1) + head K=16) */
#define NAM_A2_RECEPTIVE_FIELD 6347u

typedef struct {
    float weights[NAM_A2_WEIGHTS]; /* original .nam stream order; copied to RAM */
    float history[NAM_A2_HISTORY];
    uint16_t position[NAM_A2_LAYERS + 1];
    int ready;
} nam_a2_t;

/* All storage is caller-owned. Init and reset belong outside the audio callback.
 * Zero-state start, NOT NAM Core's silence-prewarmed start. Rejects unknown
 * rates, A2-Full/wrong count, NaN and infinity. A failed init disables state. */
int nam_a2_init(nam_a2_t *s, const float *weights, size_t count,
                unsigned model_rate, unsigned engine_rate);
void nam_a2_reset(nam_a2_t *s);
/* Mono in place; 0..DSP_BLOCK frames. Invalid arguments leave audio/history
 * unchanged. Non-finite inference silences the block and clears history. */
int nam_a2_process(nam_a2_t *s, float *audio, unsigned n);
#endif
