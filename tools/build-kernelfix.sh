#!/usr/bin/env bash
# Rebuilds lib/kernelfix.so.b64 (the kernel-version preload library) from tools/kernelfix.s.
# You only need this after you change the assembly. It needs an assembler and a linker for x86-64:
#   on an x86-64 Linux PC:   sudo apt install binutils
#   on an ARM machine:       sudo apt install binutils-x86-64-linux-gnu   (the tools are then called x86_64-linux-gnu-as / -ld)
#
#     bash tools/build-kernelfix.sh            writes lib/kernelfix.so.b64
#     bash tools/build-kernelfix.sh FILE       writes FILE instead (the test uses this to compare with the shipped one)
#
# The library is base64 text so that it can sit in the repository like any other file, and is decoded when it is
# needed. bash tests/t_kernelfix.sh checks that what is in the repository loads, works and still matches the source.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$HERE/lib/kernelfix.so.b64}
AS=as
LD=ld
if [ "$(uname -m)" != x86_64 ] || ! command -v as >/dev/null 2>&1; then AS=x86_64-linux-gnu-as; LD=x86_64-linux-gnu-ld; fi
command -v "$AS" >/dev/null 2>&1 || { echo "build-kernelfix: $AS is missing (see the top of this file)" >&2; exit 1; }
command -v "$LD" >/dev/null 2>&1 || { echo "build-kernelfix: $LD is missing (see the top of this file)" >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/kernelfix.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$AS" --64 -o "$tmp/kernelfix.o" "$HERE/tools/kernelfix.s"
# no libc, no relocations, no version information (box64 then accepts the library for every version of uname)
"$LD" -shared -o "$tmp/kernelfix.so" "$tmp/kernelfix.o" -soname spft-kernelfix.so --hash-style=sysv \
  -z noexecstack -z max-page-size=0x1000 -z common-page-size=0x1000 -z noseparate-code --build-id=none -s
base64 "$tmp/kernelfix.so" > "$OUT"
echo "wrote $OUT ($(wc -c < "$tmp/kernelfix.so") bytes of library)"
