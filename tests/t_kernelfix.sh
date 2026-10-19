#!/bin/bash
# Test of the kernel-version fix: lib/kernelfix.sh (which kernels are affected, what to show) and lib/kernelfix.so.b64
# (the tiny x86-64 library that makes uname() say it). Needs: bash, base64. Optional: readelf (checks the library's
# structure), as + ld + objcopy (checks that the library still matches tools/kernelfix.s), an x86-64 Linux machine
# with python3 (loads the library into real programs). Whatever is missing is skipped, and said so.
# On purpose in the tests: ok/bad always return 0, patterns are literal text, printf builds escapes.
# shellcheck disable=SC2015,SC2016,SC2012,SC2002,SC2059
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v base64 >/dev/null || { echo "ABORT: base64 is needed for this test"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/spft-kfix.XXXXXX")
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
FAKE=/tmp/spft-fake-kernel     # the path the library reads: fixed inside it, so the test keeps whatever is there and puts it back
BACKUP=
if [ -e "$FAKE" ] || [ -L "$FAKE" ]; then BACKUP=$T/fake.backup; cp -P -p "$FAKE" "$BACKUP" 2>/dev/null || BACKUP=; fi
restore() { rm -rf "$FAKE"; if [ -n "$BACKUP" ] && [ -e "$BACKUP" ]; then cp -p "$BACKUP" "$FAKE"; fi; }
trap restore EXIT
rm -rf "$FAKE"

# shellcheck source=lib/kernelfix.sh
. "$REPO/lib/kernelfix.sh"

echo "=== 1. which kernels does SP Flash Tool v5 turn away by mistake? (kernelfix_class)"
expect_class() { # expect_class RELEASE EXPECTED
  local got
  got=$(kernelfix_class "$1")
  if [ "$got" = "$2" ]; then ok "'$1' -> $2"; else bad "'$1' -> $got (expected $2)"; fi
}
# text: new enough, but "4.19.127" sorts before "4.19.14" as text
for r in 4.19.100 4.19.127 4.19.127-g8d3429bdb336 4.19.139 4.19.139+ 04.019.0127; do expect_class "$r" text; done
# fine: the tool accepts it (4.19.14 itself, anything from 4.19.14 to 4.19.99 sorts after 4.19.14 as text too, and newer)
for r in 4.19.14 4.19.15 4.19.99 4.19.140 4.19.157 4.20.0 5.4.0 5.10.43-android12-9 6.1.75 10.0.0; do expect_class "$r" fine; done
# old: older than 4.19.14
for r in 4.19.13 4.19.0 4.19 4.18.20 4.14.186 4.9.337-perf 3.18.140 3.10.108-g1234; do expect_class "$r" old; done
# unreadable
for r in '' garbage 4 x.y.z; do expect_class "$r" unknown; done

echo; echo "=== 2. what is the tool shown? (kernelfix_show RELEASE MODE)"
expect_show() { # expect_show RELEASE MODE EXPECTED_OUTPUT EXPECTED_STATUS
  local out rc=0
  out=$(kernelfix_show "$1" "$2") || rc=$?
  if [ "$out" = "$3" ] && [ "$rc" = "$4" ]; then ok "release '$1', mode '$2' -> '${out:-nothing}' (status $rc)"; else bad "release '$1', mode '$2' -> '$out' (status $rc), expected '$3' (status $4)"; fi
}
expect_show 4.19.127 auto 4.19.140 0
expect_show 4.19.127 '' 4.19.140 0
expect_show 4.19.100 auto 4.19.140 0
expect_show 4.19.139 auto 4.19.140 0
expect_show 5.10.43 auto '' 0
expect_show 4.19.140 auto '' 0
expect_show 4.14.186 auto '' 0
expect_show 4.19.127 off '' 0
for m in no none false 0; do expect_show 4.19.127 "$m" '' 0; done
expect_show 4.14.186 5.4.0 5.4.0 0
expect_show 5.10.43 4.19.140 4.19.140 0
expect_show 4.19.127 5.4.0-x_y+z 5.4.0-x_y+z 0
v64=$(printf 'a%.0s' $(seq 1 64)); v65=${v64}a
expect_show 4.19.127 "$v64" "$v64" 0
expect_show 4.19.127 "$v65" '' 1
for m in '5.4 0' '5.4.0;rm' '$(id)' '`id`' '5.4.0/x' '"a"' "a'b"; do expect_show 4.19.127 "$m" '' 1; done

echo; echo "=== 3. the library that is in the repository"
base64 -d "$REPO/lib/kernelfix.so.b64" > "$T/kfix.so" 2>/dev/null && ok "lib/kernelfix.so.b64 decodes" || bad "lib/kernelfix.so.b64 does not decode"
size=$(wc -c < "$T/kfix.so")
[ "$size" -gt 500 ] && [ "$size" -lt 8192 ] && ok "the library is $size bytes" || bad "the library is $size bytes"
if [ "$(head -c 4 "$T/kfix.so" | od -An -c | tr -d ' ')" = '177ELF' ]; then ok "it is an ELF file"; else bad "it is not an ELF file"; fi
if ! command -v readelf >/dev/null; then
  ok "(readelf is not installed: the structure checks are skipped)"
else
  h=$(readelf -h "$T/kfix.so" 2>&1); d=$(readelf -d "$T/kfix.so" 2>&1); r=$(readelf -r "$T/kfix.so" 2>&1)
  s=$(readelf -S "$T/kfix.so" 2>&1); y=$(readelf --dyn-syms "$T/kfix.so" 2>&1); l=$(readelf -l "$T/kfix.so" 2>&1)
  case $h in *"ELF64"*"X86-64"*) ok "64-bit x86-64" ;; *) bad "not a 64-bit x86-64 file" ;; esac
  case $h in *"DYN (Shared object file)"*) ok "a shared library" ;; *) bad "not a shared library" ;; esac
  case $d in *"(NEEDED)"*) bad "it needs another library (it must need none)" ;; *) ok "it needs no other library (not even libc)" ;; esac
  case $r in *"no relocations"*) ok "no relocations" ;; *) bad "it has relocations" ;; esac
  case $s in *".gnu.version"*) bad "it has version information (box64 would then be picky about the uname version)" ;; *) ok "no version information: it matches every version of uname()" ;; esac
  case $s in *".interp"*) bad "it has an interpreter entry" ;; *) ok "no interpreter entry" ;; esac
  if printf '%s\n' "$y" | grep -Eq 'FUNC +GLOBAL +DEFAULT +[0-9]+ uname$'; then ok "it exports the function uname"; else bad "it does not export uname"; printf '%s\n' "$y"; fi
  if [ "$(printf '%s\n' "$y" | grep -c 'GLOBAL')" = 1 ]; then ok "uname is the only thing it exports"; else bad "it exports more than uname"; fi
  if printf '%s\n' "$l" | grep -A1 GNU_STACK | tail -n 1 | grep -q 'RW  '; then ok "the stack is not executable"; else bad "the stack may be executable"; fi
fi

echo; echo "=== 4. it still matches its source, tools/kernelfix.s"
cross=
[ "$(uname -m)" = x86_64 ] || cross=x86_64-linux-gnu-
if command -v "${cross}as" >/dev/null && command -v "${cross}ld" >/dev/null && command -v objcopy >/dev/null; then
  if bash "$REPO/tools/build-kernelfix.sh" "$T/rebuilt.b64" > "$T/build.out" 2>&1; then
    base64 -d "$T/rebuilt.b64" > "$T/rebuilt.so"
    same=1
    for sec in .text .rodata; do
      objcopy -O binary --only-section="$sec" "$T/kfix.so" "$T/a$sec" 2>/dev/null
      objcopy -O binary --only-section="$sec" "$T/rebuilt.so" "$T/b$sec" 2>/dev/null
      if cmp -s "$T/a$sec" "$T/b$sec" && [ -s "$T/a$sec" ]; then ok "the section $sec is the same as in a fresh build"; else bad "the section $sec differs from a fresh build (run: bash tools/build-kernelfix.sh)"; same=0; fi
    done
    if [ "$same" = 1 ] && cmp -s "$T/kfix.so" "$T/rebuilt.so"; then ok "(the library is even byte for byte the same)"; fi
  else
    bad "tools/build-kernelfix.sh failed:"; cat "$T/build.out"
  fi
else
  ok "(as, ld or objcopy is not installed: the comparison with tools/kernelfix.s is skipped)"
fi

echo; echo "=== 5. loaded into real programs (LD_PRELOAD), the way box64 loads it for the tool"
if [ "$(uname -m)" != x86_64 ] || [ "$(uname -s)" != Linux ]; then
  ok "(this machine is not an x86-64 Linux: the real-program tests are skipped; box64 does this on the phone)"
elif ! command -v python3 >/dev/null; then
  ok "(python3 is not installed: the real-program tests are skipped)"
else
  UN=$(command -v uname)
  real_rel=$("$UN" -r)
  real_rest=$("$UN" -s -n -v -m)
  pre() { LD_PRELOAD="$T/kfix.so" "$@"; }
  set_fake() { printf "$1" > "$FAKE"; }
  # each field of struct utsname, as a program sees it: six fields of 65 bytes
  fields='import ctypes, sys
b = ctypes.create_string_buffer(390)
if ctypes.CDLL(None, use_errno=True).uname(b) != 0: sys.exit(3)
raw = b.raw
print("|".join(raw[i * 65:(i + 1) * 65].split(b"\0", 1)[0].decode("latin-1") for i in range(6)))'
  real_fields=$(python3 -I -c "$fields")

  rm -rf "$FAKE"
  [ "$(pre "$UN" -r)" = "$real_rel" ] && ok "no file: the real release ($real_rel) is shown" || bad "no file: uname -r changed"
  set_fake '4.19.140\n'
  [ "$(pre "$UN" -r)" = 4.19.140 ] && ok "the file says 4.19.140: uname -r prints it" || bad "uname -r printed '$(pre "$UN" -r)'"
  [ "$(pre "$UN" -s -n -v -m)" = "$real_rest" ] && ok "sysname, nodename, version and machine are the real ones" || bad "another field changed"
  [ "$(pre python3 -I -c 'import os; print(os.uname().release)')" = 4.19.140 ] && ok "python's os.uname().release is 4.19.140" || bad "os.uname().release differs"
  got=$(pre python3 -I -c "$fields")
  want=$(printf '%s' "$real_fields" | awk -F'|' -v OFS='|' '{ $3 = "4.19.140"; print }')
  [ "$got" = "$want" ] && ok "all six fields: only the release changed (domainname included)" || bad "fields: '$got', expected '$want'"
  [ "$(pre "$UN" -r 2>&1 | wc -l)" = 1 ] && ok "it prints nothing of its own" || bad "extra output"

  set_fake '5.4.0'
  [ "$(pre "$UN" -r)" = 5.4.0 ] && ok "a file without a newline works" || bad "no-newline file: '$(pre "$UN" -r)'"
  set_fake '5.4.0\n6.1.0\n'
  [ "$(pre "$UN" -r)" = 5.4.0 ] && ok "only the first line counts" || bad "two lines: '$(pre "$UN" -r)'"
  set_fake 'ab\0cd\n'
  [ "$(pre "$UN" -r)" = ab ] && ok "a zero byte ends the text" || bad "zero byte: '$(pre "$UN" -r)'"
  set_fake "$v64\n"
  [ "$(pre python3 -I -c 'import os; print(len(os.uname().release))')" = 64 ] && ok "a 64-character line fits" || bad "a 64-character line was cut"
  set_fake "$(printf 'b%.0s' $(seq 1 100))\n"
  [ "$(pre python3 -I -c 'import os; r = os.uname().release; print(len(r), r[:3])')" = '64 bbb' ] && ok "a 100-character line is cut to 64 characters, and ends properly" || bad "a long line: '$(pre python3 -I -c 'import os; print(len(os.uname().release))')'"
  [ "$(pre python3 -I -c "$fields" | cut -d'|' -f4-)" = "$(printf '%s' "$real_fields" | cut -d'|' -f4-)" ] && ok "a long line does not spill into the next fields" || bad "a long line damaged version, machine or domainname"

  for spec in 'an empty file|' 'a file with only a newline|\n' 'a file whose first line is empty|\nsecond\n'; do
    set_fake "${spec#*|}"
    [ "$(pre "$UN" -r)" = "$real_rel" ] && ok "${spec%%|*}: the real release stays" || bad "${spec%%|*}: '$(pre "$UN" -r)'"
  done
  rm -rf "$FAKE"; mkdir "$FAKE"
  [ "$(pre "$UN" -r)" = "$real_rel" ] && ok "a folder in place of the file: the real release" || bad "a folder: '$(pre "$UN" -r)'"
  rmdir "$FAKE"
  [ "$(pre "$UN" -r)" = "$real_rel" ] && ok "the file is gone again: the real release" || bad "file removed: '$(pre "$UN" -r)'"
  [ "$("$UN" -r)" = "$real_rel" ] && ok "programs started without the library are not affected" || bad "uname changed without the library"
fi

echo
echo "FAIL count: $fails"
rm -rf "$FAKE"
if [ -n "$BACKUP" ] && [ -e "$BACKUP" ]; then cp -p "$BACKUP" "$FAKE"; fi
trap - EXIT
rm -rf "$T"; echo "cleaned up"
[ "$fails" -eq 0 ]
