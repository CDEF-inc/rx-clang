/* What needs libclang_rt.builtins.a (scripts/builtins.sh): check-dist.sh
   compiles this without -fdenormal-fp-math=preserve-sign, so float and
   double arithmetic become calls to it (__addsf3, __muldf3, ...), and so do
   64-bit division and variable shifts. */
#include <stdint.h>

#include "test.h"

static volatile float f2 = 2.0f, f3 = 3.0f, fq = 0.75f;
static volatile double d2 = 2.0, d3 = 3.0, dbig = 1e15;
static volatile int i7 = 7, im9 = -9, s5 = 5, s40 = 40;
static volatile unsigned u4g = 4000000000u;
static volatile long long ll = -0x123456789abLL, lb = 1000000007LL;
static volatile unsigned long long ull = 0xfedcba9876543210ULL;

void rt_tests(void) {
  /* float */
  check(200, (int)((f2 + f3) * 100.0f), 500);
  check(201, (int)((f3 - f2 * fq) * 1000.0f), 1500);
  check(202, (int)(f3 / f2 * 1000.0f), 1500);
  check(203, (f2 < f3) + 2 * (f2 == f3) + 4 * (f3 >= f3), 5);
  check(204, (int)(float)im9, -9);
  check(205, (int)((float)i7 / f2 * 10.0f), 35);
  check(206, (int)((unsigned)(float)u4g / 1000u), 4000000);
  /* double */
  check(210, (int)((d2 + d3) * d3), 15);
  check(211, (int)(dbig / d3 / 1e9), 333333);
  check(212, (int)((double)fq * 4.0), 3);
  check(213, (int)(float)(d3 / d2 * 10.0), 15);
  check(214, (d2 > d3) + 2 * (d3 != d2), 2);
  check(215, (int)((long long)dbig / 1000000), 1000000000);
  check(216, (int)(dbig - (double)(long long)dbig), 0);
  /* 64-bit integers */
  check(220, (int)(ll / lb), (int)(-0x123456789abLL / 1000000007LL));
  check(221, (int)(ll % lb), (int)(-0x123456789abLL % 1000000007LL));
  check(222, (int)(ull / (unsigned long long)lb), (int)(0xfedcba9876543210ULL / 1000000007ULL));
  check(223, (int)(ull % (unsigned long long)lb), (int)(0xfedcba9876543210ULL % 1000000007ULL));
  check(224, (int)(ull >> s40), (int)(0xfedcba9876543210ULL >> 40));
  check(225, (int)((ull << s5) >> 32), (int)((0xfedcba9876543210ULL << 5) >> 32));
  check(226, (int)(ll >> s5), (int)(-0x123456789abLL >> 5));
  check(227, __builtin_popcountll(ull) + 100 * __builtin_clzll(ull >> s40), 32 + 100 * 40);
}
