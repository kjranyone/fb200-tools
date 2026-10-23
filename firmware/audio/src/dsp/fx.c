/* FX mode descriptors (fx.h). Read by the NAM RPC only: flash. MIT. */
#include "dsp/fx.h"
#include <string.h>

static const fx_mode_desc_t kModes[FX_MODES] = {
    {"PITCH", 0, 5, {
        {"SHIFT", 0, 4800, 3600, FX_UNIT_CENTS, ""},
        {"MIX", 0, 100, 50, FX_UNIT_PERCENT, ""},
        {"LEVEL", 0, 100, 50, FX_UNIT_DB18, ""},
        {"GLIDE", 0, 1000, 0, FX_UNIT_MS, ""},
        {"RANGE", 0, 1, 1, FX_UNIT_CHOICE, "Guitar|Bass"},
    }},
};

const fx_mode_desc_t *fx_mode_desc(unsigned mode)
{
    return mode >= 1u && mode <= FX_MODES ? &kModes[mode - 1u] : 0;
}

uint32_t fx_describe(unsigned mode, uint8_t *out, uint32_t cap)
{
    const fx_mode_desc_t *m = fx_mode_desc(mode);
    if (!m || cap < 19u + m->count * 43u) return 0;
    uint32_t n = 0;
    out[n++] = (uint8_t)mode;
    out[n++] = m->heavy;
    memcpy(out + n, m->name, 16); n += 16;
    out[n++] = m->count;
    for (unsigned i = 0; i < m->count; i++) {
        const fx_param_desc_t *q = &m->p[i];
        memcpy(out + n, q->name, 12); n += 12;
        const int16_t v[3] = {q->min, q->max, q->def};
        for (unsigned k = 0; k < 3; k++) {
            out[n++] = (uint8_t)v[k];
            out[n++] = (uint8_t)((uint16_t)v[k] >> 8);
        }
        out[n++] = q->unit;
        memcpy(out + n, q->labels, 24); n += 24;
    }
    return n;
}
