#!/bin/sh
# BusyBox ash and Debian dash support the hard/soft ulimit selectors below.
# shellcheck disable=SC3045
set -eu

CHROMIUM_BIN="${CHROMIUM_BIN:-chromium}"
CHROMIUM_NOFILE_LIMIT="${CHROMIUM_NOFILE_LIMIT:-65535}"
BROWSER_URL="${BROWSER_URL:-https://taoli.tools}"

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

rm -f "$HOME/data/SingletonLock"

exec "$CHROMIUM_BIN" \
  --display="$DISPLAY" \
  --enable-features=WebContentsForceDark \
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
  --disable-dev-shm-usage \
  --disable-web-security \
  --disk-cache-size=104857600 \
  --metrics-recording-only \
  --start-fullscreen \
  --user-data-dir="$HOME/data" \
  "$BROWSER_URL"
