# Taoli Tools Container

## Setup
```bash
curl -fsSL https://taoli.tools/setup | sh
```

The container starts Chromium with web security disabled and uses the dedicated
`/home/taoli/data` browser profile. It also raises Chromium's open-file limit to
65,535 so PGlite's OPFS access-handle pool can initialize the optional P&L
high-performance database on Linux.

The open-file limit can be lowered when running the image directly:

```bash
docker run -e CHROMIUM_NOFILE_LIMIT=32768 ...
```

## Update
```bash
docker pull ghcr.io/aliez-ren/taoli-tools-container:latest
docker service update --force taoli_tools_container
docker service logs -f taoli_tools_container
```

```bash
docker pull ghcr.io/aliez-ren/taoli-tools-signer:latest
docker service update --force taoli_tools_signer
docker service logs -f taoli_tools_signer
```

## Remove
```bash
docker service rm taoli_tools_container taoli_tools_signer
docker secret rm taoli_tools_CERT.pem taoli_tools_KEY.pem taoli_tools_KEYCHAIN
```
