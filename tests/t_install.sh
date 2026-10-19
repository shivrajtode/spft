#!/bin/bash
# Test of the first-time setup: install.sh and `spft install` - the path a new user takes after `git clone`.
# Stand-ins for pkg, pm, su, wget, curl, zcat, mount and chroot, a fake Debian rootfs and fake SP Flash Tool zips.
# Needs: bash, tar, gzip, zip, unzip, sha256sum, cksum, sed, head. It refuses to run where /system/bin/mount exists.
# On purpose in the tests: ok/bad always return 0, patterns are literal text, printf builds escapes.
# shellcheck disable=SC2015,SC2016,SC2012,SC2002,SC2059
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
if [ -e /system/bin/mount ]; then echo "ABORT: /system/bin/mount exists here"; exit 1; fi
for c in zip unzip tar gzip sha256sum cksum; do command -v $c >/dev/null || { echo "ABORT: $c is needed for this test"; exit 1; }; done
T=$(mktemp -d "${TMPDIR:-/tmp}/spft-inst.XXXXXX")
mkdir -p "$T/bin" "$T/pfx/bin" "$T/pfx/lib" "$T/pfx/tmp" "$T/sysbin" "$T/home/storage/downloads" "$T/media/Download" \
         "$T/served/mirror.invalid" "$T/stage" "$T/rootsrc" "$T/nosu"
ln -s "$(type -P bash)" "$T/pfx/bin/bash"
ln -s "$(type -P sh)" "$T/pfx/bin/sh"
ln -s "$(type -P tar)" "$T/pfx/bin/tar"
ln -s "$(type -P unzip)" "$T/pfx/bin/unzip"
ln -s "$(type -P dirname)" "$T/nosu/dirname"
LOG=$T/calls.log; : > "$LOG"
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
has() { if grep -q -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
hasnt() { if grep -q -- "$2" "$1"; then bad "$3"; else ok "$3"; fi; }

# --- stand-ins ------------------------------------------------------------------------------------
# (the test's folder and call log reach them through the environment: $TT and $TLOG)
cat > "$T/bin/su" <<'EOF'
#!/bin/bash
[ "$1" = -c ] || exit 2
if [ "$2" = "id -u" ]; then
  [ "${FAKE_SU_DENY:-}" != 1 ] || exit 1
  echo 0; exit 0
fi
exec env FAKE_ROOT=1 sh -c "$2"
EOF
cat > "$T/bin/zcat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = /proc/config.gz ]; then
  case ${FAKE_KERNEL:-64} in
    64) echo "CONFIG_ARM64=y" ;;
    32) echo "# CONFIG_ARM64 is not set" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exec /usr/bin/env PATH=/usr/bin:/bin zcat "$@"
EOF
cat > "$T/bin/pm" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "list packages" ]; then printf 'package:com.android.settings\n'; [ -z "${PM_LIST:-}" ] || printf '%s\n' "$PM_LIST"; fi
EOF
printf '#!/bin/bash\necho "wake-lock" >> "$TLOG"\n' > "$T/bin/termux-wake-lock"
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
out= url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -e | -A | -b | --retry | --retry-delay | --connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
echo "curl url=$url" >> "$TLOG"
hp=${url#*://}; host=${hp%%/*}; file=${hp##*/}
if [ -f "$TT/served/$host/$file" ]; then cp "$TT/served/$host/$file" "$out"; exit 0; fi
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
EOF
# pkg: FAKE_PKG_FAIL=all fails every call, FAKE_PKG_FAIL=NAME fails the calls that mention that package
cat > "$T/pfx/bin/pkg" <<'EOF'
#!/bin/bash
echo "pkg $*" >> "$TLOG"
case "${FAKE_PKG_FAIL:-}" in
  '') ;;
  all) exit 1 ;;
  *) case " $* " in *" $FAKE_PKG_FAIL "*) exit 1 ;; esac ;;
esac
exit 0
EOF
cat > "$T/pfx/bin/wget" <<'EOF'
#!/bin/bash
echo "wget $*" >> "$TLOG"
if [ "${FAKE_WGET_FAIL:-}" = 1 ]; then echo "wget: unable to resolve host address" >&2; : > "$2"; exit 4; fi
[ "$1" = -O ] || exit 2
cp "$TT/rootfs.tar.gz" "$2"
EOF
for c in mount umount; do printf '#!/bin/bash\necho "%s $*" >> "$TLOG"\n' "$c" > "$T/sysbin/$c"; done
# chroot: /bin/true (the preflight), `od` on a path inside /opt, and the provisioning run (which can "fail its self-test")
cat > "$T/sysbin/chroot" <<'EOF'
#!/bin/bash
root=$1; shift
echo "chroot $root $*" >> "$TLOG"
case $1 in
  /bin/true) exit 0 ;;
  /usr/bin/od)
    shift; args=()
    for a in "$@"; do case $a in /opt/*) args+=("$root$a") ;; *) args+=("$a") ;; esac; done
    exec od "${args[@]}" ;;
  /usr/bin/env)
    if [ "${*: -1}" = /root/spft-provision.sh ]; then
      rm -f "$root/root/.spft-selftest-failed"
      if [ "${FAKE_SELFTEST_FAIL:-}" = 1 ]; then : > "$root/root/.spft-selftest-failed"; fi
    fi
    exit 0 ;;
esac
echo "chroot stand-in: unexpected command $*" >&2
exit 1
EOF
chmod +x "$T"/bin/* "$T"/pfx/bin/pkg "$T"/pfx/bin/wget "$T"/sysbin/*

# --- a fake Debian rootfs (the installer insists on at least 10 MB) -------------------------------
R0=$T/rootsrc
mkdir -p "$R0"/bin "$R0"/usr/bin "$R0"/etc "$R0"/root "$R0"/proc "$R0"/sys "$R0"/dev "$R0"/tmp "$R0"/mnt "$R0"/opt
cp "$(type -P true)" "$R0/bin/bash"; cp "$(type -P true)" "$R0/bin/true"
head -c 10500000 /dev/urandom > "$R0/usr/bin/ballast"
tar -czf "$T/rootfs.tar.gz" -C "$R0" .

# --- fake SP Flash Tool zips ----------------------------------------------------------------------
mkelf() { # mkelf FILE MACHINE   MACHINE = the 2 bytes at offset 18 in hex (3e00 = x86-64)
  printf '\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00' > "$1"
  printf "\\x${2:0:2}\\x${2:2:2}" >> "$1"
  head -c 300 /dev/zero >> "$1"
}
mkzip() { rm -f "$1"; (cd "$T/stage" && zip -q -r "$1" .); rm -rf "$T/stage"; mkdir -p "$T/stage"; }
mkdir -p "$T/stage/SP_Flash_Tool_v5.2228_Linux/lib"
mkelf "$T/stage/SP_Flash_Tool_v5.2228_Linux/flash_tool" 3e00
echo lib > "$T/stage/SP_Flash_Tool_v5.2228_Linux/lib/libx.so"
mkzip "$T/good.zip"
GOOD=$(sha256sum "$T/good.zip" | cut -d' ' -f1)
mkdir -p "$T/stage/SP_Flash_Tool_noexe"; echo hi > "$T/stage/SP_Flash_Tool_noexe/readme.txt"
mkzip "$T/noexe.zip"
serve() { cp "$T/good.zip" "$T/served/mirror.invalid/SP_Flash_Tool_v5.2228_Linux.zip"; }
unserve() { rm -f "$T/served/mirror.invalid/"*; }

# --- the repository under test: transformed copy (Android paths moved into the work folder, "root" switchable) ----
make_repo() { # make_repo FOLDER
  rm -rf "$1"; mkdir -p "$1"
  cp -r "$REPO/lib" "$1/lib"
  printf '# test list\nv5.2228  %s  http://mirror.invalid/SP_Flash_Tool_v5.2228_Linux.zip\n' "$GOOD" > "$1/lib/tools.conf"
  sed -e "s#/system/bin/#$T/sysbin/#g" \
      -e "s#/system/xbin/chroot#$T/none/chroot#g" \
      -e "s#/data/media/0#$T/media#g" \
      -e "s#/data/system/packages.list#$T/packages.list#g" \
      -e "s#\"/data/data/\$pk\"#\"$T/appdata/\$pk\"#" \
      -e "s#\"/data/user/0/\$pk\"#\"$T/appdata0/\$pk\"#" \
      -e "s#\[ -d /data/data \] || \[ -d /data/user/0 \]#[ -d $T/appdata ] || [ -d $T/appdata0 ]#" \
      -e 's#^is_root() .*#is_root() { [ "${FAKE_ROOT:-0}" = 1 ]; }#' "$REPO/spft" > "$1/spft"
  sed -e 's#^\[ "$(id -u)" != 0 \] || die.*#true#' "$REPO/install.sh" > "$1/install.sh"
}
make_repo "$T/repo"
if grep -n '(id -u)' "$T/repo/install.sh"; then echo "NOTE: install.sh still checks id -u (the sed did not match)"; fi
if grep -n '/system/' "$T/repo/spft" | grep -v -e 'tried /system/bin' -e '/system/\*'; then echo "NOTE: unreplaced /system paths above"; fi
if grep -n -e '/data/system' -e '/data/user/' -e '"/data/data/' -e '/data/data \]' "$T/repo/spft"; then echo "NOTE: unreplaced /data paths above"; fi

run() { # run [VAR=value ...] COMMAND...   with the stand-in environment
  env -i PATH="$T/pfx/bin:$T/bin:/usr/bin:/bin" PREFIX="$T/pfx" SPFT_ROOT="$T/root" SPFT_DL="$T/dl" HOME="$T/home" TERM=xterm \
      TT="$T" TLOG="$LOG" PM_LIST="${PM_LIST:-}" "$@"
}
fresh() { chmod -R u+rwX "$T/root" 2>/dev/null; rm -rf "$T/root" "$T/dl" "$T/pfx/bin/spft" "$T/home/storage/downloads/"* "$T/media/Download/"*; : > "$LOG"; serve; make_repo "$T/repo"; }
count() { grep -c "$1" "$LOG"; }
provisions() { count '/root/spft-provision.sh$'; }
sed_t() { sed "s#$T#\$T#g"; }
INSTALL() { bash "$T/repo/install.sh" "$@"; }   # used as: run [ENV...] bash "$T/repo/install.sh" ...
# what root sees of the installed apps (/data/system/packages.list), written the way Android writes it. `pm` as the normal
# Termux user does NOT show them (Android 11 and newer hide other apps), so PM_LIST stays empty in these tests.
apps() { # apps NAME...   (no name: a phone that has only the system apps)
  mkdir -p "$T/appdata" "$T/appdata0"
  printf '%s\n' 'com.android.settings 1000 0 /data/user/0/com.android.settings platform:privapp:targetSdkVersion=30 1065,3002 0 30' > "$T/packages.list"
  local n
  for n in "$@"; do printf '%s 10215 0 /data/user/0/%s default:targetSdkVersion=29 3003,9997 0 1\n' "$n" "$n" >> "$T/packages.list"; done
}
no_list() { rm -f "$T/packages.list"; rm -rf "$T/appdata" "$T/appdata0"; }   # root can tell nothing about the apps

echo "=== 1. first install: the Termux:X11 app is not installed yet"
fresh; apps
PM_LIST='' run bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
sed_t < "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && ok "install finished with exit 0" || bad "install exit status $rc"
has "$T/out" 'root: if your root app asks, press ALLOW' "asks for root right at the start"
has "$T/out" 'Termux:X11 app: not found' "says the Termux:X11 app is missing"
has "$T/out" 'github.com/termux/termux-x11/releases/tag/nightly' "gives the link to the Termux:X11 app"
has "$T/out" 'Reminder: install the Termux:X11 app' "reminds again at the end"
hasnt "$T/out" 'must come from GitHub' "does not insist on one particular source for the app"
has "$T/out" 'Four steps follow' "says what the long step will show"
has "$T/out" "working, not stuck" "says that the longest step is working, not stuck"
has "$T/out" 'done. Start SP Flash Tool with:  spft' "ends by telling you to type spft"
echo "--- Termux packages asked for:"; grep '^pkg ' "$LOG"
has "$LOG" '^pkg install -y git curl wget tar unzip xz-utils coreutils x11-repo$' "installs git, curl, ... and the x11 repository"
has "$LOG" '^pkg install -y termux-x11-nightly$' "installs the Termux:X11 package"
has "$LOG" '^pkg install -y termux-api$' "installs termux-api"
[ -x "$T/pfx/bin/spft" ] && ok "the spft command was added" || bad "no spft command"
head -n 2 "$T/pfx/bin/spft" | sed_t
[ "$(count '^wget ')" = 1 ] && ok "Debian downloaded once" || bad "wget calls: $(count '^wget ')"
[ "$(provisions)" = 1 ] && ok "Debian set up once" || bad "provisioning runs: $(provisions)"
has "$T/root/etc/resolv.conf" 'nameserver 1.1.1.1' "Debian has DNS servers"
has "$T/root/etc/apt/apt.conf.d/01-android-nosandbox" 'Sandbox::User "root"' "apt is told not to use its sandbox user"
cmp -s "$T/root/root/spft-provision.sh" "$REPO/lib/provision.sh" && ok "provision script copied into Debian" || bad "provision script differs"
cmp -s "$T/root/usr/local/bin/spft-run" "$REPO/lib/run.sh" && ok "spft-run installed in Debian" || bad "spft-run differs"
[ -e "$T/root/.spft-unpacked" ] && ok "rootfs marker written" || bad "no rootfs marker"
[ "$(cat "$T/root/.spft-provisioned" 2>/dev/null)" = "$(cksum < "$REPO/lib/provision.sh")" ] && ok "setup marker holds the checksum of provision.sh" || bad "setup marker wrong"
[ "$(readlink "$T/root/opt/spft-current")" = SP_Flash_Tool_v5.2228_Linux ] && ok "SP Flash Tool was downloaded and is the current one" || bad "no SP Flash Tool"
[ "$(count '^curl ')" = 1 ] && ok "one download of the tool" || bad "curl calls: $(count '^curl ')"
has "$LOG" '^wake-lock$' "the phone was kept awake"

echo; echo "=== 2. the spft command works from any folder, and keeps arguments with spaces together"
(cd / && run "$T/pfx/bin/spft" help) | sed -n '1p' | sed_t
(cd / && run "$T/pfx/bin/spft" x11 'bad option' 2>&1) | sed -n '1p' | sed_t
(cd / && run "$T/pfx/bin/spft" x11 'bad option' 2>&1) | grep -q "unknown option 'bad option'" && ok "an argument with a space arrives in one piece" || bad "argument was split"
(cd / && run "$T/pfx/bin/spft" tool list) | grep -q 'v5.2228' && ok "spft tool list works through the launcher" || bad "tool list through the launcher"

echo; echo "=== 3. running install.sh again changes nothing and downloads nothing (the Termux:X11 app is installed: root sees it, pm does not)"
: > "$LOG"; apps com.termux.x11
PM_LIST='' run bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
grep -E 'Termux:X11 app|already|done' "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && ok "exit 0" || bad "exit status $rc"
has "$T/out" 'Termux:X11 app: installed' "sees that the Termux:X11 app is installed"
hasnt "$T/out" 'Reminder: install the Termux:X11 app' "no reminder when it is installed"
has "$T/out" 'rootfs already unpacked' "does not unpack the rootfs again"
has "$T/out" 'Debian is already set up' "does not set Debian up again"
has "$T/out" 'SP Flash Tool is already installed' "does not download the tool again"
[ "$(count '^wget ')" = 0 ] && [ "$(count '^curl ')" = 0 ] && [ "$(provisions)" = 0 ] && ok "no downloads, no provisioning" || bad "wget=$(count '^wget ') curl=$(count '^curl ') provisioning=$(provisions)"

echo; echo "=== 3b. root can tell nothing about the apps: only 'could not tell', never 'not found'"
no_list
: > "$LOG"
PM_LIST='' run bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
grep 'Termux:X11 app' "$T/out"
has "$T/out" 'Termux:X11 app: could not tell' "says that it can't tell"
hasnt "$T/out" 'Termux:X11 app: not found' "does not say that the app is missing"
hasnt "$T/out" 'Reminder: install the Termux:X11 app' "no reminder (nobody knows that it is missing)"
has "$T/out" 'github.com/termux/termux-x11/releases/tag/nightly' "still gives the link, in case it is missing"
echo "-- ... and when pm shows the app, that settles it"
PM_LIST=package:com.termux.x11 run bash "$T/repo/install.sh" > "$T/out" 2>&1
has "$T/out" 'Termux:X11 app: installed' "pm's answer is used"
apps com.termux.x11

echo; echo "=== 4. a changed lib/provision.sh (after \`spft update\`) is applied once"
echo '# a new line' >> "$T/repo/lib/provision.sh"
: > "$LOG"
run bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
echo "exit=$rc   provisioning runs: $(provisions)"
[ "$(provisions)" = 1 ] && ok "provisioning ran again" || bad "provisioning runs: $(provisions)"
: > "$LOG"
run bash "$T/repo/install.sh" > "$T/out" 2>&1
[ "$(provisions)" = 0 ] && ok "and not a third time" || bad "provisioning runs: $(provisions)"

echo; echo "=== 5. --no-tool leaves SP Flash Tool out"
fresh
run bash "$T/repo/install.sh" --no-tool > "$T/out" 2>&1; rc=$?
echo "exit=$rc   tool downloads: $(count '^curl ')"
[ "$rc" = 0 ] && [ "$(count '^curl ')" = 0 ] && [ ! -e "$T/root/opt/spft-current" ] && ok "no tool downloaded or installed" || bad "--no-tool did not skip the tool"
: > "$LOG"
run bash "$T/repo/install.sh" --frobnicate > "$T/out" 2>&1; rc=$?
tail -n 1 "$T/out"; echo "exit=$rc"
[ "$rc" = 1 ] && has "$T/out" "unknown option '--frobnicate'" "an unknown option is refused" || bad "unknown option accepted"
[ "$(count '^pkg ')" = 0 ] && ok "and refused before anything was installed" || bad "packages were installed before the option was checked"

echo; echo "=== 6. the box64 self-test fails: not marked as set up, exit 1, and the next run tries again"
fresh
run FAKE_SELFTEST_FAIL=1 bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 8 "$T/out" | sed_t; echo "exit=$rc"
[ "$rc" = 1 ] && ok "exit 1" || bad "exit status $rc"
has "$T/out" 'self-test FAILED' "says the self-test failed"
[ ! -e "$T/root/.spft-provisioned" ] && ok "no 'set up' marker" || bad "marker was written"
hasnt "$T/out" 'done. Start SP Flash Tool' "does not claim to be done"
hasnt "$T/out" 'SP Flash Tool is installed. Start it' "and does not say 'start it with spft' either"
: > "$LOG"
run bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
echo "second run: exit=$rc   provisioning runs: $(provisions)"
[ "$rc" = 0 ] && [ "$(provisions)" = 1 ] && [ -e "$T/root/.spft-provisioned" ] && ok "the second run set it up properly" || bad "second run: rc=$rc runs=$(provisions)"

echo; echo "=== 7. kernel checks"
fresh
run FAKE_KERNEL=32 bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 2 "$T/out"; echo "exit=$rc"
[ "$rc" = 1 ] && has "$T/out" 'not a 64-bit ARM kernel' "a 32-bit kernel is refused" || bad "32-bit kernel: rc=$rc"
[ "$(count '^wget ')" = 0 ] && [ ! -e "$T/root" ] && ok "nothing was downloaded or unpacked" || bad "work was started on a 32-bit kernel"
fresh
run FAKE_KERNEL=none bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
grep -- "config.gz" "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && has "$T/out" "can't read /proc/config.gz" "an unreadable kernel config is not a reason to stop" || bad "unknown kernel: rc=$rc"

echo; echo "=== 8. root problems"
fresh
run FAKE_SU_DENY=1 bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 2 "$T/out"; echo "exit=$rc"
[ "$rc" = 1 ] && has "$T/out" 'root was refused' "a refused root request gets a clear message" || bad "su refused: rc=$rc"
[ "$(count '^pkg ')" = 0 ] && ok "root is asked for before anything is installed" || bad "packages were installed before root was checked"
has "$T/out" 'Superuser list' "KernelSU and APatch users are told where to allow Termux"
fresh
env -i PATH="$T/pfx/bin:$T/nosu" PREFIX="$T/pfx" HOME="$T/home" bash "$T/repo/install.sh" 2>&1 | sed -n '1,3p'
env -i PATH="$T/pfx/bin:$T/nosu" PREFIX="$T/pfx" HOME="$T/home" bash "$T/repo/install.sh" 2>&1 | grep -q 'no su found' && ok "no su: says the device must be rooted" || bad "no message for a phone without su"

echo; echo "=== 9. not inside Termux / run as root / lib folder missing"
run PREFIX="$T/nowhere" bash "$T/repo/install.sh" 2>&1 | sed_t | sed -n '1p'
run PREFIX="$T/nowhere" bash "$T/repo/install.sh" 2>&1 | grep -q 'inside Termux' && ok "outside Termux: clear message" || bad "no message outside Termux"
if [ "$(id -u)" = 0 ]; then
  run bash "$REPO/install.sh" 2>&1 | sed -n '1p'
  run bash "$REPO/install.sh" 2>&1 | grep -q 'not as root' && ok "as root: refused (the real install.sh)" || bad "root not refused"
else
  echo "(skipped: this test is not running as root)"
fi
mkdir -p "$T/lonely"; cp "$T/repo/install.sh" "$T/lonely/"
run bash "$T/lonely/install.sh" 2>&1 | sed_t | sed -n '1p'
run bash "$T/lonely/install.sh" 2>&1 | grep -q 'clone the whole repository' && ok "install.sh alone (no spft, no lib): asks for the whole repository" || bad "lonely install.sh not caught"

echo; echo "=== 10. Termux package problems"
fresh
run FAKE_PKG_FAIL=git bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 2 "$T/out"; echo "exit=$rc"
[ "$rc" = 1 ] && has "$T/out" 'termux-change-repo' "a failed pkg install suggests termux-change-repo" || bad "pkg failure: rc=$rc"
run FAKE_PKG_FAIL=termux-x11-nightly bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 2 "$T/out"; echo "exit=$rc"
[ "$rc" = 1 ] && has "$T/out" 'termux-x11-nightly' "a failed termux-x11-nightly install is reported" || bad "x11 pkg failure: rc=$rc"
fresh
run FAKE_PKG_FAIL=termux-api bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
grep 'termux-api' "$T/out"; echo "exit=$rc"
[ "$rc" = 0 ] && has "$T/out" 'termux-api is optional' "termux-api is optional" || bad "termux-api failure stopped the install: rc=$rc"
fresh
run FAKE_PKG_FAIL=all bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 2 "$T/out"; echo "exit=$rc"
[ "$rc" = 1 ] && ok "no packages at all: stops" || bad "no packages: rc=$rc"

echo; echo "=== 11. too little free space"
fresh
run SPFT_MIN_MB=999999999 bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 1 "$T/out"; echo "exit=$rc"
[ "$rc" = 1 ] && has "$T/out" 'MB are free' "refuses early, with the numbers" || bad "low space: rc=$rc"
[ "$(count '^wget ')" = 0 ] && ok "nothing was downloaded" || bad "downloaded despite no space"

echo; echo "=== 12. the Debian download fails (no internet), then works"
fresh
run FAKE_WGET_FAIL=1 bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 3 "$T/out" | sed_t; echo "exit=$rc"
[ "$rc" = 1 ] && has "$T/out" 'could not download Debian' "a failed download gets a message" || bad "wget failure: rc=$rc"
if compgen -G "$T/dl/*rootfs*" > /dev/null; then bad "a half-written rootfs file is left behind"; else ok "no half-written rootfs file left"; fi
run bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "the next run completes" || bad "next run: rc=$rc"

echo; echo "=== 13. the SP Flash Tool download fails: Debian stays set up, the steps are shown, \`spft tool\` finishes it"
fresh; unserve
run bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
tail -n 14 "$T/out" | sed_t; echo "exit=$rc"
[ "$rc" = 1 ] && ok "exit 1 (the install is not complete)" || bad "exit status $rc"
has "$T/out" 'SP Flash Tool is NOT installed yet' "says the tool is missing"
has "$T/out" 'README' "points to the README for the hand download"
hasnt "$T/out" 'done. Start SP Flash Tool' "does not say done"
[ -e "$T/root/.spft-provisioned" ] && ok "Debian is marked as set up anyway" || bad "Debian marker missing"
cp "$T/good.zip" "$T/home/storage/downloads/SP_Flash_Tool_v5.2228_Linux.zip"
: > "$LOG"
run "$T/pfx/bin/spft" tool > "$T/out" 2>&1; rc=$?
echo "spft tool with the zip in the Download folder: exit=$rc"
[ "$rc" = 0 ] && [ -x "$T/root/opt/SP_Flash_Tool_v5.2228_Linux/flash_tool" ] && ok "installed from the Download folder" || bad "hand install failed"
[ "$(provisions)" = 0 ] && ok "Debian was not set up again" || bad "provisioning ran again"

echo; echo "=== 14. a bad zip found during the install must not be reported as installed"
fresh; unserve
cp "$T/noexe.zip" "$T/home/storage/downloads/SP_Flash_Tool_v5.2228_Linux.zip"
run bash "$T/repo/install.sh" > "$T/out" 2>&1; rc=$?
grep -E 'flash_tool|installed|NOT installed' "$T/out"; echo "exit=$rc"
[ "$rc" = 1 ] && ok "exit 1" || bad "exit status $rc"
has "$T/out" 'there is no flash_tool in that zip' "names the problem"
hasnt "$T/out" 'SP Flash Tool is installed. Start it' "no false 'installed' message"
has "$T/out" 'SP Flash Tool is NOT installed yet' "says what is missing"

echo; echo "=== 15. the repository in a folder with spaces in its name"
fresh
make_repo "$T/my repo"
run bash "$T/my repo/install.sh" > "$T/out" 2>&1; rc=$?
echo "exit=$rc"
[ "$rc" = 0 ] && ok "install works" || bad "install exit status $rc"
(cd / && run "$T/pfx/bin/spft" help) | sed -n '1p'
(cd / && run "$T/pfx/bin/spft" help) | grep -q '^spft - SP Flash Tool' && ok "the launcher finds spft in a folder with spaces" || bad "launcher failed"

echo; echo "FAIL count: $fails"
if grep -qF "$T" /proc/mounts; then echo "mounts under $T - not deleting"; else rm -rf "$T"; echo "cleaned up"; fi
[ "$fails" = 0 ]
