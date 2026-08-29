#!/bin/sh
set -eu

INSTALL_DIR=${TAOLI_INSTALL_DIR:-/opt/taoli-tools}
REPOSITORY=${TAOLI_REPOSITORY:-taoli-tools/taoli-tools-container}
INSTALL_REF=${TAOLI_INSTALL_REF:-main}
STACK=taoli_tools
NEW_PASSWORD_SECRET=""; OLD_PASSWORD_SECRET=""; PREVIOUS_CONTAINER_ID=""; REQUIRE_NEW_CONTAINER=0; TTY_ECHO_DISABLED=0; TWO_FA_PENDING=0

restore_tty() { [ "$TTY_ECHO_DISABLED" -eq 0 ] || { stty echo < /dev/tty 2>/dev/null || true; TTY_ECHO_DISABLED=0; }; }
container_id() { docker ps --filter label=com.docker.swarm.service.name=${STACK}_container --filter status=running --format '{{.ID}}' | head -n 1; }
secret_in_use() {
  [ -n "$1" ] && docker service inspect "${STACK}_container" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{println .SecretName}}{{end}}' 2>/dev/null | grep -Fx "$1" >/dev/null
}
cleanup() {
  restore_tty
  if [ "$TWO_FA_PENDING" -eq 1 ]; then cid="$(container_id)"; [ -z "$cid" ] || docker exec "$cid" rm -f /run/rustdesk-2fa.pending.json 2>/dev/null || true; fi
  if [ -n "$NEW_PASSWORD_SECRET" ] && ! secret_in_use "$NEW_PASSWORD_SECRET"; then docker secret rm "$NEW_PASSWORD_SECRET" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

prompt_yes_no() {
  printf '%s [y/N]: ' "$1" > /dev/tty; IFS= read -r answer < /dev/tty || return 1
  case "$answer" in y|Y|yes|YES|Yes) return 0;; *) return 1;; esac
}
prompt_yes_default() {
  printf '%s [Y/n]: ' "$1" > /dev/tty; IFS= read -r answer < /dev/tty || return 1
  case "$answer" in n|N|no|NO|No) return 1;; *) return 0;; esac
}
read_password() {
  while :; do
    printf 'Enter RustDesk permanent password: ' > /dev/tty; stty -echo < /dev/tty; TTY_ECHO_DISABLED=1
    IFS= read -r RUSTDESK_PASSWORD < /dev/tty || exit 1; restore_tty; printf '\n' > /dev/tty
    printf 'Confirm RustDesk permanent password: ' > /dev/tty; stty -echo < /dev/tty; TTY_ECHO_DISABLED=1
    IFS= read -r confirm < /dev/tty || exit 1; restore_tty; printf '\n' > /dev/tty
    [ -n "$RUSTDESK_PASSWORD" ] || { echo 'Password must not be empty.' > /dev/tty; continue; }
    [ "$RUSTDESK_PASSWORD" = "$confirm" ] && break
    echo 'Passwords do not match.' > /dev/tty
  done
  unset confirm
}
read_no_whitespace() {
  prompt=$1; required=$2
  while :; do
    printf '%s' "$prompt" > /dev/tty; IFS= read -r value < /dev/tty
    if [ "$required" = 1 ] && [ -z "$value" ]; then echo 'A value is required.' > /dev/tty; continue; fi
    case "$value" in *[[:space:]]*) echo 'Whitespace is not allowed.' > /dev/tty;; *) printf '%s' "$value"; return;; esac
  done
}
wait_container() {
  attempt=0
  while [ "$attempt" -lt 90 ]; do
    cid="$(container_id)"
    if [ -n "$cid" ] && { [ "$REQUIRE_NEW_CONTAINER" -eq 0 ] || [ "$cid" != "$PREVIOUS_CONTAINER_ID" ]; }; then printf '%s' "$cid"; return 0; fi
    attempt=$((attempt+1)); sleep 2
  done
  return 1
}
wait_rustdesk() {
  attempt=0
  while [ "$attempt" -lt 90 ]; do
    cid="$(container_id)"
    if [ -n "$cid" ] && { [ "$REQUIRE_NEW_CONTAINER" -eq 0 ] || [ "$cid" != "$PREVIOUS_CONTAINER_ID" ]; } && docker exec "$cid" test -f /run/rustdesk-ready 2>/dev/null; then
      id="$(docker exec "$cid" gosu rustdesk env HOME=/home/rustdesk rustdesk --get-id 2>/dev/null | tail -n 1 | tr -d '\r')"
      [ -z "$id" ] || { RUSTDESK_ID=$id; return 0; }
    fi
    attempt=$((attempt+1)); sleep 2
  done
  return 1
}
service_env() {
  docker service inspect "${STACK}_container" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n "s/^$1=//p" | head -n 1
}
secret_exists() { docker secret inspect "$1" >/dev/null 2>&1; }

[ -r /dev/tty ] && [ -w /dev/tty ] || { echo 'An interactive terminal is required.' >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo 'Run the installer as root.' >&2; exit 1; }
if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
docker info >/dev/null 2>&1 || { echo 'The Docker daemon is not available.' >&2; exit 1; }
SWARM_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}')"
if [ "$SWARM_STATE" = inactive ]; then docker swarm init; elif [ "$(docker info --format '{{.Swarm.ControlAvailable}}')" != true ]; then echo 'This node is a Swarm worker; run on a manager.' >&2; exit 1; fi

mkdir -p "$INSTALL_DIR" /etc/docker /mnt
umask 077
curl -fsSL "https://github.com/$REPOSITORY/raw/refs/heads/$INSTALL_REF/seccomp.json" > "$INSTALL_DIR/seccomp.json.tmp"
mv "$INSTALL_DIR/seccomp.json.tmp" /etc/docker/seccomp.json

# Reuse complete signer secrets. Recover a partial certificate pair without replacing KEYCHAIN.
cert=0; key=0; secret_exists taoli_tools_CERT.pem && cert=1; secret_exists taoli_tools_KEY.pem && key=1
if [ "$cert" -ne "$key" ]; then
  docker service rm "${STACK}_signer" >/dev/null 2>&1 || true; sleep 2
  docker secret rm taoli_tools_CERT.pem taoli_tools_KEY.pem >/dev/null 2>&1 || true; cert=0; key=0
fi
if [ "$cert" -eq 0 ]; then
  openssl req -new -newkey rsa:4096 -x509 -sha256 -days 365 -nodes -subj /CN=signer \
    -addext 'subjectAltName=DNS:signer,IP:127.0.0.1' -out "$INSTALL_DIR/CERT.pem" -keyout "$INSTALL_DIR/KEY.pem"
  docker secret create taoli_tools_CERT.pem "$INSTALL_DIR/CERT.pem" >/dev/null
  docker secret create taoli_tools_KEY.pem "$INSTALL_DIR/KEY.pem" >/dev/null
  cp "$INSTALL_DIR/CERT.pem" /mnt/CERT.pem
  rm -f "$INSTALL_DIR/CERT.pem" "$INSTALL_DIR/KEY.pem"
fi
if ! secret_exists taoli_tools_KEYCHAIN; then
  [ -f keychain.toml ] && cp keychain.toml "$INSTALL_DIR/keychain.toml" || printf ' \n' > "$INSTALL_DIR/keychain.toml"
  docker secret create taoli_tools_KEYCHAIN "$INSTALL_DIR/keychain.toml" >/dev/null; rm -f "$INSTALL_DIR/keychain.toml"
fi

while :; do
  printf '%s\n' 'Select a remote-control method:' '  1) Tailscale + noVNC (default)' '  2) RustDesk direct IP access' > /dev/tty
  printf 'Selection [1]: ' > /dev/tty; IFS= read -r selection < /dev/tty
  case "$selection" in ''|1|tailscale|Tailscale) REMOTE_CONTROL_MODE=tailscale; break;; 2|rustdesk|RustDesk) REMOTE_CONTROL_MODE=rustdesk; break;; *) echo 'Please enter 1 or 2.' > /dev/tty;; esac
done

RUSTDESK_ID_SERVER="$(service_env RUSTDESK_ID_SERVER || true)"; RUSTDESK_RELAY_SERVER="$(service_env RUSTDESK_RELAY_SERVER || true)"
RUSTDESK_API_SERVER="$(service_env RUSTDESK_API_SERVER || true)"; RUSTDESK_SERVER_KEY="$(service_env RUSTDESK_SERVER_KEY || true)"
ENABLE_NEW_2FA=0
if [ "$REMOTE_CONTROL_MODE" = rustdesk ]; then
  read_password
  if [ -n "$RUSTDESK_ID_SERVER" ] && prompt_yes_default 'Keep the existing self-hosted RustDesk server settings?'; then :
  elif prompt_yes_no 'Configure a self-hosted RustDesk ID/relay server?'; then
    RUSTDESK_ID_SERVER="$(read_no_whitespace 'RustDesk ID Server: ' 1)"
    RUSTDESK_RELAY_SERVER="$(read_no_whitespace 'RustDesk Relay Server (blank to infer): ' 0)"
    while :; do printf 'RustDesk API Server (blank for OSS): ' > /dev/tty; IFS= read -r RUSTDESK_API_SERVER < /dev/tty; case "$RUSTDESK_API_SERVER" in ''|http://*|https://*) break;; *) echo 'Use http://, https://, or leave blank.' > /dev/tty;; esac; done
    RUSTDESK_SERVER_KEY="$(read_no_whitespace 'RustDesk server public key: ' 1)"
  else RUSTDESK_ID_SERVER=""; RUSTDESK_RELAY_SERVER=""; RUSTDESK_API_SERVER=""; RUSTDESK_SERVER_KEY=""; fi
  if prompt_yes_no 'Enroll new RustDesk TOTP two-factor authentication?'; then ENABLE_NEW_2FA=1; fi
fi

if docker service inspect "${STACK}_container" >/dev/null 2>&1; then
  PREVIOUS_CONTAINER_ID="$(container_id)"
  OLD_PASSWORD_SECRET="$(docker service inspect "${STACK}_container" --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{if eq .File.Name "RUSTDESK_PASSWORD"}}{{.SecretName}}{{end}}{{end}}' 2>/dev/null || true)"
fi
if [ "$REMOTE_CONTROL_MODE" = rustdesk ]; then
  REQUIRE_NEW_CONTAINER=1
  NEW_PASSWORD_SECRET="taoli_tools_RUSTDESK_PASSWORD_$(date +%s)_$(openssl rand -hex 4)"
  printf '%s' "$RUSTDESK_PASSWORD" | docker secret create --label taoli.tools.kind=rustdesk-password "$NEW_PASSWORD_SECRET" - >/dev/null
  unset RUSTDESK_PASSWORD
  RUSTDESK_PASSWORD_SECRET_NAME=$NEW_PASSWORD_SECRET; export RUSTDESK_PASSWORD_SECRET_NAME RUSTDESK_ID_SERVER RUSTDESK_RELAY_SERVER RUSTDESK_API_SERVER RUSTDESK_SERVER_KEY
  COMPOSE_SOURCE=compose.rustdesk.yml
else
  [ -z "$OLD_PASSWORD_SECRET" ] || REQUIRE_NEW_CONTAINER=1
  COMPOSE_SOURCE=compose.yml
fi
curl -fsSL "https://github.com/$REPOSITORY/raw/refs/heads/$INSTALL_REF/$COMPOSE_SOURCE" > "$INSTALL_DIR/compose.yml.tmp"
mv "$INSTALL_DIR/compose.yml.tmp" "$INSTALL_DIR/compose.yml"

docker stack deploy -c "$INSTALL_DIR/compose.yml" -d "$STACK"
if [ "$REMOTE_CONTROL_MODE" = tailscale ]; then
  wait_container >/dev/null || { docker service logs --tail 100 "${STACK}_container" >&2 || true; exit 1; }
  [ -z "$OLD_PASSWORD_SECRET" ] || { sleep 2; docker secret rm "$OLD_PASSWORD_SECRET" >/dev/null 2>&1 || true; }
  echo 'Tailscale selected. Scan the QR code shown in the service logs.'
  trap - EXIT; restore_tty; docker service logs -f "${STACK}_container"; exit 0
fi

wait_rustdesk || { echo 'Timed out waiting for RustDesk readiness.' >&2; docker service logs --tail 100 "${STACK}_container" >&2 || true; exit 1; }
[ -z "$OLD_PASSWORD_SECRET" ] || [ "$OLD_PASSWORD_SECRET" = "$NEW_PASSWORD_SECRET" ] || docker secret rm "$OLD_PASSWORD_SECRET" >/dev/null 2>&1 || true
NEW_PASSWORD_SECRET=""

cid="$(container_id)"; CURRENT_2FA="$(docker exec "$cid" rustdesk-2fa status 2>/dev/null || echo disabled)"
if [ "$ENABLE_NEW_2FA" -eq 1 ]; then
  docker exec -e TERM=xterm-256color "$cid" rustdesk-2fa generate; TWO_FA_PENDING=1
  while :; do
    printf 'Enter the 6-digit authenticator code (or s to skip): ' > /dev/tty; IFS= read -r code < /dev/tty
    if [ "$code" = s ] || [ "$code" = S ]; then TWO_FA_PENDING=0; cid="$(container_id)"; docker exec "$cid" rm -f /run/rustdesk-2fa.pending.json; break; fi
    cid="$(container_id)"; if printf '%s\n' "$code" | docker exec -i "$cid" rustdesk-2fa verify; then TWO_FA_PENDING=0; wait_rustdesk || exit 1; break; fi
    echo 'Verification failed. Wait for a new code and try again.' > /dev/tty
  done
elif [ "$CURRENT_2FA" = enabled ] && ! prompt_yes_default 'Keep the existing RustDesk 2FA enrollment?'; then
  cid="$(container_id)"; docker exec "$cid" rustdesk-2fa disable; wait_rustdesk || exit 1
fi

echo 'RustDesk IP direct access is available on TCP port 21118.'
printf 'RustDesk ID: %s\n' "$RUSTDESK_ID"
