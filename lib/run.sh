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
echo "starting SP Flash Tool from $d (Ctrl+C to stop)"
exec box64 "./$exe"
