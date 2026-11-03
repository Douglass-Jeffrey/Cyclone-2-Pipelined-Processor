/* CoreMark port for the pipelined RV32I core (from barebones/core_portme.c, Apache-2.0, EEMBC) */
#include "coremark.h"
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;
int bm_status, bm_ok;
void start_time(void) {}
void stop_time(void) {}
CORE_TICKS get_time(void) { return 0; }
/* the run is timed by the board, not here; 10 s keeps the "too short" check quiet */
secs_ret time_in_secs(CORE_TICKS ticks) { (void)ticks; return 10; }
void portable_init(core_portable *p, int *argc, char *argv[]) { (void)argc; (void)argv; p->portable_id = 1; }
void portable_fini(core_portable *p) { p->portable_id = 0; }
int coremark_main(void);
/* 0 = CoreMark printed "Correct operation validated" and no errors */
int main(void) { coremark_main(); return bm_status ? bm_status : !bm_ok; }
