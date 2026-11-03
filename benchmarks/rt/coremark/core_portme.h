/* CoreMark port for the pipelined RV32I core (from barebones/core_portme.h,
   Apache-2.0, EEMBC).  No printf, no timer: cycles come from the board's
   counters.  ee_printf keeps only the final verdict, read from the first two
   characters of the format string, which GCC folds, so no strings are kept. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H
#include <stddef.h>
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define COMPILER_VERSION "GCC"
#define COMPILER_FLAGS "-O2"
#define MEM_LOCATION "STATIC"
typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef double ee_f32;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef ee_u32 ee_ptr_int;
typedef size_t ee_size_t;
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))
#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
extern ee_u32 default_num_contexts;
typedef struct CORE_PORTABLE_S { ee_u8 portable_id; } core_portable;
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#define PERFORMANCE_RUN 1
#endif
extern int bm_status, bm_ok;
#define BM_FMT(f, ...) (f)
#define ee_printf(...) ((void)(                                                   \
    (BM_FMT(__VA_ARGS__, 0)[0] == 'E' && BM_FMT(__VA_ARGS__, 0)[1] == 'r') ? (bm_status = 1) :  \
    (BM_FMT(__VA_ARGS__, 0)[0] == 'C' && BM_FMT(__VA_ARGS__, 0)[1] == 'a') ? (bm_status = 2) :  \
    (BM_FMT(__VA_ARGS__, 0)[0] == 'C' && BM_FMT(__VA_ARGS__, 0)[1] == 'o') ? (bm_ok = 1) : 0))
#endif
