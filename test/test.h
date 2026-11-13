/* What the parts of the QEMU check share (scripts/check-dist.sh). */
#ifndef TEST_H
#define TEST_H

#ifdef __cplusplus
extern "C" {
#endif

struct s12 { int a, b, c; };      /* in R1-R3 (both conventions) */
struct s6 { char c[6]; };         /* always on the stack */

void check(int id, int got, int want);       /* main.c */

int asm_sum3(int a, int b, int c);           /* asm.s */
int asm_fifth(int a, int b, int c, long long d, int e);

int c_fifth(int a, int b, int c, long long d, int e);   /* other.c */
int c_ext(signed char a, unsigned short b);
struct s12 c_make(int x);
int c_sum6(struct s6 s, int x);
int c_ptr_sum(const struct s12 *a, const struct s6 *b);

void cxx_tests(void);                        /* cxx.cpp */
void rt_tests(void);                         /* rt.c */

#ifdef __cplusplus
}
#endif

#endif
