#!/bin/bash
# Points the llvm-project submodule at the LLVM that rx-rust uses, so that
# C, C++, assembly and Rust objects come from the same backend (and carry
# the same .note.rx.abi rules).
#
#   update-llvm.sh [REF]      set the submodule to rx-rust REF's LLVM
#                             (default main; a release tag such as
#                             toolchain-2026-11-13.1 works too) and stage it
#   update-llvm.sh --check [REF]   only compare: exit 1 if they differ
#
# rx-rust pins LLVM indirectly: its rust submodule (CDEF-inc/rust) has
# src/llvm-project (CDEF-inc/llvm-project). Both are read through the
# GitHub API (gh), so no rust or LLVM checkout is needed; the new commit is
# written into the index (and fetched into llvm-project/ when it is checked
# out). Commit the result as "Bump llvm-project to rx-rust REF".
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
check=
[ "${1:-}" = --check ] && { check=1; shift; }
ref=${1:-main}
command -v gh > /dev/null || { echo "needs gh (GitHub CLI)" >&2; exit 2; }

rust=$(gh api "repos/CDEF-inc/rx-rust/contents/rust?ref=$ref" --jq .sha)
want=$(gh api "repos/CDEF-inc/rust/contents/src/llvm-project?ref=$rust" --jq .sha)
have=$(git -C "$root" rev-parse HEAD:llvm-project)
echo "rx-rust $ref: rust $rust, llvm-project $want"
echo "rx-clang:     llvm-project $have"
if [ "$want" = "$have" ]; then
  echo "up to date"
  exit 0
fi
[ -n "$check" ] && { echo "differs: run scripts/update-llvm.sh $ref"; exit 1; }

git -C "$root" update-index --cacheinfo "160000,$want,llvm-project"
if [ -e "$root/llvm-project/.git" ]; then
  git -C "$root/llvm-project" fetch -q --depth 1 origin "$want"
  git -C "$root/llvm-project" checkout -q "$want"
fi
echo "staged llvm-project $want; commit it:"
echo "  git commit -m 'Bump llvm-project to rx-rust $ref ($(echo "$want" | cut -c1-12))'"
