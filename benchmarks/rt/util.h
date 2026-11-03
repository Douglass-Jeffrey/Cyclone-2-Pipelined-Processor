/* stands in for riscv-tests' common/util.h: no CSRs, no printf */
#ifndef __UTIL_H
#define __UTIL_H
#include <stdint.h>
#include <stddef.h>
static inline void setStats(int enable) { (void)enable; }
static int verify(int n, const volatile int *test, const int *verify)
{
    for (int i = 0; i < n; i++)
        if (test[i] != verify[i]) return i + 1;
    return 0;
}
#define printf(...) ((void)0)
#endif
