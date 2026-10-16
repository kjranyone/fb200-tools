#include "namstore/namstore.h"
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <assert.h>
static uint8_t flash[0x800000], buffer[NAMSTORE_BANK], rx[NAMSTORE_BANK];
static unsigned rx_n, rx_at, chunk=64, capacity=0x800000, now, writes;
static int cut=-1;
static char output[8192];
void log_printf(const char *fmt, ...) {
    va_list args; va_start(args,fmt);
    vsnprintf(output+strlen(output),sizeof output-strlen(output),fmt,args); va_end(args);
}
const char *fake_log(void) { return output; }
void fake_reset(void) {
    rx_n=rx_at=0; now+=4000; namstore_task();
    memset(flash,0xff,sizeof flash); memset(buffer,0,sizeof buffer); output[0]=0;
    rx_n=rx_at=now=writes=0; cut=-1; capacity=sizeof flash; chunk=64;
}
const uint8_t *namstore_map(uint32_t off) { assert(off < sizeof flash); return flash+off; }
uint32_t namstore_capacity(void) { return capacity; }
uint8_t *namstore_buffer(void) { return buffer; }
uint32_t namstore_now(void) { return now; }
uint32_t namstore_rx(uint8_t *p, uint32_t max) {
    unsigned n=rx_n-rx_at; if(n>max)n=max; if(n>chunk)n=chunk;
    memcpy(p,rx+rx_at,n); rx_at+=n; return n;
}
int namstore_flash_write(uint32_t off, const void *data, uint32_t bytes) {
    assert(off >= NAMSTORE_BASE && off+bytes <= NAMSTORE_END);
    assert(bytes && (off&4095u)+bytes<=4096u);
    uint8_t tmp[4096]; unsigned sector=off&~4095u;
    memcpy(tmp,flash+sector,4096); memcpy(tmp+(off&4095u),data,bytes);
    memset(flash+sector,0xff,4096); writes++;
    unsigned n=cut<0?4096u:(unsigned)cut<4096u?(unsigned)cut:4096u;
    memcpy(flash+sector,tmp,n); if(cut>=0)cut-=(int)n;
    return n==4096?0:-1;
}
void fake_cut(int n) { cut=n; }
void fake_capacity(unsigned n) { capacity=n; }
unsigned fake_writes(void) { return writes; }
void fake_time(unsigned n) { now=n; }
void fake_chunk(unsigned n) { chunk=n; }
void fake_feed(const uint8_t *p, unsigned n) { assert(n<=sizeof rx); memcpy(rx,p,n); rx_n=n;rx_at=0; }
uint8_t *fake_flash(void) { return flash; }
