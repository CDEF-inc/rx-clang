#!/bin/bash
# Packs build/install (scripts/build.sh) into one archive:
#
#   dist.sh [NAME]   on Linux:   build/dist/NAME.tar.xz
#                                (default rx-clang-x86_64-linux)
#                    on Windows (Git Bash): build/dist/NAME.zip
#                                (default rx-clang-x86_64-windows)
#
# The archive holds NAME/ with
#   bin/        clang, clang++, clang-cpp, ld.lld, llvm-mc, llc and the LLVM
#               binary tools (build.sh); on Linux the aliases are symbolic
#               links, on Windows copies (a zip has no links)
#   lib/clang/N/include   clang's resource headers
#   VERSIONS    the commits it was built from, and the glibc it needs
#   LICENSE.TXT llvm-project's license (Apache-2.0 WITH LLVM-exception)
#   SBOM.spdx.json, SBOM.cdx.json  the software bill of materials, as SPDX
#               2.3 and as CycloneDX 1.6 (scripts/sbom.py), also written
#               next to the archive as build/dist/NAME.spdx.json and
#               NAME.cdx.json
#
# The Linux programs need only glibc, libstdc++, libgcc_s and zlib, of the
# machine that built them or later: the CI builds on Ubuntu 22.04 (glibc
# 2.35), so they run on Ubuntu 22.04, Debian 12 and later. The Windows ones
# need nothing installed (the MSVC runtime is linked statically).
# scripts/check-dist.sh tests an archive.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
inst=$root/build/install
case $(uname -s) in
MINGW*|MSYS*) win=1; exe=.exe; name=${1:-rx-clang-x86_64-windows} ;;
*) win=; exe=; name=${1:-rx-clang-x86_64-linux} ;;
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

if [ -z "$win" ]; then
  # Every program must run with the base system libraries: one that CMake
  # picked up from the build machine (libxml2, libedit, ...) would be
  # missing elsewhere.
  missing=$(find "$d/bin" -type f -perm -u+x -print0 |
    while IFS= read -r -d '' f; do
      ldd "$f" 2>/dev/null | awk -v f="${f#$d/}" '$2 == "=>" && $3 ~ /^\// {print f ": " $3}'
    done | grep -v -E ': /[^ ]*/(libc|libm|libdl|libpthread|librt|libutil|libresolv|ld-linux[^/]*|libgcc_s|libstdc\+\+|libz)\.so' || true)
  if [ -n "$missing" ]; then
    echo "programs that need libraries from this machine (not in the archive):" >&2
    echo "$missing" >&2
    exit 1
  fi
fi

llvm=$(git -C "$root/llvm-project" rev-parse HEAD)
rxclang=$(git -C "$root" rev-parse HEAD)
clang_version=$("$d/bin/clang" --version | head -1 | tr -d '\r')
{
  echo "rx-clang       $rxclang"
  echo "llvm-project   $llvm"
  echo "clang          $clang_version"
  echo "target         $("$d/bin/clang" -print-target-triple | tr -d '\r') (default)"
  # The newest glibc symbol version any program refers to.
  [ -n "$win" ] || echo "needs glibc    $(find "$d/bin" -type f -perm -u+x -exec objdump -T {} + 2>/dev/null |
    grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1) or later"
} > "$d/VERSIONS"
cat "$d/VERSIONS"

p() { if [ -n "$win" ]; then cygpath -m "$1"; else echo "$1"; fi; }
"$py" "$(p "$root/scripts/sbom.py")" --out "$(p "$d/SBOM.spdx.json")" \
  --cyclonedx "$(p "$d/SBOM.cdx.json")" --name "$name" \
  --rx-clang "$rxclang" --llvm "$llvm" --clang-version "$clang_version"

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
