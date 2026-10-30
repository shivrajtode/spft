#!/bin/bash
# Runs INSIDE the Debian chroot, as root.
# Installs box64, x86_64 libraries and a VNC desktop so SP Flash Tool v5 can run.
#
# It shows what it is doing all the time. The slow parts count their files, and a step that has nothing to count (apt
# checking what is missing) shows a moving bar, because a step that stays quiet for a minute looks like a hang (and apt
# IS quiet while it reads its package lists, and while dpkg unpacks, on a slow tablet).
#
# Since v6 it is also lighter and faster than it was (the first install took two hours on a slow connection):
#   - an empty stand-in package tells apt "a graphics driver is installed", so apt does not download Mesa and LLVM (about
#     100 MB to download and 500 MB on the disk, for each of the two CPU types, and SP Flash Tool never uses them),
#   - the files download several at a time, and a download that was cut off continues where it stopped,
#   - apt does not retry on its own any more: apt 3.0.3 (Debian 13) floods the screen when it does (see aptq below).
#     spft retries itself, and says so in one calm line.
set -eu
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

STEPS=4
STEP=starting
n=0
BEAT=${SPFT_BEAT:-20}     # seconds between "still working" lines
POLL=${SPFT_POLL:-5}      # seconds between download progress lines (and between the lines that stand in for the bar)
FRAME=${SPFT_FRAME:-0.3}  # seconds between two pictures of the moving bar
RETRIES=${SPFT_RETRIES:-3}         # how many more times a failed download is tried
RETRY_WAIT=${SPFT_RETRY_WAIT:-5}   # seconds before the first new try; the wait doubles each time
JOBS=${SPFT_JOBS:-4}               # files downloaded at the same time. 1 = only apt downloads, one file after the other
case $JOBS in '' | *[!0-9]* | 0) JOBS=4 ;; esac
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

# --- the network: settings, retrying, and the line that apt repeats --------------------------------------------

# Prefer IPv4 when a program connects somewhere. Many mobile networks hand out an IPv6 address that does not really work, and
# then every connection waits for its timeout before it falls back to IPv4. This only changes the ORDER: IPv6 still works.
if ! grep -qs '^precedence[[:space:]]*::ffff:0:0/96[[:space:]]*100' /etc/gai.conf; then
  echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf || true
fi

# The network settings of every apt command in this Debian, also the ones you type yourself later:
#  - Acquire::Retries 0: apt 3.0.3 (the apt of Debian 13) has a bug (Debian #1111554, fixed in 3.1.8). When a download fails
#    once and apt is allowed to retry, it puts the file back in its queue with a growing delay, and while it waits it prints
#    "W: Tried to start delayed item ... but failed" in a loop: many thousands of lines. The screen floods, the phone slows
#    down, and then it goes on by itself. So apt does not retry. retry() below does it, with one calm line each time.
#  - no translations of the package descriptions (about 6 MB nobody reads here), and no patching of the package lists in
#    many small steps (slow on a tablet; a full list is one download)
#  - a connection that gets no data for 30 seconds is dead; one request at a time per connection (mobile networks like it)
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/02spft-network <<'APT_EOF'
// Written by spft (lib/provision.sh). See the comments there.
Acquire::Retries "0";
Acquire::Languages "none";
Acquire::PDiffs "false";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::http::Pipeline-Depth "0";
APT_EOF

# apt, without colours and without its own retrying (also on the command line, so that nothing can switch it back on)
aptq() { apt-get -y --no-install-recommends -o Acquire::Retries=0 -o APT::Color=0 "$@"; }

# retry COMMAND...   run COMMAND again when it fails, up to $RETRIES more times, waiting 5, 10, 20 seconds in between. For
# commands that fail because the connection dropped or the server was slow: what was downloaded already is kept.
retry() {
  local try=0 pause=$RETRY_WAIT rc
  while :; do
    rc=0
    "$@" || rc=$?
    [ "$rc" -ne 0 ] || return 0
    try=$((try + 1))
    [ "$try" -le "$RETRIES" ] || return "$rc"
    echo "   That did not work (exit status $rc), probably the connection. Trying again in ${pause}s: attempt $((try + 1)) of $((RETRIES + 1)). What is downloaded already is kept."
    sleep "$pause"
    pause=$((pause * 2))
  done
}

# Hide the one line that apt 3.0.3 repeats without end (see above). It cannot come up with Acquire::Retries 0, this is a
# second safety. Everything else passes through unchanged.
nospam() { awk '!/Tried to start delayed item/ { print; fflush() }'; }

# apt_update: with Error-Mode=any (the same as `apt-get update --error-on=any`) a package list that could not be fetched is an
# error, and so a reason to try again, and not a warning that apt moves on from
apt_update() { beat "reading the package lists from the Debian servers" retry aptq -o APT::Update::Error-Mode=any update; }

# --- the graphics stand-in ------------------------------------------------------------------------------------
# SP Flash Tool needs the files libGL.so.1 and libEGL.so.1 to EXIST (they come from the small package libglvnd); it draws with
# plain X11 and never uses OpenGL. But libgl1 and libegl1 want "a graphics driver": libglx-mesa0 or libglx-vendor, and
# libegl-mesa0 or libegl-vendor. apt picks Mesa, and Mesa drags in LLVM 19, ICU, Z3 and more: about 100 MB to download and
# 500 MB on the disk, for the arm64 libraries AND again for the amd64 ones. That alone was a large part of the two hours.
# This empty package (no files at all) says "a driver of that kind is installed", so apt leaves Mesa out. One is needed for
# each CPU type, installed before apt works out the plan for that type.
# To get the real Mesa back:   apt remove spft-gl-stub   and then   apt install libgl1-mesa-dri libglx-mesa0 libegl-mesa0
STUB_OK=1
gl_stub() { # gl_stub ARCH
  local arch=$1 d=/root/spft-stub/$1 out
  rm -rf "$d"
  mkdir -p "$d/DEBIAN"
  cat > "$d/DEBIAN/control" <<STUB_EOF
Package: spft-gl-stub
Version: 1
Architecture: $arch
Multi-Arch: same
Section: libs
Priority: optional
Maintainer: spft <spft@localhost>
Provides: libglx-vendor, libegl-vendor
Description: empty stand-in for the Mesa graphics drivers (made by spft)
 SP Flash Tool only needs libGL.so.1 and libEGL.so.1 to exist. This package has no files. It says that a graphics driver
 is installed, so that apt does not download Mesa and LLVM (about 100 MB) for nothing.
STUB_EOF
  if out=$({ dpkg-deb --build --root-owner-group "$d" "$d.deb" && dpkg -i "$d.deb"; } 2>&1); then
    echo "   (graphics stand-in for $arch installed: apt will not download Mesa and LLVM for it)"
  else
    STUB_OK=0
    printf '%s\n' "$out" | sed 's/^/   /' >&2
    echo "   (could not set up the graphics stand-in for $arch. That only means Mesa and LLVM will be downloaded as well: slower, but it works.)"
  fi
}

# --- planning, downloading, installing ------------------------------------------------------------------------

# apt_plan [--skip-unknown] PACKAGE...   one dry run (not one per package: that is minutes on a slow tablet).
# Sets PLAN_PKGS (the names to install), PLAN_N (how many packages that means), PLAN_HEAVY (how many of them are Mesa or LLVM
# packages, which the graphics stand-in should have kept out) and PLAN_LIST/PLAN_FILES/PLAN_BYTES/PLAN_URIS (the files to
# download: "name size" lines, how many, how many bytes, and "url name size sha256" lines for the parallel download).
# It prints nothing, because it runs under `bar` (see above). What it has to say stays in PLAN_ERR (apt's error message,
# when it returns 1) and PLAN_NOTES (lines about skipped names); apt_install prints them.
PLAN_ERR=
PLAN_NOTES=
PLAN_HEAVY=0
PLAN_URIS=
apt_plan() {
  local skip=0 names out bad badline p keep tries=0 uris
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
  PLAN_HEAVY=$(printf '%s\n' "$out" | grep -c '^Inst \(mesa-libgallium\|libllvm\)' || true)
  # the files to download: apt prints  'URL' FILE SIZE HASH  for each
  # shellcheck disable=SC2086
  uris=$(aptq install --print-uris $PLAN_PKGS 2>/dev/null || true)
  PLAN_LIST=$(printf '%s\n' "$uris" | sed -n "s/^'[^']*' \\([^ ]*\\) \\([0-9][0-9]*\\) .*/\\1 \\2/p")
  PLAN_URIS=$(printf '%s\n' "$uris" | sed -n "s/^'\\(https\\{0,1\\}:[^']*\\)' \\([^ ]*\\) \\([0-9][0-9]*\\) SHA256:\\([0-9a-f]\\{64\\}\\).*/\\1 \\2 \\3 \\4/p")
  PLAN_FILES=$(printf '%s\n' "$PLAN_LIST" | grep -c . || true)
  PLAN_BYTES=$(printf '%s\n' "$PLAN_LIST" | awk '{ s += $2 } END { printf "%d", s }')
}

# How much is downloaded so far: GOT_BYTES and GOT_FILES, counted from the files that are finished (in $ARCHIVES) and the
# ones that are being written (in $ARCHIVES/partial). Both apt and the parallel download use these two places.
GOT_BYTES=0
GOT_FILES=0
count_got() {
  local f size sz
  GOT_BYTES=0
  GOT_FILES=0
  while read -r f size; do
    [ -n "$f" ] || continue
    if [ -f "$ARCHIVES/$f" ]; then
      GOT_FILES=$((GOT_FILES + 1)); GOT_BYTES=$((GOT_BYTES + size))
    elif [ -f "$ARCHIVES/partial/$f" ]; then
      sz=$(stat -c %s "$ARCHIVES/partial/$f" 2>/dev/null || echo 0); GOT_BYTES=$((GOT_BYTES + sz))
    fi
  done <<EOF
$PLAN_LIST
EOF
}

# The progress line:  downloaded 12.3 of 80.1 MB (15%) - 9 of 61 files - 1.4 MB/s, about 3 min left
# The speed is the one of the last few seconds, the time left comes from the average since the start (steadier).
# FETCH_T0 / FETCH_G0 are the time and the bytes at the start (bytes that were there from an earlier run do not count as speed);
# FETCH_PREV_T / FETCH_PREV_G are the time and bytes at the previous line.
FETCH_T0=0
FETCH_G0=0
FETCH_PREV_T=0
FETCH_PREV_G=0
fetch_progress() {
  local now=$SECONDS dt rate=''
  count_got
  dt=$((now - FETCH_PREV_T))
  if [ "$dt" -gt 0 ]; then
    rate=$(awk -v d="$((GOT_BYTES - FETCH_PREV_G))" -v dt="$dt" -v left="$((PLAN_BYTES - GOT_BYTES))" \
               -v ta="$((now - FETCH_T0))" -v ga="$((GOT_BYTES - FETCH_G0))" 'BEGIN {
      r = d / dt; if (r < 0) r = 0
      if (r >= 1000000) s = sprintf("%.1f MB/s", r / 1000000)
      else if (r >= 1000) s = sprintf("%d kB/s", r / 1000)
      else s = "waiting for data"
      a = (ta > 0) ? ga / ta : 0
      if (left > 0 && a > 1000) s = s sprintf(", about %d min left", int(left / a / 60) + 1)
      print s }')
    FETCH_PREV_T=$now
    FETCH_PREV_G=$GOT_BYTES
    rate=" - $rate"
  fi
  awk -v g="$GOT_BYTES" -v t="$PLAN_BYTES" -v f="$GOT_FILES" -v c="$PLAN_FILES" -v r="$rate" 'BEGIN {
    p = (t > 0) ? int(g * 100 / t) : 0; if (p > 100) p = 100
    printf "   downloaded %.1f of %.1f MB (%d%%) - %d of %d files%s\n", g / 1000000, t / 1000000, p, f, c, r }'
}

# get_one URL FILE SIZE SHA256   download one file into apt's folder; 0 when it is there, complete and checked.
# wget -c continues a file that was cut off. The file only gets its real name when its size and its SHA256 are right, so a
# damaged download is never handed to apt. A failure is not an error of the setup: apt fetches that file itself afterwards.
get_one() {
  local url=$1 file=$2 size=$3 sha=$4 part=$ARCHIVES/partial/$2
  [ ! -f "$ARCHIVES/$file" ] || return 0
  wget -q -c --tries=4 --waitretry=5 --retry-connrefused -T 30 -O "$part" "$url" || return 1
  if [ "$(stat -c %s "$part" 2>/dev/null || echo 0)" != "$size" ] ||
     [ "$(sha256sum "$part" 2>/dev/null | cut -d' ' -f1)" != "$sha" ]; then
    rm -f "$part"      # damaged, or another file than apt meant: start this one again later
    return 1
  fi
  mv -f "$part" "$ARCHIVES/$file"
}

# fetch_parallel   download the files of PLAN_URIS, up to $JOBS at a time. It always returns 0: what fails here, apt fetches
# afterwards. (No plain `wait`: the progress loop that runs next to it never ends by itself.)
fetch_parallel() {
  local url file size sha running=0 failed=0
  mkdir -p "$ARCHIVES/partial"
  while read -r url file size sha; do
    [ -n "$url" ] || continue
    [ ! -f "$ARCHIVES/$file" ] || continue
    get_one "$url" "$file" "$size" "$sha" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then
      wait -n || failed=$((failed + 1))
      running=$((running - 1))
    fi
  done <<EOF
$PLAN_URIS
EOF
  while [ "$running" -gt 0 ]; do
    wait -n || failed=$((failed + 1))
    running=$((running - 1))
  done
  if [ "$failed" -gt 0 ]; then
    echo "   $failed file(s) did not come through this way. apt will fetch them now, one after the other."
  fi
  return 0
}

# what apt still has to fetch (all of it when nothing was downloaded in parallel, nothing when the parallel download got all)
apt_download() {
  local rc=0
  # shellcheck disable=SC2086
  ( set -o pipefail; retry aptq install -d $PLAN_PKGS 2>&1 | nospam ) || rc=$?
  return "$rc"
}

# download everything in PLAN_PKGS without installing it, with a progress line every $POLL seconds
apt_fetch() {
  local hb rc=0 t0=$SECONDS par=0
  if [ "$PLAN_FILES" -eq 0 ]; then echo "   nothing to download (the files are in the cache already)"; return 0; fi
  if [ "$JOBS" -gt 1 ] && [ "$PLAN_FILES" -gt 3 ] && [ -n "$PLAN_URIS" ] && command -v wget >/dev/null 2>&1; then par=1; fi
  if [ "$par" = 1 ]; then
    echo "   downloading $PLAN_FILES files, $(mb "$PLAN_BYTES") MB, up to $JOBS at a time. A progress line follows every $POLL seconds."
  else
    echo "   downloading $PLAN_FILES files, $(mb "$PLAN_BYTES") MB. apt names each file below, and a progress line follows every $POLL seconds."
  fi
  count_got
  FETCH_T0=$SECONDS
  FETCH_PREV_T=$SECONDS
  FETCH_G0=$GOT_BYTES
  FETCH_PREV_G=$GOT_BYTES
  ( while :; do
      sleep "$POLL" >/dev/null 2>&1 || exit 0
      kill -0 "$$" 2>/dev/null || exit 0
      fetch_progress
    done ) &
  hb=$!
  if [ "$par" = 1 ]; then fetch_parallel; fi
  apt_download || rc=$?
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
# --force-unsafe-io: dpkg does not wait for the flash storage after every file. That wait is what makes unpacking slow on a
# tablet's eMMC. If the power fails in the middle, the next `spft install` repairs it (dpkg --configure -a, then again).
apt_setup() {
  local rc=0
  echo "   installing $PLAN_N packages: unpacking, then setting them up. No more downloading; the phone is busy, it is not stuck."
  # shellcheck disable=SC2086
  ( set -o pipefail
    aptq -o Dpkg::Options::=--force-unsafe-io install $PLAN_PKGS 2>&1 | awk -v total="$PLAN_N" '
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
  local t0=$SECONDS heavy_bytes
  echo "   checking what has to be installed (up to a minute on a slow tablet; the bar moves while it works) ..."
  if ! bar "checking what has to be installed" apt_plan "$@"; then
    printf '%s\n' "$PLAN_ERR" >&2
    return 1
  fi
  printf '%s' "$PLAN_NOTES"
  if [ "$PLAN_N" -eq 0 ]; then echo "   everything is installed already"; return 0; fi
  echo "   $PLAN_N packages to install"
  if [ "$PLAN_HEAVY" -gt 0 ]; then
    heavy_bytes=$(printf '%s\n' "$PLAN_LIST" | awk '$1 ~ /^(mesa-libgallium|libllvm)/ { s += $2 } END { printf "%d", s }')
    echo "   Note: apt also wants the Mesa graphics drivers and LLVM ($PLAN_HEAVY packages, $(mb "$heavy_bytes") MB). SP Flash Tool does not use"
    echo "   them, so this only takes longer. It is not an error, and everything still works."
    if [ "$STUB_OK" = 0 ]; then echo "   (The graphics stand-in that normally keeps them out could not be installed: see above.)"; fi
  fi
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
echo "   About 100 packages. Every part shows its progress: a moving bar while apt checks, a counter for the downloads (with the"
echo "   speed and the time left) and for the installing, and a \"still working\" line every $BEAT seconds when it is quiet."
gl_stub arm64
apt_update
# wget first, on its own and by apt: it is small, and then it downloads the rest in parallel
apt_install ca-certificates wget
apt_install gpg unzip xz-utils procps nano file \
  tigervnc-standalone-server tigervnc-common xauth x11-xkb-utils xkb-data x11-xserver-utils \
  openbox xterm fonts-dejavu-core

step "arm64 + x86_64 libraries"
echo "   This is the longest step. It is NOT stuck when it is quiet: the checking shows a moving bar, the downloads show a"
echo "   progress line, the installing shows a counter, and \"still working\" lines fill the gaps."
dpkg --add-architecture amd64
gl_stub amd64
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
  beat "downloading the test program" retry apt-get download busybox-static:amd64 ||
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
