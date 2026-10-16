#!/bin/bash
# Runs INSIDE the Debian chroot, as root.
# Installs box64, x86_64 libraries and a VNC desktop so SP Flash Tool v5 can run.
set -eu
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8

say() { printf '\n>> %s\n' "$*"; }

# Android only lets group 3003 (inet) open sockets; keep those groups for any later user account.
getent group aid_inet >/dev/null || groupadd -g 3003 aid_inet || true
getent group aid_net_raw >/dev/null || groupadd -g 3004 aid_net_raw || true
usermod -a -G aid_inet,aid_net_raw root || true

say "base packages"
apt-get update
apt-get install -y --no-install-recommends ca-certificates wget gpg unzip xz-utils procps nano file \
  tigervnc-standalone-server tigervnc-common xauth x11-xkb-utils xkb-data x11-xserver-utils \
  openbox xterm fonts-dejavu-core

say "arm64 + x86_64 libraries"
dpkg --add-architecture amd64
apt-get update
LIBS="libx11-6 libx11-xcb1 libxcb1 libxext6 libxrender1 libxi6 libxcursor1 libxrandr2 libxfixes3
libxkbcommon0 libxkbcommon-x11-0 libxcb-xkb1 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0
libxcb-render0 libxcb-render-util0 libxcb-shape0 libxcb-shm0 libxcb-sync1 libxcb-xfixes0 libxcb-xinerama0
libxcb-util1 libfontconfig1 libfreetype6 libglib2.0-0 libdbus-1-3 libgl1 libegl1 libpng16-16
libusb-1.0-0 libudev1 zlib1g libexpat1 libsm6 libice6"
# keep only the names apt can actually resolve (Debian 13 renamed some libs with a t64 suffix)
pick() { for p in "$@"; do if apt-get install -s -qq "$p" >/dev/null 2>&1; then echo "$p"; else echo "skip: $p" >&2; fi; done; }
# shellcheck disable=SC2046,SC2086
apt-get install -y --no-install-recommends $(pick $LIBS) \
  $(pick $(printf '%s:amd64 ' $LIBS) libstdc++6:amd64 libgcc-s1:amd64 libc6:amd64)

build_box64() {
  say "building box64 from source (10-20 min)"
  apt-get install -y --no-install-recommends git cmake build-essential python3
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
  apt-get update
  apt-get install -y box64-android
}

say "box64"
if ! box64 --version >/dev/null 2>&1; then
  deb_box64 || dpkg --configure -a || true
  box64 --version >/dev/null 2>&1 || build_box64
fi
box64 --version

say "self-test: running a tiny static x86_64 program through box64"
selftest() {
  rm -rf /tmp/bbtest && mkdir /tmp/bbtest && cd /tmp/bbtest || return 1
  apt-get download busybox-static:amd64 >/dev/null 2>&1 || return 1
  dpkg -x busybox-static_*_amd64.deb . || return 1
  bb=$(find . -type f -name busybox | head -n1)
  [ -n "$bb" ] || return 1
  out=$(box64 "$bb" uname -m) || return 1
  echo "busybox says machine = $out   (expected: x86_64)"
}
rm -f /root/.spft-selftest-failed
if ! ( selftest ); then
  echo "!! self-test failed - box64 can't run x86_64 code here (read the messages above)"
  : > /root/.spft-selftest-failed    # spft reads this: it will not mark the setup as finished
fi

apt-get clean # give the downloaded .deb files back (they are not needed after installing)

say "done"
echo "Debian is ready: box64, the x86_64 libraries and the desktop are installed."
