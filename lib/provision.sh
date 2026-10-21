#!/bin/bash
# Runs INSIDE the Debian chroot, as root.
# Installs box64, x86_64 libraries and a VNC desktop so SP Flash Tool v5 can run.
#
# It shows what it is doing all the time. The slow parts count their files, and a step that has nothing to count (apt
# checking what is missing) shows a moving bar, because a step that stays quiet for a minute looks like a hang (and apt
# IS quiet while it reads its package lists, and while dpkg unpacks, on a slow tablet).
set -eu
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

STEPS=4
STEP=starting
n=0
BEAT=${SPFT_BEAT:-20}     # seconds between "still working" lines
POLL=${SPFT_POLL:-5}      # seconds between download progress lines (and between the lines that stand in for the bar)
FRAME=${SPFT_FRAME:-0.3}  # seconds between two pictures of the moving bar
ARCHIVES=/var/cache/apt/archives

say() { printf '\n>> %s\n' "$*"; }
step() { n=$((n + 1)); STEP=$1; printf '\n>> [%d/%d] %s\n' "$n" "$STEPS" "$1"; }
# if anything stops the setup: say where, and that running `spft install` again carries on
trap 'rc=$?; if [ "$rc" != 0 ]; then printf "\n!! The setup stopped in step: %s (exit status %s).\n   Read the last messages above. Then run  spft install  again: it carries on, and what was already downloaded is kept.\n" "$STEP" "$rc"; fi' EXIT

# --- progress display ---------------------------------------------------------------------------------------

secs() { local s=$((SECONDS - $1)); printf '%dm%02ds' $((s / 60)) $((s % 60)); }
mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'; }   # bytes -> MB, the way apt counts (1 MB = 1,000,000 bytes)

# The little loops that print while a command runs in front. If this script is stopped (Ctrl+C, a kill) the loops would
# go on printing forever: a background job of a script ignores Ctrl+C. So each one looks, after every sleep, whether the
# script is still there (`kill -0 $$`: $$ is the script's PID, also inside a subshell) and ends when it is not.

# beat WHAT COMMAND...   run COMMAND; while it runs, print "... WHAT: still working (1m20s)" every $BEAT seconds. The exit
# status is the command's. (Pass programs, or functions that handle their own errors: `set -e` is off inside a function
# that is called like this.)
beat() {
  local what=$1 t0=$SECONDS hb rc=0
  shift
  ( while :; do
      sleep "$BEAT" >/dev/null 2>&1 || exit 0
      kill -0 "$$" 2>/dev/null || exit 0
      echo "   ... $what: still working ($(secs "$t0"))"
    done ) &
  hb=$!
  "$@" || rc=$?
  { kill "$hb" && wait "$hb"; } 2>/dev/null || true
  return "$rc"
}

# bar WHAT COMMAND...   for a step that prints nothing while it works and can take a minute (apt checking what is missing).
# On a terminal a small bar moves and the time counts, all on one line, and ends as a full bar:
#     [      =====         ] 0m12s
#     [====================] 0m23s - done
# Where the output goes to a file or a pipe (no terminal to draw over), a "still working" line comes every $POLL seconds
# instead. The exit status is the command's. COMMAND must not print anything itself, that would land in the middle of the
# bar: it keeps its messages in variables and the caller prints them afterwards.
BARW=20      # width of the bar, in characters. The whole line stays under 40 characters: a phone held upright is about
             # 45 wide, and a line that wraps cannot be drawn over again.
bar_frame() { # bar_frame NUMBER TIME   one picture of the bar (a block of 5 going to and fro), drawn over the line it is on
  local span=$((BARW - 5)) p
  p=$(($1 % (2 * span)))
  [ "$p" -le "$span" ] || p=$((2 * span - p))
  printf '\r   [%*s=====%*s] %s ' "$p" '' $((span - p)) '' "$2"
}
bar() {
  local what=$1 t0=$SECONDS hb rc=0 full
  shift
  if [ -t 1 ]; then
    ( i=0
      while :; do
        bar_frame "$i" "$(secs "$t0")"
        i=$((i + 1))
        sleep "$FRAME" >/dev/null 2>&1 || exit 0
        kill -0 "$$" 2>/dev/null || exit 0
      done ) &
    hb=$!
    "$@" || rc=$?
    { kill "$hb" && wait "$hb"; } 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
      full=$(printf '%*s' "$BARW" '' | tr ' ' '=')
      printf '\r   [%s] %s - done\n' "$full" "$(secs "$t0")"
    else
      printf '\r%*s\r' $((BARW + 20)) ''     # nothing to show: wipe the bar, the caller says what went wrong
    fi
  else
    ( while :; do
        sleep "$POLL" >/dev/null 2>&1 || exit 0
        kill -0 "$$" 2>/dev/null || exit 0
        echo "   ... $what: still working ($(secs "$t0"))"
      done ) &
    hb=$!
    "$@" || rc=$?
    { kill "$hb" && wait "$hb"; } 2>/dev/null || true
  fi
  return "$rc"
}

# apt, always with retries (a mobile connection drops now and then) and without colours
aptq() { apt-get -y --no-install-recommends -o Acquire::Retries=3 -o APT::Color=0 "$@"; }

apt_update() { beat "reading the package lists from the Debian servers" aptq update; }

# apt_plan [--skip-unknown] PACKAGE...   one dry run (not one per package: that is minutes on a slow tablet).
# Sets PLAN_PKGS (the names to install), PLAN_N (how many packages that means) and PLAN_LIST/PLAN_FILES/PLAN_BYTES
# (the files to download: "name size" lines, how many, how many bytes).
# It prints nothing, because it runs under `bar` (see above). What it has to say stays in PLAN_ERR (apt's error message,
# when it returns 1) and PLAN_NOTES (lines about skipped names); apt_install prints them.
PLAN_ERR=
PLAN_NOTES=
apt_plan() {
  local skip=0 names out bad badline p keep tries=0
  PLAN_ERR=
  PLAN_NOTES=
  if [ "${1:-}" = --skip-unknown ]; then skip=1; shift; fi
  names=$*
  while :; do
    # shellcheck disable=SC2086
    if out=$(aptq install -s $names 2>&1); then break; fi
    # names this Debian does not have: "E: Unable to locate package X" / "E: Package 'X' has no installation candidate"
    bad=$(printf '%s\n' "$out" | sed -n -e 's/^E: Unable to locate package \(.*\)$/\1/p' -e "s/^E: Package '\\([^']*\\)' has no installation candidate\$/\\1/p")
    tries=$((tries + 1))
    if [ "$skip" = 0 ] || [ -z "$bad" ] || [ "$tries" -gt 5 ]; then PLAN_ERR=$out; return 1; fi
    keep=
    badline=" $(printf '%s' "$bad" | tr '\n' ' ') "
    for p in $names; do
      case $badline in
        *" $p "*) PLAN_NOTES="$PLAN_NOTES   (this Debian does not have $p - skipped)"$'\n' ;;
        *) keep="$keep $p" ;;
      esac
    done
    names=$keep
    [ -n "$names" ] || { PLAN_ERR="no package is left to install"; return 1; }
  done
  PLAN_PKGS=$names
  PLAN_N=$(printf '%s\n' "$out" | grep -c '^Inst ' || true)
  # the files to download: apt prints  'URL' FILE SIZE HASH  for each
  # shellcheck disable=SC2086
  PLAN_LIST=$(aptq install --print-uris $PLAN_PKGS 2>/dev/null | sed -n "s/^'[^']*' \\([^ ]*\\) \\([0-9][0-9]*\\) .*/\\1 \\2/p" || true)
  PLAN_FILES=$(printf '%s\n' "$PLAN_LIST" | grep -c . || true)
  PLAN_BYTES=$(printf '%s\n' "$PLAN_LIST" | awk '{ s += $2 } END { printf "%d", s }')
}

# downloaded so far, counted from the files apt has finished (in $ARCHIVES) and is writing (in $ARCHIVES/partial)
fetch_progress() {
  local f size got=0 files=0 sz
  while read -r f size; do
    [ -n "$f" ] || continue
    if [ -f "$ARCHIVES/$f" ]; then
      files=$((files + 1)); got=$((got + size))
    elif [ -f "$ARCHIVES/partial/$f" ]; then
      sz=$(stat -c %s "$ARCHIVES/partial/$f" 2>/dev/null || echo 0); got=$((got + sz))
    fi
  done <<EOF
$PLAN_LIST
EOF
  awk -v g="$got" -v t="$PLAN_BYTES" -v f="$files" -v c="$PLAN_FILES" 'BEGIN {
    p = (t > 0) ? int(g * 100 / t) : 0; if (p > 100) p = 100
    printf "   downloaded %.1f of %.1f MB (%d%%) - %d of %d files\n", g / 1000000, t / 1000000, p, f, c }'
}

# download everything in PLAN_PKGS without installing it, with a progress line every $POLL seconds
apt_fetch() {
  local hb rc=0 t0=$SECONDS
  if [ "$PLAN_FILES" -eq 0 ]; then echo "   nothing to download (the files are in the cache already)"; return 0; fi
  echo "   downloading $PLAN_FILES files, $(mb "$PLAN_BYTES") MB. apt names each file below, and a progress line follows every $POLL seconds."
  ( while :; do
      sleep "$POLL" >/dev/null 2>&1 || exit 0
      kill -0 "$$" 2>/dev/null || exit 0
      fetch_progress
    done ) &
  hb=$!
  # shellcheck disable=SC2086
  aptq install -d $PLAN_PKGS || rc=$?
  { kill "$hb" && wait "$hb"; } 2>/dev/null || true
  [ "$rc" -eq 0 ] || return "$rc"
  fetch_progress
  echo "   download finished in $(secs "$t0")"
}

# unpack and set up the downloaded packages, counting them
#
# Two kinds of warning always show up in here, and both are harmless. They are red or yellow and sound bad, so after the
# lines the awk program adds a note that says what they are (once per kind, and only when they appeared):
#   - "Exec format error": while installing an x86_64 library Debian runs a small x86_64 helper program of that library (a
#     cache refresh). That cannot work before box64 is there, so it fails. The tool does not need what it would have made.
#   - "systemctl: command not found" and "Restarting systemd-binfmt failed", from box64's own setup: this Debian has no
#     systemd. box64 would only have registered itself so that x86_64 programs start by themselves; spft starts the tool as
#     `box64 ./flash_tool`, which needs no registration.
apt_setup() {
  local rc=0
  echo "   installing $PLAN_N packages: unpacking, then setting them up. No more downloading; the phone is busy, it is not stuck."
  # shellcheck disable=SC2086
  ( set -o pipefail
    aptq install $PLAN_PKGS 2>&1 | awk -v total="$PLAN_N" '
      function notes() {
        if (fmt == 1) {
          print "   Note: the \"Exec format error\" lines above are harmless. Debian tried to run a small x86_64 helper program"
          print "   of a library, and that cannot work before box64 is installed. The tool does not need what it would have made."
          fmt = 2
        }
        if (bin == 1) {
          print "   Note: \"systemctl: command not found\" and \"Restarting systemd-binfmt failed\" are harmless too. This Debian has"
          print "   no systemd, so box64 could not register itself there. spft starts the tool with box64 directly: no registration needed."
          bin = 2
        }
        fflush()
      }
      /^\(Reading database/ { next }
      /Exec format error/ { if (!fmt) fmt = 1; print; fflush(); next }
      /systemctl|systemd-binfmt/ { if (!bin) bin = 1; print; fflush(); next }
      { notes() }
      /^Unpacking /  { u++; printf "   [%d/%d] %s\n", u, total, $0; fflush(); next }
      /^Setting up / { s++; printf "   [%d/%d] %s\n", s, total, $0; fflush(); next }
      { print; fflush() }
      END { notes() }' ) || rc=$?
  return "$rc"
}

# apt_install [--skip-unknown] PACKAGE...   check the names (a moving bar), download (with progress), install (with a counter)
apt_install() {
  local t0=$SECONDS
  echo "   checking what has to be installed (up to a minute on a slow tablet; the bar moves while it works) ..."
  if ! bar "checking what has to be installed" apt_plan "$@"; then
    printf '%s\n' "$PLAN_ERR" >&2
    return 1
  fi
  printf '%s' "$PLAN_NOTES"
  if [ "$PLAN_N" -eq 0 ]; then echo "   everything is installed already"; return 0; fi
  echo "   $PLAN_N packages to install"
  apt_fetch || return 1
  beat "unpacking and setting up the packages" apt_setup || return 1
  echo "   done in $(secs "$t0")"
}

# --- the setup ------------------------------------------------------------------------------------------------

# Android only lets group 3003 (inet) open sockets; keep those groups for any later user account.
getent group aid_inet >/dev/null || groupadd -g 3003 aid_inet || true
getent group aid_net_raw >/dev/null || groupadd -g 3004 aid_net_raw || true
usermod -a -G aid_inet,aid_net_raw root || true

# A setup that was stopped in the middle of an install (Ctrl+C, `spft stop`, the phone's battery) can leave dpkg half
# way through a package, and then every apt command says "dpkg was interrupted". This puts that right, and finds nothing
# to do (and prints nothing) when everything is in order.
beat "making sure no package is left half installed" dpkg --configure -a || true

step "base packages"
echo "   About 100 packages. Every part shows its progress: a moving bar while apt checks, a counter for the downloads and"
echo "   for the installing, and a \"still working\" line every $BEAT seconds when it is quiet."
apt_update
apt_install ca-certificates wget gpg unzip xz-utils procps nano file \
  tigervnc-standalone-server tigervnc-common xauth x11-xkb-utils xkb-data x11-xserver-utils \
  openbox xterm fonts-dejavu-core

step "arm64 + x86_64 libraries"
echo "   This is the longest step (about 90 packages, several minutes on a slow tablet). It is NOT stuck when it is quiet:"
echo "   the checking shows a moving bar, the downloads show a progress line, the installing shows a counter, and"
echo "   \"still working\" lines fill the gaps."
dpkg --add-architecture amd64
apt_update
LIBS="libx11-6 libx11-xcb1 libxcb1 libxext6 libxrender1 libxi6 libxcursor1 libxrandr2 libxfixes3
libxkbcommon0 libxkbcommon-x11-0 libxcb-xkb1 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0
libxcb-render0 libxcb-render-util0 libxcb-shape0 libxcb-shm0 libxcb-sync1 libxcb-xfixes0 libxcb-xinerama0
libxcb-util1 libfontconfig1 libfreetype6 libglib2.0-0 libdbus-1-3 libgl1 libegl1 libpng16-16
libusb-1.0-0 libudev1 zlib1g libexpat1 libsm6 libice6"
# Names that this Debian does not have (Debian 13 renamed some libraries) are skipped, and said so.
# shellcheck disable=SC2046,SC2086
apt_install --skip-unknown $LIBS $(printf '%s:amd64 ' $LIBS) libstdc++6:amd64 libgcc-s1:amd64 libc6:amd64

build_box64() {
  say "building box64 from source (10-20 min; the percentages below are cmake's)"
  apt_install git cmake build-essential python3
  rm -rf /root/box64-src
  git clone --depth 1 https://github.com/ptitSeb/box64 /root/box64-src
  mkdir /root/box64-src/build
  cd /root/box64-src/build
  cmake .. -D ARM64=1 -D BAD_SIGNAL=ON -D CMAKE_BUILD_TYPE=RelWithDebInfo
  make -j4 || make -j1   # if the phone ran out of memory with 4 jobs, finish one job at a time
  make install
}

deb_box64() {
  install -d -m 0755 /usr/share/keyrings
  wget -qO- https://pi-apps-coders.github.io/box64-debs/KEY.gpg |
    gpg --dearmor --yes -o /usr/share/keyrings/box64-archive-keyring.gpg
  cat > /etc/apt/sources.list.d/box64.sources <<'SRC_EOF'
Types: deb
URIs: https://Pi-Apps-Coders.github.io/box64-debs/debian
Suites: ./
Architectures: arm64
Signed-By: /usr/share/keyrings/box64-archive-keyring.gpg
SRC_EOF
  apt_update
  apt_install box64-android
}

step "box64"
if ! box64 --version >/dev/null 2>&1; then
  deb_box64 || dpkg --configure -a || true
  box64 --version >/dev/null 2>&1 || build_box64
fi
box64 --version

step "self-test: running a tiny static x86_64 program through box64"
# Takes the busybox program out of the busybox-static package and lets box64 run it. (The package also holds a text file
# called busybox, in usr/share/initramfs-tools: it must not be taken for the program. That once made this test fail
# although box64 was fine.)
selftest() {
  rm -rf /tmp/bbtest && mkdir /tmp/bbtest && cd /tmp/bbtest || return 1
  beat "downloading the test program" apt-get download busybox-static:amd64 ||
    { echo "   could not download the test program (busybox-static:amd64): check the internet connection"; return 1; }
  dpkg -x busybox-static_*_amd64.deb . || { echo "   could not unpack the test program"; return 1; }
  # the real program: an executable file called busybox that is big (about 1 MB), not a config file
  bb=$(find . -type f -name busybox -perm -u+x -size +100k | head -n1)
  [ -n "$bb" ] || { echo "   there is no busybox program inside the package"; return 1; }
  out=$(box64 "$bb" uname -m) || { echo "   box64 could not run $bb (see the box64 message above)"; return 1; }
  echo "   busybox, run through box64, says: machine = $out   (expected: x86_64)"
  [ "$out" = x86_64 ]
}
rm -f /root/.spft-selftest-failed
if ! ( selftest ); then
  echo "!! self-test failed - box64 can't run x86_64 code here (read the messages above)"
  : > /root/.spft-selftest-failed    # spft reads this: it will not mark the setup as finished
fi

apt-get clean # give the downloaded .deb files back (they are not needed after installing)

say "done"
echo "Debian is ready: box64, the x86_64 libraries and the desktop are installed."
