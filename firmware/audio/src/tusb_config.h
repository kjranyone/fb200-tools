/* Copyright (C) 2026 Andrii Shylenko
 *
 * This software is released under the MIT License.
 * See the LICENSE file in the project root for full license information.
 */

/* TinyUSB configuration for the FB200 (i.MX RT10xx, device-only, no OS). */
#pragma once
#include "audio/audio_config.h"

#define CFG_TUSB_MCU            OPT_MCU_MIMXRT10XX
#define CFG_TUSB_OS             OPT_OS_NONE
#define CFG_TUSB_RHPORT0_MODE   (OPT_MODE_DEVICE | OPT_MODE_FULL_SPEED)
#define CFG_TUD_ENABLED         1
#define CFG_TUD_MAX_SPEED       OPT_MODE_FULL_SPEED
#define CFG_TUD_CDC             1
#define CFG_TUD_CDC_RX_BUFSIZE  64
#define CFG_TUD_CDC_TX_BUFSIZE  64
#define CFG_TUD_CDC_EP_BUFSIZE  64
#define CFG_TUSB_MEM_ALIGN      __attribute__((aligned(4)))

/* ---- UAC2 audio: stereo playback (RX) + stereo capture (TX), 44.1 kHz/16-bit */
#define CFG_TUD_AUDIO           1
#define CFG_TUD_HID             1
#define CFG_TUD_HID_EP_BUFSIZE  64
#define CFG_TUD_AUDIO_ENABLE_INTERRUPT_EP 1
#define CFG_TUD_AUDIO_FUNC_1_N_FORMATS 1
#define CFG_TUD_AUDIO_FUNC_1_MAX_SAMPLE_RATE AUDIO_FS
#define CFG_TUD_AUDIO_FUNC_1_N_CHANNELS_TX 2
#define CFG_TUD_AUDIO_FUNC_1_N_CHANNELS_RX 2
#define CFG_TUD_AUDIO_FUNC_1_FORMAT_1_N_BYTES_PER_SAMPLE_TX 2
#define CFG_TUD_AUDIO_FUNC_1_FORMAT_1_RESOLUTION_TX 16
#define CFG_TUD_AUDIO_FUNC_1_FORMAT_1_N_BYTES_PER_SAMPLE_RX 2
#define CFG_TUD_AUDIO_FUNC_1_FORMAT_1_RESOLUTION_RX 16
#define CFG_TUD_AUDIO_ENABLE_EP_IN 1
#define CFG_TUD_AUDIO_ENABLE_EP_OUT 1
/* Full speed: reserve one additional stereo frame for clock variation,
 * as in TinyUSB's TUD_AUDIO_EP_SIZE(false, ...). At 48 kHz, 192 bytes
 * holds only the nominal 48 frames; the endpoint must allow 49 (196 B). */
#define FB200_USB_AUDIO_EP_SIZE (((AUDIO_FS + 999u) / 1000u + 1u) * 4u)
#define CFG_TUD_AUDIO_FUNC_1_EP_IN_SZ_MAX FB200_USB_AUDIO_EP_SIZE
#define CFG_TUD_AUDIO_FUNC_1_EP_IN_SW_BUF_SZ (4u * CFG_TUD_AUDIO_FUNC_1_EP_IN_SZ_MAX)
#define CFG_TUD_AUDIO_FUNC_1_EP_OUT_SZ_MAX FB200_USB_AUDIO_EP_SIZE
#define CFG_TUD_AUDIO_FUNC_1_EP_OUT_SW_BUF_SZ (4u * CFG_TUD_AUDIO_FUNC_1_EP_OUT_SZ_MAX)
