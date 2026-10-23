/* Copyright (C) 2026 Andrii Shylenko
 *
 * This software is released under the MIT License.
 * See the LICENSE file in the project root for full license information.
 */

#ifndef FB200_AUDIO_CONFIG_H
#define FB200_AUDIO_CONFIG_H
/* One sample rate for the whole audio path (SAI, codec, USB, DSP). The
 * stock runs 44.1 kHz and its amp/cab/tone coefficients are designed for it,
 * so parity runs there too. MCLK = 256 fs from PLL4 = 722.5344 MHz / 64. */
#ifndef AUDIO_FS
#define AUDIO_FS 44100u
#endif
#if AUDIO_FS == 44100u
#define AUDIO_PLL_LOOP 30u
#define AUDIO_PLL_NUM 66u
#elif AUDIO_FS == 48000u
/* PLL4 = 24 MHz * (32 + 96/125) = 786.432 MHz. */
#define AUDIO_PLL_LOOP 32u
#define AUDIO_PLL_NUM 480u
#else
#error "AUDIO_FS must be 44100 or 48000"
#endif
#define AUDIO_PLL_DENOM 625u
#define AUDIO_MCLK_HZ (256u * AUDIO_FS)
#endif
