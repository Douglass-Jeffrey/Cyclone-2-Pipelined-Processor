/* the few libc routines GCC and the benchmarks call */
#include <stddef.h>
void *memcpy(void *d, const void *s, size_t n) { char *p = d; const char *q = s; while (n--) *p++ = *q++; return d; }
void *memmove(void *d, const void *s, size_t n) {
    char *p = d; const char *q = s;
    if (p < q) while (n--) *p++ = *q++; else { p += n; q += n; while (n--) *--p = *--q; }
    return d;
}
void *memset(void *d, int c, size_t n) { char *p = d; while (n--) *p++ = (char)c; return d; }
int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *p = a, *q = b;
    for (; n; n--, p++, q++) if (*p != *q) return *p - *q;
    return 0;
}
size_t strlen(const char *s) { const char *p = s; while (*p) p++; return p - s; }
int strcmp(const char *a, const char *b) { while (*a && *a == *b) a++, b++; return (unsigned char)*a - (unsigned char)*b; }
char *strcpy(char *d, const char *s) { char *p = d; while ((*p++ = *s++)); return d; }
int strncmp(const char *a, const char *b, size_t n) {
    for (; n; n--, a++, b++) { if (*a != *b) return (unsigned char)*a - (unsigned char)*b; if (!*a) return 0; }
    return 0;
}
char *strchr(const char *s, int c) { for (;; s++) { if (*s == (char)c) return (char *)s; if (!*s) return 0; } }

/* newlib's ctype table (ctype.h macros index _ctype_ + 1) */
const char _ctype_[257] = {
    [1 + 0 ... 1 + 31] = 040, [1 + ' '] = 0210, [1 + 9 ... 1 + 13] = 050, [1 + 127] = 040,
    [1 + '!' ... 1 + '/'] = 020, [1 + ':' ... 1 + '@'] = 020, [1 + '[' ... 1 + '`'] = 020, [1 + '{' ... 1 + '~'] = 020,
    [1 + '0' ... 1 + '9'] = 04, [1 + 'A' ... 1 + 'F'] = 0101, [1 + 'G' ... 1 + 'Z'] = 01,
    [1 + 'a' ... 1 + 'f'] = 0102, [1 + 'g' ... 1 + 'z'] = 02,
};

/* bump allocator in the data region, between .bss and the stack */
extern char __bss_end[];
static char *heap = __bss_end;
void *malloc(size_t n) { void *p = heap; heap += (n + 3) & ~3u; return p; }
void free(void *p) { (void)p; }
