import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from evidence import ReviewEvidenceRecorder, gitlab_get


class ReviewEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.head = "a" * 40
        self.mr = {"project_id": 1, "iid": 2, "state": "opened", "sha": self.head}
        self.discussions = [{"notes": [{"id": 11, "author": {"id": 4}, "system": False,
                                        "body": "Check the assertion", "resolved": False}]}]
        self.recorder = ReviewEvidenceRecorder(self.root, self.read)

    def read(self, host, endpoint):
        self.assertEqual(host, "gitlab.example.org")
        if endpoint == "/projects/1/merge_requests/2":
            return self.mr
        if endpoint == "/projects/1/merge_requests/2/discussions?per_page=100&page=1":
            return self.discussions
        self.fail(endpoint)

    def record(self):
        return self.recorder.record_verdict("gitlab.example.org", "1", "2", self.head, "no_objections")

    def test_records_exact_head_and_current_discussion_content_without_plugin(self):
        expected = hashlib.sha256(("11:4:" + hashlib.sha256(b"Check the assertion").hexdigest() + "\n").encode()).hexdigest()
        result = self.record()
        self.assertEqual(result.get("discussionFingerprint"), expected)
        receipt = json.loads((self.root / "verdicts/gitlab.example.org/1-2.json").read_text())
        self.assertEqual(receipt["headSHA"], self.head)
        self.assertEqual(receipt["discussionFingerprint"], expected)
        self.assertEqual(receipt["verdict"], "no_objections")

    def test_rejects_changed_head_closed_request_and_wrong_identity(self):
        for field, value in (("sha", "b" * 40), ("state", "closed"), ("project_id", 3), ("iid", 4)):
            with self.subTest(field=field):
                old = self.mr[field]
                self.mr[field] = value
                with self.assertRaises(ValueError): self.record()
                self.mr[field] = old
        self.assertFalse((self.root / "verdicts").exists())

    def test_rechecks_head_after_reading_discussions(self):
        original = self.read
        def changing(host, endpoint):
            value = original(host, endpoint)
            if "discussions" in endpoint: self.mr["sha"] = "b" * 40
            return value
        self.recorder = ReviewEvidenceRecorder(self.root, changing)
        with self.assertRaises(ValueError): self.record()
        self.assertFalse((self.root / "verdicts").exists())

    def test_refuses_incomplete_comments_and_invalid_record_arguments(self):
        self.discussions[0]["notes"][0].pop("body")
        with self.assertRaises(ValueError): self.record()
        for host, project, iid, head, verdict in (
            ("../host", "1", "2", self.head, "no_objections"),
            ("gitlab.example.org", "0", "2", self.head, "no_objections"),
            ("gitlab.example.org", "1", "2", "short", "no_objections"),
            ("gitlab.example.org", "1", "2", self.head, "approve"),
        ):
            with self.assertRaises(ValueError):
                self.recorder.record_verdict(host, project, iid, head, verdict)
        self.assertFalse((self.root / "verdicts").exists())

    def test_getter_uses_only_get_and_explicit_home_and_path(self):
        with patch("evidence.shutil.which", return_value="/usr/local/bin/glab"), \
                patch("evidence.subprocess.run") as run:
            run.return_value.stdout = b'{"id":4}'
            self.assertEqual(gitlab_get("gitlab.example.org", "/user"), {"id": 4})
            command = run.call_args.args[0]
            self.assertEqual(command[-2:], ["--method", "GET"])
            self.assertEqual(command[0], "/usr/local/bin/glab")
            environment = run.call_args.kwargs["env"]
            self.assertIn("HOME", environment)
            self.assertIn("PATH", environment)
            self.assertNotIn("ANTHROPIC_API_KEY", environment)

    def test_getter_preserves_sandbox_proxy_and_certificates_without_forwarding_secrets(self):
        with patch("evidence.shutil.which", return_value="/usr/local/bin/glab"), \
                patch.dict("evidence.os.environ", {"HTTPS_PROXY": "http://127.0.0.1:1234", "http_proxy": "http://127.0.0.1:1234", "SSL_CERT_FILE": "/tmp/proxy.pem", "ANTHROPIC_API_KEY": "must-not-forward"}), \
                patch("evidence.subprocess.run") as run:
            run.return_value.stdout = b'{"id":4}'
            self.assertEqual(gitlab_get("gitlab.example.org", "/user"), {"id": 4})
            env = run.call_args.kwargs["env"]
            self.assertEqual(env.get("HTTPS_PROXY"), "http://127.0.0.1:1234")
            self.assertEqual(env.get("http_proxy"), "http://127.0.0.1:1234")
            self.assertEqual(env.get("SSL_CERT_FILE"), "/tmp/proxy.pem")
            self.assertNotIn("ANTHROPIC_API_KEY", env)


if __name__ == "__main__": unittest.main()
