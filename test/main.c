/* The C side of the QEMU check (scripts/check-dist.sh). It uses only
   clang's resource headers (no C library), calls C in another translation
   unit (other.c), assembly (asm.s) and C++ (cxx.cpp), and records the
   results in the variables below, which check-dist.sh reads through the
   QEMU monitor.

   WANT_ABI is the calling convention check-dist.sh asked for: 1 CC-RX's
   (no -mabi, or -mabi=ccrx), 2 GNURX's (-mabi=gnu). */
#include <float.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "test.h"

#if !defined(__RX__) || !defined(__RX_LITTLE_ENDIAN__) || !defined(__RX_ABI__)
#error "not compiling for rx-none-elf"
#endif
#if WANT_ABI == 1
#if !defined(__RX_CCRX_ABI__) || defined(__RX_GNU_ABI__)
#error "CC-RX's convention: want __RX_CCRX_ABI__ and no __RX_GNU_ABI__"
#endif
_Static_assert(sizeof(wchar_t) == 2, "CC-RX's wchar_t is unsigned short");
_Static_assert((wchar_t)-1 > 0, "CC-RX's wchar_t is unsigned short");
#elif WANT_ABI == 2
#if !defined(__RX_GNU_ABI__) || defined(__RX_CCRX_ABI__)
#error "GNURX's convention: want __RX_GNU_ABI__ and no __RX_CCRX_ABI__"
#endif
_Static_assert(sizeof(wchar_t) == 4, "GNURX's wchar_t is long");
#else
#error "WANT_ABI must be 1 (CC-RX) or 2 (GNURX)"
#endif
/* The types both conventions share (GCC's and CC-RX's). */
_Static_assert(sizeof(int) == 4 && sizeof(long) == 4 && sizeof(long long) == 8, "");
_Static_assert(sizeof(void *) == 4 && sizeof(size_t) == 4, "");
_Static_assert(sizeof(double) == 8 && DBL_MANT_DIG == 53, "clang: 64-bit double");
_Static_assert(_Alignof(long long) == 4 && _Alignof(double) == 4, "");
_Static_assert(CHAR_MIN == 0, "plain char is unsigned");
_Static_assert(_Generic((int32_t)0, long: 1, default: 0), "int32_t is long");
_Static_assert(INT32_MAX == 0x7fffffff && UINT64_MAX == 0xffffffffffffffffULL, "");

volatile int checks, failures, first_failure, got_value, want_value;

void check(int id, int got, int want) {
  checks++;
  if (got != want && failures++ == 0) {
    first_failure = id;
    got_value = got;
    want_value = want;
  }
}

static __attribute__((noinline)) int vsum(int n, ...) {
  va_list ap;
  int s = 0;
  va_start(ap, n);
  for (int i = 0; i < n; i++) {
    if (i == 2)
      s += (int)(va_arg(ap, long long) >> 32);
    else
      s += va_arg(ap, int);
  }
  va_end(ap);
  return s;
}

static __attribute__((noinline)) int classify(int x) {
  switch (x) {
  case 0: return 10;
  case 1: return 21;
  case 2: return 32;
  case 3: return 43;
  case 4: return 54;
  case 5: return 65;
  case 7: return 87;
  default: return -1;
  }
}

/* Values the optimizer cannot see through. */
static volatile int v3 = 3, v4 = 4, v5 = 5;
static volatile signed char vsc = -7;
static volatile unsigned short vus = 60000;
static volatile long long vll = 0x123456789LL;
static volatile float vf = 1.5f;
static volatile bool vtrue = true;

int main(void) {
  /* Assembly. */
  check(1, asm_sum3(1, 20, 300), 321);
  check(2, asm_fifth(1, 2, 3, 0x500000007LL, 40), 47);
  /* C in the other translation unit, including the argument that the two
     conventions place differently. */
  check(3, c_fifth(1, 2, 3, 0x500000007LL, 40), 47);
  check(4, c_ext(vsc, vus), 60000 - 7);
  struct s12 s = c_make(v3);
  check(5, s.a + s.b * 10 + s.c * 100, 3 + 40 + 500);
  struct s6 t = {{1, 2, 3, 4, 5, 6}};
  check(6, c_sum6(t, v4), 21 + 4);
  check(7, c_ptr_sum(&s, &t), 543 + 21);
  /* Here. */
  check(8, vsum(4, 1, 2, 0x700000000LL, 9), 1 + 2 + 7 + 9);
  int sw = 0;
  for (int i = 0; i < 9; i++)
    sw += classify(i);
  check(9, sw, 10 + 21 + 32 + 43 + 54 + 65 - 1 + 87 - 1);
  check(10, (int)((vll + vll) >> 4), (int)(0x2468ACF12LL >> 4));
  check(11, vll > 0x100000000LL && vtrue, 1);
  check(12, (int)(vf * vf * 4.0f), 9);
  check(13, v5 / v3 * 100 + v5 % v3, 102);
  /* C++. */
  cxx_tests();
  /* Through libclang_rt.builtins.a. */
  rt_tests();
  return 0;
}
