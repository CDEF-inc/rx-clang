#!/bin/bash
# Builds the parts of llvm-project (the submodule) that the RX C / C++ /
# assembler toolchain needs and installs them into build/install, which
# scripts/dist.sh packs:
#
#   bin/      clang (and clang++, clang-cpp), ld.lld (lld), llvm-mc, llc,
#             llvm-ar (llvm-ranlib), llvm-objcopy (llvm-strip),
#             llvm-objdump, llvm-nm, llvm-size, llvm-readobj (llvm-readelf),
#             llvm-strings, llvm-symbolizer (llvm-addr2line), llvm-cxxfilt,
#             llvm-dwarfdump
#   lib/clang/N/include   clang's resource headers (stddef.h, stdint.h,
#             stdarg.h, ...)
#
#   build.sh                     on Linux
#   scripts\msvc.bat scripts/build.sh   on Windows, in Git Bash with the
#                                MSVC environment (Visual Studio's C++ tools;
#                                CMake and Ninja come with them)
#
# Only the RX target is built (LLVM_TARGETS_TO_BUILD is empty, RX is
# experimental), and clang's default target is rx-none-elf, so a plain
# `clang -c foo.c` makes RX code. The options follow rx-rust's
# scripts/build-llvm.sh (assertions on, as in rx-rust's LLVM; no zstd or
# libxml2, which would be missing on other machines). On Windows the MSVC
# runtime is linked statically (rx-rust's scripts/build-windows.sh), so the
# programs need no Visual C++ redistributable.
#
# BUILD_DIR is the CMake build directory (default build/llvm); JOBS the
# compile parallelism (default: Ninja's). ccache is used when it is
# installed (on Linux; CCACHE_DIR etc. as usual).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
src=$root/llvm-project/llvm
out=${BUILD_DIR:-$root/build/llvm}
inst=$root/build/install
jobs=${JOBS:+-j $JOBS}
[ -f "$src/CMakeLists.txt" ] || {
  echo "no llvm-project checkout: git submodule update --init --depth 1 llvm-project" >&2
  exit 2
}

# What dist.sh packs; install-distribution builds only these.
components="clang;clang-resource-headers;lld;llvm-mc;llc;llvm-ar;llvm-ranlib"
components+=";llvm-objcopy;llvm-strip;llvm-objdump;llvm-nm;llvm-size"
components+=";llvm-readobj;llvm-readelf;llvm-strings;llvm-symbolizer"
components+=";llvm-addr2line;llvm-cxxfilt;llvm-dwarfdump"

flags=(
  -G Ninja -S "$src" -B "$out"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$inst"
  "-DLLVM_ENABLE_PROJECTS=clang;lld"
  -DLLVM_TARGETS_TO_BUILD=
  -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=RX
  -DLLVM_DEFAULT_TARGET_TRIPLE=rx-none-elf
  -DLLVM_ENABLE_ASSERTIONS=ON
  "-DLLVM_DISTRIBUTION_COMPONENTS=$components"
  # Not clang-cl, ld64.lld, lld-link or wasm-ld (copies on Windows).
  "-DCLANG_LINKS_TO_CREATE=clang++;clang-cpp"
  -DLLD_SYMLINKS_TO_CREATE=ld.lld
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DCLANG_INCLUDE_TESTS=OFF
  -DCLANG_INCLUDE_DOCS=OFF
  -DCLANG_ENABLE_ARCMT=OFF
  -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_PLUGIN_SUPPORT=OFF
  -DLLVM_ENABLE_ZSTD=OFF
  -DLLVM_ENABLE_LIBXML2=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
)
case $(uname -s) in
MINGW*|MSYS*)
  command -v cl > /dev/null || { echo "run this through scripts\\msvc.bat" >&2; exit 2; }
  # Git Bash's /usr/bin/link is not the linker.
  PATH=$(dirname "$(command -v cl)"):$PATH
  # -utf-8, not /utf-8: Git Bash turns what looks like a Unix path into a
  # Windows one. cl reads the sources in the system's code page otherwise,
  # and in code page 932 that breaks clang's Lexer (rx-rust's
  # build-windows.sh).
  export CL=-utf-8 VSLANG=1033
  flags+=(
    -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    -DLLVM_ENABLE_ZLIB=OFF
    -DLLVM_ENABLE_DIA_SDK=OFF
    -DLLVM_PARALLEL_LINK_JOBS=2
  ) ;;
*)
  command -v ccache > /dev/null && flags+=(-DLLVM_CCACHE_BUILD=ON)
  # Linking clang takes a few GB each.
  flags+=(-DLLVM_PARALLEL_LINK_JOBS=${LINK_JOBS:-2}) ;;
esac

mkdir -p "$out"
# Every time: cheap once configured, and a changed option above takes effect.
cmake "${flags[@]}" > "$out/cmake.log" 2>&1 || { tail -30 "$out/cmake.log"; exit 1; }
rm -rf "$inst"
ninja -C "$out" $jobs install-distribution-stripped > "$out/ninja.log" 2>&1 ||
  { grep -E -B2 -A8 'error|FAILED' "$out/ninja.log" | head -80; exit 1; }
"$inst/bin/clang" --version
"$inst/bin/llc" --version | grep -iE 'llvm version|default target| rx '
