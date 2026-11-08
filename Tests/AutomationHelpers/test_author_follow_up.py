import base64
import contextlib
import io
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
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
        self.discussions = []
        self.evidence = json.dumps({"discussionFingerprint": hashlib.sha256(b"").hexdigest(),
                                   "files": [{"path": "Tests/A.swift", "sha256": hashlib.sha256(self.content).hexdigest()}]})
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
        if endpoint == "/projects/1/merge_requests/2/discussions?per_page=100&page=1":
            return self.discussions
        self.fail(endpoint)

    def verify(self):
        return self.verifier.verify("gitlab.example.org", "1", "2", self.run["runID"], self.head, self.evidence)

    def test_push_off_cannot_verify_or_seal_a_run(self):
        self.run["pushAllowed"] = False
        self.save_run()
        with self.assertRaises(ValueError):
            self.verify()
        self.assertFalse((self.root / "follow-up-verifications").exists())

    def repair_scope(self, intended_body="Corrected wording backed by the current source"):
        self.run["repairDrafts"] = [{"id": 12, "bodySHA256": hashlib.sha256(self.drafts[0]["note"].encode()).hexdigest()}]
        self.save_run()
        evidence = json.loads(self.evidence)
        if intended_body is not None:
            evidence["repairIntent"] = {"draftID": 12, "bodySHA256": hashlib.sha256(intended_body.encode()).hexdigest()}
        self.evidence = json.dumps(evidence)

    def test_repair_can_refresh_only_the_exact_owned_reply_after_remote_proof(self):
        self.repair_scope()
        proof = self.verify()
        self.drafts[0]["note"] = "Corrected wording backed by the current source"
        receipt = self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[12]")
        self.assertEqual([d["id"] for d in receipt["drafts"]], [12])

    def test_repair_seal_cannot_adopt_an_unrelated_new_or_user_created_reply(self):
        self.repair_scope()
        proof = self.verify()
        self.drafts.append({"id": 13, "author_id": 3, "note": "Unrelated new reply"})
        with self.assertRaises(ValueError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")
        self.assertFalse((self.root / "follow-up-verifications").exists())

    def test_repair_seal_rejects_extra_ids_even_alongside_the_allowed_changed_reply(self):
        self.repair_scope()
        proof = self.verify()
        self.drafts[0]["note"] = "Corrected owned reply"
        self.drafts.append({"id": 13, "author_id": 3, "note": "Unrelated new reply"})
        with self.assertRaises(ValueError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[12,13]")

    def test_user_edit_before_repair_verification_revokes_the_exact_body_permission(self):
        self.repair_scope()
        self.drafts[0]["note"] = "A user edited this reply"
        with self.assertRaises(ValueError):
            self.verify()

    def test_user_edit_after_verification_cannot_be_adopted_by_a_repair_seal(self):
        self.repair_scope()
        proof = self.verify()
        self.drafts[0]["note"] = "An unexpected user edit after remote verification"
        # Changing later input cannot replace the correction intent already persisted before PUT.
        evidence = json.loads(self.evidence)
        evidence["repairIntent"]["bodySHA256"] = hashlib.sha256(self.drafts[0]["note"].encode()).hexdigest()
        self.evidence = json.dumps(evidence)
        with self.assertRaises(ValueError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[12]")
        self.assertFalse((self.root / "follow-up-verifications").exists())

    def test_code_only_repair_can_verify_but_cannot_seal_an_unplanned_reply_edit(self):
        self.repair_scope(intended_body=None)
        proof = self.verify()
        self.drafts[0]["note"] = "Unplanned wording change"
        with self.assertRaises(ValueError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[12]")

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
        self.assertEqual(receipt.get("discussionFingerprint"), hashlib.sha256(b"").hexdigest())
        self.assertTrue((self.root / "follow-up-verifications/gitlab.example.org/1-2-me.json").exists())

    def test_new_comment_between_verification_and_sealing_requires_recheck(self):
        proof = self.verify()
        self.drafts.append({"id": 13, "author_id": 3, "note": "Verified fix"})
        self.discussions = [{"notes": [{"id": 40, "author": {"id": 8}, "body": "New concern", "system": False}]}]
        with self.assertRaises(ValueError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")

    def test_comment_arriving_during_implementation_requires_assessment_before_verification(self):
        self.discussions = [{"notes": [{"id": 40, "author": {"id": 8}, "body": "New concern", "system": False}]}]
        with self.assertRaises(ValueError):
            self.verify()

    def test_rechecking_after_failed_seal_requires_explicitly_refreshed_drafts(self):
        proof = self.verify()
        self.drafts.append({"id": 13, "author_id": 3, "note": "Original reply"})
        self.discussions = [{"notes": [{"id": 40, "author": {"id": 8}, "body": "New concern", "system": False}]}]
        with self.assertRaises(ValueError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")
        evidence = json.loads(self.evidence)
        evidence["discussionFingerprint"] = self.verifier.discussion_fingerprint("gitlab.example.org", "1", "2")
        self.evidence = json.dumps(evidence)
        proof = self.verify()
        self.drafts[-1]["note"] = "Reply refreshed after assessing the new concern"
        self.assertTrue(self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")["sealed"])

    def test_discussion_evidence_ignores_resolution_but_detects_edited_text(self):
        self.discussions = [{"notes": [{"id": 40, "author": {"id": 8}, "body": "Please fix this", "system": False,
                                       "resolved": False}]}]
        before = self.verifier.discussion_fingerprint("gitlab.example.org", "1", "2")
        self.discussions[0]["notes"][0]["resolved"] = True
        self.discussions[0]["notes"].append({"id": 41, "system": True, "body": "Resolved"})
        self.assertEqual(before, self.verifier.discussion_fingerprint("gitlab.example.org", "1", "2"))
        self.discussions[0]["notes"][0]["body"] = "Edited concern"
        self.assertNotEqual(before, self.verifier.discussion_fingerprint("gitlab.example.org", "1", "2"))

    def test_fingerprint_matches_the_swift_unicode_fixture(self):
        self.discussions = [{"notes": [{"id": 40, "author": {"id": 8}, "body": "Zażółć gęślą jaźń 🧵\nCheck this", "system": False}]}]
        self.assertEqual(self.verifier.discussion_fingerprint("gitlab.example.org", "1", "2"),
                         "820aa6b58b9b1848a9f2c75f526a2057b5cf98f1f7b52acae2bbead69a588a4a")

    def test_resolution_only_change_does_not_prevent_sealing(self):
        self.discussions = [{"notes": [{"id": 40, "author": {"id": 8}, "body": "Concern", "system": False, "resolved": False}]}]
        evidence = json.loads(self.evidence)
        evidence["discussionFingerprint"] = self.verifier.status("gitlab.example.org", "1", "2", self.run["runID"])["discussionFingerprint"]
        self.evidence = json.dumps(evidence)
        proof = self.verify()
        self.drafts.append({"id": 13, "author_id": 3, "note": "Verified reply"})
        self.discussions[0]["notes"][0]["resolved"] = True
        self.assertTrue(self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")["sealed"])

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

    def test_sealing_a_successor_preserves_each_original_run_receipt(self):
        proof = self.verify()
        self.drafts.append({"id": 13, "author_id": 3, "note": "First verified reply"})
        first = self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")
        self.run["runID"] = str(uuid.uuid4())
        self.save_run()
        proof = self.verify()
        # An unchanged draft from another run still cannot be silently adopted.
        with self.assertRaises(ValueError):
            self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[13]")
        self.drafts.append({"id": 14, "author_id": 3, "note": "Second verified reply"})
        second = self.verifier.seal("gitlab.example.org", "1", "2", proof["verificationID"], "[14]")
        archive = self.root / "follow-up-verifications-archive/gitlab.example.org/1-2-me"
        self.assertTrue(archive.is_dir())
        records = [json.loads(path.read_text()) for path in archive.glob("*.json")]
        self.assertCountEqual(records, [first, second])
        latest = json.loads((self.root / "follow-up-verifications/gitlab.example.org/1-2-me.json").read_text())
        self.assertEqual(latest, second)

    def test_non_author_or_legacy_run_kind_cannot_authorize(self):
        self.run.pop("kind")
        self.save_run()
        with self.assertRaises(ValueError): self.verify()

    def test_rejects_empty_evidence_and_other_author_mrs(self):
        with self.assertRaises(ValueError):
            self.verifier.verify("gitlab.example.org", "1", "2", self.run["runID"], self.head, "[]")
        self.mr["author"]["id"] = 9
        with self.assertRaises(ValueError): self.verify()

    def test_standalone_status_command_uses_bundled_evidence_module(self):
        from author_follow_up import main
        output = io.StringIO()
        arguments = ["author_follow_up.py", "status", "--host", "gitlab.example.org",
                     "--project-id", "1", "--iid", "2", "--run-id", self.run["runID"]]
        with patch("sys.argv", arguments), patch("evidence.ROOT", self.root), \
                patch("evidence.gitlab_get", side_effect=self.read), contextlib.redirect_stdout(output):
            main()
        result = json.loads(output.getvalue())
        self.assertEqual(result["runID"], self.run["runID"])
        self.assertEqual(result["headSHA"], self.head)
        self.assertTrue(result["pushAllowed"])
