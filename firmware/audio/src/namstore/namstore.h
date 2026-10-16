/* Runtime A2-Lite model slots. MIT, see project LICENSE. */
#ifndef FB200_NAMSTORE_H
#define FB200_NAMSTORE_H
#include <stdint.h>
#include "dsp/nam_a2.h"
#define NAMSTORE_BASE 0x00502000u
#define NAMSTORE_SLOTS 3u
#define NAMSTORE_BANK 8192u
#define NAMSTORE_END (NAMSTORE_BASE + NAMSTORE_SLOTS * 2u * NAMSTORE_BANK)
#define NAMSTORE_HEADER 64u
#define NAMSTORE_BYTES (NAMSTORE_HEADER + NAM_A2_WEIGHTS * 4u)
#define NAMSTORE_MAGIC 0x4d4e4246u /* FBNM */
/* Validates header, architecture/rate, finite weights and both CRCs.
 * 1 model, 2 tombstone, 0 invalid. Packet length is always NAMSTORE_BYTES. */
int namstore_valid(const uint8_t *record);
/* slot is 1..3. Returns latest valid bank or -1 (including a small chip).
 * A tombstone is current but not loadable; never resurrect its older bank. */
int namstore_current(unsigned slot);
const uint8_t *namstore_record(unsigned slot, unsigned bank);
int namstore_ready(void);
/* Caller owns an 8192-byte staging buffer. Packet validated before any write.
 * Commit writes alternate bank data, then header; old bank stays intact. */
int namstore_write(unsigned slot, uint8_t *staging);
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
