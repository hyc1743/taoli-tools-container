#!/usr/bin/python3
"""Provision RustDesk TOTP 2FA from a non-GUI installation flow."""

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time
from urllib.parse import quote

from nacl.secret import SecretBox


CONFIG_DIR = Path("/root/.config/rustdesk")
PENDING_FILE = CONFIG_DIR / "2fa.pending.json"
MACHINE_ID_FILE = CONFIG_DIR / "machine-id"
ISSUER = "RustDesk Connection"


def rustdesk_id() -> str:
    value = subprocess.check_output(["rustdesk", "--get-id"], text=True).strip()
    if not value:
        raise RuntimeError("RustDesk ID is not ready")
    return value


def totp(secret: bytes, timestamp: int) -> str:
    counter = timestamp // 30
    digest = hmac.new(secret, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    number = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return f"{number % 1_000_000:06d}"


def generate() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    device_id = rustdesk_id()
    secret = os.urandom(20)
    secret_base32 = base64.b32encode(secret).decode().rstrip("=")
    label = quote(f"{ISSUER}:{device_id}", safe="")
    issuer = quote(ISSUER, safe="")
    url = (
        f"otpauth://totp/{label}?secret={secret_base32}"
        f"&issuer={issuer}&algorithm=SHA1&digits=6&period=30"
    )
    pending = {
        "name": device_id,
        "secret": base64.b64encode(secret).decode(),
        "created_at": int(time.time() * 1000),
        "url": url,
    }
    PENDING_FILE.write_text(json.dumps(pending), encoding="utf-8")
    PENDING_FILE.chmod(0o600)

    print("\nScan this QR code with an authenticator app:\n")
    subprocess.run(["qrencode", "-t", "ANSIUTF8", url], check=True)
    print(f"\nManual TOTP secret: {secret_base32}")


def verify(code: str) -> None:
    if not (len(code) == 6 and code.isdigit()):
        raise RuntimeError("2FA code must contain exactly 6 digits")
    if not PENDING_FILE.is_file():
        raise RuntimeError("No pending 2FA enrollment; generate it first")

    pending = json.loads(PENDING_FILE.read_text(encoding="utf-8"))
    secret = base64.b64decode(pending["secret"])
    now = int(time.time())
    if code not in {totp(secret, now + offset * 30) for offset in (-1, 0, 1)}:
        raise RuntimeError("The 2FA code is incorrect or expired")

    machine_id = MACHINE_ID_FILE.read_text(encoding="utf-8").strip().encode()
    key = machine_id[: SecretBox.KEY_SIZE].ljust(SecretBox.KEY_SIZE, b"\0")
    encrypted = SecretBox(key).encrypt(secret)
    # RustDesk password_security FORMAT_V1 is: version byte + nonce + secretbox.
    payload = b"\x01" + bytes(encrypted)
    stored_secret = b"00" + base64.b64encode(payload)
    config = {
        "name": pending["name"],
        "secret": list(stored_secret),
        "digits": 6,
        "created_at": pending["created_at"],
    }
    subprocess.run(
        ["rustdesk", "--option", "2fa", json.dumps(config, separators=(",", ":"))],
        check=True,
    )
    PENDING_FILE.unlink(missing_ok=True)
    print("RustDesk two-factor authentication enabled.")


def disable() -> None:
    subprocess.run(["rustdesk", "--option", "2fa", ""], check=True)
    PENDING_FILE.unlink(missing_ok=True)
    print("RustDesk two-factor authentication disabled.")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "generate":
        generate()
    elif len(sys.argv) == 3 and sys.argv[1] == "verify":
        verify(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "disable":
        disable()
    else:
        raise RuntimeError("usage: rustdesk-2fa generate | verify CODE | disable")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"rustdesk-2fa: {exc}", file=sys.stderr)
        sys.exit(1)
