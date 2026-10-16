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
for c in mount umount; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$c" "$LOG" > "$T/sysbin/$c"
done
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
# the kernel config: FAKE_ACM=y|m|n sets CONFIG_USB_ACM, FAKE_ACM=none makes the config unreadable
cat > "$T/bin/zcat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = /proc/config.gz ]; then
  [ "${FAKE_ACM:-}" != none ] || exit 1
  echo "CONFIG_ARM64=y"
  case ${FAKE_ACM:-} in y | m) echo "CONFIG_USB_ACM=$FAKE_ACM" ;; n) echo "# CONFIG_USB_ACM is not set" ;; esac
  exit 0
fi
exec /usr/bin/env PATH=/usr/bin:/bin zcat "$@"
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
    -e "s#/sys/bus/usb/drivers/cdc_acm#$T/no-cdc_acm#g" \
    -e "s#free_mb /data)#free_mb $T/no-such-folder)#" \
    -e 's#^is_root() .*#is_root() { [ "${FAKE_ROOT:-0}" = 1 ]; }#' "${SPFT_UNDER_TEST:-$REPO/spft}" > "$T/spft_test.sh"
if grep -n '/system/' "$T/spft_test.sh" | grep -v -e 'tried /system/bin' -e '/system/\*'; then echo "NOTE: unreplaced /system paths above"; fi

run() { # run PATHDIR ARGS...
  local pd=$1; shift
  env -i PATH="$pd:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/invisible" SPFT_DL="$T/dl" HOME="$T" TERM=xterm \
      PREF_STATE="$T/pref.state" PREF_LOG="$T/pref.log" PREF_SILENT="${PREF_SILENT:-}" PM_LIST="${PM_LIST:-}" FAKE_ACM="${FAKE_ACM:-}" \
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
echo "-- nothing at all: nothing to report"
run "$T/bin" stop | grep -c 'Termux:X11'

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

echo; echo "=== X. spft check (the Termux part, then the phone part) with the Termux:X11 app installed"
PM_LIST=package:com.termux.x11 run "$T/bin" check; echo "exit=$?"
echo; echo "=== X1. cdc_acm: what the kernel config says when the driver folder is missing"
for v in m y n none ''; do
  echo "-- FAKE_ACM=${v:-(option not in the config)}"
  FAKE_ACM=$v run "$T/bin" check 2>&1 | grep '^cdc_acm'
done
echo; echo "=== X2. ... with the app missing"
run "$T/bin" check 2>&1 | grep -E 'x11-app'; echo "exit=${PIPESTATUS[0]}"
echo; echo "=== X3. ... when the phone's package manager can't be asked"
mv "$T/bin/pm" "$T/pm.off"
run "$T/bin" check 2>&1 | grep -E 'x11-app'
mv "$T/pm.off" "$T/bin/pm"

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
