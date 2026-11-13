#!/bin/bash
# Builds compiler-rt's builtins (libclang_rt.builtins.a: soft float, 64-bit
# division and shifts, ...) for RX with the clang in build/install, into the
# directory the driver links it from (clang -print-libgcc-file-name).
#
#   scripts/builtins.sh       (scripts/build.sh runs it after the install)
#
# compiler-rt's CMake does not know RX, so this compiles the generic C
# sources it lists (GENERIC_SOURCES in compiler-rt/lib/builtins/CMakeLists.txt)
# itself, with the flags it would use for a bare-metal target. One library
# serves every CPU and both calling conventions: it is built for the RXv1
# instruction set without the FPU (-mcpu=rx100), and none of its functions
# passes arguments differently under CC-RX's and GNURX's conventions, so each
# object's .note.rx.abi says "neither" (checked below).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd -P)
install=$(cd "$root/build/install" && pwd -P)
src=$root/llvm-project/compiler-rt/lib/builtins
obj=$root/build/builtins
jobs=${JOBS:-$(nproc 2> /dev/null || echo "$NUMBER_OF_PROCESSORS")}
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) exe=.exe ;; *) exe= ;; esac
cc=$install/bin/clang$exe

# GENERIC_SOURCES, without the Darwin and PowerPC only ones (they compile to
# nothing elsewhere). RX has no __bf16, so BF16_SOURCES are left out too.
skip=" apple_versioning.c os_version_check.c trampoline_setup.c "
sources=$(sed -n '/^set(GENERIC_SOURCES$/,/^)/p' "$src/CMakeLists.txt" |
  sed -n 's/^ *\([a-z_0-9]*\.c\)$/\1/p' |
  while read -r f; do case "$skip" in *" $f "*) ;; *) echo "$f" ;; esac; done)
[ "$(echo "$sources" | wc -w)" -gt 100 ] ||
  { echo "GENERIC_SOURCES not found in $src/CMakeLists.txt" >&2; exit 1; }

lib=$("$cc" -print-libgcc-file-name -rtlib=compiler-rt | tr -d '\r')
if command -v cygpath > /dev/null; then lib=$(cygpath -u "$lib"); fi
case "$lib" in "$install"/*) ;; *) echo "unexpected runtime path $lib" >&2; exit 1 ;; esac
# The flags of compiler-rt's CMake (lib/builtins/CMakeLists.txt) for a
# standalone bare-metal build, for RXv1 without the FPU: float arithmetic in
# the sources (powisf2.c, mulsc3.c, ...) calls these functions themselves.
cflags="-mcpu=rx100 -O2 -std=c11 -ffreestanding -fno-builtin \
  -fomit-frame-pointer -nostdinc++ \
  -Wno-c2y-extensions -fdebug-prefix-map=$root/llvm-project=llvm-project"

rm -rf "$obj"
mkdir -p "$obj"
export cc cflags src obj
echo "$sources" | tr ' ' '\n' | grep . |
  xargs -P "$jobs" -I{} sh -c '$cc $cflags -c "$src/{}" -o "$obj/$(basename {} .c).o"'

# Every object must carry the "neither" note (3): one that depends on a
# convention would make the library unusable from the other.
for o in "$obj"/*.o; do
  note=$("$install/bin/llvm-readelf$exe" -x .note.rx.abi "$o" 2> /dev/null |
    sed -n 's/^ *0x00000010 \([0-9a-f]*\).*/\1/p')
  [ "$note" = 03000000 ] ||
    { echo "$(basename "$o"): .note.rx.abi is '$note', not 3 (neither)" >&2; exit 1; }
done

# Nor any FPU (or DFPU) instruction: RX100 and RX200 have none.
fpu=$("$install/bin/llvm-objdump$exe" -d "$obj"/*.o |
  grep -E -w 'fadd|fsub|fmul|fdiv|fcmp|ftoi|ftou|itof|utof|round|fsqrt|mvtfpsw|dadd|dsub|dmul|ddiv|dcmp|dmov|dtoi|dtof|ftod|itod' |
  head -3 || true)
[ -z "$fpu" ] || { echo "FPU instructions in the builtins:" >&2; echo "$fpu" >&2; exit 1; }

mkdir -p "$(dirname "$lib")"
rm -f "$lib"
"$install/bin/llvm-ar$exe" rcsD "$lib" "$obj"/*.o
echo "$lib: $(ls "$obj"/*.o | wc -l) objects"
