#!/bin/sh
set -eu

VNC_PID=""
WEBSOCKIFY_PID=""
OPENBOX_PID=""
BROWSER_PID=""
TAILSCALED_PID=""
TAILSCALE_PID=""

cleanup() {
  for pid in "$VNC_PID" "$WEBSOCKIFY_PID" "$OPENBOX_PID" "$BROWSER_PID" "$TAILSCALED_PID" "$TAILSCALE_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup INT TERM

Xvnc "$DISPLAY" -rfbport "$VNC_PORT" -localhost -AlwaysShared -SecurityTypes None -depth 16 &
VNC_PID=$!

mkdir -p "$HOME/websockify"
openssl req -new -newkey rsa:4096 -x509 -sha256 -days 365 -nodes -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -out "$HOME/websockify/CERT.pem" -keyout "$HOME/websockify/KEY.pem"
websockify --web /usr/share/novnc/ --cert "$HOME/websockify/CERT.pem" --key "$HOME/websockify/KEY.pem" "127.0.0.1:$NOVNC_PORT" "127.0.0.1:$VNC_PORT" &
WEBSOCKIFY_PID=$!

openbox-session &
OPENBOX_PID=$!

/usr/local/bin/chromium-entrypoint &
BROWSER_PID=$!

tailscaled --tun=userspace-networking --socket="$HOME/tailscale.socket" &
TAILSCALED_PID=$!

sleep 5

tailscale --socket="$HOME/tailscale.socket" up --hostname=taoli-tools-container --qr &
TAILSCALE_PID=$!

wait $BROWSER_PID
