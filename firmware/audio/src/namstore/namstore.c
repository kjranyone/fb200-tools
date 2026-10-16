#include "namstore.h"
#include "crc32.h"
#include "debug/cdc_log.h"
#include <string.h>

static uint32_t get32(const uint8_t *p)
{ return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static void put32(uint8_t *p, uint32_t v)
{ for (unsigned i=0; i<4; i++) p[i] = (uint8_t)(v >> (i*8)); }
static void seal(uint8_t *p) { put32(p+60, crc32_ieee(p, 60)); }

int namstore_ready(void) { return namstore_capacity() >= NAMSTORE_END; }
const uint8_t *namstore_record(unsigned slot, unsigned bank)
{
    if (!namstore_ready() || slot < 1 || slot > NAMSTORE_SLOTS || bank > 1) return 0;
    return namstore_map(NAMSTORE_BASE + ((slot-1)*2+bank)*NAMSTORE_BANK);
}

int namstore_valid(const uint8_t *p)
{
    if (!p || get32(p) != NAMSTORE_MAGIC || p[4] != 1 || p[5] || p[6] != 2 || p[7] ||
        get32(p+8) != NAM_A2_RATE || get32(p+60) != crc32_ieee(p, 60)) return 0;
    if (get32(p+48) == 1 && get32(p+12) == 0 && get32(p+16) == 0) return 2;
    if (get32(p+48) || get32(p+12) != NAM_A2_WEIGHTS || !p[24] || p[47]) return 0;
    for (unsigned i=24; i<47 && p[i]; i++) if (p[i] < 33 || p[i] > 126) return 0;
    for (unsigned i=52; i<60; i++) if (p[i]) return 0;
    if (crc32_ieee(p+NAMSTORE_HEADER, NAM_A2_WEIGHTS*4) != get32(p+16)) return 0;
    for (unsigned i=0; i<NAM_A2_WEIGHTS; i++) {
        /* Reject IEEE754 exponent 255: no floating-point interpretation of
         * potentially unaligned/untrusted input and no NaN/Inf in a model. */
        if ((get32(p+NAMSTORE_HEADER+i*4) & 0x7f800000u) == 0x7f800000u) return 0;
    }
    return 1;
}

int namstore_current(unsigned slot)
{
    const uint8_t *a = namstore_record(slot, 0), *b = namstore_record(slot, 1);
    int va = namstore_valid(a), vb = namstore_valid(b);
    if (va && vb) return (int32_t)(get32(b+20)-get32(a+20)) > 0 ? 1 : 0;
    return vb ? 1 : va ? 0 : -1;
}

int namstore_write(unsigned slot, uint8_t *buf)
{
    if (!namstore_ready() || slot < 1 || slot > NAMSTORE_SLOTS || !namstore_valid(buf)) return -1;
    int old = namstore_current(slot), bank = old == 0 ? 1 : 0;
    uint32_t seq = old < 0 ? 1 : get32(namstore_record(slot, (unsigned)old)+20)+1;
    uint8_t header[NAMSTORE_HEADER];
    memcpy(header, buf, sizeof header);
    put32(header+20, seq);
    seal(header);
    memset(buf, 0xff, NAMSTORE_HEADER); /* invalid until the final header commit */
    memset(buf+NAMSTORE_BYTES, 0xff, NAMSTORE_BANK-NAMSTORE_BYTES);
    uint32_t off = NAMSTORE_BASE + ((slot-1)*2+(unsigned)bank)*NAMSTORE_BANK;
    for (unsigned sector=0; sector<2; sector++)
        if (namstore_flash_write(off+sector*4096u, buf+sector*4096u, 4096u)) return -2;
    if (namstore_flash_write(off, header, sizeof header)) return -2;
    return namstore_current(slot) == bank ? 0 : -3;
}

static struct { unsigned slot, rx; uint32_t crc, last; int active; } session;

int namstore_delete(unsigned slot)
{
    if (session.active || slot < 1 || slot > NAMSTORE_SLOTS || !namstore_ready()) return -1;
    uint8_t *p = namstore_buffer();
    memset(p, 0, NAMSTORE_BANK);
    put32(p, NAMSTORE_MAGIC);
    p[4] = 1; p[6] = 2;
    put32(p+8, NAM_A2_RATE);
    put32(p+48, 1);
    seal(p);
    return namstore_write(slot, p);
}

int namstore_begin(unsigned slot, uint32_t bytes, uint32_t crc)
{
    if (session.active || !namstore_ready() || slot < 1 || slot > NAMSTORE_SLOTS ||
        bytes != NAMSTORE_BYTES) { log_printf("nam: refused (slot/size/busy/capacity)\r\n"); return -1; }
    session.slot = slot; session.rx = 0; session.crc = crc;
    session.last = namstore_now(); session.active = 1;
    log_printf("nam ready\r\n");
    return 0;
}

int namstore_active(void) { return session.active; }
int namstore_console_active(void) { return session.active == 1; }
int namstore_framed_begin(unsigned slot, uint32_t bytes, uint32_t crc)
{
    if (session.active || !namstore_ready() || slot < 1 || slot > NAMSTORE_SLOTS ||
        bytes != NAMSTORE_BYTES) return -1;
    session.slot=slot; session.rx=0; session.crc=crc;
    session.last=namstore_now(); session.active=2;
    return 0;
}
unsigned namstore_received(void) { return session.rx; }
int namstore_framed_feed(unsigned offset, const uint8_t *data, unsigned n)
{
    if (session.active != 2 || !n || n>64 || offset>session.rx ||
        offset>NAMSTORE_BYTES || n>NAMSTORE_BYTES-offset) return -1;
    uint8_t *p=namstore_buffer();
    if (offset<session.rx) {
        if (n>session.rx-offset || memcmp(p+offset,data,n)) return -1;
    } else { memcpy(p+offset,data,n); session.rx+=n; }
    session.last=namstore_now();
    return 0;
}
int namstore_framed_finish(void)
{
    if (session.active!=2 || session.rx!=NAMSTORE_BYTES) return -1;
    uint8_t *p=namstore_buffer();
    int result = crc32_ieee(p,NAMSTORE_BYTES)==session.crc && namstore_valid(p)==1
        ? namstore_write(session.slot,p) : -4;
    session.active=0;
    return result;
}
void namstore_framed_abort(void) { if (session.active==2) session.active=0; }
void namstore_task(void)
{
    if (!session.active) return;
    if (session.active==2) {
        if ((uint32_t)(namstore_now()-session.last)>=3000u) session.active=0;
        return;
    }
    uint8_t *p = namstore_buffer();
    uint32_t got = namstore_rx(p+session.rx, NAMSTORE_BYTES-session.rx);
    session.rx += got;
    if (got) session.last = namstore_now();
    if (session.rx == NAMSTORE_BYTES) {
        int result = -1;
        if (crc32_ieee(p, NAMSTORE_BYTES) == session.crc && namstore_valid(p) == 1)
            result = namstore_write(session.slot, p);
        session.active = 0;
        log_printf("nam done %s slot %u\r\n", result == 0 ? "ok" : "FAILED", session.slot);
    } else if ((uint32_t)(namstore_now()-session.last) >= 3000u) {
        session.active = 0;
        log_printf("nam aborted timeout\r\n");
    }
}

void namstore_list(void)
{
    if (!namstore_ready()) { log_printf("nam: unavailable (flash capacity)\r\n"); return; }
    for (unsigned slot=1; slot<=NAMSTORE_SLOTS; slot++) {
        int bank = namstore_current(slot);
        const uint8_t *p = bank < 0 ? 0 : namstore_record(slot, (unsigned)bank);
        if (namstore_valid(p) == 1)
            log_printf("nam %u rate 48000 name %s\r\n", slot, (const char *)p+24);
    }
    log_printf("nam slots: 3\r\n");
}
