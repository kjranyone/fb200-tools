/* Runtime A2-Lite model slots. MIT, see project LICENSE. */
#ifndef FB200_NAMSTORE_H
#define FB200_NAMSTORE_H
#include <stdint.h>
#include "dsp/nam_a2.h"
#define NAMSTORE_BASE 0x00400000u
/* 64 slots x two 8 KiB banks = 1 MiB: F:0x400000..0x4FFFFF, the former long
 * IR store area (unused by the NAM audio chain). The long IR store is not
 * compiled into NAM builds; 0x500000..0x50DFFF stays spare and the guard
 * sector before the looper metadata remains. */
#define NAMSTORE_SLOTS 64u
#define NAMSTORE_BANK 8192u
#define NAMSTORE_END (NAMSTORE_BASE + NAMSTORE_SLOTS * 2u * NAMSTORE_BANK)
#define NAMSTORE_HEADER 64u
#define NAMSTORE_BYTES (NAMSTORE_HEADER + NAM_A2_WEIGHTS * 4u)
#define NAMSTORE_MAGIC 0x4d4e4246u /* FBNM */
/* Header byte 52: what the capture is (0 unknown, 1 amp + cab, 2 amp, 3 cab,
 * 4 pedal, 5 outboard, 6 space, 7 experimental; docs/NAM_BLE_PROTOCOL.md).
 * Any value is stored; 53..59 stay reserved zero. */
#define NAMSTORE_KIND 52u
/* Validates header, architecture/rate, finite weights and both CRCs.
 * 1 model, 2 tombstone, 0 invalid. Packet length is always NAMSTORE_BYTES. */
int namstore_valid(const uint8_t *record);
/* slot is 1..3. Returns latest valid bank or -1 (including a small chip).
 * A tombstone is current but not loadable; never resurrect its older bank. */
int namstore_current(unsigned slot);
/* Validated current bank contains a model (not empty/corrupt/tombstoned). */
int namstore_is_model(unsigned slot);
/* Changes before every attempted flash mutation, including failed writes.
 * Main-loop catalog readers must discard their cached slot list on change. */
uint32_t namstore_revision(void);
const uint8_t *namstore_record(unsigned slot, unsigned bank);
int namstore_ready(void);
/* Caller owns an 8192-byte staging buffer. Packet validated before any write.
 * Commit writes alternate bank data, then header; old bank stays intact. */
int namstore_write(unsigned slot, uint8_t *staging);
/* Rewrites the stored slot under a new name by committing the unchanged
 * packet to the alternate bank (old bank stays valid until the header
 * commit). Name: 1..23 printable bytes at 33..126, NUL padded to 24. */
int namstore_rename(unsigned slot, const uint8_t *name);
/* Rewrites the stored slot with a new kind byte, like rename. */
int namstore_set_kind(unsigned slot, uint8_t kind);
/* Kind byte of a stored model, -1 for an empty/tombstoned/invalid slot. */
int namstore_kind(unsigned slot);
int namstore_delete(unsigned slot);
int namstore_begin(unsigned slot, uint32_t bytes, uint32_t crc);
int namstore_active(void);
int namstore_console_active(void);
/* Framed BLE/HID upload shares the staging-buffer lock with USB CDC. */
int namstore_framed_begin(unsigned slot, uint32_t bytes, uint32_t crc);
int namstore_framed_feed(unsigned offset, const uint8_t *data, unsigned n);
unsigned namstore_received(void);
int namstore_framed_finish(void);
void namstore_framed_abort(void);
void namstore_task(void);
void namstore_list(void);
/* Target hooks; host tests supply fake NOR, USB and time. */
const uint8_t *namstore_map(uint32_t offset);
uint32_t namstore_capacity(void);
int namstore_flash_write(uint32_t offset, const void *data, uint32_t bytes);
uint8_t *namstore_buffer(void);
uint32_t namstore_rx(uint8_t *dst, uint32_t max);
uint32_t namstore_now(void);
#endif
