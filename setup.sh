#!/bin/sh

mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<'EOF'
{
  "seccomp-profile": "/etc/docker/seccomp.json",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65535,
      "Soft": 65535
    }
  }
}
EOF

curl -fsSL https://github.com/aliez-ren/taoli-tools-container/raw/refs/heads/main/seccomp.json > /etc/docker/seccomp.json

curl -fsSL https://get.docker.com | sh

curl -fsSL https://github.com/aliez-ren/taoli-tools-container/raw/refs/heads/main/compose.yml > compose.yml

openssl req -new -newkey rsa:4096 -x509 -sha256 -days 365 -nodes -subj /CN=signer -addext 'subjectAltName=DNS:signer,IP:127.0.0.1' -out CERT.pem -keyout KEY.pem

if [ ! -f keychain.toml ]; then
  echo " " > keychain.toml
fi

docker swarm init

docker pull ghcr.io/aliez-ren/taoli-tools-container:latest

docker pull ghcr.io/aliez-ren/taoli-tools-signer:latest

docker stack deploy -c compose.yml -d taoli_tools

rm -f keychain.toml KEY.pem

mv CERT.pem /mnt/

docker service logs -f taoli_tools_container
