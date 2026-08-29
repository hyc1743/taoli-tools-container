import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "rustdesk-2fa.py"


class RustDeskConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        config = root / "config"
        config.mkdir()
        (config / "machine-id").write_text("0123456789abcdef0123456789abcdef\n")
        password_file = root / "password"
        password_file.write_text("correct horse battery staple")
        os.environ["RUSTDESK_CONFIG_DIR"] = str(config)
        os.environ["RUSTDESK_PASSWORD_FILE"] = str(password_file)
        spec = importlib.util.spec_from_file_location("rustdesk_config", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def tearDown(self):
        self.tmp.cleanup()

    def test_v1_random_nonce_round_trip(self):
        first = self.module.encrypt(b"secret")
        second = self.module.encrypt(b"secret")
        self.assertEqual(first[0], 1)
        self.assertNotEqual(first, second)
        self.assertEqual(self.module.decrypt(first), b"secret")

    def test_provisioned_password_matches_rustdesk_149_layout(self):
        self.module.provision()
        config = self.module.load(self.module.CONFIG_FILE)
        self.assertTrue(config["password"].startswith("01"))
        inner = self.module.decrypt(base64.b64decode(config["password"][2:]))
        self.assertTrue(inner.startswith(b"00"))
        expected = hashlib.sha256(b"correct horse battery staple" + config["salt"].encode()).digest()
        self.assertEqual(base64.b64decode(inner[2:]), expected)
        options = self.module.load(self.module.CONFIG2_FILE)["options"]
        self.assertEqual(options["direct-server"], "Y")
        self.assertEqual(options["direct-access-port"], "21118")

    def test_totp_storage_and_rfc_vector(self):
        secret = b"12345678901234567890"
        self.assertEqual(self.module.totp(secret, 59), "287082")
        stored = self.module.encode_secret(secret)
        self.assertEqual(self.module.decode_secret(stored), secret)
        value = json.loads(json.dumps({"secret": list(stored)}))
        self.assertEqual(self.module.decode_secret(bytes(value["secret"])), secret)


if __name__ == "__main__":
    unittest.main()
