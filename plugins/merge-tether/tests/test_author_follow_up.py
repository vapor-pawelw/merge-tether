import base64
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from author_follow_up import AuthorFollowUpVerifier


class AuthorFollowUpTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.head = "a" * 40
        self.content = b"assert OPERATION_NOT_ALLOWED;\n"
        self.run = {"version": 1, "kind": "author_follow_up", "runID": str(uuid.uuid4()), "host": "gitlab.example.org",
                    "projectID": 1, "iid": 2, "username": "me", "pushAllowed": True}
        self.run_path = self.root / "follow-up-runs/gitlab.example.org/1-2-me.json"
        self.run_path.parent.mkdir(parents=True)
        self.save_run()
        self.mr = {"project_id": 1, "iid": 2, "state": "opened", "author": {"id": 3},
                   "sha": self.head, "source_project_id": 4, "source_branch": "fix/test"}
        self.drafts = [{"id": 12, "author_id": 3, "note": "Local-only completion"}]
        self.evidence = json.dumps([{"path": "Tests/A.swift", "sha256": hashlib.sha256(self.content).hexdigest()}])
        self.verifier = AuthorFollowUpVerifier(self.root, self.read)

    def save_run(self):
        self.run_path.write_text(json.dumps(self.run))

    def read(self, host, endpoint):
        self.assertEqual(host, "gitlab.example.org")
        if endpoint == "/user":
            return {"id": 3, "username": "me"}
        if endpoint == "/projects/1/merge_requests/2":
            return self.mr
        if endpoint == "/projects/4/repository/branches/fix%2Ftest":
            return {"commit": {"id": self.mr["sha"]}}
        if endpoint.startswith("/projects/4/repository/files/Tests%2FA.swift?ref="):
            return {"file_path": "Tests/A.swift", "encoding": "base64", "content": base64.b64encode(self.content).decode()}
        if endpoint == "/projects/1/merge_requests/2/draft_notes?per_page=100&page=1":
            return self.drafts
        self.fail(endpoint)

    def verify(self):
        return self.verifier.verify("gitlab.example.org", "1", "2", self.run["runID"], self.head, self.evidence)

    def test_push_off_cannot_verify_or_seal_a_run(self):
        self.run["pushAllowed"] = False
        self.save_run()
        with self.assertRaises(ValueError):
            self.verify()
        self.assertFalse((self.root / "follow-up-verifications").exists())

    def test_local_commit_absent_from_remote_or_wrong_file_contents_cannot_verify(self):
        self.mr["sha"] = "b" * 40
        with self.assertRaises(ValueError):
            self.verify()
        self.mr["sha"] = self.head
        self.content = b"old code without the claimed assertion"
        with self.assertRaises(ValueError):
            self.verify()

    def test_remote_proof_precedes_fresh_drafts_and_binds_exact_bodies(self):
        proof = self.verify()
        with self.assertRaises(ValueError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[12]")
        self.drafts.append({"id": 13, "author_id": 3, "note": "Verified fix is on the remote branch"})
        receipt = self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")
        self.assertTrue(receipt["sealed"])
        self.assertEqual(receipt["runID"], self.run["runID"])
        self.assertEqual(receipt["drafts"], [{"id": 13, "bodySHA256": hashlib.sha256(self.drafts[-1]["note"].encode()).hexdigest()}])
        self.assertEqual(receipt["sourceProjectID"], 4)
        self.assertEqual(receipt["headSHA"], self.head)
        self.assertTrue((self.root / "follow-up-verifications/gitlab.example.org/1-2-me.json").exists())

    def test_current_head_run_and_permission_are_checked_again_at_sealing(self):
        for change in ("head", "run", "permission"):
            with self.subTest(change=change):
                proof = self.verify()
                self.drafts.append({"id": 13, "author_id": 3, "note": "New reply"})
                if change == "head": self.mr["sha"] = "b" * 40
                if change == "run": self.run["runID"] = str(uuid.uuid4())
                if change == "permission": self.run["pushAllowed"] = False
                self.save_run()
                with self.assertRaises(ValueError):
                    self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")
                self.mr["sha"] = self.head
                self.run["pushAllowed"] = True
                self.save_run()
                self.drafts = self.drafts[:1]

    def test_token_is_one_use_and_reverification_keeps_same_run_sealed_drafts(self):
        proof = self.verify()
        self.drafts.append({"id": 13, "author_id": 3, "note": "A verified remote fix"})
        self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")
        with self.assertRaises(OSError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")
        # Same run, later remote verification: unchanged managed replies can be retained.
        proof = self.verify()
        self.drafts.append({"id": 14, "author_id": 3, "note": "Another verified correction"})
        receipt = self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13,14]")
        self.assertEqual([d["id"] for d in receipt["drafts"]], [13, 14])

    def test_non_author_or_legacy_run_kind_cannot_authorize(self):
        self.run.pop("kind")
        self.save_run()
        with self.assertRaises(ValueError): self.verify()

    def test_rejects_empty_evidence_and_other_author_mrs(self):
        with self.assertRaises(ValueError):
            self.verifier.verify("gitlab.example.org", "1", "2", self.run["runID"], self.head, "[]")
        self.mr["author"]["id"] = 9
        with self.assertRaises(ValueError): self.verify()
