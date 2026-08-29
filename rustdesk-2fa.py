#!/usr/bin/python3
"""Provision and validate RustDesk 1.4.9 password and TOTP configuration."""

import base64, hashlib, hmac, json, os, secrets, signal, socket, struct, subprocess, sys, time
from pathlib import Path
from urllib.parse import quote
from nacl.secret import SecretBox
import toml

CONFIG_DIR = Path(os.environ.get("RUSTDESK_CONFIG_DIR", "/home/rustdesk/.config/rustdesk"))
CONFIG_FILE, CONFIG2_FILE = CONFIG_DIR / "RustDesk.toml", CONFIG_DIR / "RustDesk2.toml"
MACHINE_ID_FILE = CONFIG_DIR / "machine-id"
PENDING_FILE = Path("/run/rustdesk-2fa.pending.json")
SERVER_PID_FILE = Path("/run/rustdesk-server.pid")
RESTART_MARKER, READY_FILE = Path("/run/rustdesk-restart-requested"), Path("/run/rustdesk-ready")
FORMAT_V1 = 1

def key():
    value = MACHINE_ID_FILE.read_text().strip().encode()
    return value[:SecretBox.KEY_SIZE].ljust(SecretBox.KEY_SIZE, b"\0")

def encrypt(data):
    # RustDesk 1.4.9 (hbb_common 7e1c392):
    # version byte || random nonce || secretbox ciphertext.
    # https://github.com/rustdesk/hbb_common/blob/7e1c392c62d39c364127307cd408421dd5f8cfb0/src/password_security.rs#L212-L264
    return bytes([FORMAT_V1]) + bytes(SecretBox(key()).encrypt(data))

def decrypt(payload):
    if payload[:1] == bytes([FORMAT_V1]):
        return SecretBox(key()).decrypt(payload[1:])
    return SecretBox(key()).decrypt(payload, nonce=b"\0" * SecretBox.NONCE_SIZE)

def encode_secret(data):
    return b"00" + base64.b64encode(encrypt(data))

def decode_secret(value):
    if not value.startswith(b"00"):
        raise RuntimeError("unexpected RustDesk encrypted-value prefix")
    return decrypt(base64.b64decode(value[2:], validate=True))

def load(path):
    return toml.load(path) if path.is_file() else {}

def store(path, value):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(toml.dumps(value))
    os.chmod(temporary, 0o600)
    if os.geteuid() == 0:
        os.chown(temporary, 1001, 1001)
    os.replace(temporary, path)

def validate_password(password=None):
    config = load(CONFIG_FILE)
    storage, salt = str(config.get("password", "")), str(config.get("salt", ""))
    if not storage.startswith("01") or not salt:
        raise RuntimeError("RustDesk permanent password storage is incomplete")
    inner = decrypt(base64.b64decode(storage[2:], validate=True))
    decoded = base64.b64decode(inner[2:], validate=True) if inner.startswith(b"00") else b""
    if len(decoded) != 32:
        raise RuntimeError("RustDesk permanent password storage failed its round trip")
    if password is not None:
        expected = hashlib.sha256(password.encode() + salt.encode()).digest()
        if not hmac.compare_digest(decoded, expected):
            raise RuntimeError("RustDesk permanent password hash does not match the secret")

def provision():
    password = Path(os.environ.get("RUSTDESK_PASSWORD_FILE", "/run/secrets/RUSTDESK_PASSWORD")).read_text()
    if not password:
        raise RuntimeError("RustDesk permanent password must not be empty")
    config = load(CONFIG_FILE)
    salt = str(config.get("salt") or "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(32)))
    h1 = hashlib.sha256(password.encode() + salt.encode()).digest()
    config.update(password="01" + base64.b64encode(encrypt(b"00" + base64.b64encode(h1))).decode(), salt=salt)
    store(CONFIG_FILE, config)
    config2 = load(CONFIG2_FILE)
    config2.setdefault("options", {}).update({
        "direct-server": "Y", "direct-access-port": os.environ.get("RUSTDESK_PORT", "21118"),
        "approve-mode": "password", "verification-method": "use-permanent-password", "enable-audio": "N",
        "custom-rendezvous-server": os.environ.get("RUSTDESK_ID_SERVER", ""),
        "relay-server": os.environ.get("RUSTDESK_RELAY_SERVER", ""),
        "api-server": os.environ.get("RUSTDESK_API_SERVER", ""), "key": os.environ.get("RUSTDESK_SERVER_KEY", ""),
    })
    store(CONFIG2_FILE, config2)
    validate_password(password)

def rustdesk_id():
    value = subprocess.check_output(["gosu", "rustdesk", "env", "HOME=/home/rustdesk", "rustdesk", "--get-id"], text=True, stderr=subprocess.DEVNULL).strip()
    if not value:
        raise RuntimeError("RustDesk ID is not ready")
    return value

def totp(secret, timestamp):
    digest = hmac.new(secret, struct.pack(">Q", timestamp // 30), hashlib.sha1).digest()
    offset = digest[-1] & 15
    number = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7fffffff
    return f"{number % 1_000_000:06d}"

def generate():
    device_id, secret = rustdesk_id(), os.urandom(20)
    base32 = base64.b32encode(secret).decode().rstrip("=")
    label = quote(f"RustDesk Connection:{device_id}", safe="")
    url = f"otpauth://totp/{label}?secret={base32}&issuer={quote('RustDesk Connection', safe='')}&algorithm=SHA1&digits=6&period=30"
    PENDING_FILE.write_text(json.dumps({"name": device_id, "secret": base64.b64encode(secret).decode(), "created_at": int(time.time() * 1000)}))
    PENDING_FILE.chmod(0o600)
    print("\nScan this QR code with an authenticator app:\n")
    subprocess.run(["qrencode", "-t", "ANSIUTF8", url], check=True)
    print(f"\nManual TOTP secret: {base32}")

def restart_after_atomic_update(update):
    pid = int(SERVER_PID_FILE.read_text().strip())
    READY_FILE.unlink(missing_ok=True)
    os.killpg(pid, signal.SIGSTOP)
    try:
        update()
        RESTART_MARKER.touch(mode=0o600, exist_ok=True)
        os.killpg(pid, signal.SIGKILL)
    except Exception:
        os.killpg(pid, signal.SIGCONT)
        raise

def verify(code):
    if not (len(code) == 6 and code.isdigit()):
        raise RuntimeError("2FA code must contain exactly 6 digits")
    if not PENDING_FILE.is_file():
        raise RuntimeError("No pending 2FA enrollment; generate it first")
    pending = json.loads(PENDING_FILE.read_text())
    secret, now = base64.b64decode(pending["secret"], validate=True), int(time.time())
    if code not in {totp(secret, now + offset * 30) for offset in (-1, 0, 1)}:
        raise RuntimeError("The 2FA code is incorrect or expired")
    stored = encode_secret(secret)
    value = {"name": pending["name"], "secret": list(stored), "digits": 6, "created_at": pending["created_at"]}
    def update():
        config2 = load(CONFIG2_FILE)
        config2.setdefault("options", {})["2fa"] = json.dumps(value, separators=(",", ":"))
        store(CONFIG2_FILE, config2)
        if decode_secret(bytes(value["secret"])) != secret:
            raise RuntimeError("stored 2FA secret failed its RustDesk-compatible round trip")
    restart_after_atomic_update(update)
    PENDING_FILE.unlink(missing_ok=True)
    print("RustDesk two-factor authentication enabled.")

def disable():
    PENDING_FILE.unlink(missing_ok=True)
    if not load(CONFIG2_FILE).get("options", {}).get("2fa"):
        print("RustDesk two-factor authentication is already disabled.")
        return
    def update():
        config2 = load(CONFIG2_FILE)
        config2.setdefault("options", {})["2fa"] = ""
        store(CONFIG2_FILE, config2)
    restart_after_atomic_update(update)
    print("RustDesk two-factor authentication disabled.")

def status():
    print("enabled" if load(CONFIG2_FILE).get("options", {}).get("2fa") else "disabled")

def ready():
    validate_password()
    with socket.create_connection(("127.0.0.1", int(os.environ.get("RUSTDESK_PORT", "21118"))), timeout=2):
        pass
    print(rustdesk_id())

def main():
    args = sys.argv[1:]
    if args == ["provision"]: provision()
    elif args == ["generate"]: generate()
    elif args == ["verify"]: verify(sys.stdin.readline().strip())
    elif args == ["disable"]: disable()
    elif args == ["status"]: status()
    elif args == ["ready"]: ready()
    elif args == ["validate-password"]: validate_password()
    else: raise RuntimeError("usage: rustdesk-2fa provision|generate|verify|disable|status|ready|validate-password")

if __name__ == "__main__":
    try: main()
    except Exception as exc:
        print(f"rustdesk-2fa: {exc}", file=sys.stderr)
        sys.exit(1)
