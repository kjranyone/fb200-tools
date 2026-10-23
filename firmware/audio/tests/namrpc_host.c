/* Host-only UI/engine boundary; storage and RPC are the actual firmware C. */
#include "namstore/namrpc.h"
#include "namstore/namstore.h"
#include "dsp/fx.h"
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
uint32_t namrpc_fx_describe(unsigned mode, uint8_t *out, uint32_t cap)
{ return fx_describe(mode, out, cap); }
static unsigned word_offset, word_value, word_writes;
int namrpc_edit_word(unsigned offset, uint16_t value)
{ word_offset = offset; word_value = value; word_writes++; return 0; }
unsigned fake_word(unsigned *value) { *value = word_value; return word_writes ? word_offset : 0u; }
