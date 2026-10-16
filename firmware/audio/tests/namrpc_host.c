/* Host-only UI/engine boundary; storage and RPC are the actual firmware C. */
#include "namstore/namrpc.h"
#include "namstore/namstore.h"
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
unsigned fake_saved(void) { return saved; }
