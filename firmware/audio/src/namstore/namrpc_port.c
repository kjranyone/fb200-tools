#include "namrpc.h"
#include "namstore.h"
#include "audio/engine.h"
#include "ui/ui.h"
#include "proto/proto.h"
uint32_t proto_hook_nam(uint8_t src,const uint8_t *p,uint32_t n,uint8_t *out,uint32_t cap)
{ return namrpc_request(src,p,n,out,cap); }
unsigned namrpc_selected(void) { return engine_nam_selected(); }
int namrpc_select(unsigned slot,int save)
{
    int r=(save && engine_nam_selected()==slot)?0:engine_nam_select(slot);
    if(r) return r;
    uint8_t record[4]={(uint8_t)NAM_MARK,(uint8_t)(NAM_MARK>>8),(uint8_t)slot,0};
    ui_edit_write(P_NAM_MARK,record,4);
    if(slot) { uint8_t en[2]={1,0}; ui_edit_write(P_AMP_EN,en,2); }
    return save?ui_save():0;
}
int namrpc_delete(unsigned slot)
{
    int r=namstore_delete(slot);
    if(!r && engine_nam_selected()==slot) return namrpc_select(0,0);
    return r;
}
