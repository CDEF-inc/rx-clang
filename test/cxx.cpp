// The C++ side of the QEMU check (scripts/check-dist.sh), compiled with
// -fno-exceptions -fno-rtti and no C++ library: virtual calls (vtables), a
// global object with a constructor (.init_array, run by start.s),
// templates, constexpr, lambdas, overloading (Itanium mangling) and
// operator new / delete of its own.
#include <stddef.h>
#include <stdint.h>

#include "test.h"

// There is no <new>: placement new and the allocation functions are ours.
inline void *operator new(size_t, void *p) noexcept { return p; }

alignas(8) static unsigned char heap[512];
static size_t heap_used;
void *operator new(size_t n) {
  void *p = heap + heap_used;
  heap_used += (n + 7) & ~size_t(7);
  return p;
}
void operator delete(void *) noexcept {}
void operator delete(void *, size_t) noexcept {}

namespace {

struct Shape {
  virtual int area() const { return 0; }
  int scale = 1;
};
struct Rect : Shape {
  int w, h;
  Rect(int w, int h) : w(w), h(h) {}
  int area() const override { return w * h * scale; }
};
struct Square final : Rect {
  explicit Square(int s) : Rect(s, s) {}
  int area() const override { return Rect::area() + 1; }
};

int constructed;
struct Counter {
  int value;
  Counter() : value(42) { ++constructed; }
};
Counter global_counter;   // trivial destructor: no __cxa_atexit

template <typename T, int N> struct Array {
  T v[N];
  constexpr T sum() const {
    T s = 0;
    for (int i = 0; i < N; i++)
      s += v[i];
    return s;
  }
};
constexpr Array<short, 4> kArray{{1, 2, 3, 4}};
static_assert(kArray.sum() == 10, "constexpr");

}  // namespace

// External, so that the mangled names are in cxx.o (check-dist.sh looks
// for __Z8overloadi and __Z8overloads).
__attribute__((noinline)) int overload(int x) { return x + 1; }
__attribute__((noinline)) int overload(short x) { return x + 2; }

__attribute__((noinline)) static int total(Shape *const *s, int n) {
  int t = 0;
  for (int i = 0; i < n; i++)
    t += s[i]->area();
  return t;
}

template <typename F> __attribute__((noinline)) static int apply(F f, int x) { return f(x); }

extern "C" void cxx_tests() {
  check(100, global_counter.value, 42);
  check(101, constructed, 1);
  Rect r(3, 4);
  Square q(5);
  q.scale = 2;
  Shape base;
  Shape *shapes[] = {&r, &q, &base};
  check(102, total(shapes, 3), 12 + 51 + 0);
  Square *p = new Square(2);
  Shape *ps = p;
  check(103, ps->area(), 5);
  delete p;
  alignas(Rect) unsigned char buf[sizeof(Rect)];
  Rect *pr = new (buf) Rect(6, 7);
  Shape *placed[] = {pr};
  check(104, total(placed, 1), 42);
  Array<int, 3> a{{10, 20, 30}};
  check(105, a.sum(), 60);
  int k = 7;
  check(106, apply([k](int x) { return x * k; }, 6), 42);
  check(107, overload(1) * 10 + overload(short(1)), 23);
}
