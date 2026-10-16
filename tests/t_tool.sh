#!/bin/bash
# Test of `spft tool`: finding or downloading SP Flash Tool, checking it, unpacking it into Debian's /opt.
# Stand-ins for su, curl, chroot (only `od`) and a fake Debian folder. Needs: bash, zip, unzip, sha256sum, sed.
# It refuses to run where a real /system/bin/mount exists.
# On purpose in the tests: ok/bad always return 0, patterns are literal text, printf builds escapes.
# shellcheck disable=SC2015,SC2016,SC2012,SC2002,SC2059
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
if [ -e /system/bin/mount ]; then echo "ABORT: /system/bin/mount exists here"; exit 1; fi
for c in zip unzip sha256sum; do command -v $c >/dev/null || { echo "ABORT: $c is needed for this test"; exit 1; }; done
T=$(mktemp -d "${TMPDIR:-/tmp}/spft-tool.XXXXXX")
mkdir -p "$T/bin" "$T/pfx/bin" "$T/pfx/lib" "$T/sysbin" "$T/dl" "$T/root/bin" "$T/root/opt" \
         "$T/home/storage/downloads" "$T/media/Download" "$T/served" "$T/stage"
ln -s "$(type -P bash)" "$T/pfx/bin/bash"
ln -s "$(type -P unzip)" "$T/pfx/bin/unzip"
cp "$(type -P true)" "$T/root/bin/bash"
CURL_LOG=$T/curl.log; : > "$CURL_LOG"
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { if grep -q -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }

# --- stand-ins ------------------------------------------------------------------------------------
cat > "$T/bin/su" <<EOF
#!/bin/bash
[ "\$1" = -c ] || exit 2
[ "\$2" != "id -u" ] || { echo 0; exit 0; }
exec env FAKE_ROOT=1 sh -c "\$2"
EOF
# curl: serves $T/served/<host>/<file name>; 404 (exit 22) when that file is not there; logs what it was asked
cat > "$T/bin/curl" <<EOF
#!/bin/bash
out= ref= url=
while [ \$# -gt 0 ]; do
  case \$1 in
    -o) out=\$2; shift 2 ;;
    -e) ref=\$2; shift 2 ;;
    -A | -b | --retry | --retry-delay | --connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
echo "curl url=\$url referer=\$ref" >> "$CURL_LOG"
hp=\${url#*://}; host=\${hp%%/*}; file=\${hp##*/}
if [ -f "$T/served/\$host/\$file" ]; then cp "$T/served/\$host/\$file" "\$out"; exit 0; fi
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
EOF
# chroot: only the one command spft runs in there, `od` on a path inside /opt
cat > "$T/sysbin/chroot" <<'EOF'
#!/bin/bash
root=$1; shift
cmd=$1; shift
if [ "$cmd" = /usr/bin/od ]; then
  args=()
  for a in "$@"; do case $a in /opt/*) args+=("$root$a") ;; *) args+=("$a") ;; esac; done
  exec od "${args[@]}"
fi
echo "chroot stand-in: unexpected command $cmd" >&2
exit 1
EOF
chmod +x "$T"/bin/* "$T"/sysbin/*

# --- fake SP Flash Tool zips ----------------------------------------------------------------------
mkelf() { # mkelf FILE MACHINE   MACHINE is the 2 bytes at offset 18 in hex: 3e00 = x86-64, b700 = aarch64
  printf '\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00' > "$1"
  printf "\\x${2:0:2}\\x${2:2:2}" >> "$1"
  head -c 300 /dev/zero >> "$1"
}
mkzip() { # mkzip ZIPFILE   (zips the contents of $T/stage, then empties it)
  rm -f "$1"
  (cd "$T/stage" && zip -q -r "$1" .)
  rm -rf "$T/stage"; mkdir -p "$T/stage"
}
mkdir -p "$T/stage/SP_Flash_Tool_v5.2228_Linux/lib" "$T/stage/SP_Flash_Tool_v5.2228_Linux/plugins"
mkelf "$T/stage/SP_Flash_Tool_v5.2228_Linux/flash_tool" 3e00
echo lib > "$T/stage/SP_Flash_Tool_v5.2228_Linux/lib/libx.so"
echo "MTK_AllInOne_DA" > "$T/stage/SP_Flash_Tool_v5.2228_Linux/MTK_AllInOne_DA.bin"
mkzip "$T/good.zip"
GOOD=$(sha256sum "$T/good.zip" | cut -d' ' -f1)

mkdir -p "$T/stage/SP_Flash_Tool_v6.2228_Linux"; mkelf "$T/stage/SP_Flash_Tool_v6.2228_Linux/SPFlashToolV6" 3e00
mkzip "$T/v6.zip"; V6=$(sha256sum "$T/v6.zip" | cut -d' ' -f1)

mkelf "$T/stage/flash_tool" 3e00; echo da > "$T/stage/MTK_AllInOne_DA.bin"
mkzip "$T/flat.zip"

mkdir -p "$T/stage/SP_Flash_Tool_noexe"; echo hi > "$T/stage/SP_Flash_Tool_noexe/readme.txt"
mkzip "$T/noexe.zip"

mkdir -p "$T/stage/SP_Flash_Tool_arm"; mkelf "$T/stage/SP_Flash_Tool_arm/flash_tool" b700
mkzip "$T/arm.zip"

mkdir -p "$T/stage/SP_Flash_Tool_script"; printf '#!/bin/sh\necho hi\n' > "$T/stage/SP_Flash_Tool_script/flash_tool"
mkzip "$T/script.zip"

mkdir -p "$T/stage/SP_Flash_Tool_other"; mkelf "$T/stage/SP_Flash_Tool_other/flash_tool" 3e00; echo different > "$T/stage/SP_Flash_Tool_other/x"
mkzip "$T/other.zip"     # a valid zip, but not the one whose checksum is known

# --- the script under test, next to its own lib folder with a test tools.conf ----------------------
cp -r "$REPO/lib" "$T/lib"
cat > "$T/lib/tools.conf" <<EOF
# test list
v5.2228  $GOOD  http://mirror-a.invalid/dl/SP_Flash_Tool_v5.2228_Linux.zip
v5.2228  $GOOD  http://mirror-b.invalid/dl/SP_Flash_Tool_v5.2228_Linux.zip
v6.2228  $V6    http://mirror-a.invalid/dl/SP_Flash_Tool_v6.2228_Linux.zip
v7.0     -      http://mirror-a.invalid/dl/SP_Flash_Tool_v7.0_Linux.zip
EOF
sed -e "s#/system/bin/#$T/sysbin/#g" \
    -e "s#/system/xbin/chroot#$T/none/chroot#g" \
    -e "s#/data/media/0#$T/media#g" \
    -e 's#^is_root() .*#is_root() { [ "${FAKE_ROOT:-0}" = 1 ]; }#' "$REPO/spft" > "$T/spft_test.sh"

run() { env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/root" SPFT_DL="$T/dl" HOME="$T/home" TERM=xterm \
        "$@" bash "$T/spft_test.sh" tool "${ARGS[@]}"; }
tool() { ARGS=("$@"); run; }     # tool ARGS...   (extra environment can be put in front with env VAR=x ... not needed here)
curls() { grep -c '^curl ' "$CURL_LOG"; }
current() { readlink "$T/root/opt/spft-current" 2>/dev/null || echo none; }
reset_root() { rm -rf "$T/root/opt"; mkdir -p "$T/root/opt"; }

echo "=== 1. tool list"
tool list

echo; echo "=== 2. nothing on the phone: download. The first mirror is down, the second one works"
mkdir -p "$T/served/mirror-b.invalid"; cp "$T/good.zip" "$T/served/mirror-b.invalid/SP_Flash_Tool_v5.2228_Linux.zip"
tool 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
[ "$(current)" = SP_Flash_Tool_v5.2228_Linux ] && ok "spft-current -> $(current)" || bad "spft-current is '$(current)'"
[ -x "$T/root/opt/SP_Flash_Tool_v5.2228_Linux/flash_tool" ] && ok "flash_tool is executable" || bad "flash_tool is not executable"
[ -f "$T/root/opt/SP_Flash_Tool_v5.2228_Linux/lib/libx.so" ] && ok "the rest of the zip was unpacked" || bad "lib/libx.so missing"
if [ -e "$T/root/opt/.spft-unpack" ]; then bad "temporary unpack folder left behind"; else ok "no temporary folder left behind"; fi
has "$CURL_LOG" 'mirror-a.invalid.*referer=http://mirror-a.invalid/dl/SP_Flash_Tool_v5.2228_Linux.zip' "the Referer header is the file's own address (the mirror needs that)"
echo "curl calls: $(curls)"

echo; echo "=== 3. --if-missing does nothing when the tool is there"
: > "$CURL_LOG"
tool --if-missing; echo "exit=$?   curl calls: $(curls)"

echo; echo "=== 4. an earlier download that is still good is reused (no new download)"
: > "$CURL_LOG"; reset_root
tool 2>&1 | grep -E 'earlier download|checksum matches|installed:' | sed "s#$T#\$T#g"
echo "curl calls: $(curls)"

echo; echo "=== 5. a damaged earlier download is thrown away and fetched again"
: > "$CURL_LOG"; reset_root
echo garbage > "$T/dl/SP_Flash_Tool_v5.2228_Linux.zip"
tool 2>&1 | grep -E 'earlier download|mismatch|downloading|installed:' | sed "s#$T#\$T#g"
echo "curl calls: $(curls)"

echo; echo "=== 6. a zip in the Download folder wins over downloading (and says which version it is)"
: > "$CURL_LOG"; reset_root; rm -f "$T/dl"/*.zip
cp "$T/v6.zip" "$T/home/storage/downloads/SP_Flash_Tool_v6.2228_Linux.zip"
tool 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
echo "curl calls: $(curls)   current: $(current)"
[ -x "$T/root/opt/SP_Flash_Tool_v6.2228_Linux/SPFlashToolV6" ] && ok "the v6 program name is accepted" || bad "v6 program missing"
rm -f "$T/home/storage/downloads/"*

echo; echo "=== 7. a mirror hands out a different file than the checksum says -> thrown away, clear help, exit 1"
: > "$CURL_LOG"; reset_root; rm -f "$T/dl"/*.zip
cp "$T/other.zip" "$T/served/mirror-b.invalid/SP_Flash_Tool_v5.2228_Linux.zip"
mkdir -p "$T/served/mirror-a.invalid"; cp "$T/other.zip" "$T/served/mirror-a.invalid/SP_Flash_Tool_v5.2228_Linux.zip"
tool 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
[ "$(current)" = none ] && ok "nothing was installed" || bad "something was installed: $(current)"
if compgen -G "$T/dl/*.part" > /dev/null; then bad "a .part file was left behind"; else ok "no .part file left behind"; fi
cp "$T/good.zip" "$T/served/mirror-b.invalid/SP_Flash_Tool_v5.2228_Linux.zip"; rm -f "$T/served/mirror-a.invalid/SP_Flash_Tool_v5.2228_Linux.zip"

echo; echo "=== 8. a version that is not in tools.conf"
tool v9.9; echo "exit=$?"

echo; echo "=== 9. a zip given by hand, with spaces in its path"
reset_root; mkdir -p "$T/home/My Files"; cp "$T/good.zip" "$T/home/My Files/my tool.zip"
tool "$T/home/My Files/my tool.zip" 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
[ "$(current)" = SP_Flash_Tool_v5.2228_Linux ] && ok "installed from a path with spaces" || bad "current is '$(current)'"

echo; echo "=== 10. a zip without flash_tool"
reset_root
tool "$T/noexe.zip" 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
[ -z "$(ls -A "$T/root/opt")" ] && ok "nothing left in /opt" || bad "left in /opt: $(ls -A "$T/root/opt")"

echo; echo "=== 11. flash_tool built for another CPU (aarch64): box64 could not run it"
tool "$T/arm.zip" 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
[ -z "$(ls -A "$T/root/opt")" ] && ok "nothing left in /opt" || bad "left in /opt: $(ls -A "$T/root/opt")"

echo; echo "=== 12. flash_tool that is not a program at all"
tool "$T/script.zip" 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
[ -z "$(ls -A "$T/root/opt")" ] && ok "nothing left in /opt" || bad "left in /opt: $(ls -A "$T/root/opt")"

echo; echo "=== 13. a zip with no folder inside is put in a folder named after the zip"
tool "$T/flat.zip" 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
[ "$(current)" = flat ] && ok "spft-current -> flat" || bad "current is '$(current)'"
[ -x "$T/root/opt/flat/flash_tool" ] && ok "flash_tool is inside it" || bad "flash_tool not found"

echo; echo "=== 14. installing a second version moves spft-current and keeps the first"
tool "$T/good.zip" >/dev/null 2>&1
tool "$T/v6.zip" >/dev/null 2>&1
echo "folders in /opt: $(ls "$T/root/opt" | tr '\n' ' ')  current -> $(current)"
[ "$(current)" = SP_Flash_Tool_v6.2228_Linux ] && ok "the newest install is the current one" || bad "current is '$(current)'"
[ -d "$T/root/opt/SP_Flash_Tool_v5.2228_Linux" ] && ok "the older one is still there" || bad "older one is gone"

echo; echo "=== 15. installing the same version again replaces its folder"
echo "stale" > "$T/root/opt/SP_Flash_Tool_v5.2228_Linux/stale.txt"
tool "$T/good.zip" >/dev/null 2>&1
[ -e "$T/root/opt/SP_Flash_Tool_v5.2228_Linux/stale.txt" ] && bad "stale file survived" || ok "old folder content replaced"

echo; echo "=== 16. an address given by hand, with a checksum that matches / does not match"
reset_root; mkdir -p "$T/served/example.invalid"; cp "$T/good.zip" "$T/served/example.invalid/mytool.zip"
SPFT_TOOL_SHA256=$GOOD run env true >/dev/null 2>&1 || true
ARGS=(http://example.invalid/mytool.zip)
env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/root" SPFT_DL="$T/dl" HOME="$T/home" SPFT_TOOL_SHA256="$GOOD" \
  bash "$T/spft_test.sh" tool "${ARGS[@]}" 2>&1 | sed "s#$T#\$T#g" | grep -E 'checksum|installed:|did not work'
echo "-- with a wrong checksum:"
env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/root" SPFT_DL="$T/dl" HOME="$T/home" SPFT_TOOL_SHA256=0000 \
  bash "$T/spft_test.sh" tool "${ARGS[@]}" 2>&1 | sed "s#$T#\$T#g" | grep -E 'mismatch|did not work'

echo; echo "=== 17. Termux may not read shared storage, root can: the zip is found in /data/media/0/Download"
: > "$CURL_LOG"; reset_root; rm -f "$T/dl"/*.zip
cp "$T/good.zip" "$T/media/Download/SP_Flash_Tool_v5.2228_Linux.zip"
tool 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}   curl calls: $(curls)"
[ "$(current)" = SP_Flash_Tool_v5.2228_Linux ] && ok "installed from shared storage through root" || bad "current is '$(current)'"

echo; echo "=== 18. a /sdcard path that only root can reach"
reset_root; cp "$T/good.zip" "$T/media/Download/x.zip"
tool /sdcard/Download/x.zip 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
[ "$(current)" = SP_Flash_Tool_v5.2228_Linux ] && ok "/sdcard/... was mapped to the real folder" || bad "current is '$(current)'"
rm -f "$T/media/Download/"*

echo; echo "=== 19. no Debian folder yet"
mv "$T/root/bin/bash" "$T/bash.off"
tool "$T/good.zip" 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
mv "$T/bash.off" "$T/root/bin/bash"

echo; echo "=== 20. check names the installed tool"
reset_root; tool "$T/good.zip" >/dev/null 2>&1
env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/root" SPFT_DL="$T/dl" HOME="$T/home" FAKE_ROOT=1 \
  bash "$T/spft_test.sh" root-check 2>&1 | grep -E '^(tool|debian) ' | sed "s#$T#\$T#g"

echo
echo "FAIL count: $fails"
if grep -qF "$T" /proc/mounts; then echo "mounts under $T - not deleting"; else rm -rf "$T"; echo "cleaned up"; fi
[ "$fails" -eq 0 ]
