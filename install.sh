#!/data/data/com.termux/files/usr/bin/bash
# One-time setup. Run it from Termux right after cloning this repository:
#
#     bash install.sh
#
# It installs what Termux needs, adds the `spft` command, then sets up Debian + box64 and downloads
# SP Flash Tool (the first time it takes a while, depending on the internet; keep the phone awake and plugged in). Running it again is safe.
# Any option is passed on to `spft install` (the only one is --no-tool: do not download SP Flash Tool).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}

say() { printf '\n>> %s\n' "$*"; }
die() { echo "install: $*" >&2; exit 1; }

for a in "$@"; do
  case $a in --no-tool) ;; *) die "unknown option '$a' (the only option is --no-tool: do not download SP Flash Tool)" ;; esac
done
[ "$(id -u)" != 0 ] || die "run this as the normal Termux user, not as root"
[ -x "$PREFIX/bin/pkg" ] || die "this has to run inside Termux (get Termux from https://f-droid.org/packages/com.termux/)"
{ [ -f "$HERE/spft" ] && [ -d "$HERE/lib" ]; } || die "spft and the lib folder must sit next to install.sh - clone the whole repository"
command -v su >/dev/null 2>&1 || die "no su found - this needs a rooted phone or tablet (Magisk, KernelSU, ...)"

# Ask for root right now, while you are looking at the screen, and not 15 minutes from now after the downloads:
# Magisk's "Allow?" window disappears by itself after a few seconds.
say "root: if your root app asks, press ALLOW for Termux"
[ "$(su -c 'id -u' 2>/dev/null || true)" = 0 ] ||
  die "root was refused. Open your root app (Magisk, KernelSU, APatch ...) and allow Termux (with KernelSU or APatch: switch Termux on in the Superuser list), then run this again"

# have_app PACKAGE  ->  0 installed, 1 not installed, 2 can't tell. Root is asked (spft app-installed): since Android 11 a
# normal app such as Termux is not shown the other apps, and `pm list packages` run from Termux leaves out Termux:X11.
have_app() {
  local rc=0
  bash "$HERE/spft" app-installed "$1" || rc=$?
  return "$rc"
}

if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock >/dev/null 2>&1 || true; fi

say "1/4  Termux packages"
pkg update -y || echo "(pkg update did not finish - going on)"
pkg install -y git curl wget tar unzip xz-utils coreutils x11-repo ||
  die "pkg could not install the packages. Try: termux-change-repo   and then run this again"
pkg update -y || true
pkg install -y termux-x11-nightly ||
  die "pkg could not install termux-x11-nightly (needs the x11-repo package from the step above). Run this again"
pkg install -y termux-api || echo "(termux-api is optional - going on without it)"

say "2/4  the Termux:X11 app"
x11_app=0
have_app com.termux.x11 || x11_app=$?
case $x11_app in
  0) echo "Termux:X11 app: installed (spft does not mind where you got it: GitHub nightly, F-Droid, ...)" ;;
  1) cat <<'EOF'
Termux:X11 app: not found. It is the screen SP Flash Tool is shown on. Install it before you start the tool, for example
   the nightly APK from https://github.com/termux/termux-x11/releases/tag/nightly   (file: termux-x11-universal-debug.apk)
EOF
  ;;
  *) echo "Termux:X11 app: could not tell if it is installed (Android hides other apps from Termux). If it is not, get it from"
     echo "   https://github.com/termux/termux-x11/releases/tag/nightly   (file: termux-x11-universal-debug.apk)" ;;
esac

say "3/4  the spft command"
launcher=$PREFIX/bin/spft
printf '#!%s/bin/sh\nexec "%s/bin/bash" "%s/spft" "$@"\n' "$PREFIX" "$PREFIX" "$HERE" > "$launcher"
chmod 755 "$launcher"
echo "added $launcher (it runs $HERE/spft)"

say "4/4  Debian, box64 and SP Flash Tool"
rc=0
bash "$HERE/spft" install "$@" || rc=$?

if [ "$x11_app" = 1 ]; then
  echo
  echo "Reminder: install the Termux:X11 app before you run spft (link above)."
fi
exit "$rc"
