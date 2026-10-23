#include "namrpc.h"
#include "namstore.h"
#include "crc32.h"
#include <string.h>
static uint32_t rd(const uint8_t *p, unsigned n)
{ uint32_t v=0; for(unsigned i=0;i<n;i++) v|=(uint32_t)p[i]<<(i*8); return v; }
static void wr(uint8_t *p,uint32_t v,unsigned n)
{ for(unsigned i=0;i<n;i++) p[i]=(uint8_t)(v>>(i*8)); }
static uint32_t token, generation;
static uint8_t owner;
/* The largest list page is (cap - 2) / 30 records; the target passes
 * PROTO_MAX_LEN (1018) -> 33 records. 1024 covers any page we build. */
static uint8_t cached[1024];
static uint32_t cached_n, cached_hash;
static uint16_t cached_id;
static uint8_t cached_source;
__attribute__((weak)) uint32_t namrpc_tuner(uint8_t *out) { (void)out; return 0; }
__attribute__((weak)) uint32_t namrpc_levels(uint8_t *out) { (void)out; return 0; }

void namrpc_task(void)
{
    /* CDC owns its own reader; framed transfers only need inactivity expiry. */
    if (!namstore_console_active()) namstore_task();
    if (!namstore_active()) { token=0; owner=0; }
}

uint32_t namrpc_request(uint8_t source,const uint8_t *p,uint32_t n,uint8_t *out,uint32_t cap)
{
    if (n<4 || n>80 || cap<128 || (source!=1 && source!=2)) return 0;
    namrpc_task();
    uint16_t id=(uint16_t)rd(p+2,2);
    uint32_t hash=crc32_ieee(p,n);
    if(cached_n && source==cached_source && id==cached_id && hash==cached_hash) {
        memcpy(out,cached,cached_n); return cached_n;
    }
    memcpy(out,p,4); out[0]=1; out[4]=0;
    uint32_t size=5;
    const uint8_t *a=p+4; unsigned len=n-4;
    if(p[0]!=1) { out[4]=5; goto done; }
    if(!namstore_ready()) { out[4]=4; goto done; }
    switch(p[1]) {
    case 0: /* capabilities: rate u32, weights u16, slots, chunk, bytes u16, flags u16, selected */
        if(len) { out[4]=1; break; }
        wr(out+5,NAM_A2_RATE,4); wr(out+9,NAM_A2_WEIGHTS,2);
        out[11]=NAMSTORE_SLOTS; out[12]=64;
        wr(out+13,NAMSTORE_BYTES,2);
        /* bits: 0 framed upload, 1 select/save, 2 delete, 3 drums+tuner,
         * 4 rename (op 9), 5 paged list (op 1 takes a start index),
         * 6 looper (0xD7 control), 7 stock cab/MOD/reverb in the chain,
         * 8 Bluetooth audio mixed in (`nam-manager`),
         * 9 NAM amp-word tone EQ is connected to the audio path,
         * 10 level peaks (op 10), 11 NAM GAIN spans -18..+18 dB,
         * 12 model kind byte (ops 11/12, header byte 52),
         * 13 second NAM before the first (preset words 0xE2..0xE9) */
#ifdef NAM_UTILITIES
        wr(out+15,15|16|32|64|128|256|512|1024|2048|4096|8192,2);
#else
        wr(out+15,7|16|32|512|1024|2048|4096|8192,2);
#endif
        out[17]=(uint8_t)namrpc_selected(); size=18; break;
    case 1: /* list page [start:u8, 0-based]: [selected][start][count] then
     * count records of {slot:u8, used:u8, name 24, payloadCRC:u32} */
        if(len!=1 || a[0]>=NAMSTORE_SLOTS) { out[4]=1; break; }
        {
            unsigned page=(cap-8u)/30u;
            if(page>NAMSTORE_SLOTS-(unsigned)a[0]) page=NAMSTORE_SLOTS-a[0];
            out[size++]=(uint8_t)namrpc_selected();
            out[size++]=(uint8_t)a[0];
            out[size++]=(uint8_t)page;
            for(unsigned i=0;i<page;i++) {
                unsigned slot=(unsigned)a[0]+1u+i;
                int bank=namstore_current(slot);
                const uint8_t *r=bank<0?0:namstore_record(slot,(unsigned)bank);
                int used=namstore_valid(r)==1;
                out[size++]=(uint8_t)slot; out[size++]=(uint8_t)used;
                memset(out+size,0,28);
                if(used) { memcpy(out+size,r+24,24); memcpy(out+size+24,r+16,4); }
                size+=28;
            }
        }
        break;
    case 2:
        if(len!=7 || a[0]<1 || a[0]>NAMSTORE_SLOTS || rd(a+1,2)!=NAMSTORE_BYTES) { out[4]=1; break; }
        if(namstore_active()) { out[4]=2; break; }
        if(namstore_framed_begin(a[0],rd(a+1,2),rd(a+3,4))) { out[4]=4; break; }
        generation++; if(!generation) generation++;
        token=generation; owner=source;
        wr(out+5,token,4); wr(out+9,0,2); size=11; break;
    case 3: case 4: case 5:
        if(len<4 || !token || owner!=source || rd(a,4)!=token || !namstore_active())
            { out[4]=6; break; }
        if(p[1]==3) {
            if(len<7 || len>70 || namstore_framed_feed(rd(a+4,2),a+6,len-6))
                { out[4]=1; break; }
            wr(out+5,token,4); wr(out+9,namstore_received(),2); size=11;
        } else if(len!=4) out[4]=1;
        else if(p[1]==5) { namstore_framed_abort(); token=0; owner=0; }
        else {
            int r=namstore_framed_finish();
            out[4]=r==0?0:r==-4?3:r==-1?1:4;
            if(!namstore_active()) { token=0; owner=0; }
        }
        break;
    case 6:
        if(len!=2 || a[0]>NAMSTORE_SLOTS || a[1]>1) { out[4]=1; break; }
        if(namstore_active()) { out[4]=2; break; }
        out[4]=namrpc_select(a[0],a[1])?4:0; break;
    case 7:
        if(len!=1 || a[0]<1 || a[0]>NAMSTORE_SLOTS) { out[4]=1; break; }
        if(namstore_active()) { out[4]=2; break; }
        out[4]=namrpc_delete(a[0])?4:0; break;
    case 9: /* rename: [slot][name 24, NUL padded] */
        if(len!=25 || a[0]<1 || a[0]>NAMSTORE_SLOTS) { out[4]=1; break; }
        if(namstore_active()) { out[4]=2; break; }
        { int r=namstore_rename(a[0],a+1);
          out[4]=r==0?0:(r==-2||r==-3)?4:1; }
        break;
    case 8:
        if(len) { out[4]=1; break; }
        { uint32_t count=namrpc_tuner(out+5);
          if(count) size+=count; else out[4]=5; }
        break;
    case 10: /* level peaks since the last read: input, NAM input, output (f32) */
        if(len) { out[4]=1; break; }
        { uint32_t count=namrpc_levels(out+5);
          if(count) size+=count; else out[4]=5; }
        break;
    case 11: /* kinds: one byte per slot 1..64, 0 for an empty slot */
        if(len) { out[4]=1; break; }
        for(unsigned slot=1;slot<=NAMSTORE_SLOTS;slot++) {
            int kind=namstore_kind(slot);
            out[size++]=(uint8_t)(kind<0?0:kind);
        }
        break;
    case 12: /* set kind: [slot][kind] */
        if(len!=2 || a[0]<1 || a[0]>NAMSTORE_SLOTS) { out[4]=1; break; }
        if(namstore_active()) { out[4]=2; break; }
        { int r=namstore_set_kind(a[0],a[1]);
          out[4]=r==0?0:(r==-2||r==-3)?4:1; }
        break;
    default: out[4]=5; break;
    }
done:
    memcpy(cached,out,size); cached_n=size; cached_id=id;
    cached_source=source; cached_hash=hash;
    return size;
}
