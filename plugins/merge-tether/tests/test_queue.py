import base64
import json
import pathlib
import tempfile
import unittest
import uuid

from relay import Queue, handle


class QueueTest(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = pathlib.Path(folder.name)
        for name in ("jobs", "claims", "receipts"):
            (self.root / name).mkdir()
        self.queue = Queue(self.root)

    def test_subprocess_transport_uses_the_same_durable_queue(self):
        import subprocess
        import sys
        home = self.root / "home"
        canonical = home / "Library/Application Support/com.vaporpw.GitLabTodos/Codex Desktop Relay"
        for name in ("jobs", "claims", "receipts"):
            (canonical / name).mkdir(parents=True)
        job_id = self.job(reuse=False)
        (canonical / "jobs" / (job_id + ".json")).write_bytes((self.root / "jobs" / (job_id + ".json")).read_bytes())
        requests = [
            {"jsonrpc":"2.0", "id":1, "method":"tools/list"},
            {"jsonrpc":"2.0", "id":2, "method":"tools/call", "params":{"name":"queue_status","arguments":{}}},
            {"jsonrpc":"2.0", "id":3, "method":"tools/call", "params":{"name":"claim_next","arguments":{}}},
        ]
        relay = pathlib.Path(__file__).resolve().parents[1] / "relay.py"
        result = subprocess.run([sys.executable, "-B", str(relay)], input="".join(json.dumps(r)+"\n" for r in requests),
                                capture_output=True, text=True, timeout=5, cwd=home,
                                env={"HOME":str(home), "PATH":"/usr/bin:/bin"}, check=True)
        replies = [json.loads(line)["result"] for line in result.stdout.splitlines()]
        self.assertIn("claim_next", [tool["name"] for tool in replies[0]["tools"]])
        self.assertEqual(json.loads(replies[1]["content"][0]["text"])["pending"], 1)
        self.assertFalse(replies[2]["isError"])
        self.assertTrue((canonical / "claims" / job_id / "job.json").exists())
        self.assertTrue((canonical / "jobs" / (job_id + ".json")).exists())

    def test_review_verdict_is_bound_to_discussion_content(self):
        import hashlib
        from unittest.mock import patch
        head = "a" * 40
        discussion = [{"notes": [{"id": 71, "author": {"id": 9}, "system": False, "body": "Reply"}]}]
        def read(host, endpoint):
            self.assertEqual(host, "gitlab.example.org")
            if "/discussions?" in endpoint:
                return discussion
            return {"sha": head, "state": "opened"}
        with patch("relay.gitlab_get", side_effect=read):
            self.queue.record_verdict("gitlab.example.org", "1", "2", head, "no_objections")
        record = json.loads((self.root / "verdicts/gitlab.example.org/1-2.json").read_text())
        body_hash = hashlib.sha256(b"Reply").hexdigest()
        expected = hashlib.sha256(f"71:9:{body_hash}\n".encode()).hexdigest()
        self.assertEqual(record.get("discussionFingerprint"), expected)

    def test_ai_assessment_binds_exact_comment_and_rejects_weak_confidence(self):
        import hashlib
        self.queue.record_ai_assessment("gitlab.example.org", "1", "2", "42", hashlib.sha256(b"AI text").hexdigest(), "very_high", "Explicit AI disclosure")
        path = self.root / "ai-assessments/gitlab.example.org/1-2-42.json"
        record = json.loads(path.read_text())
        self.assertEqual(record["bodySHA256"], hashlib.sha256(b"AI text").hexdigest())
        self.assertEqual(record["noteID"], 42)
        with self.assertRaises(ValueError):
            self.queue.record_ai_assessment("../bad", "1", "2", "42", "text", "very_high", "evidence")
        with self.assertRaises(ValueError):
            self.queue.record_ai_assessment("gitlab.example.org", "1", "2", "42", "text", "low", "evidence")
        with self.assertRaises(ValueError):
            self.queue.record_ai_assessment("gitlab.example.org", "1", "2", "42", hashlib.sha256(b"text").hexdigest(), "very_high", "")

    def test_follow_up_tools_dispatch_and_malformed_evidence_does_not_stop_queue(self):
        from unittest.mock import patch
        args = {"host": "gitlab.example.org", "projectID": "1", "iid": "2", "runID": str(uuid.uuid4()), "headSHA": "a"*40, "filesJSON": "[]"}
        request = {"method": "tools/call", "params": {"name": "verify_author_follow_up", "arguments": args}}
        with patch("author_follow_up.AuthorFollowUpVerifier.verify", return_value={"verified": True}) as verify:
            result = handle(request, self.queue)
            self.assertFalse(result["isError"])
            self.assertTrue(verify.called)
        with patch("author_follow_up.AuthorFollowUpVerifier.verify", side_effect=KeyError("content")):
            self.assertTrue(handle(request, self.queue)["isError"])
        self.assertFalse(handle({"method":"tools/call", "params":{"name":"queue_status"}}, self.queue)["isError"])

    def job(self, reuse=True, **fields):
        job_id = str(uuid.uuid4())
        (self.root / "jobs" / (job_id + ".json")).write_text(json.dumps({
            "version": 1, "id": job_id.upper(), "title": "[MT] Review",
            "prompt": "Prepare a private review.", "conversationKey": "repo-42", "reuse": reuse, **fields,
        }))
        return job_id

    def test_claim_preserves_review_model_only_when_set(self):
        self.job(reuse=False, model="gpt-6.1-sol", thinking="high")
        job = self.queue.claim_next()
        self.assertEqual((job.get("model"), job.get("thinking")), ("gpt-6.1-sol", "high"))

    def test_delivery_bootstrap_preserves_complete_instructions_after_job_withdrawal(self):
        import hashlib
        prompt = "https://gitlab.example.org/g/p/-/merge_requests/42\n\n" + "Pełne instrukcje — żadnego skracania.\n" * 500
        job_id = self.job(prompt=prompt)
        job = self.queue.claim_next()
        bootstrap = job.get("deliveryPrompt", "")
        self.assertTrue(bootstrap.startswith(prompt.splitlines()[0]))
        self.assertLess(len(bootstrap), 1500)
        digest = hashlib.sha256(prompt.encode()).hexdigest()
        self.assertIn(digest, bootstrap)
        instructions = self.root / "claims" / job_id / "instructions.json"
        self.assertIn(str(instructions), bootstrap)
        record = json.loads(instructions.read_text())
        self.assertEqual(record["prompt"], prompt)
        self.assertEqual(record["promptSHA256"], digest)
        self.assertEqual(record["title"], job["title"])
        (self.root / "jobs" / (job_id + ".json")).unlink()
        self.queue.record(job_id, str(uuid.uuid4()))
        self.assertEqual(json.loads(instructions.read_text())["prompt"], prompt)

    def test_merged_update_needs_capability_and_confirmed_chat(self):
        thread = str(uuid.uuid4())
        path = self.root / "jobs" / (thread + ".json")
        path.write_text(json.dumps({
            "version": 1, "id": thread, "operation": "mark_merged",
            "threadID": thread, "conversationKey": "merged:" + thread,
        }))
        self.assertIsNone(self.queue.claim_next(allow_merged=True))
        key = base64.b64encode(json.dumps({"assistant": "codex", "work": {"iid": 42}}).encode()).decode()
        delivery = self.job(reuse=False, conversationKey=key)
        self.assertEqual(self.queue.claim_next()["id"], delivery)
        self.queue.record(delivery, thread)
        self.assertIsNone(self.queue.claim_next())
        self.assertEqual(self.queue.claim_next(allow_merged=True), {
            "id": thread, "threadID": thread, "operation": "mark_merged",
        })
        with self.assertRaises(ValueError):
            self.queue.record(thread, str(uuid.uuid4()))
        self.queue.record(thread, thread)
        self.assertIsNone(self.queue.claim_next(allow_merged=True))

    def test_work_item_proposal_requires_a_compatible_listener(self):
        thread = str(uuid.uuid4())
        key = base64.b64encode(json.dumps({"assistant": "codex", "work": {"iid": 42}}).encode()).decode()
        delivery = self.job(reuse=False, conversationKey=key)
        self.assertEqual(self.queue.claim_next()["id"], delivery)
        self.queue.record(delivery, thread)
        path = self.root / "jobs" / (thread + ".json")
        prompt = "Propose a work item update without modifying GitLab."
        path.write_text(json.dumps({
            "version": 1, "id": thread, "operation": "mark_merged_with_work_item",
            "threadID": thread, "conversationKey": "merged:" + thread, "followUpPrompt": prompt,
        }))
        self.assertIsNone(self.queue.claim_next(allow_merged=True))
        self.assertEqual(self.queue.claim_next(allow_merged=True, allow_work_item=True), {
            "id": thread, "threadID": thread, "operation": "mark_merged_with_work_item", "followUpPrompt": prompt,
        })
        self.queue.record(thread, thread)
        self.assertIsNone(self.queue.claim_next(allow_merged=True, allow_work_item=True))

    def test_stack_title_can_change_and_then_clear_for_the_same_chat(self):
        thread = str(uuid.uuid4())
        key = base64.b64encode(json.dumps({"assistant": "codex", "work": {"iid": 42}}).encode()).decode()
        links = self.root / "linked-chats"
        links.mkdir()
        (links / (thread + ".json")).write_text(json.dumps({
            "version": 1, "threadID": thread, "conversationKey": key,
        }))
        for position in ("2/3", "1/2", None):
            job = str(uuid.uuid4())
            payload = {"version": 1, "id": job, "operation": "set_stack_position",
                       "threadID": thread, "conversationKey": "stack:" + thread, "iid": 42, "position": position}
            (self.root / "jobs" / (job + ".json")).write_text(json.dumps(payload))
            self.assertIsNone(self.queue.claim_next())
            self.assertEqual(self.queue.claim_next(allow_merged=True), {
                "id": job, "threadID": thread, "operation": "set_stack_position", "iid": 42, "position": position,
            })
            self.queue.record(job, thread)

    def test_read_only_mr_lookup_matches_dispatched_account_and_mr(self):
        from unittest.mock import patch
        key = base64.b64encode(json.dumps({
            "assistant": "codex", "access": "gitLabRead", "username": "me",
            "work": {"host": "gitlab.example.org", "projectID": 12, "iid": 42},
        }).encode()).decode()
        self.job(conversationKey=key)
        self.queue.claim_next()
        args = {"host": "gitlab.example.org", "projectID": "12", "iid": "42", "resource": "diffs"}
        def read(**changes):
            return handle({"method": "tools/call", "params": {
                "name": "read_merge_request", "arguments": {**args, **changes},
            }}, self.queue)
        with patch("relay.gitlab_get", side_effect=[{"username": "me"}, [{"diff": "example"}]]) as get:
            self.assertTrue(read(iid="43")["isError"])
            self.assertTrue(read(resource="../merge")["isError"])
            self.assertTrue(read(method="POST")["isError"])
            self.assertFalse(read()["isError"])
            self.assertEqual([call.args for call in get.call_args_list], [
                ("gitlab.example.org", "/user"),
                ("gitlab.example.org", "/projects/12/merge_requests/42/diffs?per_page=20&page=1"),
            ])

    def test_source_hashes_preserve_exact_whitespace_without_model_copying(self):
        from unittest.mock import patch
        import hashlib
        key = base64.b64encode(json.dumps({
            "assistant": "codex", "access": "gitLabRead", "username": "me",
            "work": {"host": "gitlab.example.org", "projectID": 12, "iid": 42},
        }).encode()).decode()
        self.job(conversationKey=key)
        self.queue.claim_next()
        body = "AI finding  \r\n\n"
        with patch("relay.gitlab_get", side_effect=[{"username": "me"}, [{"id": "abc", "notes": [{"id": 9, "body": body}, {"id": 10, "body": "\ud800"}]}]]):
            result = self.queue.read_merge_request("gitlab.example.org", "12", "42", "discussions")
        self.assertEqual(result["sourceCommentHashes"], {"9": hashlib.sha256(body.encode()).hexdigest()})
        self.assertEqual(result["data"][0]["notes"][0]["body"], body)

    def test_claim_then_reuse_confirmed_chat(self):
        first = self.job(repository="cards-api", title="[MT] A custom title")
        job = self.queue.claim_next()
        self.assertEqual(job["id"], first)
        self.assertEqual(job["sectionName"], "[MT] cards-api")
        second = self.job(repository="cards-api")
        self.assertIsNone(Queue(self.root).claim_next())
        thread = str(uuid.uuid4())
        self.queue.record(first, thread)
        job = self.queue.claim_next()
        self.assertEqual((job["id"], job["threadID"]), (second, thread))
        self.assertNotIn("sectionName", job)
        self.assertEqual(json.loads((self.root / "receipts" / (first + ".json")).read_text())["threadID"], thread)

    def test_read_job_reuses_legacy_preparation_chat_after_delivery(self):
        def key(access, workspace):
            scope = {"assistant": "codex", "username": "me", "access": access, "workspace": workspace,
                     "work": {"host": "gitlab.example.org", "projectID": 12, "iid": 42}}
            return base64.b64encode(json.dumps(scope).encode()).decode()

        legacy = self.job(conversationKey=key("preparation", "/legacy/workspace"))
        self.assertEqual(self.queue.claim_next()["id"], legacy)
        read_key = key("gitLabRead", "")
        follow_up = self.job(conversationKey=read_key, repository="cards-api")
        self.assertIsNone(self.queue.claim_next())
        thread = str(uuid.uuid4())
        self.queue.record(legacy, thread)
        job = self.queue.claim_next()
        self.assertEqual((job["id"], job["threadID"]), (follow_up, thread))
        self.assertNotIn("sectionName", job)
        claim = json.loads((self.root / "claims" / follow_up / "job.json").read_text())
        self.assertEqual(claim["conversationKey"], read_key)

    def test_legacy_prompt_routes_only_to_the_dispatched_mr_repository(self):
        key = base64.b64encode(json.dumps({
            "assistant": "codex", "access": "gitLabRead", "username": "me",
            "work": {"host": "gitlab.example.org", "projectID": 12, "iid": 42},
        }).encode()).decode()
        self.job(title="[MT] cards-api !42 (Me)", conversationKey=key,
                 prompt="[Open MR in GitLab](<https://gitlab.example.org/group/cards-api/-/merge_requests/42>)\n\nDo the task")
        self.assertEqual(self.queue.claim_next()["sectionName"], "[MT] cards-api")

    def test_withdrawn_claim_can_record_result_without_recreating_job(self):
        job_id = self.job()
        self.queue.claim_next()
        (self.root / "jobs" / (job_id + ".json")).unlink()
        thread = str(uuid.uuid4())
        self.queue.record(job_id, thread)
        self.queue.record(job_id, thread)
        with self.assertRaises(ValueError):
            self.queue.record(job_id, str(uuid.uuid4()))
        self.assertIsNone(self.queue.claim_next())

    def test_two_receivers_cannot_dispatch_same_job(self):
        from concurrent.futures import ThreadPoolExecutor

        job_id = self.job()
        with ThreadPoolExecutor(2) as pool:
            first, second = pool.map(lambda _: Queue(self.root).claim_next(), range(2))
        self.assertEqual([job["id"] for job in (first, second) if job], [job_id])

    def test_reuse_disabled_ignores_previous_chat(self):
        first = self.job()
        self.queue.claim_next()
        self.queue.record(first, str(uuid.uuid4()))
        second = self.job(reuse=False)
        job = self.queue.claim_next()
        self.assertEqual((job["id"], job["threadID"]), (second, None))

    def test_only_a_dispatch_poll_records_liveness(self):
        from relay import handle

        heartbeat = self.root / "heartbeat.json"
        call = lambda tool: handle({"method": "tools/call", "params": {"name": tool}}, self.queue)
        call("queue_status")
        self.assertFalse(heartbeat.exists())
        self.assertFalse(call("poll")["isError"])
        self.assertEqual(json.loads(heartbeat.read_text()), {"version": 1})

    def test_poll_includes_mr_status_with_an_empty_queue(self):
        report = {"checkedAt": "2026-11-04T20:00:00Z", "complete": True, "mergeRequests": [{"iid": 42}]}
        (self.root / "mr-status.json").write_text(json.dumps(report))
        self.assertEqual(self.queue.poll(), {"pending": 0, "claimed": 0, "mrStatus": report})


class ClaudeSessionTest(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = pathlib.Path(folder.name)
        for name in ("jobs", "claims", "receipts", "claude-jobs"):
            (self.root / name).mkdir()
        self.queue = Queue(self.root)

    def claude_job(self, assistant="claude"):
        job_id = str(uuid.uuid4())
        key = base64.b64encode(json.dumps({"assistant": assistant, "access": "gitLabRead",
                                           "work": {"host": "gitlab.example.org", "projectID": 1, "iid": 2},
                                           "username": "me", "workspace": ""}).encode()).decode()
        (self.root / "claude-jobs" / (job_id + ".json")).write_text(json.dumps({
            "version": 1, "id": job_id.upper(), "title": "[MT] Review", "prompt": "Review.", "conversationKey": key,
        }))
        return job_id

    def test_codex_listener_never_claims_claude_jobs(self):
        self.claude_job()
        self.assertIsNone(self.queue.claim_next())

    def test_records_one_session_per_claude_job(self):
        job_id = self.claude_job()
        session = "local_" + str(uuid.uuid4())
        self.queue.record_claude_session(job_id, session)
        self.queue.record_claude_session(job_id, session)
        receipt = json.loads((self.root / "claude-receipts" / (job_id + ".json")).read_text())
        self.assertEqual((receipt["jobID"], receipt["threadID"]), (job_id, session))
        with self.assertRaises(ValueError):
            self.queue.record_claude_session(job_id, "local_" + str(uuid.uuid4()))

    def test_rejects_unknown_jobs_codex_jobs_and_bad_session_ids(self):
        with self.assertRaises(ValueError):
            self.queue.record_claude_session(str(uuid.uuid4()), "local_" + str(uuid.uuid4()))
        with self.assertRaises(ValueError):
            self.queue.record_claude_session(self.claude_job(assistant="codex"), "local_" + str(uuid.uuid4()))
        with self.assertRaises(ValueError):
            self.queue.record_claude_session(self.claude_job(), str(uuid.uuid4()))
        self.assertFalse((self.root / "claude-receipts").exists())

    def test_tool_is_listed(self):
        tools = handle({"method": "tools/list"}, self.queue)["tools"]
        self.assertIn("record_claude_session", [tool["name"] for tool in tools])
