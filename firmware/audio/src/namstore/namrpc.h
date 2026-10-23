#ifndef FB200_NAMRPC_H
#define FB200_NAMRPC_H
#include <stdint.h>
/* E0 request: [version=1, op, request-id u16 LE, args...]
 * E1 reply:   [version=1, op, request-id u16 LE, status, data...]
 * Stop-and-wait; request IDs make retry of the last request idempotent.
 * ops: 0 caps, 1 list page [start], 2 begin, 3 chunk, 4 commit, 5 abort,
 * 6 select, 7 delete, 8 tuner snapshot, 9 rename, 10 level peaks,
 * 11 model kinds, 12 set kind, 14 FX mode descriptor, 15 set a preset-tail word.
 * 64 slots (flash_rmw.h). */
uint32_t namrpc_request(uint8_t source, const uint8_t *p, uint32_t n,
                        uint8_t *out, uint32_t cap);
void namrpc_task(void);
unsigned namrpc_selected(void);
int namrpc_select(unsigned slot, int save);
int namrpc_delete(unsigned slot);
uint32_t namrpc_tuner(uint8_t *out);
uint32_t namrpc_levels(uint8_t *out);
uint32_t namrpc_fx_describe(unsigned mode, uint8_t *out, uint32_t cap);
int namrpc_edit_word(unsigned offset, uint16_t value);
#endif
