#include "namrpc.h"
#include <string.h>
#include "namstore.h"
#include "audio/engine.h"
#include "ui/ui.h"
#include "proto/proto.h"
#ifdef NAM_UTILITIES
uint32_t namrpc_tuner(uint8_t *out)
{
    tuner_result_t r;
    engine_tuner_latest(&r);
    out[0]=ui_settings()->b[S_TUNER]; out[1]=(uint8_t)(r.valid && !r.silent);
    out[2]=(uint8_t)r.note; out[3]=(uint8_t)r.octave;
    memcpy(out+4,&r.freq,4); memcpy(out+8,&r.cents,4); memcpy(out+12,&r.confidence,4);
    return 16;
}
#endif
uint32_t namrpc_levels(uint8_t *out)
{
    float v[3];
    engine_levels(v);
    memcpy(out,v,sizeof v);
    return sizeof v;
}
uint32_t proto_hook_nam(uint8_t src,const uint8_t *p,uint32_t n,uint8_t *out,uint32_t cap)
{ return namrpc_request(src,p,n,out,cap); }
unsigned namrpc_selected(void) { return engine_nam_selected(); }
int namrpc_select(unsigned slot,int save)
{
    int r=ui_nam_select(slot,!save);
    if(r) return r;
    return save?ui_save():0;
}
int namrpc_delete(unsigned slot)
{
    int r=namstore_delete(slot);
    if(!r && engine_nam_selected()==slot) return namrpc_select(0,0);
    return r;
}
