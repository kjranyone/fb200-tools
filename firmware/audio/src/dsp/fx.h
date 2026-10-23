/* The FX block's modes as the app sees them (docs/NAM_FX_BLOCK.md): each
 * mode describes its parameters, so the app builds its controls without
 * knowing the mode. MIT. */
#ifndef FB200_DSP_FX_H
#define FB200_DSP_FX_H
#include <stdint.h>

enum { FX_MODE_OFF = 0, FX_MODE_PITCH = 1, FX_MODES = 1 };

/* flags word (preset 0xEE) */
#define FX_FLAG_ON 1u
#define FX_FLAG_POST 2u        /* after the cabinet and EQ instead of before the NAMs */

enum { FX_UNIT_NONE, FX_UNIT_PERCENT, FX_UNIT_DB18, FX_UNIT_MS, FX_UNIT_CENTS, FX_UNIT_CHOICE };

typedef struct {
    char name[12];
    int16_t min, max, def;
    uint8_t unit;              /* FX_UNIT_*; CENTS: value - 2400; DB18: 50 = 0 dB, +-18 dB */
    char labels[24];           /* CHOICE: "A|B|..." for min..max */
} fx_param_desc_t;

typedef struct {
    char name[16];
    uint8_t heavy;             /* takes the arena (exclusive with the second NAM) */
    uint8_t count;
    fx_param_desc_t p[8];
} fx_mode_desc_t;

/* 1..FX_MODES; NULL for anything else. */
const fx_mode_desc_t *fx_mode_desc(unsigned mode);
/* NAM RPC op 14 reply data: [mode][heavy][name 16][count] then count x
 * {name 12, min, max, def i16 LE, unit u8, labels 24}. 0: no such mode or
 * no room. */
uint32_t fx_describe(unsigned mode, uint8_t *out, uint32_t cap);
#endif
