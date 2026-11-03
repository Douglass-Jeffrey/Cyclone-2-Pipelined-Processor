/* stands in for riscv-tests' util.h for Dhrystone: no CSRs, no output */
#ifndef __UTIL_H
#define __UTIL_H
static long bm_clock;
#define read_csr(r) (bm_clock += 1000000)
#define setStats(e) ((void)0)
#define debug_printf(...) ((void)0)
#define printf(...) ((void)0)
#endif
