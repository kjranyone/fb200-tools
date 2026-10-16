#ifndef FB200_NAMRPC_H
#define FB200_NAMRPC_H
#include <stdint.h>
/* E0 request: [version=1, op, request-id u16 LE, args...]
 * E1 reply:   [version=1, op, request-id u16 LE, status, data...]
 * Stop-and-wait; request IDs make retry of the last request idempotent.
 * ops: 0 caps, 1 slots, 2 begin, 3 chunk, 4 commit, 5 abort, 6 select, 7 delete. */
uint32_t namrpc_request(uint8_t source, const uint8_t *p, uint32_t n,
                        uint8_t *out, uint32_t cap);
void namrpc_task(void);
unsigned namrpc_selected(void);
int namrpc_select(unsigned slot, int save);
int namrpc_delete(unsigned slot);
#endif
