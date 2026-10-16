#include "namstore.h"
#include "debug/flash_rmw.h"
#include "debug/selfupdate.h"
#include "tusb.h"
_Static_assert(NAMSTORE_BASE == FLASH_NAM_BASE && NAMSTORE_END == FLASH_NAM_LIMIT,
               "NAM write range mismatch");
_Static_assert(NAMSTORE_BASE == FLASH_IRSTORE_LIMIT && NAMSTORE_END <= FLASH_LOOP_META,
               "NAM must not overlap IR or looper data");
static uint8_t staging[NAMSTORE_BANK] __attribute__((section(".ocram"), aligned(4)));
const uint8_t *namstore_map(uint32_t off) { return (const uint8_t *)(0x60000000u+off); }
uint32_t namstore_capacity(void) { return flash_capacity(); }
int namstore_flash_write(uint32_t off, const void *p, uint32_t n) { return flash_store(off,p,n); }
uint8_t *namstore_buffer(void) { return staging; }
uint32_t namstore_rx(uint8_t *p, uint32_t n) { return tud_cdc_read(p,n); }
extern uint32_t tusb_time_millis_api(void);
uint32_t namstore_now(void) { return tusb_time_millis_api(); }
