#!/bin/bash
# usage: spft-run [folder-with-flash_tool]      (runs INSIDE Debian; `spft` in Termux calls it for you)
# Shows SP Flash Tool on Termux:X11 when that is running (fast), otherwise on a VNC desktop.
# SPFT_DISPLAY=x11 or SPFT_DISPLAY=vnc forces one of the two.
f=${1:-}
if [ -z "$f" ]; then
  # `spft tool` points /opt/spft-current at the version that was installed last
  if [ -d /opt/spft-current ]; then f=/opt/spft-current; else f=/opt; fi
fi
if [ -d "$f" ]; then
  f=$(find "$f"/ -maxdepth 3 -type f \( -name flash_tool -o -name SPFlashToolV6 \) 2>/dev/null | head -n1)
fi
if [ -z "$f" ] || [ ! -f "$f" ]; then
  echo "SP Flash Tool is not installed yet. In Termux run:  spft tool"
  exit 1
fi

# one copy only: a second one would open a second window on top of the first
pid=$(pgrep -f 'box64 \./(flash_tool|SPFlashToolV6)' | head -n1)
[ -n "$pid" ] || pid=$(pgrep -x flash_tool | head -n1)
[ -n "$pid" ] || pid=$(pgrep -x SPFlashToolV6 | head -n1)
if [ -n "$pid" ]; then
  echo "SP Flash Tool is already running (pid $pid), so no second copy is started."
  echo "Switch to the Termux:X11 app (or your VNC viewer) to see it."
  echo "To close it first, run in Termux:  spft stop   (never while a flash is running)"
  exit 0
fi

chmod +x "$f"
exe=${f##*/}
cd "$(dirname "$f")" || exit 1
d=$PWD

mode=${SPFT_DISPLAY:-auto}
if [ "$mode" = auto ]; then
  if [ -S /tmp/.X11-unix/X0 ]; then
    mode=x11
  else
    mode=vnc
    echo "(Termux:X11 not detected - for the faster display, run 'spft' in Termux)"
  fi
fi
case $mode in
  x11)
    if [ ! -S /tmp/.X11-unix/X0 ]; then
      echo "Termux:X11 is not running, or Debian was entered before it started."
      echo "In Termux run:  spft"
      exit 1
    fi
    export DISPLAY=:0
    ob_up() { [ -f /tmp/spft-openbox0.pid ] && kill -0 "$(cat /tmp/spft-openbox0.pid)" 2>/dev/null; }
    # Let the tool's main window fill the screen (dialogs keep their own size): one rule in openbox's config,
    # made from Debian's default the first time. Delete ~/.config/openbox/rc.xml to undo it.
    rc=$HOME/.config/openbox/rc.xml
    if [ ! -f "$rc" ] && [ -f /etc/xdg/openbox/rc.xml ]; then
      mkdir -p "${rc%/*}"
      sed 's#<applications>#&\n    <application class="*" type="normal"><maximized>yes</maximized></application>#' \
        /etc/xdg/openbox/rc.xml > "$rc"
      if ob_up; then openbox --reconfigure; fi
    fi
    # a light window manager, so the tool gets normal windows and dialogs
    if ! ob_up; then
      nohup openbox >/tmp/openbox0.log 2>&1 &
      echo $! > /tmp/spft-openbox0.pid
    fi
    echo "display: Termux:X11"
    ;;
  vnc)
    spft-gui
    export DISPLAY=:1
    ;;
  *)
    echo "SPFT_DISPLAY must be x11 or vnc (or unset)"
    exit 1
    ;;
esac

export QT_X11_NO_MITSHM=1 XDG_RUNTIME_DIR=/tmp/runtime-root
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
export BOX64_LD_LIBRARY_PATH="$d/lib:$d:/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu"
[ -d "$d/plugins" ] && export QT_PLUGIN_PATH="$d/plugins"
export BOX64_LOG="${BOX64_LOG:-1}"

# SP Flash Tool v5 turns some new-enough kernels away with "Invalid linux kernel version" (see lib/kernelfix.sh).
# For those kernels, and only for those, a tiny library tells the tool a version it accepts.
#   SPFT_FAKE_KERNEL=auto (default)   only for the kernels the tool wrongly rejects
#   SPFT_FAKE_KERNEL=off              never
#   SPFT_FAKE_KERNEL=5.4.0            always show that version (for a kernel older than 4.19.14 that the tool refuses: at your own risk)
LIBDIR=${SPFT_LIBDIR:-/usr/local/lib/spft}
rm -f /tmp/spft-fake-kernel
if [ -f "$LIBDIR/kernelfix.sh" ] && [ -f "$LIBDIR/kernelfix.so.b64" ]; then
  # shellcheck source=lib/kernelfix.sh
  . "$LIBDIR/kernelfix.sh"
  real=$(uname -r)
  if fake=$(kernelfix_show "$real" "${SPFT_FAKE_KERNEL:-auto}"); then
    if [ -n "$fake" ]; then
      if base64 -d "$LIBDIR/kernelfix.so.b64" > /tmp/spft-kernelfix.so 2>/dev/null && printf '%s\n' "$fake" > /tmp/spft-fake-kernel; then
        export BOX64_LD_PRELOAD="/tmp/spft-kernelfix.so${BOX64_LD_PRELOAD:+:$BOX64_LD_PRELOAD}"
        if [ "${SPFT_FAKE_KERNEL:-auto}" = auto ]; then
          echo "kernel $real: SP Flash Tool v5 refuses kernels like this one by mistake (it seems to compare versions as text), so it is shown $fake."
          echo "(to turn this off: SPFT_FAKE_KERNEL=off spft)"
        else
          echo "kernel $real: SP Flash Tool is shown the kernel version $fake, as SPFT_FAKE_KERNEL says."
        fi
      else
        echo "(could not set up the kernel-version fix. If the tool says \"Invalid linux kernel version\", see docs/TROUBLESHOOTING.md)"
      fi
    fi
  else
    echo "SPFT_FAKE_KERNEL must be auto, off, or a version like 5.4.0 - ignoring '${SPFT_FAKE_KERNEL:-}'"
  fi
fi

# The tool's file windows list the user's "home" folder in their side bar, and open in it. In Debian that is /root, which
# means nothing to someone who is looking for a firmware file. So the tool is started with the phone's internal storage as
# its home, and the side bar says "sdcard". Only the tool sees this change: its own settings and caches stay in /root
# (the XDG folders say so), and the window manager was started above, before the change.
#   SPFT_STORAGE=auto (default)   /sdcard
#   SPFT_STORAGE=off              leave home as it is (/root)
#   SPFT_STORAGE=/some/folder     that folder
store=${SPFT_STORAGE:-auto}
if [ "$store" = auto ]; then store=/sdcard; fi
if [ "$store" != off ]; then
  if [ -d "$store" ]; then
    export XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-${HOME:-/root}/.config}
    export XDG_CACHE_HOME=${XDG_CACHE_HOME:-${HOME:-/root}/.cache}
    export XDG_DATA_HOME=${XDG_DATA_HOME:-${HOME:-/root}/.local/share}
    export HOME=$store
    echo "file windows: start in $store (the phone's internal storage). To turn this off: SPFT_STORAGE=off spft"
  else
    echo "(the folder $store is not there, so the file windows start in ${HOME:-/root})"
  fi
fi

echo "box64 prints a few 'Cannot dlopen' / 'Error loading needed lib' lines at the start. They are normal."
echo "Only a red BOX64 in front of 'Error:' is a real problem."
echo "starting SP Flash Tool from $d (Ctrl+C to stop)"
exec box64 "./$exe"
