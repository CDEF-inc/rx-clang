#!/bin/bash
# Tests a dist.sh archive with nothing else of this repository's builds:
# unpacks it, and with only its programs compiles test/main.c and
# test/other.c (C), test/cxx.cpp (C++, -fno-exceptions -fno-rtti),
# assembles test/start.s and test/asm.s, links them with ld.lld (through
# the clang driver) and runs them on qemu-system-rx. Every combination of
#   calling convention  the default (CC-RX's), -mabi=ccrx, -mabi=gnu
#   CPU                 the default (-mcpu=rx600, RXv1 with the FPU) on
#                       QEMU's rx62n, -mcpu=rxv2 on rxv2, -mcpu=rxv3 on rxv3
#   optimization        -O0, -O2
# Then: the objects' .note.rx.abi, ld.lld refusing CC-RX and GNURX objects
# together (and only warning with -z rx-abi-check=warning), the Itanium
# mangling of cxx.o, the resource headers, and the SBOMs.
#
#   check-dist.sh ARCHIVE.tar.xz|ARCHIVE.zip [RX_RUST_ARCHIVE]
#
# qemu-system-rx is QEMU, else the one in RX_RUST_ARCHIVE: a release
# archive of CDEF-inc/rx-rust (rx-toolchain-x86_64-linux.tar.xz, or
# rx-toolchain-x86_64-windows.zip in Git Bash), of which only QEMU and its
# libraries are unpacked. RUN_SECONDS is how long each program runs
# (default 2).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
[ $# = 1 ] || [ $# = 2 ] || { echo "usage: $0 ARCHIVE.tar.xz|ARCHIVE.zip [RX_RUST_ARCHIVE]" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# QEMU on Windows takes Windows paths, also in file: (rx-rust's run-rust-rom.sh).
w() { if command -v cygpath > /dev/null; then cygpath -m "$1"; else echo "$1"; fi; }

# unpack ARCHIVE DIR [PATTERN...]
unpack() {
  local a=$1 d=$2
  shift 2
  mkdir -p "$d"
  case $a in
  *.zip) "$SYSTEMROOT/System32/tar.exe" -C "$(cygpath -w "$d")" -xf "$(cygpath -w "$(realpath "$a")")" "$@" ;;
  *) tar -C "$d" -xJf "$a" --wildcards "$@" ;;
  esac
}
unpack "$1" "$tmp/dist"
T=$(ls -d "$tmp"/dist/*/ | head -1)
T=${T%/}
B=$T/bin
cat "$T/VERSIONS"
if [ -z "${QEMU:-}" ]; then
  [ $# = 2 ] || { echo "no qemu-system-rx: set QEMU or give an rx-rust archive" >&2; exit 2; }
  case $2 in
  *.zip) unpack "$2" "$tmp/rx-rust" '*/bin/qemu-system-rx.exe' '*/bin/*.dll' ;;
  *) unpack "$2" "$tmp/rx-rust" '*/bin/qemu-system-rx' '*/lib/lib*.so*' \
       --exclude='*/lib/librustc_driver*' --exclude='*/lib/liblldb*' ;;
  esac
  QEMU=$(ls "$tmp"/rx-rust/*/bin/qemu-system-rx* | head -1)
fi
"$QEMU" --version | head -1

status=0
ok() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; status=1; }

# run ELF QEMU_CPU LABEL: runs ELF and reads the results through the
# QEMU monitor
run() {
  local elf=$1 cpu=$2 label=$3 s
  declare -A A=()
  for s in checks failures first_failure got_value want_value exit_code finished; do
    A[$s]=$("$B/llvm-nm" "$elf" | awk -v s="_$s" '$3 == s {print $1}')
  done
  head -c 16 /dev/zero > "$tmp/bios.bin"
  {
    sleep "${RUN_SECONDS:-2}"
    for s in "${!A[@]}"; do echo "xp /1wd 0x${A[$s]}"; done
    echo "info registers"
    echo quit
  } | timeout 60 "$QEMU" -M gdbsim-r5f562n8 -cpu "$cpu" -bios "$(w "$tmp/bios.bin")" \
      -display none -serial none -device loader,file="$(w "$elf")",cpu-num=0 \
      -monitor stdio 2>&1 | tr -d '\r' > "$tmp/monitor.log" || true
  # The monitor prints addresses as 8 or 16 hex digits.
  get() {
    awk -v k="$(printf '%x' $((16#${A[$1]})))" \
      '{a = tolower($1); sub(/:$/, "", a); sub(/^0+/, "", a); if (a == k) print $2}' "$tmp/monitor.log"
  }
  if [ "$(get finished)" != 1 ]; then
    fail "$label: did not finish ($(grep -o 'pc=0x[0-9a-f]*' "$tmp/monitor.log" | head -1))"
  elif [ "$(get failures)" != 0 ] || [ "$(get exit_code)" != 0 ] || [ "$(get checks)" -lt 20 ]; then
    fail "$label: checks=$(get checks) failures=$(get failures) first=$(get first_failure)" \
      "got=$(get got_value) want=$(get want_value) exit=$(get exit_code)"
  else
    ok "$label: $(get checks) checks"
  fi
}

S=$root/test
cd "$tmp"
for abi in default ccrx gnu; do
  case $abi in
  default) aflag=; want=1; asflag= ;;
  ccrx) aflag=-mabi=ccrx; want=1; asflag= ;;
  gnu) aflag=-mabi=gnu; want=2; asflag=-Wa,--defsym,GNU_ABI=1 ;;
  esac
  for cpu in rx600:rx62n rxv2:rxv2 rxv3:rxv3; do
    mcpu=${cpu%:*} qcpu=${cpu#*:}
    for opt in -O0 -O2; do
      o=$abi-$mcpu$opt
      mkdir -p "$o"
      # No --target: the archive's clang defaults to rx-none-elf. There is
      # no libgcc, so float arithmetic has to use the FPU, which clang does
      # only when denormals may flush to zero.
      cc="$B/clang -mcpu=$mcpu $aflag $opt -Wall -Werror -fdenormal-fp-math=preserve-sign"
      if $cc -DWANT_ABI=$want -c "$S/main.c" -o "$o/main.o" &&
         $cc -c "$S/other.c" -o "$o/other.o" &&
         "$B/clang++" -mcpu=$mcpu $aflag $opt -Wall -Werror -fno-exceptions -fno-rtti \
           -c "$S/cxx.cpp" -o "$o/cxx.o" &&
         "$B/clang" -mcpu=$mcpu $asflag -c "$S/asm.s" -o "$o/asm.o" &&
         "$B/clang" -mcpu=$mcpu -c "$S/start.s" -o "$o/start.o" &&
         "$B/clang++" -mcpu=$mcpu -nostdlib -T "$S/qemu.ld" "$o/start.o" "$o/main.o" \
           "$o/other.o" "$o/cxx.o" "$o/asm.o" -o "$o/test.elf" 2> "$o/build.log"; then
        run "$o/test.elf" "$qcpu" "$abi -mcpu=$mcpu $opt"
      else
        fail "$abi -mcpu=$mcpu $opt: does not build"
        cat "$o/build.log" 2> /dev/null || true
      fi
    done
  done
done

# The calling-convention note and ld.lld's check of it.
note() {
  "$B/llvm-readelf" -n "$1" | awk '/description data:/ {print $3; exit}'
}
for x in "default-rx600-O2/main.o 01" "ccrx-rx600-O2/other.o 01" "gnu-rx600-O2/main.o 02" "gnu-rx600-O2/other.o 02"; do
  set -- $x
  [ "$(note "$1")" = "$2" ] && ok "$1: .note.rx.abi $2" || fail "$1: .note.rx.abi '$(note "$1")', want $2"
done
[ -f default-rx600-O2/asm.o ] && [ -z "$(note default-rx600-O2/asm.o)" ] && ok "asm.o: no .note.rx.abi" || fail "asm.o has a .note.rx.abi"
m=default-rx600-O2 g=gnu-rx600-O2
mixed="$m/start.o $m/main.o $g/other.o $m/cxx.o $m/asm.o"
if out=$("$B/ld.lld" -T "$S/qemu.ld" $mixed -o mixed.elf 2>&1); then
  fail "ld.lld links CC-RX and GNURX objects together"
else
  echo "$out" | grep -q "error: .*calling convention" &&
    ok "ld.lld refuses CC-RX and GNURX objects: $(echo "$out" | head -1)" ||
    { fail "ld.lld fails, but not on the calling convention"; echo "$out"; }
fi
if out=$("$B/clang" -nostdlib -T "$S/qemu.ld" -Wl,-z,rx-abi-check=warning $mixed -o mixed.elf 2>&1) &&
   echo "$out" | grep -q "warning: .*calling convention"; then
  ok "-Wl,-z,rx-abi-check=warning links them with a warning"
else
  fail "-z rx-abi-check=warning"; echo "$out"
fi

# C++ names are Itanium-mangled, with the leading underscore of C names.
syms=$("$B/llvm-nm" "$m/cxx.o")
for s in __Z8overloadi __Z8overloads _cxx_tests; do
  echo "$syms" | grep -q " T $s\$" && ok "cxx.o defines $s" || fail "cxx.o: no $s"
done
# clang's resource headers are the ones it uses.
inc=$("$B/clang" -print-resource-dir | tr -d '\r')/include
[ -f "$inc/stdint.h" ] && [ -f "$inc/stdarg.h" ] && ok "resource headers in ${inc#$T/}" ||
  fail "no resource headers in $inc"
# The tools besides the compiler.
for t in llvm-mc llc llvm-objcopy llvm-objdump llvm-ar llvm-size; do
  "$B/$t" --version > /dev/null 2>&1 && ok "$t runs" || fail "$t does not run"
done
echo 'mov.l #1, r1' | "$B/llvm-mc" -triple=rx-none-elf -show-encoding | grep -q 'encoding:' &&
  ok "llvm-mc assembles RX" || fail "llvm-mc does not assemble RX"

# The SBOMs (scripts/sbom.py).
s=$T/SBOM.spdx.json
grep -q '"spdxVersion": "SPDX-2.3"' "$s" && grep -q '"name": "llvm-project"' "$s" &&
  ok "SBOM (SPDX): $(grep -c '"SPDXID"' "$s") SPDX ids" || fail "no SPDX 2.3 SBOM.spdx.json"
s=$T/SBOM.cdx.json
grep -q '"bomFormat": "CycloneDX"' "$s" && grep -q '"specVersion": "1.6"' "$s" &&
  grep -q '"name": "llvm-project"' "$s" &&
  ok "SBOM (CycloneDX): $(grep -c '"bom-ref"' "$s") bom-refs" || fail "no CycloneDX 1.6 SBOM.cdx.json"
exit $status
