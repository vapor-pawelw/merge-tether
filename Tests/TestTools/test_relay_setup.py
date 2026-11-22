import errno
import os
from pathlib import Path
import pty
import select
import stat
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/setup-relay.sh"
ORIGIN = " HTTPS://Relay.Example.Test:443/ "
TOKEN = "a" * 43


class RelaySetupTests(unittest.TestCase):
    def setUp(self):
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        self.home = Path(home.name)
        self.relay = self.home / "Library/Application Support/MergeTether/remote-relay"
        self.build_origin = self.relay / "build-origin.txt"
        self.pairing = self.relay / "pairing.txt"

    def run_setup(self, origin=ORIGIN, token=TOKEN):
        master, slave = pty.openpty()
        try:
            with subprocess.Popen(
                ["/bin/bash", "-x", str(SCRIPT)], cwd=self.home, stdin=slave,
                stdout=slave, stderr=slave,
                env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
            ) as process:
                os.close(slave)
                slave = None
                try:
                    output = b""
                    prompts = [(b"Relay HTTPS URL: ", origin), (b"Relay access token: ", token)]
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if not select.select([master], [], [], 0.1)[0]:
                            continue
                        try:
                            chunk = os.read(master, 4096)
                        except OSError as error:
                            if error.errno != errno.EIO:
                                raise
                            break
                        if not chunk:
                            break
                        output += chunk
                        if prompts and prompts[0][0] in output:
                            _, answer = prompts.pop(0)
                            os.write(master, (answer + "\n").encode())
                    return process.wait(timeout=2), output.decode()
                finally:
                    if process.poll() is None:
                        process.kill()
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_configures_both_app_builds_and_private_mac_prefill(self):
        status, output = self.run_setup()
        self.assertEqual(status, 0, output)
        self.assertNotIn(TOKEN, output)
        self.assertEqual(self.build_origin.read_text(), ORIGIN + "\n")
        self.assertEqual(self.pairing.read_text(), ORIGIN + "\n" + TOKEN + "\n")
        self.assertEqual(stat.S_IMODE(self.pairing.stat().st_mode), 0o600)
        self.assertEqual(set(self.home.iterdir()), {self.home / "Library"})
        self.assertEqual(set(self.relay.iterdir()), {self.build_origin, self.pairing})

    def test_invalid_input_keeps_existing_configuration(self):
        status, output = self.run_setup()
        self.assertEqual(status, 0, output)
        for origin, token in [(" ", TOKEN), ("https://new.example.test", "invalid-token")]:
            with self.subTest(origin=origin):
                status, output = self.run_setup(origin, token)
                self.assertNotEqual(status, 0, output)
                self.assertNotIn(token, output)
                self.assertEqual(self.build_origin.read_text(), ORIGIN + "\n")
                self.assertEqual(self.pairing.read_text(), ORIGIN + "\n" + TOKEN + "\n")
