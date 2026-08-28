#!/bin/sh
set -eu

RUSTDESK_SECRET_NAME=taoli_tools_RUSTDESK_PASSWORD
TTY_ECHO_DISABLED=0
CONTAINER_ID=""
RUSTDESK_2FA_PENDING=0

restore_tty() {
  if [ "$TTY_ECHO_DISABLED" -eq 1 ]; then
    stty echo < /dev/tty 2>/dev/null || true
    TTY_ECHO_DISABLED=0
  fi
}

cleanup() {
  restore_tty
  if [ "$RUSTDESK_2FA_PENDING" -eq 1 ] && [ -n "$CONTAINER_ID" ]; then
    docker exec "$CONTAINER_ID" rustdesk-2fa disable >/dev/null 2>&1 || true
  fi
}

abort() {
  exit 1
}

prompt_yes_no() {
  prompt=$1
  printf '%s [y/N]: ' "$prompt" > /dev/tty
  IFS= read -r answer < /dev/tty || return 1
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

trap cleanup EXIT
trap abort HUP INT TERM

if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
  echo "An interactive terminal is required." >&2
  exit 1
fi

while :; do
  printf '%s\n' 'Select a remote-control method:' > /dev/tty
  printf '%s\n' '  1) Tailscale + noVNC (default)' > /dev/tty
  printf '%s\n' '  2) RustDesk direct IP access' > /dev/tty
  printf 'Selection [1]: ' > /dev/tty
  IFS= read -r REMOTE_CONTROL_SELECTION < /dev/tty
  case "$REMOTE_CONTROL_SELECTION" in
    ""|1|tailscale|Tailscale)
      REMOTE_CONTROL_MODE=tailscale
      break
      ;;
    2|rustdesk|RustDesk)
      REMOTE_CONTROL_MODE=rustdesk
      break
      ;;
    *) echo 'Please enter 1 or 2.' > /dev/tty ;;
  esac
done

ENABLE_RUSTDESK_2FA=0
CONFIGURE_CUSTOM_RUSTDESK_SERVER=0
RUSTDESK_ID_SERVER=""
RUSTDESK_RELAY_SERVER=""
RUSTDESK_API_SERVER=""
RUSTDESK_SERVER_KEY=""

if [ "$REMOTE_CONTROL_MODE" = "rustdesk" ]; then
  while :; do
    printf 'Enter RustDesk permanent password: ' > /dev/tty
    stty -echo < /dev/tty
    TTY_ECHO_DISABLED=1
    IFS= read -r RUSTDESK_PASSWORD < /dev/tty || exit 1
    restore_tty
    printf '\n' > /dev/tty

    printf 'Confirm RustDesk permanent password: ' > /dev/tty
    stty -echo < /dev/tty
    TTY_ECHO_DISABLED=1
    IFS= read -r RUSTDESK_PASSWORD_CONFIRM < /dev/tty || exit 1
    restore_tty
    printf '\n' > /dev/tty

    if [ -z "$RUSTDESK_PASSWORD" ]; then
      echo "RustDesk permanent password must not be empty." > /dev/tty
    elif [ "$RUSTDESK_PASSWORD" != "$RUSTDESK_PASSWORD_CONFIRM" ]; then
      echo "Passwords do not match. Please try again." > /dev/tty
    else
      break
    fi
  done
  unset RUSTDESK_PASSWORD_CONFIRM

  if prompt_yes_no 'Enable RustDesk TOTP two-factor authentication?'; then
    ENABLE_RUSTDESK_2FA=1
  fi

  if prompt_yes_no 'Configure a self-hosted RustDesk ID/relay server?'; then
    CONFIGURE_CUSTOM_RUSTDESK_SERVER=1
    while [ -z "$RUSTDESK_ID_SERVER" ]; do
      printf 'RustDesk ID Server (hbbs host or host:21116): ' > /dev/tty
      IFS= read -r RUSTDESK_ID_SERVER < /dev/tty
      case "$RUSTDESK_ID_SERVER" in
        *[[:space:]]*)
          echo 'ID Server must not contain whitespace.' > /dev/tty
          RUSTDESK_ID_SERVER=""
          ;;
      esac
    done

    printf 'RustDesk Relay Server (hbbr host:21117, blank to infer): ' > /dev/tty
    IFS= read -r RUSTDESK_RELAY_SERVER < /dev/tty
    case "$RUSTDESK_RELAY_SERVER" in
      *[[:space:]]*) echo 'Relay Server must not contain whitespace.' >&2; exit 1 ;;
    esac

    printf 'RustDesk API Server (Pro only, blank for OSS): ' > /dev/tty
    IFS= read -r RUSTDESK_API_SERVER < /dev/tty
    case "$RUSTDESK_API_SERVER" in
      ""|http://*|https://*) ;;
      *) echo 'API Server must be blank or start with http:// or https://.' >&2; exit 1 ;;
    esac

    while [ -z "$RUSTDESK_SERVER_KEY" ]; do
      printf 'RustDesk server public key (id_ed25519.pub): ' > /dev/tty
      IFS= read -r RUSTDESK_SERVER_KEY < /dev/tty
      case "$RUSTDESK_SERVER_KEY" in
        *[[:space:]]*)
          echo 'Server public key must not contain whitespace.' > /dev/tty
          RUSTDESK_SERVER_KEY=""
          ;;
      esac
    done
  fi
else
  RUSTDESK_PASSWORD=unused
fi

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "seccomp-profile": "/etc/docker/seccomp.json",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 100000,
      "Soft": 65535
    }
  }
}
EOF

curl -fsSL https://github.com/taoli-tools/taoli-tools-container/raw/refs/heads/main/seccomp.json > /etc/docker/seccomp.json
curl -fsSL https://get.docker.com | sh
if [ "$REMOTE_CONTROL_MODE" = "rustdesk" ]; then
  COMPOSE_SOURCE=compose.rustdesk.yml
else
  COMPOSE_SOURCE=compose.yml
fi
curl -fsSL "https://github.com/taoli-tools/taoli-tools-container/raw/refs/heads/main/$COMPOSE_SOURCE" > compose.yml

openssl req -new -newkey rsa:4096 -x509 -sha256 -days 365 -nodes \
  -subj /CN=signer -addext 'subjectAltName=DNS:signer,IP:127.0.0.1' \
  -out CERT.pem -keyout KEY.pem
if [ ! -f keychain.toml ]; then
  echo " " > keychain.toml
fi

docker swarm init
if [ "$REMOTE_CONTROL_MODE" = "rustdesk" ]; then
  if docker secret inspect "$RUSTDESK_SECRET_NAME" >/dev/null 2>&1; then
    echo "Docker secret $RUSTDESK_SECRET_NAME already exists; this installer only supports fresh installations." >&2
    exit 1
  fi
  printf '%s' "$RUSTDESK_PASSWORD" | docker secret create "$RUSTDESK_SECRET_NAME" - >/dev/null
fi
unset RUSTDESK_PASSWORD

if [ "$REMOTE_CONTROL_MODE" = "rustdesk" ]; then
  docker pull ghcr.io/taoli-tools/taoli-tools-container:rustdesk
else
  docker pull ghcr.io/taoli-tools/taoli-tools-container:latest
fi
docker pull ghcr.io/taoli-tools/taoli-tools-signer:latest
docker stack deploy -c compose.yml -d taoli_tools

rm -f keychain.toml KEY.pem
mv CERT.pem /mnt/

if [ "$REMOTE_CONTROL_MODE" = "tailscale" ]; then
  echo "Tailscale selected. Scan the QR code shown in the service logs."
  docker service logs -f taoli_tools_container
  exit 0
fi

RUSTDESK_ID=""
attempt=0
while [ "$attempt" -lt 90 ]; do
  CONTAINER_ID="$(docker ps \
    --filter label=com.docker.swarm.service.name=taoli_tools_container \
    --filter status=running --format '{{.ID}}' | head -n 1)"
  if [ -n "$CONTAINER_ID" ] && docker exec "$CONTAINER_ID" test -f /run/rustdesk-ready 2>/dev/null; then
    RUSTDESK_ID="$(docker exec "$CONTAINER_ID" rustdesk --get-id 2>/dev/null | tail -n 1 | tr -d '\r')"
    [ -n "$RUSTDESK_ID" ] && break
  fi
  attempt=$((attempt + 1))
  sleep 2
done
if [ -z "$RUSTDESK_ID" ]; then
  echo "Timed out waiting for RustDesk to become ready." >&2
  docker service logs --tail 100 taoli_tools_container >&2 || true
  exit 1
fi

if [ "$CONFIGURE_CUSTOM_RUSTDESK_SERVER" -eq 1 ]; then
  docker exec "$CONTAINER_ID" rustdesk --option custom-rendezvous-server "$RUSTDESK_ID_SERVER"
  docker exec "$CONTAINER_ID" rustdesk --option relay-server "$RUSTDESK_RELAY_SERVER"
  docker exec "$CONTAINER_ID" rustdesk --option api-server "$RUSTDESK_API_SERVER"
  docker exec "$CONTAINER_ID" rustdesk --option key "$RUSTDESK_SERVER_KEY"

  CONFIGURED_ID_SERVER="$(docker exec "$CONTAINER_ID" rustdesk --option custom-rendezvous-server | tr -d '\r')"
  CONFIGURED_RELAY="$(docker exec "$CONTAINER_ID" rustdesk --option relay-server | tr -d '\r')"
  CONFIGURED_API="$(docker exec "$CONTAINER_ID" rustdesk --option api-server | tr -d '\r')"
  CONFIGURED_KEY="$(docker exec "$CONTAINER_ID" rustdesk --option key | tr -d '\r')"
  if [ "$CONFIGURED_ID_SERVER" != "$RUSTDESK_ID_SERVER" ] || \
     [ "$CONFIGURED_RELAY" != "$RUSTDESK_RELAY_SERVER" ] || \
     [ "$CONFIGURED_API" != "$RUSTDESK_API_SERVER" ] || \
     [ "$CONFIGURED_KEY" != "$RUSTDESK_SERVER_KEY" ]; then
    echo "Failed to configure the self-hosted RustDesk server." >&2
    exit 1
  fi
  echo "RustDesk ID Server: $CONFIGURED_ID_SERVER"
  if [ -n "$CONFIGURED_RELAY" ]; then
    echo "RustDesk Relay Server: $CONFIGURED_RELAY"
  else
    echo "RustDesk Relay Server: inferred automatically from the ID Server"
  fi
  [ -z "$CONFIGURED_API" ] || echo "RustDesk API Server: $CONFIGURED_API"
  # Allow the rendezvous mediator to re-register with the selected ID server.
  sleep 3
fi

if [ "$ENABLE_RUSTDESK_2FA" -eq 1 ]; then
  docker exec -e TERM=xterm-256color "$CONTAINER_ID" rustdesk-2fa generate
  RUSTDESK_2FA_PENDING=1
  while :; do
    printf 'Enter the 6-digit authenticator code (or s to skip): ' > /dev/tty
    IFS= read -r RUSTDESK_2FA_CODE < /dev/tty
    if [ "$RUSTDESK_2FA_CODE" = "s" ] || [ "$RUSTDESK_2FA_CODE" = "S" ]; then
      docker exec "$CONTAINER_ID" rustdesk-2fa disable >/dev/null
      RUSTDESK_2FA_PENDING=0
      echo "RustDesk two-factor authentication skipped."
      break
    fi
    if docker exec "$CONTAINER_ID" rustdesk-2fa verify "$RUSTDESK_2FA_CODE"; then
      RUSTDESK_2FA_PENDING=0
      break
    fi
    echo "Verification failed. Wait for a new code and try again." > /dev/tty
  done
  unset RUSTDESK_2FA_CODE
fi

RUSTDESK_ID="$(docker exec "$CONTAINER_ID" rustdesk --get-id 2>/dev/null | tail -n 1 | tr -d '\r')"
echo "RustDesk IP direct access is available on TCP port 21118."
printf 'RustDesk ID: %s\n' "$RUSTDESK_ID"
