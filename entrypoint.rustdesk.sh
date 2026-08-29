#!/bin/sh
# shellcheck disable=SC3045
set -eu

VNC_PID=""; DBUS_PID=""; BROWSER_PID=""; RUSTDESK_PID=""
XAUTHORITY=/run/taoli-Xauthority
RUSTDESK_HOME=/home/rustdesk
RUSTDESK_CONFIG_DIR=$RUSTDESK_HOME/.config/rustdesk
RUSTDESK_PASSWORD_FILE="${RUSTDESK_PASSWORD_FILE:-/run/secrets/RUSTDESK_PASSWORD}"

cleanup() {
  trap - EXIT INT TERM HUP
  for pid in "$RUSTDESK_PID" "$BROWSER_PID" "$VNC_PID" "$DBUS_PID"; do
    [ -z "$pid" ] || kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

[ -s "$RUSTDESK_PASSWORD_FILE" ] || { echo "RustDesk password secret is missing or empty" >&2; exit 1; }
rm -f /run/rustdesk-ready /run/rustdesk-restart-requested /run/rustdesk-server.pid
mkdir -p /run/dbus "$RUSTDESK_CONFIG_DIR"
[ "$(stat -c %u:%g /home/taoli/data)" = "1000:1000" ] || chown -R taoli:taoli /home/taoli/data
[ "$(stat -c %u:%g "$RUSTDESK_CONFIG_DIR")" = "1001:1001" ] || chown -R rustdesk:rustdesk "$RUSTDESK_CONFIG_DIR"
chmod 700 "$RUSTDESK_CONFIG_DIR"

if [ ! -s "$RUSTDESK_CONFIG_DIR/machine-id" ]; then dbus-uuidgen > "$RUSTDESK_CONFIG_DIR/machine-id"; fi
chmod 600 "$RUSTDESK_CONFIG_DIR/machine-id"; chown rustdesk:rustdesk "$RUSTDESK_CONFIG_DIR/machine-id"
cp "$RUSTDESK_CONFIG_DIR/machine-id" /etc/machine-id
mkdir -p /var/lib/dbus; cp "$RUSTDESK_CONFIG_DIR/machine-id" /var/lib/dbus/machine-id
dbus-daemon --system --nofork --nopidfile & DBUS_PID=$!

COOKIE="$(dbus-uuidgen)"; touch "$XAUTHORITY"; xauth -f "$XAUTHORITY" add "$DISPLAY" . "$COOKIE"
chown root:desktop "$XAUTHORITY"; chmod 640 "$XAUTHORITY"; unset COOKIE

gosu taoli setsid env HOME=/home/taoli DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
  Xvnc "$DISPLAY" -rfbport "$VNC_PORT" -localhost -AlwaysShared -SecurityTypes None \
  -nolisten tcp -auth "$XAUTHORITY" -depth 24 -geometry "$DISPLAY_GEOMETRY" &
VNC_PID=$!; sleep 1; kill -0 "$VNC_PID"

start_rustdesk() {
  gosu rustdesk setsid env HOME="$RUSTDESK_HOME" DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
    dbus-run-session -- rustdesk --server &
  RUSTDESK_PID=$!; printf '%s\n' "$RUSTDESK_PID" > /run/rustdesk-server.pid
}
wait_for_id() {
  attempt=0
  while [ "$attempt" -lt 60 ]; do
    ID="$(gosu rustdesk env HOME="$RUSTDESK_HOME" rustdesk --get-id 2>/dev/null || true)"
    [ -z "$ID" ] || return 0
    kill -0 "$RUSTDESK_PID" 2>/dev/null || return 1
    attempt=$((attempt + 1)); sleep 2
  done
  return 1
}
wait_ready() {
  attempt=0; RUSTDESK_ID=""
  while [ "$attempt" -lt 60 ]; do
    if RUSTDESK_ID="$(RUSTDESK_CONFIG_DIR="$RUSTDESK_CONFIG_DIR" rustdesk-2fa ready 2>/dev/null)"; then return 0; fi
    kill -0 "$RUSTDESK_PID" 2>/dev/null || return 1
    attempt=$((attempt + 1)); sleep 2
  done
  return 1
}

# Generate a persistent identity while direct access is still disabled.
start_rustdesk
wait_for_id || { echo "RustDesk failed to generate an ID" >&2; exit 1; }
kill -TERM "-$RUSTDESK_PID" 2>/dev/null || true; wait "$RUSTDESK_PID" 2>/dev/null || true; RUSTDESK_PID=""
RUSTDESK_PASSWORD_FILE="$RUSTDESK_PASSWORD_FILE" RUSTDESK_CONFIG_DIR="$RUSTDESK_CONFIG_DIR" rustdesk-2fa provision

start_rustdesk
wait_ready || { echo "Timed out waiting for RustDesk TCP port" >&2; exit 1; }

# No process containing the plaintext password is alive when Chromium starts.
gosu taoli setsid env HOME=/home/taoli DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
  CHROMIUM_BIN=/usr/lib/chromium/chromium BROWSER_URL="${BROWSER_URL:-https://taoli.tools}" \
  dbus-run-session -- sh -c 'openbox-session & exec /usr/local/bin/chromium-entrypoint' &
BROWSER_PID=$!
pkill -u rustdesk -f "rustdesk --tray" 2>/dev/null || true
touch /run/rustdesk-ready
echo "RustDesk direct access port: ${RUSTDESK_PORT:-21118}/tcp"; echo "RustDesk ID: $RUSTDESK_ID"

while kill -0 "$BROWSER_PID" 2>/dev/null; do
  if ! kill -0 "$RUSTDESK_PID" 2>/dev/null; then
    wait "$RUSTDESK_PID" 2>/dev/null || true
    if [ -f /run/rustdesk-restart-requested ]; then
      rm -f /run/rustdesk-restart-requested /run/rustdesk-ready
      start_rustdesk
      wait_ready || { echo "RustDesk failed to restart after configuration" >&2; exit 1; }
      touch /run/rustdesk-ready
    else
      echo "RustDesk server exited unexpectedly" >&2; exit 1
    fi
  fi
  sleep 2
done
wait "$BROWSER_PID"
