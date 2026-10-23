/* Reuse the NOR busy/pump harness, exercise the NAM-specific allowlist. */
#define main stock_suite_main
#include "flash_rmw_host_test.c"
#undef main
int main(void) {
    test_write(); test_rejects(); test_failures();
    uint8_t byte=42;
    reset_counters();
    CHECK(flash_rmw(FLASH_NAM_BASE,&byte,1)==0,"NAM first byte");
    CHECK(flash_rmw(FLASH_NAM_LIMIT-1,&byte,1)==0,"NAM last byte");
    CHECK(flash_rmw(FLASH_NAM_LIMIT,&byte,1)==-1,"NAM exclusive end");
    CHECK(flash_rmw(FLASH_NAM_LIMIT-1,&byte,2)==-1,"NAM crossing end");
    CHECK(pumps==busy_polls && !violations,"audio pump remains RAM-only");
    reset_counters(); capacity=FLASH_NAM_LIMIT-1;
    CHECK(flash_rmw(FLASH_NAM_BASE,&byte,1)==-1 && !erases,"small chip");
    puts(fails?"NAM RMW FAILED":"NAM RMW OK");
    return fails?1:0;
}
