#!/bin/bash
# Tests a dist.sh archive with nothing else of this repository's builds:
# unpacks it, and with only its programs compiles test/main.c,
# test/other.c and test/rt.c (C), test/cxx.cpp (C++, -fno-exceptions
# -fno-rtti), assembles test/start.s and test/asm.s, links them with ld.lld
# and the archive's libclang_rt.builtins.a (through the clang driver) and
# runs them on qemu-system-rx. Every combination of
#   calling convention  the default (CC-RX's), -mabi=ccrx, -mabi=gnu
#   CPU                 the default (-mcpu=rx600, RXv1 with the FPU) on
#                       QEMU's rx62n, -mcpu=rxv2 on rxv2, -mcpu=rxv3 on rxv3
#   optimization        -O0, -O2
# Then: a debugging session with the archive's lldb on its qemu-system-rx
# (breakpoints in C and C++, backtraces, arguments, `finish`), the builtins
# that rt.c calls, the objects' .note.rx.abi, ld.lld refusing CC-RX and
# GNURX objects together (and only warning with -z rx-abi-check=warning),
# the Itanium mangling of cxx.o, the resource headers, and the SBOMs.
#
#   check-dist.sh ARCHIVE.tar.xz|ARCHIVE.zip
#
# The programs run on the archive's qemu-system-rx, or on QEMU if it is set.
# RUN_SECONDS is how long each program runs (default 2); LLDB_TIMEOUT
# bounds the LLDB session (seconds, default 120).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
[ $# = 1 ] || { echo "usage: $0 ARCHIVE.tar.xz|ARCHIVE.zip" >&2; exit 2; }
tmp=$(mktemp -d)
qemu_pid=
trap '[ -z "$qemu_pid" ] || kill "$qemu_pid" 2> /dev/null; rm -rf "$tmp"' EXIT
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
QEMU=${QEMU:-$(ls "$B"/qemu-system-rx* | head -1)}
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
      # No --target: the archive's clang defaults to rx-none-elf. main.c
      # and other.c use the FPU for float arithmetic, which clang does only
      # when denormals may flush to zero; rt.c calls libclang_rt.builtins.a
      # for it instead.
      cc="$B/clang -mcpu=$mcpu $aflag $opt -Wall -Werror"
      if $cc -fdenormal-fp-math=preserve-sign -DWANT_ABI=$want -c "$S/main.c" -o "$o/main.o" &&
         $cc -fdenormal-fp-math=preserve-sign -c "$S/other.c" -o "$o/other.o" &&
         $cc -c "$S/rt.c" -o "$o/rt.o" &&
         "$B/clang++" -mcpu=$mcpu $aflag $opt -Wall -Werror -fno-exceptions -fno-rtti \
           -c "$S/cxx.cpp" -o "$o/cxx.o" &&
         "$B/clang" -mcpu=$mcpu $asflag -c "$S/asm.s" -o "$o/asm.o" &&
         "$B/clang" -mcpu=$mcpu -c "$S/start.s" -o "$o/start.o" &&
         "$B/clang++" -mcpu=$mcpu -nostartfiles -nolibc -nostdlib++ -T "$S/qemu.ld" \
           "$o/start.o" "$o/main.o" "$o/other.o" "$o/rt.o" "$o/cxx.o" "$o/asm.o" \
           -o "$o/test.elf" 2> "$o/build.log"; then
        run "$o/test.elf" "$qcpu" "$abi -mcpu=$mcpu $opt"
      else
        fail "$abi -mcpu=$mcpu $opt: does not build"
        cat "$o/build.log" 2> /dev/null || true
      fi
    done
  done
done

# LLDB: the program (default convention and CPU, -O0 -g) on qemu-system-rx's
# gdbstub, stopped before its first instruction (-S). Breakpoints in C
# (c_sum6, whose struct argument is on the stack and x in R1) and in C++
# (overload(int), by its unmangled name), backtraces into main and
# cxx_tests, an argument, and `finish` with the return value.
LLDB=$B/lldb
[ -f "$LLDB" ] || LLDB=$B/lldb.exe
if [ ! -f "$LLDB" ]; then
  fail "no lldb in the archive"
else
  o=lldb
  mkdir -p "$o"
  cc="$B/clang -g -O0 -Wall -Werror"
  if $cc -fdenormal-fp-math=preserve-sign -DWANT_ABI=1 -c "$S/main.c" -o "$o/main.o" &&
     $cc -fdenormal-fp-math=preserve-sign -c "$S/other.c" -o "$o/other.o" &&
     $cc -c "$S/rt.c" -o "$o/rt.o" &&
     "$B/clang++" -g -O0 -Wall -Werror -fno-exceptions -fno-rtti -c "$S/cxx.cpp" -o "$o/cxx.o" &&
     "$B/clang" -c "$S/asm.s" -o "$o/asm.o" && "$B/clang" -c "$S/start.s" -o "$o/start.o" &&
     "$B/clang++" -nostartfiles -nolibc -nostdlib++ -T "$S/qemu.ld" "$o/start.o" "$o/main.o" \
       "$o/other.o" "$o/rt.o" "$o/cxx.o" "$o/asm.o" -o "$o/test.elf" 2> "$o/build.log"; then
    port=$((20000 + $$ % 20000))
    head -c 16 /dev/zero > "$tmp/bios.bin"
    "$QEMU" -M gdbsim-r5f562n8 -bios "$(w "$tmp/bios.bin")" -display none -serial none \
      -monitor none -device loader,file="$(w "$tmp/$o/test.elf")",cpu-num=0 -S \
      -gdb tcp:127.0.0.1:$port > "$o/qemu.log" 2>&1 &
    qemu_pid=$!
    # Until the gdbstub listens (a connection that closes leaves it stopped).
    for _ in $(seq 50); do
      (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null && break
      sleep 0.2
    done
    cmds=(
      "breakpoint set -n c_sum6" "continue" "bt" "frame variable x" "finish"
      "breakpoint delete -f 1" "breakpoint set -n overload" "continue" "bt" "frame variable" "finish"
      "kill"
    )
    args=()
    for c in "${cmds[@]}"; do args+=(-o "$c"); done
    # LLDB's own exit status, not tr's (there is no pipefail).
    timeout -k 10 "${LLDB_TIMEOUT:-120}" "$LLDB" -b -x -o "settings set use-color false" \
      -o "target create $(w "$tmp/$o/test.elf")" -o "gdb-remote 127.0.0.1:$port" \
      "${args[@]}" 2>&1 | tr -d '\r' > "$o/lldb.log"
    lldb_status=${PIPESTATUS[0]}
    kill "$qemu_pid" 2> /dev/null || true
    wait "$qemu_pid" 2> /dev/null || true
    qemu_pid=
    lstatus=$status
    expect() {
      grep -q -E -- "$2" "$o/lldb.log" && ok "lldb: $1" || fail "lldb: $1: no /$2/"
    }
    case $lldb_status in
      0) ;;
      124 | 137) fail "lldb: did not finish in ${LLDB_TIMEOUT:-120} s" ;;
      *) fail "lldb: exited with status $lldb_status" ;;
    esac
    expect "stops in C"           "frame #0: 0x[0-9a-f]+ test\\.elf\`c_sum6\\(s=.*, x=4\\) at other\\.c:[0-9]+"
    expect "C backtrace"          "frame #1: 0x[0-9a-f]+ test\\.elf\`main at main\\.c:101"
    expect "C argument"           '^\(int\) x = 4$'
    expect "finish in C"          'Return value: \(int\) \$[0-9]+ = 25$'
    expect "stops in C++"         "frame #0: 0x[0-9a-f]+ test\\.elf\`overload\\(x=1\\) at cxx\\.cpp:63"
    expect "C++ backtrace"        "frame #1: 0x[0-9a-f]+ test\\.elf\`(::)?cxx_tests\\(\\) at cxx\\.cpp:96"
    expect "finish in C++"        'Return value: \(int\) \$[0-9]+ = 2$'
    grep -q -E 'Assertion|Stack dump|PLEASE submit' "$o/lldb.log" && fail "lldb crashed"
    if [ $status != $lstatus ]; then
      echo "   (the LLDB session:)"; cat "$o/lldb.log"
    fi
  else
    fail "lldb: the -g program does not build"
    cat "$o/build.log" 2> /dev/null || true
  fi
fi

# The first .note.rx.abi word of an object, or of each member of an archive.
note() {
  "$B/llvm-readelf" -n "$1" | awk '/^File: .*\(/ {multi = 1} /description data:/ {print $3; if (!multi) exit}'
}

# libclang_rt.builtins.a: where the driver links it from, what rt.o calls in
# it, and its objects' .note.rx.abi (neither convention, so both link it).
rtlib=$("$B/clang" -print-libgcc-file-name | tr -d '\r')
if command -v cygpath > /dev/null; then rtlib=$(cygpath -u "$rtlib"); fi
[ -f "$rtlib" ] && ok "${rtlib#$T/}: $("$B/llvm-ar" t "$rtlib" | wc -l) objects" ||
  fail "no libclang_rt.builtins.a at $rtlib"
undef=$("$B/llvm-nm" -u default-rx600-O2/rt.o)
for s in ___addsf3 ___mulsf3 ___divsf3 ___adddf3 ___divdf3 ___divdi3 ___udivdi3 ___umoddi3 ___lshrdi3 ___fixdfdi; do
  echo "$undef" | grep -q " $s\$" && "$B/llvm-nm" default-rx600-O2/test.elf | grep -q " $s\$" &&
    ok "rt.o calls $s, linked from the builtins" || fail "rt.o / test.elf: $s"
done
[ "$(note "$rtlib" | sort -u)" = 03 ] && ok "the builtins' .note.rx.abi: 03 (neither)" ||
  fail "the builtins' .note.rx.abi: $(note "$rtlib" | sort -u | tr '\n' ' ')"

# The calling-convention note and ld.lld's check of it.
for x in "default-rx600-O2/main.o 01" "ccrx-rx600-O2/other.o 01" "gnu-rx600-O2/main.o 02" "gnu-rx600-O2/other.o 02"; do
  set -- $x
  [ "$(note "$1")" = "$2" ] && ok "$1: .note.rx.abi $2" || fail "$1: .note.rx.abi '$(note "$1")', want $2"
done
[ -f default-rx600-O2/asm.o ] && [ -z "$(note default-rx600-O2/asm.o)" ] && ok "asm.o: no .note.rx.abi" || fail "asm.o has a .note.rx.abi"
m=default-rx600-O2 g=gnu-rx600-O2
mixed="$m/start.o $m/main.o $g/other.o $m/rt.o $m/cxx.o $m/asm.o $rtlib"
if out=$("$B/ld.lld" -T "$S/qemu.ld" $mixed -o mixed.elf 2>&1); then
  fail "ld.lld links CC-RX and GNURX objects together"
else
  echo "$out" | grep -q "error: .*calling convention" &&
    ok "ld.lld refuses CC-RX and GNURX objects: $(echo "$out" | head -1)" ||
    { fail "ld.lld fails, but not on the calling convention"; echo "$out"; }
fi
if out=$("$B/ld.lld" -T "$S/qemu.ld" -z rx-abi-check=warning $mixed -o mixed.elf 2>&1) &&
   echo "$out" | grep -q "warning: .*calling convention"; then
  ok "-z rx-abi-check=warning links them with a warning"
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
