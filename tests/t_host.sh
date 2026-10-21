#!/bin/bash
# Flow test for the `spft` command: x11 / vnc / stop / enter / check / update / help, with stand-ins for su,
# mount, chroot, termux-x11, termux-x11-preference, am, pm and the wake-lock tools.
# Needs: bash, python3, git, sed, pgrep. It refuses to run where a real /system/bin/mount exists.
# On purpose in the tests: ok/bad always return 0, patterns are literal text, printf builds escapes.
# shellcheck disable=SC2015,SC2016,SC2012,SC2002,SC2059
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
if [ -e /system/bin/mount ]; then echo "ABORT: /system/bin/mount exists here"; exit 1; fi
T=$(mktemp -d "${TMPDIR:-/tmp}/spft-host.XXXXXX")
mkdir -p "$T/bin" "$T/bin2" "$T/bin3" "$T/bin4" "$T/pfx/bin" "$T/pfx/lib" "$T/pfx/tmp" "$T/sysbin" "$T/dl" \
         "$T/root/bin" "$T/root/tmp" "$T/root/dev" "$T/root/proc" "$T/root/sys" "$T/root/mnt/sdcard"
ln -s "$(type -P bash)" "$T/pfx/bin/bash"
cp "$(type -P true)" "$T/root/bin/bash"      # the script only checks that it is executable
LOG=$T/calls.log; : > "$LOG"
: > "$T/mounts.fake"                          # stands in for /proc/mounts: one line per pretend mount

# stand-ins -----------------------------------------------------------------
printf '#!/bin/bash\necho "mount $*" >> "%s"\n' "$LOG" > "$T/sysbin/mount"
# umount: logs the call. With FAKE_UMOUNT=real it also takes the mount out of the pretend /proc/mounts (like the real one does);
# otherwise the mount is "busy" and stays.
cat > "$T/sysbin/umount" <<EOF
#!/bin/bash
echo "umount \$*" >> "$LOG"
if [ "\${FAKE_UMOUNT:-}" = real ]; then
  grep -vF " \$1 " "$T/mounts.fake" > "$T/mounts.new"; mv "$T/mounts.new" "$T/mounts.fake"
fi
exit 0
EOF
# root's own tools, the ones the root step uses: am (force-stop), wm (the screen size), du and sync (the cache clearing)
printf '#!/bin/bash\necho "root-am $*" >> "%s"\n' "$LOG" > "$T/sysbin/am"
cat > "$T/sysbin/wm" <<EOF
#!/bin/bash
# FAKE_WM=1280x800 is the screen (default 1080x1920), FAKE_WM_OVERRIDE=720x1280 adds an "Override size" line, FAKE_WM=none: no answer
echo "root-wm \$*" >> "$LOG"
[ "\${FAKE_WM:-}" != none ] || exit 1
echo "Physical size: \${FAKE_WM:-1080x1920}"
[ -z "\${FAKE_WM_OVERRIDE:-}" ] || echo "Override size: \$FAKE_WM_OVERRIDE"
EOF
printf '#!/bin/bash\nexec /usr/bin/du "$@"\n' > "$T/sysbin/du"
printf '#!/bin/bash\nexit 0\n' > "$T/sysbin/sync"
# rm: logs the call, then really deletes (the uninstall test needs the folder to go)
printf '#!/bin/bash\necho "rm $*" >> "%s"\nexec /bin/rm "$@"\n' "$LOG" > "$T/sysbin/rm"
cat > "$T/sysbin/chroot" <<EOF
#!/bin/bash
echo "chroot-call" >> "$LOG"
for a in "\$@"; do echo "chroot-arg:\$a" >> "$LOG"; done
EOF
# Like the real phone: the normal user cannot see the Debian folder (it gets a path that does not exist),
# while the root step sees the real one. `su -c 'id -u'` says 0.
cat > "$T/bin/su" <<EOF
#!/bin/bash
[ "\$1" = -c ] || exit 2
[ "\$2" != "id -u" ] || { echo 0; exit 0; }
cmd=\$(printf '%s' "\$2" | sed 's#SPFT_ROOT=$T/invisible#SPFT_ROOT=$T/root#')
exec env FAKE_ROOT=1 sh -c "\$cmd"
EOF
# the kernel config: FAKE_ACM=y|m|n sets CONFIG_USB_ACM, FAKE_ACM=none makes the config unreadable,
# FAKE_ARM64=0 makes it a 32-bit kernel
cat > "$T/bin/zcat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = /proc/config.gz ]; then
  [ "${FAKE_ACM:-}" != none ] || exit 1
  if [ "${FAKE_ARM64:-1}" = 0 ]; then echo "# CONFIG_ARM64 is not set"; else echo "CONFIG_ARM64=y"; fi
  case ${FAKE_ACM:-} in y | m) echo "CONFIG_USB_ACM=$FAKE_ACM" ;; n) echo "# CONFIG_USB_ACM is not set" ;; esac
  exit 0
fi
exec /usr/bin/env PATH=/usr/bin:/bin zcat "$@"
EOF
# the phone as spft check sees it: the kernel release, Android's properties and the free space come from the environment
cat > "$T/bin/uname" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -r ] && [ "${FAKE_UNAME_R+set}" = set ]; then echo "$FAKE_UNAME_R"; exit 0; fi
exec /usr/bin/env PATH=/usr/bin:/bin uname "$@"
EOF
cat > "$T/bin/getprop" <<'EOF'
#!/bin/bash
case ${1:-} in
  ro.build.version.sdk) echo "${FAKE_SDK:-}" ;;
  ro.build.version.release) echo "${FAKE_REL:-}" ;;
  ro.product.cpu.abilist) echo "${FAKE_ABIS:-}" ;;
  *) echo ;;
esac
EOF
cat > "$T/bin/stat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -f ] && [ "${2:-}" = -c ]; then
  [ -n "${FAKE_FREE_MB:-}" ] || exit 1
  echo "$FAKE_FREE_MB 1048576"     # blocks of 1 MB: the free blocks are the free megabytes
  exit 0
fi
exec /usr/bin/env PATH=/usr/bin:/bin stat "$@"
EOF
cat > "$T/bin/termux-x11" <<EOF
#!/bin/bash
echo "termux-x11 \$*" >> "$LOG"
mkdir -p "\$PREFIX/tmp/.X11-unix"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "\$PREFIX/tmp/.X11-unix/X0"
EOF
printf '#!/bin/bash\necho "am $*" >> "%s"\n' "$LOG" > "$T/bin/am"
printf '#!/bin/bash\necho "wake-lock" >> "%s"\n' "$LOG" > "$T/bin/termux-wake-lock"
printf '#!/bin/bash\necho "wake-unlock" >> "%s"\n' "$LOG" > "$T/bin/termux-wake-unlock"
# the phone's package manager: `pm list packages` prints one "package:NAME" per line
cat > "$T/bin/pm" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "list packages" ]; then printf 'package:com.android.settings\n'; [ -z "${PM_LIST:-}" ] || printf '%s\n' "$PM_LIST"; fi
EOF
# Termux:X11's settings tool: the settings live in $PREF_STATE as key=value lines. Like the real one it prints
# "unrecognised option" with exit 0 for an unknown key, exits 1 for a refused value, and refuses a whole batch
# when one key in it is refused.
cat > "$T/bin/termux-x11-preference" <<'EOF'
#!/bin/bash
echo "pref $*" >> "$PREF_LOG"
[ -z "${PREF_SILENT:-}" ] || exit 1
if [ "$1" = list ]; then sed 's/^\([^=]*\)=\(.*\)$/"\1"="\2"/' "$PREF_STATE"; exit 0; fi
for a in "$@"; do
  k=${a%%:*}; v=${a#*:}
  grep -q "^$k=" "$PREF_STATE" || { echo "$k: unrecognised option"; exit 0; }
  case $k in
    forceOrientation) case $v in auto|portrait|landscape|"reverse portrait"|"reverse landscape") ;; *) echo "set: Unexpected result 1"; exit 1 ;; esac ;;
    displayResolutionMode) case $v in native|scaled|exact|custom) ;; *) echo "set: Unexpected result 1"; exit 1 ;; esac ;;
    displayFilteringMode) case $v in bilinear|nearest) ;; *) echo "set: Unexpected result 1"; exit 1 ;; esac ;;
    displayScale) case $v in ''|*[!0-9]*) echo "displayScale: failed to parse integer"; exit 0 ;; esac ;;
  esac
done
for a in "$@"; do
  k=${a%%:*}; v=${a#*:}
  case $k in fullscreen|additionalKbdVisible) [ "$v" = true ] || v=false ;; esac
  sed -i "s|^$k=.*|$k=$v|" "$PREF_STATE"
done
echo Done
EOF
# the settings as the user has them now: the app is in portrait, at the phone's own size
reset_prefs() {
  printf '%s\n' fullscreen=false forceOrientation=portrait displayScale=100 displayResolutionMode=native \
    displayFilteringMode=nearest additionalKbdVisible=true showAdditionalKbd=true touchMode=1 > "$T/pref.state"
  : > "$T/pref.log"
}
reset_prefs
# pretend that processes whose command line starts with "box64 ./flash_tool" live inside the Debian folder
cat > "$T/sysbin/readlink" <<EOF
#!/bin/bash
pid=\${1#/proc/}; pid=\${pid%/root}
if tr '\0' ' ' < "/proc/\$pid/cmdline" 2>/dev/null | grep -q '^box64 ./flash_tool'; then echo "$T/root"; else readlink "\$1"; fi
EOF
# a server that "starts" but never makes the socket
printf '#!/bin/bash\necho "termux-x11(broken) $*" >> "%s"\necho "boom: no app" \n' "$LOG" > "$T/bin2/termux-x11"
cp "$T/bin/su" "$T/bin/am" "$T/bin2/"
cp "$T/bin/su" "$T/bin3/"
mkdir -p "$T/bin5"; cp "$T/bin/su" "$T/bin/zcat" "$T/bin5/"
printf '#!/bin/bash\necho "pkg stub: would install $*"\nexit 1\n' > "$T/bin5/pkg"
cp "$T/bin/su" "$T/bin/am" "$T/bin/termux-x11" "$T/bin4/"      # an older Termux:X11 package: no settings tool
chmod +x "$T"/bin*/* "$T"/sysbin/*

# the script under test (with its lib folder next to it): Android paths moved into the work folder, and
# "root" made switchable
cp -r "$REPO/lib" "$T/lib"
# (/proc/mounts, the USB driver folder and /data are moved too, so that the output does not depend on the machine)
sed -e "s#/system/bin/#$T/sysbin/#g" \
    -e "s#/system/xbin/chroot#$T/none/chroot#g" \
    -e "s#/proc/mounts#$T/mounts.fake#g" \
    -e "s#/proc/sys/vm/drop_caches#$T/drop_caches#g" \
    -e "s#^X11_DATA=.*#X11_DATA=$T/x11data/\$X11_PKG#" \
    -e "s#^X11_MEDIA=.*#X11_MEDIA=$T/appmedia/\$X11_PKG#" \
    -e "s#/sys/bus/usb/drivers/cdc_acm#$T/no-cdc_acm#g" \
    -e "s#free_mb /data)#free_mb $T/no-such-folder)#" \
    -e "s#/data/system/packages.list#$T/packages.list#g" \
    -e "s#\"/data/data/\$pk\"#\"$T/appdata/\$pk\"#" \
    -e "s#\"/data/user/0/\$pk\"#\"$T/appdata0/\$pk\"#" \
    -e "s#\[ -d /data/data \] || \[ -d /data/user/0 \]#[ -d $T/appdata ] || [ -d $T/appdata0 ]#" \
    -e 's#^is_root() .*#is_root() { [ "${FAKE_ROOT:-0}" = 1 ]; }#' "${SPFT_UNDER_TEST:-$REPO/spft}" > "$T/spft_test.sh"
if grep -n '/system/' "$T/spft_test.sh" | grep -v -e 'tried /system/bin' -e '/system/\*'; then echo "NOTE: unreplaced /system paths above"; fi
if grep -n -e '/data/system' -e '/data/user/' -e '"/data/data/' -e '/data/data \]' -e '^X11_DATA=/data' -e '^X11_MEDIA=/data' -e '/proc/sys/' "$T/spft_test.sh"; then echo "NOTE: unreplaced /data paths above"; fi

run() { # run PATHDIR ARGS...
  local pd=$1; shift
  env -i PATH="$pd:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/invisible" SPFT_DL="$T/dl" HOME="$T" TERM=xterm \
      PREF_STATE="$T/pref.state" PREF_LOG="$T/pref.log" PREF_SILENT="${PREF_SILENT:-}" PM_LIST="${PM_LIST:-}" FAKE_ACM="${FAKE_ACM:-}" \
      FAKE_UNAME_R="${FAKE_UNAME_R-5.10.43-android12-9}" FAKE_ARM64="${FAKE_ARM64:-1}" FAKE_SDK="${FAKE_SDK:-}" FAKE_REL="${FAKE_REL:-}" \
      FAKE_ABIS="${FAKE_ABIS:-}" FAKE_FREE_MB="${FAKE_FREE_MB:-}" SPFT_MIN_MB="${SPFT_MIN_MB:-}" \
      FAKE_WM="${FAKE_WM:-}" FAKE_WM_OVERRIDE="${FAKE_WM_OVERRIDE:-}" FAKE_UMOUNT="${FAKE_UMOUNT:-}" \
      bash "${SCRIPT:-$T/spft_test.sh}" "$@"
}
lastcall() { awk '/^chroot-call$/ {buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' "$LOG" | sed -n 's/^chroot-arg://p'; }

echo "=== A. x11 without termux-x11 installed"
run "$T/bin3" x11; echo "exit=$?"

echo; echo "=== B. x11 called as root"
env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/root" SPFT_DL="$T/dl" HOME="$T" FAKE_ROOT=1 bash "$T/spft_test.sh" x11; echo "exit=$?"

echo; echo "=== C. x11, first run (server not running yet)"
run "$T/bin" x11; echo "exit=$?"
echo "--- calls:"; grep -v '^chroot-' "$LOG" | sed "s#$T#\$T#g"
echo "--- command line handed to chroot (one argument per line):"; lastcall | sed "s#$T#\$T#g"
echo "--- helpers written inside Debian:"
ls -l "$T/root/usr/local/bin/" | sed -n '2,$p' | awk '{print $1, $NF}'
cmp "$T/root/usr/local/bin/spft-run" "$REPO/lib/run.sh" && echo "spft-run identical to lib/run.sh"
cmp "$T/root/usr/local/bin/spft-gui" "$REPO/lib/gui.sh" && echo "spft-gui identical to lib/gui.sh"
cmp "$T/root/usr/local/lib/spft/kernelfix.sh" "$REPO/lib/kernelfix.sh" && echo "kernelfix.sh identical to lib/kernelfix.sh (spft-run reads it in Debian)"
cmp "$T/root/usr/local/lib/spft/kernelfix.so.b64" "$REPO/lib/kernelfix.so.b64" && echo "kernelfix.so.b64 identical to lib/kernelfix.so.b64"
echo "--- file-dialog shortcuts (top level of Debian, then Debian's home):"
ls -l "$T/root/sdcard" | awk '{print "/sdcard", $(NF-1), $NF}'
ls -l "$T/root/root/" | awk 'NR>1 {print "~/" $(NF-2), $(NF-1), $NF}'
echo "--- the root step ran a copy kept under Termux's own folder:"
ls "$T/dl/app" | tr '\n' ' '; echo
cmp "$T/dl/app/lib/run.sh" "$REPO/lib/run.sh" && echo "copy of lib/run.sh is identical"
echo "--- Termux:X11 settings now (the app started out in portrait, at the phone's own size):"
tr '\n' ' ' < "$T/pref.state"; echo
echo "--- saved for 'x11 reset':"; tr '\n' ' ' < "$T/dl/x11-prefs.orig"; echo
echo "--- the phone was kept awake: wake-lock calls = $(grep -c '^wake-lock$' "$LOG")"

echo; echo "=== F. x11 again (server already up -> must not start a second one, no setting changed again)"
: > "$LOG"; : > "$T/pref.log"
run "$T/bin" x11; echo "exit=$?"
echo "termux-x11 starts: $(grep -c '^termux-x11 ' "$LOG")   am calls: $(grep -c '^am ' "$LOG")"
echo "settings-tool calls: list=$(grep -c '^pref list' "$T/pref.log") set=$(grep -c '^pref [A-Za-z]*:' "$T/pref.log")"

echo; echo "=== H. plain \`spft\` (no argument) does the same as x11"
: > "$LOG"; : > "$T/pref.log"
run "$T/bin"; echo "exit=$?"
echo "tool started: $(grep -c '^chroot-call' "$LOG")   last chroot args:"; lastcall | tail -n 2

echo; echo "=== H2. spft start / spft help / an unknown command"
: > "$LOG"
run "$T/bin" start >/dev/null; echo "start: exit=$?   tool started: $(grep -c '^chroot-call' "$LOG")"
run "$T/bin" help | sed -n '1p;3p'; echo "help: exit=${PIPESTATUS[0]}"
run "$T/bin" frobnicate 2>&1 | sed -n '1p'; echo "unknown: exit=${PIPESTATUS[0]}"

echo; echo "=== K. x11 reverse zoom=200 keys"
: > "$T/pref.log"
run "$T/bin" x11 reverse zoom=200 keys; echo "exit=$?"
tr '\n' ' ' < "$T/pref.state"; echo

echo; echo "=== K2. x11 portrait: no zoom unless asked for (the tool is wider than a portrait screen)"
: > "$T/pref.log"
run "$T/bin" x11 portrait; echo "exit=$?"
tr '\n' ' ' < "$T/pref.state"; echo

echo; echo "=== L. x11 plain leaves the settings alone"
: > "$T/pref.log"; : > "$LOG"
run "$T/bin" x11 plain; echo "exit=$?"
echo "settings-tool calls: $(wc -l < "$T/pref.log")   tool started: $(grep -c '^chroot-call' "$LOG")"

echo; echo "=== M. x11 reset puts the original settings back and does not start the tool"
: > "$LOG"
run "$T/bin" x11 reset; echo "exit=$?"
tr '\n' ' ' < "$T/pref.state"; echo
if [ -e "$T/dl/x11-prefs.orig" ]; then echo "FAIL: saved file is still there"; else echo "ok: saved file removed"; fi
echo "tool started: $(grep -c '^chroot-call' "$LOG")   am calls: $(grep -c '^am ' "$LOG")"
echo "--- reset again:"
run "$T/bin" x11 reset; echo "exit=$?"

echo; echo "=== V. vnc starts the tool in VNC mode"
: > "$LOG"
run "$T/bin" vnc; echo "exit=$?"
lastcall | tail -n 2

echo; echo "=== V2. a setting typed in front of the command (SPFT_STORAGE=off spft) must reach the shell in Debian"
# On the way there su may drop the environment, and `enter` starts Debian's shell with env -i. This su does drop the settings
# (the other stand-in passes everything on), so they only get there when spft puts them into the command line itself.
mkdir -p "$T/bin6"; cp "$T"/bin/* "$T/bin6/"
cat > "$T/bin6/su" <<EOF
#!/bin/bash
[ "\$1" = -c ] || exit 2
[ "\$2" != "id -u" ] || { echo 0; exit 0; }
cmd=\$(printf '%s' "\$2" | sed 's#SPFT_ROOT=$T/invisible#SPFT_ROOT=$T/root#')
exec env -u SPFT_FAKE_KERNEL -u SPFT_STORAGE -u SPFT_GEOMETRY -u BOX64_LOG FAKE_ROOT=1 sh -c "\$cmd"
EOF
chmod +x "$T"/bin6/*
# what the programs in Debian see: the command line is read there by a shell, with an empty environment
seen() { env -i PATH=/usr/bin:/bin bash -c 'spft-run() { echo "display=$SPFT_DISPLAY fake_kernel=${SPFT_FAKE_KERNEL-unset} storage=${SPFT_STORAGE-unset} geometry=${SPFT_GEOMETRY-unset} box64_log=${BOX64_LOG-unset}"; }; '"$1"; }
typed() { # typed "spft arguments" "what Debian must see" VAR=value...   run spft with those settings typed in front of it
  local -a words
  local want=$2 got
  read -ra words <<< "$1"; shift 2
  : > "$LOG"
  env -i PATH="$T/bin6:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/invisible" SPFT_DL="$T/dl" HOME="$T" TERM=xterm \
      PREF_STATE="$T/pref.state" PREF_LOG="$T/pref.log" "$@" bash "$T/spft_test.sh" "${words[@]}" >/dev/null 2>&1; echo "exit=$?"
  echo "  command line for Debian: $(lastcall | tail -n 1)"
  got=$(seen "$(lastcall | tail -n 1)")
  if [ "$got" = "$want" ]; then echo "ok: Debian sees  $got"; else echo "FAIL: Debian sees  $got   (wanted: $want)"; fi
}
typed "x11 plain" "display=x11 fake_kernel=off storage=/sdcard/My Folder (1) geometry=unset box64_log=3" \
  SPFT_STORAGE='/sdcard/My Folder (1)' SPFT_FAKE_KERNEL=off BOX64_LOG=3
typed "x11 plain" "display=x11 fake_kernel=unset storage=/sdcard/Shivraj's files geometry=unset box64_log=unset" \
  SPFT_STORAGE="/sdcard/Shivraj's files"
typed "vnc" "display=vnc fake_kernel=5.4.0 storage=unset geometry=1920x1080 box64_log=unset" \
  SPFT_GEOMETRY=1920x1080 SPFT_FAKE_KERNEL=5.4.0
echo "--- nothing typed in front: nothing is added"
typed "x11 plain" "display=x11 fake_kernel=unset storage=unset geometry=unset box64_log=unset"
echo "--- an empty setting counts as not set"
typed "x11 plain" "display=x11 fake_kernel=unset storage=unset geometry=unset box64_log=unset" SPFT_STORAGE= BOX64_LOG=

echo; echo "=== D. enter with a command"
run "$T/bin" enter echo hi there; echo "exit=$?"
echo "--- last chroot args:"; lastcall | tail -n 3

echo; echo "=== E. enter without a command"
run "$T/bin" enter; echo "exit=$?"
echo "--- last chroot args:"; lastcall | tail -n 2

echo; echo "=== I. stop closes the tool and lets the phone sleep again; a second stop finds nothing"
: > "$LOG"
bash -c 'exec -a "box64 ./flash_tool" sleep 60' & DECOY=$!
sleep 1
run "$T/bin" stop; echo "exit=$?"
if kill -0 "$DECOY" 2>/dev/null; then echo "FAIL: the tool is still running"; kill "$DECOY"; else echo "ok: the tool process is gone"; fi
echo "wake-unlock calls: $(grep -c '^wake-unlock$' "$LOG")"
run "$T/bin" stop; echo "exit=$?"

echo; echo "=== I2. stop also stops the Termux:X11 server, and removes the socket that a killed server leaves behind"
SOCK=$T/pfx/tmp/.X11-unix/X0
mksock() { mkdir -p "$T/pfx/tmp/.X11-unix"; rm -f "$SOCK"; python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCK"; }
echo "-- a server is running (its process is called \"termux-x11 <app id> :0\")"
mksock
bash -c 'exec -a "termux-x11 com.termux.x11 :0" sleep 60' & XDECOY=$!
sleep 1
run "$T/bin" stop; echo "exit=$?"
if kill -0 "$XDECOY" 2>/dev/null; then echo "FAIL: the Termux:X11 server is still running"; kill "$XDECOY"; else echo "ok: the server process is gone"; fi
if [ -e "$SOCK" ]; then echo "FAIL: the socket file is still there"; else echo "ok: the socket file is gone"; fi
echo "-- only a socket file is left (the server was killed): it is removed, so that the next spft starts a new server"
mksock
run "$T/bin" stop; echo "exit=$?"
if [ -e "$SOCK" ]; then echo "FAIL: the stale socket is still there"; else echo "ok: the stale socket is gone"; fi
echo "-- nothing at all: nothing to report about a server or a socket"
run "$T/bin" stop | grep -c 'old Termux:X11 socket\|an old one left\|stopped the Termux:X11 server'

echo; echo "=== I3. a program that ignores the polite request (TERM) is killed anyway: the tool, and the Termux:X11 server"
mksock
bash -c 'trap "" TERM; exec -a "box64 ./flash_tool" sleep 60' & DECOY=$!
bash -c 'trap "" TERM; exec -a "termux-x11 com.termux.x11 :0" sleep 60' & XDECOY=$!
sleep 1
run "$T/bin" stop > "$T/stop.out" 2>&1; echo "exit=$?"
grep -E '^(debian|x11-server)[ :]' "$T/stop.out"
if kill -0 "$DECOY" 2>/dev/null; then echo "FAIL: the tool that ignores TERM is still running"; kill -9 "$DECOY"; else echo "ok: the tool that ignores TERM is gone"; fi
if kill -0 "$XDECOY" 2>/dev/null; then echo "FAIL: the server that ignores TERM is still running"; kill -9 "$XDECOY"; else echo "ok: the Termux:X11 server that ignores TERM is gone"; fi
if [ -e "$SOCK" ]; then echo "FAIL: the socket file is still there"; else echo "ok: the socket file is gone"; fi

echo; echo "=== S. stop ends everything, unmounts, and clears the caches - and leaves the rest alone"
mksock
bash -c 'exec -a "box64 ./flash_tool" sleep 60' & DECOY=$!
bash -c 'exec -a "termux-x11 com.termux.x11 :0" sleep 60' & XDECOY=$!
# what is a cache: Debian's /tmp and ~/.cache, the Termux:X11 app's cache folders (private and on the shared storage)
mkdir -p "$T/root/tmp/runtime-root" "$T/root/tmp/.X11-unix" "$T/root/root/.cache/fontconfig" "$T/x11data/com.termux.x11/cache" \
         "$T/x11data/com.termux.x11/code_cache" "$T/appmedia/com.termux.x11/cache"
head -c 300000 /dev/zero > "$T/root/tmp/spft-kernelfix.so"; echo x > "$T/root/tmp/runtime-root/sock"; echo x > "$T/root/tmp/.hidden-file"
head -c 500000 /dev/zero > "$T/root/root/.cache/fontconfig/cache-1"
head -c 700000 /dev/zero > "$T/x11data/com.termux.x11/cache/webview"
echo x > "$T/x11data/com.termux.x11/code_cache/c"; echo x > "$T/appmedia/com.termux.x11/cache/m"
# what must stay: the tool's own logs, Debian's settings and apt's downloads, the Termux:X11 app's settings
mkdir -p "$T/root/opt/spft-current/log" "$T/root/root/.config" "$T/root/var/cache/apt/archives" "$T/x11data/com.termux.x11/shared_prefs"
echo keep > "$T/root/opt/spft-current/log/flash.log"; echo keep > "$T/root/root/.config/settings.conf"
echo keep > "$T/root/var/cache/apt/archives/pkg.deb"; echo keep > "$T/x11data/com.termux.x11/shared_prefs/prefs.xml"
printf '/dev %s/root/dev tmpfs rw 0 0\nproc %s/root/proc proc rw 0 0\n/data/media %s/root/mnt/sdcard sdcardfs rw 0 0\n' "$T" "$T" "$T" > "$T/mounts.fake"
sleep 1
: > "$LOG"; rm -f "$T/drop_caches"
FAKE_UMOUNT=real run "$T/bin" stop > "$T/stop.out" 2>&1; echo "exit=$?"
sed -e 's/[0-9][0-9]*\.[0-9] MB freed/N.N MB freed/' "$T/stop.out" | sed "s#$T#\$T#g"
gone() { if [ -e "$2" ]; then echo "FAIL: still there: $1"; else echo "ok: gone - $1"; fi; }
kept() { if [ -e "$2" ]; then echo "ok: kept - $1"; else echo "FAIL: deleted: $1"; fi; }
if kill -0 "$DECOY" 2>/dev/null; then echo "FAIL: the tool is still running"; kill "$DECOY"; else echo "ok: the tool process is gone"; fi
if kill -0 "$XDECOY" 2>/dev/null; then echo "FAIL: the server is still running"; kill "$XDECOY"; else echo "ok: the Termux:X11 server process is gone"; fi
gone "the server's socket file" "$SOCK"
gone "the kernel-fix library in Debian's /tmp" "$T/root/tmp/spft-kernelfix.so"
gone "a socket in a folder in /tmp" "$T/root/tmp/runtime-root"
gone "a hidden file in /tmp" "$T/root/tmp/.hidden-file"
gone "Debian's ~/.cache" "$T/root/root/.cache/fontconfig"
gone "the app's cache" "$T/x11data/com.termux.x11/cache/webview"
gone "the app's code cache" "$T/x11data/com.termux.x11/code_cache/c"
gone "the app's cache on the shared storage" "$T/appmedia/com.termux.x11/cache/m"
kept "the folder /tmp itself" "$T/root/tmp"
kept "the app's cache folder itself" "$T/x11data/com.termux.x11/cache"
kept "the tool's log" "$T/root/opt/spft-current/log/flash.log"
kept "Debian's settings" "$T/root/root/.config/settings.conf"
kept "apt's downloaded file (an interrupted install resumes from it)" "$T/root/var/cache/apt/archives/pkg.deb"
kept "the Termux:X11 app's settings" "$T/x11data/com.termux.x11/shared_prefs/prefs.xml"
freed=$(sed -n 's/.*cleared, \([0-9]*\)\.[0-9] MB freed.*/\1/p' "$T/stop.out")
if [ "${freed:-0}" -ge 1 ]; then echo "ok: at least 1 MB was freed (3 MB of files were made)"; else echo "FAIL: freed '${freed:-nothing}' MB"; fi
echo "--- unmount calls (in this order, and only for what was mounted):"; grep '^umount ' "$LOG" | sed "s#$T#\$T#g"
echo "--- force-stop calls: $(grep -c '^root-am force-stop com.termux.x11$' "$LOG")   wake-unlock calls: $(grep -c '^wake-unlock$' "$LOG")"
echo "--- the memory cache was dropped: $(tr -d '\n' < "$T/drop_caches" 2>/dev/null)"
if grep -qF "$T/root" "$T/mounts.fake"; then echo "FAIL: something is still mounted"; else echo "ok: nothing is mounted any more"; fi

echo; echo "=== S2. a mount that will not go: a WARNING, Debian's own folders are left alone, the rest is still cleared"
head -c 300000 /dev/zero > "$T/root/tmp/spft-kernelfix.so"; mkdir -p "$T/x11data/com.termux.x11/cache"; echo x > "$T/x11data/com.termux.x11/cache/webview"
printf '/dev %s/root/dev tmpfs rw 0 0\n' "$T" > "$T/mounts.fake"
run "$T/bin" stop 2>&1 | sed -e 's/[0-9][0-9]*\.[0-9] MB freed/N.N MB freed/' -e "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
kept "Debian's /tmp file (something is still mounted in Debian, so it was not touched)" "$T/root/tmp/spft-kernelfix.so"
gone "the app's cache (it is not in Debian)" "$T/x11data/com.termux.x11/cache/webview"
: > "$T/mounts.fake"

echo; echo "=== S3. clear_dir on its own: it refuses shallow folders and walks around mount points"
(
  # the two functions, as they are in the script under test
  eval "$(sed -n '/^is_mounted() /p;/^clear_dir() {/,/^}/p' "$T/spft_test.sh")"
  SH=/tmp/spft-shallow.$$     # only two levels deep: refused
  if mkdir "$SH" 2>/dev/null; then
    echo x > "$SH/file"
    clear_dir "$SH"; echo "a folder two levels deep: status=$?"
    if [ -e "$SH/file" ]; then echo "ok: nothing was deleted in it"; else echo "FAIL: a shallow folder was emptied"; fi
    rm -rf "$SH"
  else
    echo "(skipped: /tmp is not writable here)"
  fi
  D=$T/clear-test
  mkdir -p "$D/a/b" "$D/mnt/deep" "$D/.hid"; echo x > "$D/f"; echo x > "$D/.dot"; echo x > "$D/mnt/deep/f"; ln -s /etc "$D/link"
  printf 'dev %s tmpfs rw 0 0\n' "$D/mnt" > "$T/mounts.fake"
  clear_dir "$D"; echo "a folder with a mount point inside: status=$?"
  for x in a f .dot .hid link; do if [ -e "$D/$x" ] || [ -L "$D/$x" ]; then echo "FAIL: $x is still there"; else echo "ok: $x is gone"; fi; done
  if [ -e "$D/mnt/deep/f" ]; then echo "ok: what is inside the mount point was not touched"; else echo "FAIL: the delete went through the mount point"; fi
  if [ -e /etc/hostname ] || [ -e /etc/passwd ]; then echo "ok: the link was removed, its target was not followed"; else echo "FAIL: /etc is gone"; fi
  : > "$T/mounts.fake"
  clear_dir "$T/no-such-folder/at/all"; echo "a folder that is not there: status=$?"
)

echo; echo "=== Z. the zoom picks itself: the biggest at which the tool's window (about 720 pixels tall) still fits"
zoom_for() { # zoom_for WIDTHxHEIGHT [ARGS...]   starts the tool and prints the zoom that was set
  local scr=$1; shift
  : > "$T/pref.log"; reset_prefs; rm -f "$T/dl/x11-prefs.orig"; : > "$LOG"
  FAKE_WM=$scr FAKE_WM_OVERRIDE="${OVR:-}" run "$T/bin" x11 "$@" > "$T/z.out" 2>&1
  grep '^displayScale=' "$T/pref.state" | tr '\n' ' '
}
for scr in 1280x800 1080x1920 800x1280 720x1280 1200x1920 1440x3200 480x800; do
  z=$(zoom_for "$scr"); z=${z#displayScale=}; z=${z% }
  short=${scr%x*}; [ "${scr#*x}" -ge "$short" ] || short=${scr#*x}
  h=$((short * 100 / z))
  echo "screen $scr -> zoom $z, a Termux:X11 screen $h pixels tall"
  if [ "$h" -ge 740 ]; then echo "ok: tall enough"; else echo "FAIL: the window would be cut off"; fi
  if [ $((z + 5)) -le 300 ] && [ $((short * 100 / (z + 5))) -ge 740 ]; then echo "FAIL: a bigger zoom would still fit"; fi
done
echo "-- what the user sees about it:"
FAKE_WM=1280x800 run "$T/bin" x11 2>&1 | grep -E '^>> (screen|could not)'
echo "-- 'Override size' (the phone was set to another size with wm size) wins over the real size"
OVR=720x1600 zoom_for 1080x2400; echo
echo "-- zoom=auto written out is the same as no zoom"
zoom_for 1280x800 zoom=auto; echo
echo "-- a zoom of your own is used as it is, and the screen is not even asked"
zoom_for 1280x800 zoom=120; echo "   screen asked: $(grep -c '^root-wm' "$LOG") times"
echo "-- portrait: no zoom, and the screen is not asked"
zoom_for 1280x800 portrait; echo "   screen asked: $(grep -c '^root-wm' "$LOG") times"
echo "-- the screen size can't be read: 150, and what to do if the window is cut off"
FAKE_WM=none run "$T/bin" x11 2>&1 | grep -E '^>> (screen|could not)'
z=$(zoom_for none); echo "$z"
echo "-- an answer that is not a size"
printf '#!/bin/bash\necho "root-wm $*" >> "%s"\necho "Physical size: unknown"\n' "$LOG" > "$T/sysbin/wm"
z=$(zoom_for 1280x800); echo "$z"
cat > "$T/sysbin/wm" <<EOF
#!/bin/bash
echo "root-wm \$*" >> "$LOG"
[ "\${FAKE_WM:-}" != none ] || exit 1
echo "Physical size: \${FAKE_WM:-1080x1920}"
[ -z "\${FAKE_WM_OVERRIDE:-}" ] || echo "Override size: \$FAKE_WM_OVERRIDE"
EOF
chmod +x "$T/sysbin/wm"
reset_prefs; rm -f "$T/dl/x11-prefs.orig"

echo; echo "=== J. umount also stops processes first, then reports"
bash -c 'exec -a "box64 ./flash_tool" sleep 60' & DECOY=$!
sleep 1
run "$T/bin" umount; echo "exit=$?"
kill "$DECOY" 2>/dev/null

echo; echo "=== J2. umount while something is still mounted: a WARNING, the list, and exit status 1"
printf '/data/media %s/root/mnt/sdcard sdcardfs rw,nosuid,nodev 0 0\n' "$T" > "$T/mounts.fake"
run "$T/bin" umount; echo "exit=$?"
: > "$T/mounts.fake"

echo; echo "=== N. bad options"
for o in sideways zoom=abc zoom= zoom=500 zoom=20 zoom=0150 zoom=08; do echo "-- x11 $o"; run "$T/bin" x11 "$o"; echo "exit=$?"; done

echo; echo "=== O. an older Termux:X11 without displayFilteringMode and additionalKbdVisible"
reset_prefs; sed -i '/^displayFilteringMode=/d;/^additionalKbdVisible=/d' "$T/pref.state"
rm -f "$T/dl/x11-prefs.orig"; : > "$LOG"
run "$T/bin" x11; echo "exit=$?"
tr '\n' ' ' < "$T/pref.state"; echo
echo "tool started: $(grep -c '^chroot-call' "$LOG")"

echo; echo "=== O2. an app version without forceOrientation: the by-hand steps are shown"
reset_prefs; sed -i '/^forceOrientation=/d' "$T/pref.state"
rm -f "$T/dl/x11-prefs.orig"; : > "$LOG"
run "$T/bin" x11; echo "exit=$?"
echo "tool started: $(grep -c '^chroot-call' "$LOG")"

echo; echo "=== P. the Termux:X11 app does not answer (about 8 s)"
reset_prefs; rm -f "$T/dl/x11-prefs.orig"; : > "$LOG"
PREF_SILENT=1 run "$T/bin" x11; echo "exit=$?"
echo "settings unchanged: $(tr '\n' ' ' < "$T/pref.state")"
echo "tool started: $(grep -c '^chroot-call' "$LOG")"

echo; echo "=== Q. a Termux:X11 package without termux-x11-preference"
: > "$LOG"
run "$T/bin4" x11; echo "exit=$?"
echo "tool started: $(grep -c '^chroot-call' "$LOG")"

echo; echo "=== X. spft check, Android 11 style: Termux:X11 is in ROOT's package list, the normal user's pm does not show it"
printf '%s\n' 'com.android.settings 1000 0 /data/user/0/com.android.settings platform:privapp:targetSdkVersion=30 1065,3002 0 30' \
  'com.termux.x11 10215 0 /data/user/0/com.termux.x11 default:targetSdkVersion=29 3003,9997 0 1' > "$T/packages.list"
run "$T/bin" check; echo "exit=$?"
echo "-- the same question the way install.sh asks it:"
run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"

echo; echo "=== X1. cdc_acm: what the kernel config says when the driver folder is missing"
for v in m y n none ''; do
  echo "-- FAKE_ACM=${v:-(option not in the config)}"
  FAKE_ACM=$v run "$T/bin" check 2>&1 | grep '^cdc_acm'
done

echo; echo "=== X2. the app is not in root's package list: NOT installed"
printf '%s\n' 'com.android.settings 1000 0 /data/user/0/com.android.settings platform:privapp:targetSdkVersion=30 1065,3002 0 30' > "$T/packages.list"
run "$T/bin" check 2>&1 | grep -E 'x11-app'; echo "exit=${PIPESTATUS[0]}"
run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"
echo "-- a package that only STARTS with the app's name is not the app"
printf '%s\n' 'com.termux.x11.extra 10300 0 /data/user/0/com.termux.x11.extra default 3003 0 1' > "$T/packages.list"
run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"
echo "-- ... but if pm does list the app, it is installed: any source that says yes wins (a false NOT installed is the worse mistake)"
PM_LIST=package:com.termux.x11 run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"

echo; echo "=== X3. root can read no package list: the app's data folder tells"
rm -f "$T/packages.list"; mkdir -p "$T/appdata" "$T/appdata0"
echo "-- the base folders exist, the app's folder does not:"
run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"
echo "-- the app's folder exists (main user):"
mkdir "$T/appdata0/com.termux.x11"
run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"
rmdir "$T/appdata0/com.termux.x11"
echo "-- the app's folder exists (the old /data/data place):"
mkdir "$T/appdata/com.termux.x11"
run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"
rmdir "$T/appdata/com.termux.x11"

echo; echo "=== X3b. root can tell nothing (no list, no folders): pm of the normal user is the only source"
rmdir "$T/appdata" "$T/appdata0"
echo "-- pm lists the app:"
PM_LIST=package:com.termux.x11 run "$T/bin" check 2>&1 | grep -E 'x11-app'
PM_LIST=package:com.termux.x11 run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"
echo "-- pm does not list it: only 'could not tell', never a false NOT installed"
run "$T/bin" check 2>&1 | grep -E 'x11-app'
run "$T/bin" app-installed com.termux.x11; echo "app-installed: exit=$?"
echo "-- pm can't be asked either:"
mv "$T/bin/pm" "$T/pm.off"
run "$T/bin" check 2>&1 | grep -E 'x11-app'
mv "$T/pm.off" "$T/bin/pm"

echo; echo "=== X4. root refused: the Termux part is shown, the phone part is skipped (exit 1); the app is asked of pm"
mkdir -p "$T/bin6"
printf '#!/bin/bash\necho "su: permission denied" >&2\nexit 1\n' > "$T/bin6/su"
cp "$T/bin/pm" "$T/bin/termux-x11" "$T/bin6/"
chmod +x "$T/bin6"/*
PM_LIST=package:com.termux.x11 run "$T/bin6" check; echo "exit=$?"

echo; echo "=== X5. no su at all (a phone that is not rooted)"
mkdir -p "$T/nosu"
ln -sf "$(type -P timeout)" "$T/nosu/timeout"
cp "$T/bin/pm" "$T/nosu/pm"
env -i PATH="$T/nosu" PREFIX="$T/pfx" SPFT_ROOT="$T/invisible" SPFT_DL="$T/dl" HOME="$T" TERM=xterm PM_LIST= \
  "$(type -P bash)" "$T/spft_test.sh" check; echo "exit=$?"

echo; echo "=== X6. the kernel version row (SP Flash Tool v5 wants 4.19.14 or newer, and misreads 4.19.100 to 4.19.139)"
for v in 4.19.127-g8d3429bdb336 4.19.100 4.19.139 4.19.140 4.19.14 4.19.13 4.14.186 3.18.140-perf 5.10.43-android12-9 6.1.75 garbage; do
  echo "-- kernel $v"
  FAKE_UNAME_R=$v FAKE_ACM=y run "$T/bin" check 2>&1 | sed -n '/^kernel-ver/p;/^ - the kernel/p'
done
echo "-- the kernel version can't be read"
FAKE_UNAME_R='' FAKE_ACM=y run "$T/bin" check 2>&1 | grep '^kernel-ver'

echo; echo "=== X7. the Result block: what blocks spft, and what to keep in mind"
echo "-- the tablet from the report: Android 11, kernel 4.19.127, no cdc_acm, plenty of space"
FAKE_UNAME_R=4.19.127-g8d3429bdb336 FAKE_ACM=n FAKE_SDK=30 FAKE_REL=11 FAKE_ABIS=arm64-v8a,armeabi-v7a,armeabi FAKE_FREE_MB=12000 FAKE_WM=1280x800 \
  run "$T/bin" check 2>&1 | sed -n '/^== phone/,$p'
echo "-- a phone that has everything: no 'Keep in mind' at all"
FAKE_ACM=y FAKE_SDK=29 FAKE_REL=10 FAKE_FREE_MB=9000 run "$T/bin" check 2>&1 | sed -n '/^== Result/,$p'
echo "-- a 32-bit kernel: spft cannot run (a blocker)"
FAKE_ARM64=0 FAKE_ACM=y run "$T/bin" check 2>&1 | sed -n '/^== Result/,$p'
echo "-- 900 MB free, below the 1500 that the install insists on (a blocker)"
FAKE_ACM=y FAKE_FREE_MB=900 run "$T/bin" check 2>&1 | sed -n '/^free/p;/^== Result/,$p'
echo "-- 2500 MB free: it can run, but it is tight"
FAKE_ACM=y FAKE_FREE_MB=2500 run "$T/bin" check 2>&1 | sed -n '/^== Result/,$p'
echo "-- no chroot command (a blocker)"
mv "$T/sysbin/chroot" "$T/chroot.off"
FAKE_ACM=y run "$T/bin" check 2>&1 | sed -n '/^chroot/p;/^== Result/,$p'
mv "$T/chroot.off" "$T/sysbin/chroot"
echo "-- Android 13: the hint to the README section on killed background processes"
FAKE_ACM=y FAKE_SDK=33 FAKE_REL=13 run "$T/bin" check 2>&1 | sed -n '/^== Result/,$p'
echo "-- the screen row: a tablet (1280x800), a phone whose size was overridden, and a phone that will not say"
FAKE_ACM=y FAKE_WM=1280x800 run "$T/bin" check 2>&1 | grep '^screen'
FAKE_ACM=y FAKE_WM=1080x2400 FAKE_WM_OVERRIDE=720x1600 run "$T/bin" check 2>&1 | grep '^screen'
FAKE_ACM=y FAKE_WM=none run "$T/bin" check 2>&1 | grep '^screen'
echo "-- an old kernel, no driver, 32-bit: everything at once"
FAKE_UNAME_R=3.18.71 FAKE_ARM64=0 FAKE_ACM=n FAKE_FREE_MB=1000 FAKE_SDK=31 run "$T/bin" check 2>&1 | sed -n '/^== Result/,$p'
echo "-- the check is only a read: it changed nothing in Debian"
if [ -e "$T/root/.spft-provisioned" ]; then echo "FAIL: check wrote a marker"; else echo "ok: no marker written"; fi

echo; echo "=== U. spft update: git pull, then the install step runs again (here the pkg stand-in stops it)"
git init -q --bare -b main "$T/origin.git"
git -c init.defaultBranch=main clone -q "$T/origin.git" "$T/clone" 2>/dev/null
cp "$T/spft_test.sh" "$T/clone/spft_test.sh"; cp -r "$T/lib" "$T/clone/lib"
git -C "$T/clone" -c user.name=t -c user.email=t@t add -A
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q -m first
git -C "$T/clone" push -q origin HEAD:main 2>/dev/null
git -c init.defaultBranch=main clone -q "$T/origin.git" "$T/work" 2>/dev/null
echo '# newer' >> "$T/work/lib/run.sh"
git -C "$T/work" -c user.name=t -c user.email=t@t commit -q -am second
git -C "$T/work" push -q origin HEAD:main 2>/dev/null
SCRIPT="$T/clone/spft_test.sh" run "$T/bin5" update 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[0]}"
if tail -n 1 "$T/clone/lib/run.sh" | grep -q '# newer'; then echo "ok: the clone got the newer lib/run.sh"; else echo "FAIL: not updated"; fi
echo "--- a copy that was not made with git clone:"
run "$T/bin" update 2>&1 | sed -n '1p'; echo "exit=${PIPESTATUS[0]}"

echo; echo "=== G. server that never makes its socket (takes ~20 s)"
rm -f "$T/pfx/tmp/.X11-unix/X0"
run "$T/bin2" x11; echo "exit=$?"

echo; echo "=== W. uninstall (last: it deletes the pretend Debian folder)"
touch "$T/root/.sentinel"
echo "-- an unknown option"
run "$T/bin" uninstall --frob 2>&1 | sed -n '1p'; echo "exit=${PIPESTATUS[0]}"
echo "-- anything but \"yes\" cancels"
: > "$LOG"
echo no | run "$T/bin" uninstall; echo "exit=$?"
if [ -e "$T/root/.sentinel" ]; then echo "ok: nothing was deleted"; else echo "FAIL: the Debian folder is gone"; fi
echo "rm calls: $(grep -c '^rm ' "$LOG")"
echo "-- something is still mounted inside the folder: NOTHING is deleted, exit 1"
printf '/dev/block/dm-0 %s/root/dev tmpfs rw 0 0\n' "$T" > "$T/mounts.fake"
: > "$LOG"
run "$T/bin" uninstall --yes; echo "exit=$?"
if [ -e "$T/root/.sentinel" ]; then echo "ok: the Debian folder is untouched"; else echo "FAIL: the Debian folder is gone"; fi
echo "rm calls: $(grep -c '^rm ' "$LOG")"
if [ -d "$T/dl/app" ]; then echo "ok: the downloads are untouched"; else echo "FAIL: the downloads were deleted"; fi
: > "$T/mounts.fake"
echo "-- a folder that is too shallow, or inside the system folders, is refused (made-up names: nothing real is at risk here)"
: > "$LOG"
for bad_root in /spft-test-no-such-folder /proc/spft-test/no/such/folder; do
  env -i PATH="$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$bad_root" FAKE_ROOT=1 SPFT_DL="$T/dl" HOME="$T" \
    bash "$T/spft_test.sh" root-uninstall 2>&1 | cut -c1-70; echo "exit=${PIPESTATUS[0]}"
done
echo "rm calls: $(grep -c '^rm ' "$LOG")"
echo "-- nothing is mounted: the Debian folder and spft's downloads go, a file of yours in that folder stays"
touch "$T/dl/rootfs.tar.gz" "$T/dl/SP_Flash_Tool_v5.2228_Linux.zip" "$T/dl/keep-me.txt"
: > "$LOG"
echo yes | run "$T/bin" uninstall 2>&1 | sed "s#$T#\$T#g"; echo "exit=${PIPESTATUS[1]}"
if [ -e "$T/root" ]; then echo "FAIL: the Debian folder is still there"; else echo "ok: the Debian folder is gone"; fi
ls "$T/dl" | tr '\n' ' '; echo
echo "wake-unlock calls: $(grep -c '^wake-unlock$' "$LOG")"
echo "-- and again, now that nothing is left"
run "$T/bin" uninstall --yes 2>&1 | grep -E 'nothing to delete|removed'; echo "exit=${PIPESTATUS[0]}"

if grep -qF "$T" /proc/mounts; then echo "mounts under $T - not deleting"; else rm -rf "$T"; echo "cleaned up"; fi
