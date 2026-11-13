/* C functions that main.c calls from another translation unit
   (scripts/check-dist.sh). c_fifth and c_sum6 are the cases where CC-RX's
   and GNURX's conventions place an argument differently, so this object
   and main.o carry a .note.rx.abi that says which one they use; ld.lld
   refuses to link them when they differ. */
#include "test.h"

int c_fifth(int a, int b, int c, long long d, int e) {
  return a + b + c - 6 + (int)d + e;
}

/* The caller and the callee both extend char / short arguments. */
int c_ext(signed char a, unsigned short b) { return a + b; }

struct s12 c_make(int x) {
  struct s12 s = {x, x + 1, x + 2};
  return s;
}

/* s is on the stack: in CC-RX's convention x is in R1, in GNURX's in R3. */
int c_sum6(struct s6 s, int x) {
  int sum = 0;
  for (int i = 0; i < 6; i++)
    sum += s.c[i];
  return sum + x;
}

int c_ptr_sum(const struct s12 *a, const struct s6 *b) {
  return a->a + a->b * 10 + a->c * 100 + c_sum6(*b, 0);
}
