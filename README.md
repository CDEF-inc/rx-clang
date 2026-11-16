# rx-clang

A C, C++ and assembler toolchain for Renesas RX microcontrollers: clang,
llvm-mc and lld, built from the RX backend in
[CDEF-inc/llvm-project](https://github.com/CDEF-inc/llvm-project), with the
LLDB debugger and the qemu-system-rx emulator. It uses the same LLVM as the
Rust toolchain in [CDEF-inc/rx-rust](https://github.com/CDEF-inc/rx-rust), so
C, C++, assembly and Rust objects link together.

Status: experimental. The archives are on the
[releases page](https://github.com/CDEF-inc/rx-clang/releases), each with its
SBOMs; the CI also builds them for every commit (the `rx-clang-x86_64-linux`
artifact of the CI workflow and `rx-clang-x86_64-windows` of the Windows
workflow).

## What is in the archive

`rx-clang-x86_64-linux.tar.xz` (built on Ubuntu 22.04, so it runs on Ubuntu
22.04, Debian 12 and later) and `rx-clang-x86_64-windows.zip` (needs no
Visual C++ redistributable) hold `rx-clang-x86_64-linux/` or
`rx-clang-x86_64-windows/` with

| Path | What |
|---|---|
| `bin/clang`, `clang++`, `clang-cpp` | the compiler driver; its default target is `rx-none-elf` |
| `bin/ld.lld` | the linker (the driver's default) |
| `bin/llvm-mc` | the assembler on its own (clang assembles `.s` / `.S` itself) |
| `bin/llc` | the LLVM IR compiler |
| `bin/llvm-ar` (`llvm-ranlib`), `llvm-objcopy` (`llvm-strip`), `llvm-objdump`, `llvm-nm`, `llvm-size`, `llvm-readobj` (`llvm-readelf`), `llvm-strings`, `llvm-symbolizer` (`llvm-addr2line`), `llvm-cxxfilt`, `llvm-dwarfdump` | the binary tools |
| `lib/clang/N/include` | clang's resource headers: `stddef.h`, `stdint.h`, `stdarg.h`, `stdbool.h`, `limits.h`, `float.h`, ... |
| `lib/clang/N/lib/rx-unknown-none-elf/libclang_rt.builtins.a` | compiler-rt's builtins: soft-float `float` / `double` arithmetic, 64-bit division and shifts, ... (the driver links it) |
| `bin/lldb` | the debugger, with RX support (see [Debugging](#debugging)); on Linux with `lib/liblldb.so*`, on Windows `bin/liblldb.dll` |
| `bin/qemu-system-rx` | QEMU with RXv1, RXv2, RXv3 and RXv3e ([CDEF-inc/qemu](https://github.com/CDEF-inc/qemu)); on Linux with the libraries it needs in `lib/` (glib, pixman, ...), on Windows its DLLs in `bin/` |
| `VERSIONS` | the commits it was built from (rx-clang, llvm-project, qemu, and the rx-rust release that LLDB and QEMU come from) and the glibc it needs |
| `LICENSE.TXT` | llvm-project's license |
| `COPYING.QEMU` | QEMU's license (GPL-2.0) |
| `SBOM.spdx.json`, `SBOM.cdx.json` | the software bill of materials (SPDX 2.3, CycloneDX 1.6) |

There is no C library or C++ library in it (see
[C and C++ libraries](#c-and-c-libraries)). LLDB and qemu-system-rx are the
ones in the [rx-rust release](https://github.com/CDEF-inc/rx-rust/releases)
of the same LLVM, unchanged.

## Install

Download the archive from the
[latest release](https://github.com/CDEF-inc/rx-clang/releases/latest),
unpack it anywhere and put its `bin` on `PATH`:

```bash
tar -xJf rx-clang-x86_64-linux.tar.xz
export PATH=$PWD/rx-clang-x86_64-linux/bin:$PATH
clang --version
```

On Windows, unzip `rx-clang-x86_64-windows.zip` and add
`rx-clang-x86_64-windows\bin` to `PATH`.

## Usage

```bash
clang -mcpu=rxv3 -O2 -c main.c
clang++ -mcpu=rxv3 -O2 -fno-exceptions -fno-rtti -c app.cpp
clang -mcpu=rxv3 -c start.s
clang++ -mcpu=rxv3 -nostartfiles -nolibc -nostdlib++ -T board.ld start.o main.o app.o -o app.elf
llvm-objcopy -O srec app.elf app.mot
```

`--target=rx-none-elf` is the default and may be given as well. `.S` files
go through the preprocessor first. The driver links with the `ld.lld` next
to it and the archive's `libclang_rt.builtins.a`; you give the start-up
code and the linker script (`-T`), and while there is no C library
`-nostartfiles -nolibc` (without them the driver asks for `crt0.o` and
newlib), with `clang++` also `-nostdlib++`. `-nostdlib` leaves out the
builtins as well. [`test/`](test) is a small example: start-up
code that clears `.bss` and runs the C++ constructors
([`test/start.s`](test/start.s)), a linker script
([`test/qemu.ld`](test/qemu.ld)), and C, C++ and assembly that call each
other.

CPU and floating point, as in GNURX's `rx-elf-gcc`:

- `-mcpu=` takes the backend's `rxv1`, `rxv2`, `rxv3`, `rxv3e` and GNURX's
  `rx100`, `rx13t`, `rx140`, `rx200`, `rx230`, `rx600`, `rx610`, `rx64m`,
  `rx66t`, `rx71m`, `rx72t`. The default is `rx600` (RXv1 with the
  single-precision FPU). Without `-mcpu=`, GNURX's `-misa=v1|v2|v3|v3e` work
  too.
- `-nofpu` / `-mnofpu`; `-mdfpu` / `-mno-dfpu` for the RXv3 double-precision
  FPU (the backend's `rxv3` / `rxv3e` have it; GNURX's CPU names and `-misa`
  only with `-mdfpu`); `-m64bit-doubles` (the default: `double` is 8 bytes) /
  `-m32bit-doubles`.
- The FPU is used only where the result is the IEEE one. It flushes
  denormals to zero, so `float` (and, with the DFPU, `double`) arithmetic
  becomes calls into the builtins (`__mulsf3`, ...) unless you allow that with
  `-fdenormal-fp-math=preserve-sign` (GCC's `-fpu` does the same).
- Types as in GCC: plain `char` is unsigned, `int`, `long` and pointers are 4
  bytes, `long long` and `double` 8 bytes with 4-byte alignment, `int32_t`
  is `long`; bit-fields use GCC's (MS) layout.
- Predefined macros as in GNURX: `__RX__`, `__RXv1__` / `__RXv2__` /
  `__RXv3__`, the CPU name (`__RX600__`, ...), `__RX_LITTLE_ENDIAN__`,
  `__RX_64BIT_DOUBLES__` / `__RX_32BIT_DOUBLES__`, `__RX_FPU_INSNS__`,
  `__RX_DFPU_INSNS__`, `__RX_ABI__`, and the calling convention's below.

Not supported (the backend does not have them): `-mbig-endian-data`, `-mpid`,
`-mno-allow-string-insns`, `-msmall-data-limit`, `-mint-register`,
`-mgcc-abi`, and `__attribute__((interrupt))` / `fast_interrupt` (write
interrupt entries in assembly).

## Debugging

Build with `-g` and debug with the archive's `lldb` over the GDB remote
protocol: on QEMU's gdbstub, or on a board through a GDB server (Renesas e2
studio's `e2-server-gdb` with an E2 / E2 Lite emulator).

```bash
clang -g -O0 -c main.c && clang -g -O0 -c start.s
clang -nostartfiles -nolibc -T board.ld start.o main.o -o app.elf
# QEMU: the program in the SDRAM of gdbsim-r5f562n8, stopped (-S) until LLDB continues it
qemu-system-rx -M gdbsim-r5f562n8 -cpu rxv3 -bios empty.bin -display none \
  -device loader,file=app.elf,cpu-num=0 -S -gdb tcp:127.0.0.1:1234 &
lldb app.elf -o "gdb-remote 127.0.0.1:1234"
(lldb) breakpoint set -n main
(lldb) continue
```

`-bios` takes any file (16 zero bytes, say): the program is loaded into RAM
by `-device loader` and runs from its entry point. `-cpu` is `rx62n` (RXv1,
the default), `rxv2`, `rxv3` or `rxv3e`. LLDB reads the RX registers
(including the FPU's and, on RXv3, the DFPU's), sets breakpoints and
watchpoints, steps, shows C and C++ arguments and locals from the DWARF, and
`finish` reads return values (either calling convention). Code without
debug info (assembly, `-g0`) is unwound by emulating its prologue.
`scripts/check-dist.sh` runs such a session on every archive.

## Calling conventions: `-mabi=ccrx` and `-mabi=gnu`

clang follows Renesas CC-RX's calling convention (the CC-RX manual's
chapter 9.1, the only written RX ABI) by default, and GNURX's
(`rx-elf-gcc`'s) with `-mabi=gnu`:

| | `-mabi=ccrx` (default) | `-mabi=gnu` |
|---|---|---|
| macro | `__RX_CCRX_ABI__` | `__RX_GNU_ABI__` |
| arguments after one that did not fit in R1-R4 (a `long long` after three `int`s, a structure that is always on the stack) | take the registers left free | all on the stack |
| `wchar_t` | `unsigned short` (2 bytes) | `long` (4 bytes) |
| links with | CC-RX objects; rustc's `rx-none-elf` | GNURX objects and libraries |

Both define `__RX_ABI__` (stack arguments at their natural alignment, GCC's
meaning). Everything else is the same in both: R1-R4 for arguments, R15 for
the address of a returned structure, structures of 16 bytes or less whose
size is a multiple of 4 in R1-R4 (as arguments and as return values),
varargs on the stack, and `char` / `short` arguments extended by both the
caller and the callee (so clang's code works with either compiler's callers
and callees).

Differences clang does not follow:

- A plain `int` bit-field is unsigned in CC-RX, signed in GCC and clang.
  The layout is the same; write `signed` or `unsigned` in code shared with
  CC-RX.
- `double` is 8 bytes in clang (as Rust's `f64`); CC-RX and GNURX default to
  4. Compile the CC-RX side with `-dbl_size=8` (GNURX: `-m64bit-doubles`).

### The `.note.rx.abi` check in ld.lld

Every object this LLVM writes has a `.note.rx.abi` ELF note (owner `RX`,
type 1) that says whether it depends on CC-RX's convention (1), on GNURX's
(2) or on neither (3: no function it defines or calls outside the object
places its arguments differently under the two, which is most code).
`ld.lld` refuses to link an object that depends on CC-RX's convention with
one that depends on GNURX's, or with an object of an older LLVM (no note,
and a `clang version` / `rustc version` `.comment`):

```
ld.lld: error: main.o uses CC-RX's calling convention (-mabi=ccrx) and other.o GNURX's (-mabi=gnu): calls between them may pass arguments in different places; build them with the same convention (-z rx-abi-check=warning to link anyway)
```

`-Wl,-z,rx-abi-check=warning` makes it a warning, `-Wl,-z,rx-abi-check=none`
skips the check. `llvm-readelf -n foo.o` shows the note. Objects without a
note otherwise (GCC's, CC-RX's, assembly) are not checked, so GCC code of
the other convention is not caught; GNU ld and CC-RX's rlink do not check
the note at all.

### With other compilers

- **Rust** ([rx-rust](https://github.com/CDEF-inc/rx-rust)): the same LLVM.
  rustc's `rx-none-elf` uses CC-RX's convention, so it links with clang's
  default objects (GNURX's: `"llvm-abiname": "gnu"` in a target JSON).
- **CC-RX**: C names match (a leading `_` in all three compilers), and
  ld.lld links CC-RX's ELF objects as they are. CC-RX's own linker (rlink)
  does not take LLVM objects yet (their e_flags, section symbols and DWARF:
  CDEF-inc/rx-rust#178), so link with ld.lld.
- **GNURX / GCC**: with `-mabi=gnu`, clang's objects and GCC's call each
  other both ways (rx-rust's `test/clang` checks it on QEMU).

## C and C++ libraries

The archive is freestanding: clang's headers and compiler-rt's builtins
(`libclang_rt.builtins.a`, what GCC has in libgcc), no C library. Code that
needs no C library links with `-nostartfiles -nolibc` (and `-nostdlib++`
with `clang++`): supply `memcpy` / `memset` if the compiler emits calls to
them; `llvm-nm -u` lists what an object needs.

The builtins ([`scripts/builtins.sh`](scripts/builtins.sh)) are compiler-rt's
generic C sources compiled for RXv1 without the FPU (`-mcpu=rx100`), so
they run on every RX CPU, and none of them depends on the calling
convention (their `.note.rx.abi` says neither), so the same library links
with `-mabi=ccrx` and `-mabi=gnu` objects. They give `float` and `double`
arithmetic and conversions in software (where the FPU / DFPU is not used,
see `-fdenormal-fp-math` above), 64-bit division, remainder and variable
shifts, the complex multiplication and division, `__builtin_popcount` and
the like. There are no `long double` (it is `double`), `__int128`, `__bf16`
or atomic routines.

With `-mabi=gnu` you can use GNURX's newlib, libgcc and libstdc++:

```bash
clang -mabi=gnu -mcpu=rxv3 --gcc-toolchain="C:/ProgramData/GCC for Renesas RX 14.2.0.202607-GNURX-ELF/rx-elf/rx-elf" main.c -o main.elf
```

The driver finds libgcc, `crt0.o`, `crtbegin.o` / `crtend.o` and newlib in
that GCC installation (or in an `rx-elf` GCC next to clang; without a GCC
it looks for a C library in `rx-elf/` next to `bin/`), picks GCC's multilib
for the CPU, and links like `rx-elf-gcc`: `crt0.o`, `-lgcc --start-group
-lc -lnosys --end-group -lgcc` (`-lsim` with `-msim`), and libgloss's
`rx.ld` unless `-T` is given. Use it only with `-mabi=gnu`: GCC's objects
carry no ABI note, so with the default `-mabi=ccrx` ld.lld cannot tell, and
a call into the library that the two conventions place differently would
pass its arguments in the wrong place without an error. llvm-test-suite's
SingleSource passes 387 of 411 tests on QEMU this way (rx-rust's
`scripts/run-test-suite.sh`).

## C++

- Compile with `-fno-exceptions -fno-rtti`. The RX backend does not emit
  unwind tables or exception handling yet (CDEF-inc/rx-rust#170), so
  exceptions are untested and `throw` cannot work; RTTI is untested too
  (and needs a C++ ABI library: `__cxxabiv1::__class_type_info`).
- Without a C++ library there are no C++ headers (`<new>`, `<cstdint>`,
  ...): use the C headers, and define `operator new` / `delete` and
  placement `new` yourself, as [`test/cxx.cpp`](test/cxx.cpp) does. With
  `-mabi=gnu` and `--gcc-toolchain`, GNURX's libstdc++ provides them.
- The start-up code must run `.init_array` for global constructors
  ([`test/start.s`](test/start.s)). A global with a non-trivial destructor
  needs `__cxa_atexit` and `__dso_handle`, a function-local static with a
  constructor `__cxa_guard_acquire` / `release` (or
  `-fno-threadsafe-statics`), a pure virtual function `__cxa_pure_virtual`.
- Names are Itanium-mangled (`__Z8overloadi`), as GCC's, so clang's and
  GNURX's C++ objects link with each other. CC-RX mangles C++ names its own
  way (`_overload__Fi`): between CC-RX's C++ and clang's only `extern "C"`
  functions link.

## Building

```bash
git clone https://github.com/CDEF-inc/rx-clang.git && cd rx-clang
git submodule update --init --depth 1 llvm-project
bash scripts/build.sh          # build/install
# LLDB and qemu-system-rx: from the rx-rust release of the same LLVM
curl -fLO https://github.com/CDEF-inc/rx-rust/releases/download/$(grep -v '^#' .github/rx-rust-release)/rx-toolchain-x86_64-linux.tar.xz
bash scripts/dist.sh rx-toolchain-x86_64-linux.tar.xz    # build/dist/rx-clang-x86_64-linux.tar.xz
bash scripts/check-dist.sh build/dist/rx-clang-x86_64-linux.tar.xz
```

- [`scripts/build.sh`](scripts/build.sh) configures llvm-project with only
  `clang;lld` and the RX target and builds what the archive holds
  (`install-distribution-stripped`, then the builtins with
  [`scripts/builtins.sh`](scripts/builtins.sh)): about 3300 steps, 12
  minutes on 28 cores. It needs CMake, Ninja, Python 3 and a C++ compiler, and uses ccache
  if it is installed. On Windows run `scripts\msvc.bat scripts/build.sh`
  (Visual Studio's C++ tools and Git for Windows).
- [`scripts/dist.sh`](scripts/dist.sh) packs the archive with `VERSIONS`,
  the licenses and the SBOMs ([`scripts/sbom.py`](scripts/sbom.py)). It
  takes LLDB, qemu-system-rx and their libraries from the rx-rust release
  archive given to it (for the same host), refuses one whose LLDB is built
  from another llvm-project commit, copies that archive's SBOM entries for
  them (QEMU, libxml2 in LLDB, QEMU's libraries), and fetches QEMU's
  `COPYING` at the commit it was built from. It refuses programs that need
  libraries beyond glibc, libstdc++, libgcc_s, zlib and what the archive
  brings.
- [`scripts/check-dist.sh`](scripts/check-dist.sh) tests an archive with
  nothing but its own programs. It builds [`test/`](test) (C, C++ with
  `-fno-exceptions -fno-rtti`, assembly, and C that calls the builtins) for
  every combination of the
  default convention, `-mabi=ccrx` and `-mabi=gnu`, three CPUs and `-O0` /
  `-O2`, runs the programs on the archive's qemu-system-rx (or `QEMU=`),
  debugs one with the archive's lldb (breakpoints in C and C++,
  backtraces, arguments, `finish`), and checks the builtins, the ABI notes
  and ld.lld's check of them, the C++ mangling and the SBOMs.
- The CI ([`.github/workflows`](.github/workflows)): `ci.yml` builds on
  Ubuntu 22.04 (build/install cached by the llvm-project commit, ccache for
  rebuilds), packs the archive and runs check-dist.sh on Ubuntu 22.04 and
  Debian 12; `windows.yml` builds, packs and checks the zip (on `main`, by
  hand, and on pull requests that change the Windows build). The rx-rust
  release that LLDB and QEMU are taken from is in
  [`.github/rx-rust-release`](.github/rx-rust-release).

### Following rx-rust's LLVM

`llvm-project` is a submodule pinned to the commit rx-rust uses: rx-rust's
`rust` submodule (CDEF-inc/rust) has it as `src/llvm-project`. When rx-rust
bumps it, bump this one in a pull request of its own:

```bash
bash scripts/update-llvm.sh          # rx-rust main's LLVM; or a tag: update-llvm.sh toolchain-2026-11-13.1
git commit -m "Bump llvm-project to rx-rust main"
```

[`scripts/update-llvm.sh`](scripts/update-llvm.sh) reads both commits
through the GitHub API (`gh`), so it needs no rust checkout;
`update-llvm.sh --check` only compares. The CI's `llvm-pin` job warns when
the submodule is not rx-rust main's LLVM. Point
[`.github/rx-rust-release`](.github/rx-rust-release) at the rx-rust release
of that LLVM in the same pull request: dist.sh refuses a release whose LLDB
is built from another commit.

## License

The scripts and tests of this repository are licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option, as rx-rust is. In the archives:

- clang, lld, LLDB and the LLVM tools are LLVM, under the Apache License
  2.0 with LLVM Exceptions (`Apache-2.0 WITH LLVM-exception`; `LICENSE.TXT`
  in the archive, `llvm/LICENSE.TXT` in
  [CDEF-inc/llvm-project](https://github.com/CDEF-inc/llvm-project)). LLDB
  links libxml2 (MIT) statically.
- qemu-system-rx is QEMU, under the GPL version 2 (`COPYING.QEMU` in the
  archive). Its source is
  [CDEF-inc/qemu](https://github.com/CDEF-inc/qemu) at the commit in
  `VERSIONS`. The libraries it needs (glib, pixman, ... on Linux; MinGW's
  DLLs on Windows) keep their own licenses, which the SBOMs list.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.

Security issues: see [SECURITY.md](SECURITY.md).
