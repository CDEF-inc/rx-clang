#!/bin/bash
# Packs build/install (scripts/build.sh), with LLDB and qemu-system-rx from
# an rx-rust release archive, into one archive:
#
#   dist.sh RX_RUST_ARCHIVE [NAME]
#                    on Linux:   build/dist/NAME.tar.xz
#                                (default rx-clang-x86_64-linux)
#                    on Windows (Git Bash): build/dist/NAME.zip
#                                (default rx-clang-x86_64-windows)
#
# RX_RUST_ARCHIVE is a CDEF-inc/rx-rust release archive for the same host
# (rx-toolchain-x86_64-linux.tar.xz or rx-toolchain-x86_64-windows.zip; the
# CI takes the release in .github/rx-rust-release). Its LLDB must be built
# from this llvm-project commit (its VERSIONS says so); only LLDB, QEMU and
# their libraries are taken from it.
#
# The archive holds NAME/ with
#   bin/        clang, clang++, clang-cpp, ld.lld, llvm-mc, llc and the LLVM
#               binary tools (build.sh); on Linux the aliases are symbolic
#               links, on Windows copies (a zip has no links); lldb and
#               qemu-system-rx (on Windows with liblldb.dll and QEMU's DLLs)
#   lib/clang/N/include   clang's resource headers
#   lib/        on Linux liblldb and the shared libraries qemu-system-rx
#               needs beyond glibc (glib, pixman, ...), as in rx-rust's
#               archive (the programs' RUNPATH is $ORIGIN/../lib)
#   VERSIONS    the commits it was built from, and the glibc it needs
#   LICENSE.TXT llvm-project's license (Apache-2.0 WITH LLVM-exception)
#   COPYING.QEMU  QEMU's license (GPL-2.0), from CDEF-inc/qemu at the commit
#               that qemu-system-rx was built from
#   SBOM.spdx.json, SBOM.cdx.json  the software bill of materials, as SPDX
#               2.3 and as CycloneDX 1.6 (scripts/sbom.py), also written
#               next to the archive as build/dist/NAME.spdx.json and
#               NAME.cdx.json
#
# The Linux programs need only glibc, libstdc++, libgcc_s and zlib, of the
# machine that built them or later (and what lib/ brings): the CI builds on
# Ubuntu 22.04 (glibc 2.35), as rx-rust's does, so they run on Ubuntu
# 22.04, Debian 12 and later. The Windows ones need nothing installed (the
# MSVC runtime is linked statically). scripts/check-dist.sh tests an
# archive.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
inst=$root/build/install
[ $# -ge 1 ] && [ -f "$1" ] || { echo "usage: $0 RX_RUST_ARCHIVE [NAME]" >&2; exit 2; }
rxrust=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
case $(uname -s) in
MINGW*|MSYS*) win=1; exe=.exe; name=${2:-rx-clang-x86_64-windows} ;;
*) win=; exe=; name=${2:-rx-clang-x86_64-linux} ;;
esac
for t in clang clang++ ld.lld llvm-mc llc llvm-ar llvm-objcopy llvm-objdump llvm-nm llvm-readelf; do
  [ -e "$inst/bin/$t$exe" ] || { echo "no $inst/bin/$t$exe; run scripts/build.sh" >&2; exit 2; }
done
ls -d "$inst"/lib/clang/*/include/stdint.h > /dev/null ||
  { echo "no resource headers in $inst/lib/clang; run scripts/build.sh" >&2; exit 2; }
py=python3
python3 -c '' 2> /dev/null || py=python   # Windows: python3 may be the Store's stub
"$py" -c '' || { echo "needs python3 (scripts/sbom.py)" >&2; exit 2; }

mkdir -p "$root/build/dist"
tmp=$root/build/dist/tmp
rm -rf "$tmp"
trap 'rm -rf "$tmp"' EXIT
d=$tmp/$name
mkdir -p "$d"
cp -a "$inst/bin" "$inst/lib" "$d/"
cp "$root/llvm-project/llvm/LICENSE.TXT" "$d/LICENSE.TXT"
llvm=$(git -C "$root/llvm-project" rev-parse HEAD)

# LLDB and qemu-system-rx from the rx-rust archive: unpack only them, their
# libraries, its VERSIONS and its SBOM (for theirs).
r=$tmp/rx-rust
mkdir -p "$r"
if [ -n "$win" ]; then
  "$SYSTEMROOT/System32/tar.exe" -C "$(cygpath -w "$r")" -xf "$(cygpath -w "$rxrust")" \
    '*/VERSIONS' '*/SBOM.spdx.json' '*/bin/lldb.exe' '*/bin/qemu-system-rx.exe' '*/bin/*.dll'
else
  tar -C "$r" -xJf "$rxrust" --wildcards '*/VERSIONS' '*/SBOM.spdx.json' '*/bin/lldb' \
    '*/bin/qemu-system-rx' '*/lib/lib*.so*' --exclude='*/lib/librustc_driver*'
fi
R=$(ls -d "$r"/*/ | head -1)
R=${R%/}
rv() { awk -v k="$1" '$1 == k {sub(/^[^ ]+ +/, ""); print; exit}' "$R/VERSIONS" | tr -d '\r'; }
[ "$(rv llvm-project)" = "$llvm" ] || {
  echo "$rxrust: its LLDB is built from llvm-project $(rv llvm-project), this is $llvm:" >&2
  echo "use the rx-rust release of this LLVM (.github/rx-rust-release, scripts/update-llvm.sh)" >&2
  exit 2
}
for t in lldb qemu-system-rx; do
  [ -f "$R/bin/$t$exe" ] || { echo "$rxrust has no bin/$t$exe" >&2; exit 2; }
  cp "$R/bin/$t$exe" "$d/bin/"
done
if [ -n "$win" ]; then
  # liblldb.dll and QEMU's (MinGW) DLLs; not rustc's.
  for f in "$R"/bin/*.dll; do
    case $(basename "$f") in rustc_driver-*) ;; *) cp "$f" "$d/bin/" ;; esac
  done
else
  cp -a "$R"/lib/lib*.so* "$d/lib/"
fi
qemu=$(rv qemu | awk '{print $1}')
# QEMU is GPL-2.0: its license goes with the program, from the commit that
# rx-rust built it from.
curl -fsSL --retry 3 -o "$d/COPYING.QEMU" \
  "https://raw.githubusercontent.com/CDEF-inc/qemu/$qemu/COPYING" ||
  { echo "cannot fetch QEMU's COPYING at $qemu" >&2; exit 2; }

if [ -z "$win" ]; then
  # Every program must run with the base system libraries and what lib/
  # brings: one that CMake picked up from the build machine (libxml2,
  # libedit, ...) would be missing elsewhere.
  missing=$(find "$d/bin" "$d/lib" -maxdepth 1 -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
    while IFS= read -r -d '' f; do
      ldd "$f" 2>/dev/null | awk -v f="${f#$d/}" '$2 == "=>" && $3 ~ /^\// {print f ": " $3}'
    done | grep -v -F "$d/" |
    grep -v -E ': /[^ ]*/(libc|libm|libdl|libpthread|librt|libutil|libresolv|ld-linux[^/]*|libgcc_s|libstdc\+\+|libz)\.so' || true)
  if [ -n "$missing" ]; then
    echo "programs that need libraries from this machine (not in the archive):" >&2
    echo "$missing" >&2
    exit 1
  fi
fi

rxclang=$(git -C "$root" rev-parse HEAD)
clang_version=$("$d/bin/clang" --version | head -1 | tr -d '\r')
{
  echo "rx-clang       $rxclang"
  echo "llvm-project   $llvm"
  echo "clang          $clang_version"
  echo "target         $("$d/bin/clang" -print-target-triple | tr -d '\r') (default)"
  echo "lldb           $(rv lldb)"
  echo "qemu           $qemu"
  echo "qemu-system-rx $(rv qemu-system-rx)"
  echo "rx-rust        $(rv rx-rust) (lldb and qemu-system-rx are from its archive)"
  # The newest glibc symbol version any program or library refers to.
  [ -n "$win" ] || echo "needs glibc    $(find "$d/bin" "$d/lib" -maxdepth 1 -type f \( -perm -u+x -o -name '*.so*' \) \
    -exec objdump -T {} + 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1) or later"
} > "$d/VERSIONS"
cat "$d/VERSIONS"

p() { if [ -n "$win" ]; then cygpath -m "$1"; else echo "$1"; fi; }
"$py" "$(p "$root/scripts/sbom.py")" --out "$(p "$d/SBOM.spdx.json")" \
  --cyclonedx "$(p "$d/SBOM.cdx.json")" --name "$name" \
  --rx-clang "$rxclang" --llvm "$llvm" --clang-version "$clang_version" \
  --rx-rust-sbom "$(p "$R/SBOM.spdx.json")"

if [ -n "$win" ]; then
  out=$root/build/dist/$name.zip
  rm -f "$out"
  # Windows's own tar (bsdtar); Git Bash's cannot write a zip.
  (cd "$tmp" && "$SYSTEMROOT/System32/tar.exe" -a -cf "$(cygpath -w "$out")" "$name")
else
  out=$root/build/dist/$name.tar.xz
  tar -C "$tmp" -cf - "$name" | xz -T0 -6 > "$out"
fi
cp "$d/SBOM.spdx.json" "$root/build/dist/$name.spdx.json"
cp "$d/SBOM.cdx.json" "$root/build/dist/$name.cdx.json"
ls -l "$out" "$root/build/dist/$name".{spdx,cdx}.json
