# Taoli Tools Container

Taoli Tools Container runs Chromium in a virtual Linux desktop. The installer
lets you choose one of two remote-control methods:

- **Tailscale + noVNC** (default): preserves the original browser-based remote
  access flow and does not expose a public remote-desktop port.
- **RustDesk**: native remote desktop with TCP `21118` direct IP access,
  unattended permanent-password login, and a persistent RustDesk ID.

## Setup

Run the installer from an interactive terminal:

```bash
curl -fsSL https://taoli.tools/setup | sh
```

For Tailscale, scan the QR code from the service logs and access noVNC over the
assigned Tailnet address.

For RustDesk, the installer prompts twice for a permanent password without
echoing it. The password is stored as a Docker secret, and the final line is:

```text
RustDesk ID: <id>
```

The RustDesk flow also provides two optional settings:

- TOTP two-factor authentication: the installer prints a QR code, verifies one
  six-digit authenticator code, and stores the encrypted TOTP secret in the
  persistent RustDesk configuration volume.
- Self-hosted ID/relay server, following RustDesk's official client settings:
  `ID Server` (`hbbs`, required), server public `Key` (`id_ed25519.pub`,
  required), optional `Relay Server` (`hbbr`, normally inferred from the ID
  Server), and optional `API Server` (Pro only). Direct IP connections continue
  to use TCP port 21118. See the [official client configuration
  documentation](https://rustdesk.com/docs/en/self-host/client-configuration/).

Open or forward TCP port `21118` in the host firewall, cloud security group and
upstream NAT device. In the RustDesk client, connect to:

```text
<server-ip>:21118
```

Then enter the permanent password supplied during setup. The ID and encrypted
RustDesk configuration are kept in a Docker volume, so recreating or updating
the container does not change the ID.

The virtual display starts at 1280x720. RustDesk can switch it between 720p
(1280x720) and 1080p (1920x1080) from its display resolution menu.

The RustDesk image is tuned for unattended, long-running browser sessions. It
runs the remote-control daemon as a dedicated non-root user, isolates its
configuration from Chromium, disables X11 TCP listening, and uses a 256 MiB
`/dev/shm` tmpfs when deployed through Swarm.

The container starts Chromium with web security disabled and uses the dedicated
`/home/taoli/data` browser profile. It also raises Chromium's open-file limit to
65,535 so PGlite's OPFS access-handle pool can initialize the optional P&L
high-performance database on Linux.

The open-file limit can be lowered when running the image directly:

```bash
docker run -e CHROMIUM_NOFILE_LIMIT=32768 ...
```

## Update

For a Tailscale installation:

```bash
docker pull ghcr.io/taoli-tools/taoli-tools-container:latest
docker service update --image ghcr.io/taoli-tools/taoli-tools-container:latest --force taoli_tools_container
docker service logs -f taoli_tools_container
```

For a RustDesk installation:

```bash
docker pull ghcr.io/taoli-tools/taoli-tools-container:rustdesk
docker service update --image ghcr.io/taoli-tools/taoli-tools-container:rustdesk --force taoli_tools_container
docker service logs -f taoli_tools_container
```

Do not switch remote-control modes by changing only the service image. Re-run
the installer and select the desired mode instead. The installer supports
repairs, RustDesk password rotation, and switching in either direction while
preserving the browser, Tailscale, and RustDesk identity volumes.

```bash
docker pull ghcr.io/taoli-tools/taoli-tools-signer:latest
docker service update --image ghcr.io/taoli-tools/taoli-tools-signer:latest --force taoli_tools_signer
docker service logs -f taoli_tools_signer
```

## Remove

```bash
docker service rm taoli_tools_container taoli_tools_signer
docker secret rm taoli_tools_CERT.pem taoli_tools_KEY.pem taoli_tools_KEYCHAIN
# RustDesk installations only:
docker secret rm taoli_tools_RUSTDESK_PASSWORD 2>/dev/null || true
docker secret ls --filter label=taoli.tools.kind=rustdesk-password -q | xargs -r docker secret rm
```

The `taoli_tools_data`, `taoli_tools_tailscale`, and `taoli_tools_rustdesk`
volumes are intentionally not removed, preserving browser and remote-control
identities across updates.
