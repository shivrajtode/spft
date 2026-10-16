#!/bin/bash
# Start a VNC desktop on :1 (listens on 127.0.0.1:5901 only) unless it is already running.
export DISPLAY=:1
mkdir -p /tmp/.X11-unix /root/.vnc
chmod 1777 /tmp/.X11-unix
[ -f /root/.vnc/passwd ] || { echo spft1234 | vncpasswd -f > /root/.vnc/passwd; chmod 600 /root/.vnc/passwd; }
if ! pgrep -x Xtigervnc >/dev/null; then
  nohup Xtigervnc :1 -geometry "${SPFT_GEOMETRY:-1280x720}" -depth 24 -rfbport 5901 -localhost \
    -rfbauth /root/.vnc/passwd -SecurityTypes VncAuth -AlwaysShared >/tmp/xvnc.log 2>&1 &
  sleep 2
  nohup openbox >/tmp/openbox.log 2>&1 &
fi
echo "VNC viewer app -> localhost:5901   password: spft1234"
