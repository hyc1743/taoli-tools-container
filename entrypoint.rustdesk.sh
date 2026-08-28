#!/bin/sh
# Debian dash supports the hard/soft ulimit selectors used below.
# shellcheck disable=SC3045
set -eu

VNC_PID=""
DBUS_PID=""
BROWSER_PID=""
RUSTDESK_PID=""

CHROMIUM_NOFILE_LIMIT="${CHROMIUM_NOFILE_LIMIT:-65535}"
RUSTDESK_PASSWORD_FILE="${RUSTDESK_PASSWORD_FILE:-/run/secrets/RUSTDESK_PASSWORD}"
BROWSER_URL="${BROWSER_URL:-https://taoli.tools}"

cleanup() {
  trap - EXIT INT TERM HUP
  for pid in "$RUSTDESK_PID" "$BROWSER_PID" "$VNC_PID" "$DBUS_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
}

handle_signal() {
  exit 0
}

trap cleanup EXIT
trap handle_signal INT TERM HUP

if [ ! -r "$RUSTDESK_PASSWORD_FILE" ]; then
  echo "RustDesk password secret is missing: $RUSTDESK_PASSWORD_FILE" >&2
  exit 1
fi

RUSTDESK_PASSWORD="$(cat "$RUSTDESK_PASSWORD_FILE")"
if [ -z "$RUSTDESK_PASSWORD" ]; then
  echo "RustDesk permanent password must not be empty" >&2
  exit 1
fi

# Named volumes retain numeric ownership across image upgrades. Migrate an
# existing browser profile when the image's fixed taoli UID/GID differs.
if [ "$(stat -c %u:%g /home/taoli/data)" != "$(id -u taoli):$(id -g taoli)" ]; then
  chown -R taoli:taoli /home/taoli/data
fi

rm -f /run/rustdesk-ready

case "$CHROMIUM_NOFILE_LIMIT" in
  ''|*[!0-9]*)
    echo "CHROMIUM_NOFILE_LIMIT must be a positive integer" >&2
    exit 1
    ;;
esac

NOFILE_HARD_LIMIT="$(ulimit -Hn)"
if [ "$NOFILE_HARD_LIMIT" != "unlimited" ] && [ "$CHROMIUM_NOFILE_LIMIT" -gt "$NOFILE_HARD_LIMIT" ]; then
  CHROMIUM_NOFILE_LIMIT="$NOFILE_HARD_LIMIT"
fi
ulimit -Sn "$CHROMIUM_NOFILE_LIMIT"
echo "Starting Chromium with a nofile soft limit of $(ulimit -Sn)"

mkdir -p /run/dbus
RUSTDESK_MACHINE_ID_FILE=/root/.config/rustdesk/machine-id
if [ ! -s "$RUSTDESK_MACHINE_ID_FILE" ]; then
  dbus-uuidgen > "$RUSTDESK_MACHINE_ID_FILE"
  chmod 600 "$RUSTDESK_MACHINE_ID_FILE"
fi
cp "$RUSTDESK_MACHINE_ID_FILE" /etc/machine-id
mkdir -p /var/lib/dbus
cp "$RUSTDESK_MACHINE_ID_FILE" /var/lib/dbus/machine-id
dbus-daemon --system --nofork --nopidfile &
DBUS_PID=$!

# Xvnc is only used as the virtual X11 display. Its VNC socket remains bound to
# localhost; remote access is provided exclusively by RustDesk.
gosu taoli env HOME=/home/taoli DISPLAY="$DISPLAY" \
  Xvnc "$DISPLAY" -rfbport "$VNC_PORT" -localhost -AlwaysShared \
  -SecurityTypes None -ac -depth 24 -geometry "$DISPLAY_GEOMETRY" &
VNC_PID=$!

sleep 1

rm -f /home/taoli/data/SingletonLock

gosu taoli env HOME=/home/taoli DISPLAY="$DISPLAY" dbus-run-session -- \
  sh -c 'openbox-session & exec /usr/lib/chromium/chromium "$@"' sh \
    --display="$DISPLAY" \
    --disable-background-networking \
    --disable-backgrounding-occluded-windows \
    --disable-breakpad \
    --disable-client-side-phishing-detection \
    --disable-component-extensions-with-background-pages \
    --disable-component-update \
    --disable-default-apps \
    --disable-domain-reliability \
    --disable-extensions \
    --disable-features=AutofillServerCommunication,CertificateTransparencyComponentUpdater,InterestFeedContentSuggestions,MediaRouter,OnDeviceModel,OptimizationGuideModelDownloading,OptimizationHints,Translate \
    --no-default-browser-check \
    --no-first-run \
    --no-pings \
    --no-service-autorun \
    --password-store=basic \
    --process-per-site \
    --disable-background-timer-throttling \
    --disable-gpu \
    --use-gl=disabled \
    --disable-web-security \
    --disk-cache-size=104857600 \
    --metrics-recording-only \
    --user-data-dir=/home/taoli/data \
    "$BROWSER_URL" &
BROWSER_PID=$!

dbus-run-session -- rustdesk --server &
RUSTDESK_PID=$!

RUSTDESK_ID=""
attempt=0
while [ "$attempt" -lt 60 ]; do
  RUSTDESK_ID="$(rustdesk --get-id 2>/dev/null || true)"
  if [ -n "$RUSTDESK_ID" ]; then
    break
  fi
  if ! kill -0 "$RUSTDESK_PID" 2>/dev/null; then
    echo "RustDesk server exited before it became ready" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 2
done

if [ -z "$RUSTDESK_ID" ]; then
  echo "Timed out waiting for RustDesk ID" >&2
  exit 1
fi

rustdesk --option direct-server Y
rustdesk --option direct-access-port "$RUSTDESK_PORT"
rustdesk --option approve-mode password
rustdesk --option verification-method use-permanent-password
rustdesk --option enable-audio N

PASSWORD_RESULT="$(rustdesk --password "$RUSTDESK_PASSWORD" 2>&1 || true)"
unset RUSTDESK_PASSWORD
case "$PASSWORD_RESULT" in
  *Done!*) ;;
  *)
    echo "Failed to set the RustDesk permanent password: $PASSWORD_RESULT" >&2
    exit 1
    ;;
esac
unset PASSWORD_RESULT

# The tray UI is not needed for unattended password access and otherwise keeps
# a second Flutter process resident for the lifetime of the container.
pkill -f "rustdesk --tray" 2>/dev/null || true

touch /run/rustdesk-ready
echo "RustDesk direct access port: $RUSTDESK_PORT/tcp"
echo "RustDesk ID: $RUSTDESK_ID"

while kill -0 "$BROWSER_PID" 2>/dev/null && kill -0 "$RUSTDESK_PID" 2>/dev/null; do
  sleep 2
done

if ! kill -0 "$RUSTDESK_PID" 2>/dev/null; then
  wait "$RUSTDESK_PID" 2>/dev/null || true
  echo "RustDesk server exited unexpectedly" >&2
  exit 1
fi

wait "$BROWSER_PID"
