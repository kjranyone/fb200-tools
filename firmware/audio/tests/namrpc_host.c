/* Host-only UI/engine boundary; storage and RPC are the actual firmware C. */
#include "namstore/namrpc.h"
#include "namstore/namstore.h"
#include <string.h>
static unsigned selected, saved;
unsigned namrpc_selected(void) { return selected; }
int namrpc_select(unsigned slot, int save)
{
    if (slot) {
        int bank=namstore_current(slot);
        if (bank<0 || namstore_valid(namstore_record(slot,(unsigned)bank))!=1) return -1;
    }
    selected=slot; saved+=(unsigned)save; return 0;
}
int namrpc_delete(unsigned slot)
{
    int r=namstore_delete(slot);
    if (!r && selected==slot) selected=0;
    return r;
}
void fake_selection_reset(void) { selected=saved=0; }
static float levels[3];
void fake_levels(float in, float nam, float out) { levels[0]=in; levels[1]=nam; levels[2]=out; }
uint32_t namrpc_levels(uint8_t *out)
{ memcpy(out,levels,sizeof levels); memset(levels,0,sizeof levels); return sizeof levels; }
unsigned fake_saved(void) { return saved; }
