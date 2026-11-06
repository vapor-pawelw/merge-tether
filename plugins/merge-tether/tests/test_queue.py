import base64
import json
import pathlib
import tempfile
import unittest
import uuid

from relay import Queue, handle


class QueueTest(unittest.TestCase):
    def test_status_title_formatter_uses_one_tag_and_preserves_mr_identity(self):
        for state, expected in (
            ("closed", "[MT] [Closed] cards-api !42 (Me)"),
            ("merged", "[MT] [Merged] cards-api !42 (Me)"),
            ("draft", "[MT] [Draft] cards-api !42 1/2 (Me)"),
            ("open", "[MT] cards-api !42 1/2 (Me)"),
        ):
            call = {"method": "tools/call", "params": {"name": "format_chat_status_title", "arguments": {
                "title": "[MT] [Closed] [Draft] cards-api !42 1/2 (Me)", "status": state}}}
            reply = handle(call, Queue(pathlib.Path("/unused")))
            self.assertFalse(reply["isError"])
            self.assertEqual(json.loads(reply["content"][0]["text"])["title"], expected)
        untouched = handle({"method": "tools/call", "params": {"name": "format_chat_status_title", "arguments": {
            "title": "My manually named chat", "status": "closed"}}}, Queue(pathlib.Path("/unused")))
        self.assertIsNone(json.loads(untouched["content"][0]["text"])["title"])

    def test_status_jobs_require_listener_capability_and_never_create_chats(self):
        from unittest.mock import patch
        thread, job_id = str(uuid.uuid4()), str(uuid.uuid4())
        key = base64.b64encode(json.dumps({"assistant": "codex", "work": {"iid": 42}}).encode()).decode()
        delivery = self.job(conversationKey=key)
        self.queue.claim_next()
        self.queue.record(delivery, thread)
        (self.root / "jobs" / (job_id + ".json")).write_text(json.dumps({"version": 1, "id": job_id,
            "operation": "set_mr_status", "threadID": thread, "conversationKey": "status:" + thread, "status": "closed"}))
        self.assertIsNone(self.queue.claim_next(allow_merged=True))
        call = {"method": "tools/call", "params": {"name": "claim_next", "arguments": {"allowStatus": True}}}
        with patch("relay.gitlab_get") as remote:
            reply = handle(call, self.queue)
        remote.assert_not_called()
        self.assertFalse(reply["isError"])
        self.assertEqual(json.loads(reply["content"][0]["text"])["job"], {
            "id": job_id, "operation": "set_mr_status", "threadID": thread, "status": "closed"})
        self.queue.record(job_id, thread)

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
        key = base64.b64encode(json.dumps({"assistant": "codex", "access": "gitLabRead", "username": "me",
            "work": {"host": "gitlab.example.org", "projectID": 1, "iid": 42}, "workspace": ""}).encode()).decode()
        job_id = self.job(reuse=False, conversationKey=key)
        (canonical / "jobs" / (job_id + ".json")).write_bytes((self.root / "jobs" / (job_id + ".json")).read_bytes())
        requests = [
            {"jsonrpc":"2.0", "id":1, "method":"tools/list"},
            {"jsonrpc":"2.0", "id":2, "method":"tools/call", "params":{"name":"queue_status","arguments":{}}},
            {"jsonrpc":"2.0", "id":3, "method":"tools/call", "params":{"name":"claim_next","arguments":{}}},
        ]
        relay = pathlib.Path(__file__).resolve().parents[1] / "relay.py"
        server = (f"import sys; sys.path.insert(0, {str(relay.parent)!r}); import relay; "
                  "relay.gitlab_get = lambda host, endpoint: ({'username':'me'} if endpoint == '/user' "
                  "else {'project_id':1,'iid':42,'state':'opened'}); relay.serve()")
        result = subprocess.run([sys.executable, "-B", "-c", server], input="".join(json.dumps(r)+"\n" for r in requests),
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

    def test_template_registration_is_exposed_validated_and_visible_to_setup(self):
        tools = handle({"method": "tools/list"}, self.queue)["tools"]
        registration = next((tool for tool in tools if tool["name"] == "record_dispatch_template"), None)
        self.assertIsNotNone(registration)
        self.assertEqual(registration["inputSchema"]["required"], ["threadID"])
        self.assertFalse(registration["inputSchema"]["additionalProperties"])
        thread = str(uuid.uuid4())
        request = {"method": "tools/call", "params": {
            "name": "record_dispatch_template", "arguments": {"threadID": thread.upper()}}}
        self.assertFalse(handle(request, self.queue)["isError"])
        self.assertEqual(json.loads((self.root / "template.json").read_text()), {"version": 1, "threadID": thread})
        status = handle({"method": "tools/call", "params": {"name": "queue_status"}}, Queue(self.root))
        self.assertEqual(json.loads(status["content"][0]["text"]), {
            "pending": 0, "claimed": 0, "validatesOpenMR": True, "supportsStatusTitles": True, "templateThreadID": thread,
        })
        for args in ({"threadID": "../not-a-thread"}, {"threadID": None},
                     {"threadID": thread, "permissions": "full"}):
            with self.subTest(args=args):
                request["params"]["arguments"] = args
                self.assertTrue(handle(request, self.queue)["isError"])
                self.assertEqual(json.loads((self.root / "template.json").read_text())["threadID"], thread)

    def test_configured_template_routes_only_new_chats_and_allows_explicit_opt_out(self):
        template = str(uuid.uuid4())
        (self.root / "template.json").write_text(json.dumps({"version": 1, "threadID": template}))
        for index, fields in enumerate(({}, {"useTemplate": True}, {"useTemplate": False})):
            with self.subTest(fields=fields):
                self.job(reuse=False, conversationKey=f"review-{index}", repository="cards-api",
                         model="gpt-6.1-sol", thinking="high", **fields)
                job = self.queue.claim_next()
                self.assertIsNone(job["threadID"])
                if fields.get("useTemplate") is False:
                    self.assertNotIn("templateThreadID", job)
                else:
                    self.assertEqual(job.get("templateThreadID"), template)
                self.assertEqual(job["sectionName"], "[MT] cards-api")
                self.assertEqual((job["model"], job["thinking"]), ("gpt-6.1-sol", "high"))
                self.assertIn("deliveryPrompt", job)
                self.assertNotIn("prompt", job)

    def test_template_registration_is_idempotent_but_cannot_replace_existing_routing(self):
        thread = str(uuid.uuid4())
        self.queue.record_dispatch_template(thread)
        path = self.root / "template.json"
        original = path.read_bytes()
        self.queue.record_dispatch_template(thread.upper())
        self.assertEqual(path.read_bytes(), original)
        with self.assertRaisesRegex(ValueError, "reset template in MergeTether settings first"):
            self.queue.record_dispatch_template(str(uuid.uuid4()))
        self.assertEqual(path.read_bytes(), original)

    def test_template_registration_requires_gui_reset_of_unreadable_or_invalid_existing_metadata(self):
        invalid = ["not json", "[]", "{}", json.dumps({"version": 2, "threadID": str(uuid.uuid4())}),
                   json.dumps({"version": True, "threadID": str(uuid.uuid4())}),
                   json.dumps({"version": 1, "threadID": "not-a-uuid"})]
        path = self.root / "template.json"
        for metadata in invalid:
            with self.subTest(metadata=metadata):
                path.write_text(metadata)
                original = path.read_bytes()
                result = handle({"method": "tools/call", "params": {
                    "name": "record_dispatch_template", "arguments": {"threadID": str(uuid.uuid4())},
                }}, self.queue)
                self.assertTrue(result["isError"])
                self.assertIn("reset template in MergeTether settings first", result["content"][0]["text"])
                self.assertEqual(path.read_bytes(), original)

    def test_missing_or_malformed_template_preserves_legacy_claim_and_status(self):
        invalid = [None, "not json", [], {"version": 2, "threadID": str(uuid.uuid4())},
                   {"version": True, "threadID": str(uuid.uuid4())},
                   {"version": 1, "threadID": "not-a-uuid"}, {"version": 1}]
        for index, template in enumerate(invalid):
            with self.subTest(template=template):
                path = self.root / "template.json"
                if template is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_text(template if isinstance(template, str) else json.dumps(template))
                self.assertNotIn("templateThreadID", self.queue.status())
                self.job(reuse=False, conversationKey=f"review-{index}")
                self.assertNotIn("templateThreadID", self.queue.claim_next())

    def test_delivery_bootstrap_preserves_complete_instructions_after_job_withdrawal(self):
        import hashlib
        prompt = "https://gitlab.example.org/g/p/-/merge_requests/42\n\n" + "Pełne instrukcje — żadnego skracania.\n" * 500
        job_id = self.job(prompt=prompt)
        job = self.queue.claim_next()
        bootstrap = job.get("deliveryPrompt", "")
        # The transport must stay small even when the immutable instructions are large.
        self.assertNotIn("prompt", job)
        self.assertLess(len(json.dumps(job)), 2500)
        self.assertTrue(bootstrap.startswith(prompt.splitlines()[0]))
        self.assertLess(len(bootstrap), 2500)
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

    def test_each_claim_has_private_scratch_bound_to_its_instruction_snapshot(self):
        import hashlib
        import stat
        prompt = "https://gitlab.example.org/g/p/-/merge_requests/42\n\nKeep the full instructions unchanged."
        workspaces = []
        for index in range(2):
            self.job(reuse=False, conversationKey=f"isolated-{index}", prompt=prompt)
            claim = self.queue.claim_next()
            instructions = self.root / "claims" / claim["id"] / "instructions.json"
            snapshot = json.loads(instructions.read_text())
            workspace = pathlib.Path(snapshot.get("workingDirectory", ""))
            self.assertEqual(workspace, instructions.parent / "workspace")
            self.assertTrue(workspace.is_dir())
            self.assertEqual(stat.S_IMODE(workspace.stat().st_mode), 0o700)
            self.assertIn(json.dumps(str(workspace), ensure_ascii=False), claim["deliveryPrompt"])
            self.assertIn("template folder untouched", claim["deliveryPrompt"])
            self.assertEqual(snapshot["prompt"], prompt)
            self.assertEqual(snapshot["promptSHA256"], hashlib.sha256(prompt.encode()).hexdigest())
            self.assertNotIn("prompt", claim)
            self.assertLess(len(claim["deliveryPrompt"]), 2500)
            workspaces.append(workspace)
        self.assertNotEqual(workspaces[0], workspaces[1])

    def test_merged_update_needs_capability_and_confirmed_chat(self):
        (self.root / "template.json").write_text(json.dumps({"version": 1, "threadID": str(uuid.uuid4())}))
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
        from unittest.mock import patch
        with patch("relay.gitlab_get") as remote:
            reply = handle({"method": "tools/call", "params": {"name": "claim_next", "arguments": {"allowMerged": True}}}, self.queue)
        self.assertFalse(reply["isError"])
        remote.assert_not_called()
        self.assertEqual(json.loads(reply["content"][0]["text"])["job"], {
            "id": thread, "threadID": thread, "operation": "mark_merged",
        })
        with self.assertRaises(ValueError):
            self.queue.record(thread, str(uuid.uuid4()))
        self.queue.record(thread, thread)
        self.assertIsNone(self.queue.claim_next(allow_merged=True))

    def test_work_item_proposal_requires_a_compatible_listener(self):
        (self.root / "template.json").write_text(json.dumps({"version": 1, "threadID": str(uuid.uuid4())}))
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
        (self.root / "template.json").write_text(json.dumps({"version": 1, "threadID": str(uuid.uuid4())}))
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
        (self.root / "template.json").write_text(json.dumps({"version": 1, "threadID": str(uuid.uuid4())}))
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
        self.assertNotIn("templateThreadID", job)
        snapshot = json.loads((self.root / "claims" / second / "instructions.json").read_text())
        workspace = self.root / "claims" / second / "workspace"
        self.assertEqual(snapshot.get("workingDirectory"), str(workspace))
        self.assertTrue(workspace.is_dir())
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
        result = self.queue.poll()
        self.assertEqual({key: result[key] for key in ("pending", "claimed", "mrStatus")},
                         {"pending": 0, "claimed": 0, "mrStatus": report})

    def test_poll_formats_current_rows_with_exact_roles_and_unpublished_counts(self):
        report = {"checkedAt": "2026-11-06T00:34:10Z", "complete": True, "mergeRequests": [
            {"iid": 42, "url": "https://gitlab.example.org/team/cards-api/-/merge_requests/42",
             "role": "author", "mergeStatus": "merge_request_blocked", "pipeline": "failed", "unpublishedComments": 1},
            {"iid": 7, "url": "https://gitlab.example.org/team/mobile/-/merge_requests/7",
             "role": "reviewer", "draft": True, "unpublishedComments": 0},
        ]}
        (self.root / "mr-status.json").write_text(json.dumps(report))
        result = self.queue.poll()
        markdown = result.get("mrStatusMarkdown")
        self.assertIsInstance(markdown, str)
        self.assertIn("2026-11-06 00:34:10 UTC", markdown)
        self.assertIn("### Own MRs", markdown)
        self.assertIn("### For review", markdown)
        rows = [line for line in markdown.splitlines() if "[!" in line]
        self.assertEqual(len(rows), 2)
        self.assertIn("[!42](<https://gitlab.example.org/team/cards-api/-/merge_requests/42>)", rows[0])
        self.assertIn("Blocked", rows[0])
        self.assertTrue(rows[0].endswith("| **Failed** | **1** |"))
        self.assertTrue(rows[1].endswith("| **DRAFT** | — | 0 |"))
        self.assertLess(markdown.index(rows[0]), markdown.index("### For review"))
        self.assertGreater(markdown.index(rows[1]), markdown.index("### For review"))

    def test_native_claim_skips_terminal_mrs_without_claim_or_delivery(self):
        from unittest.mock import patch
        key = base64.b64encode(json.dumps({"assistant": "codex", "access": "gitLabRead", "username": "me",
            "work": {"host": "gitlab.example.org", "projectID": 1, "iid": 42}, "workspace": ""}).encode()).decode()
        call = {"method": "tools/call", "params": {"name": "claim_next"}}
        for state in ("merged", "closed"):
            with self.subTest(state=state):
                job_id = self.job(conversationKey=key)
                def read(host, endpoint):
                    self.assertEqual(host, "gitlab.example.org")
                    if endpoint == "/user": return {"username": "me"}
                    self.assertEqual(endpoint, "/projects/1/merge_requests/42")
                    return {"project_id": 1, "iid": 42, "state": state}
                with patch("relay.gitlab_get", side_effect=read) as remote:
                    response = handle(call, self.queue)
                self.assertFalse(response["isError"])
                self.assertIsNone(json.loads(response["content"][0]["text"])["job"])
                self.assertEqual(remote.call_count, 2)
                self.assertFalse((self.root / "claims" / job_id).exists())
                self.assertFalse(self.queue.receipt(job_id).exists())
                skipped = json.loads((self.root / "skipped" / (job_id + ".json")).read_text())
                self.assertEqual((skipped["jobID"], skipped["state"], skipped["conversationKey"]), (job_id, state, key))
                self.assertEqual(self.queue.status()["pending"], 0)
        reopened_job = self.job(conversationKey=key)
        with patch("relay.gitlab_get", side_effect=[{"username": "me"}, {"project_id": 1, "iid": 42, "state": "opened"}]):
            reopened = handle(call, self.queue)
        self.assertEqual(json.loads(reopened["content"][0]["text"])["job"]["id"], reopened_job)

    def test_native_claim_requires_verified_open_state_and_matching_account(self):
        from unittest.mock import patch
        key = base64.b64encode(json.dumps({"assistant": "codex", "access": "gitLabRead", "username": "me",
            "work": {"host": "gitlab.example.org", "projectID": 1, "iid": 42}, "workspace": ""}).encode()).decode()
        job_id = self.job(conversationKey=key)
        call = {"method": "tools/call", "params": {"name": "claim_next"}}
        for replies in ([ValueError("offline")], [{"username": "other"}],
                        [{"username": "me"}, {"project_id": 1, "iid": 42, "state": "unknown"}],
                        [{"username": "me"}, {"project_id": 2, "iid": 42, "state": "opened"}]):
            with patch("relay.gitlab_get", side_effect=replies):
                self.assertTrue(handle(call, self.queue)["isError"])
            self.assertFalse((self.root / "claims" / job_id).exists())
            self.assertEqual(self.queue.status()["pending"], 1)
        with patch("relay.gitlab_get", side_effect=[{"username": "me"}, {"project_id": 1, "iid": 42, "state": "opened"}]):
            result = handle(call, self.queue)
        self.assertFalse(result["isError"])
        self.assertEqual(json.loads(result["content"][0]["text"])["job"]["id"], job_id)
        with patch("relay.gitlab_get") as remote:
            uncertain = handle(call, self.queue)
        remote.assert_not_called()
        self.assertIsNone(json.loads(uncertain["content"][0]["text"])["job"])
        self.assertTrue((self.root / "claims" / job_id).is_dir())
        self.assertFalse((self.root / "skipped" / (job_id + ".json")).exists())

    def test_polish_report_uses_current_snapshot_and_puts_draft_mrs_last(self):
        report = {"checkedAt": "2026-11-06T00:34:10Z", "complete": False, "mergeRequests": [
            {"iid": 1, "url": "https://gitlab.example.org/team/cards-api/-/merge_requests/1",
             "role": "author", "draft": True, "unpublishedComments": 0},
            {"iid": 2, "url": "https://gitlab.example.org/team/cards-api/-/merge_requests/2",
             "role": "author", "mergeStatus": "discussions_not_resolved", "pipeline": "failed", "unpublishedComments": 3},
        ]}
        path = self.root / "mr-status.json"
        path.write_text(json.dumps(report))
        call = {"method": "tools/call", "params": {"name": "poll", "arguments": {"reportLanguage": "pl"}}}
        result = handle(call, self.queue)
        self.assertFalse(result["isError"])
        markdown = json.loads(result["content"][0]["text"])["mrStatusMarkdown"]
        self.assertIn("Częściowy", markdown)
        self.assertIn("**Otwarte dyskusje** | **Błąd** | **3**", markdown)
        self.assertLess(markdown.index("[!2]"), markdown.index("[!1]"))
        self.assertIn("### Własne MR-y", markdown)
        self.assertNotIn("### Do review", markdown)
        self.assertIn("0 oczekujących · 0 zajętych", markdown)
        report["mergeRequests"] = []
        path.write_text(json.dumps(report))
        current = self.queue.poll(report_language="pl")["mrStatusMarkdown"]
        self.assertNotIn("[!", current)
        self.assertIn("Brak otwartych MR-ów", current)

    def test_report_does_not_turn_untrusted_fields_into_markup_or_break_poll(self):
        report = {"checkedAt": "2026-11-06T00:34:10Z", "complete": True, "mergeRequests": [
            {"iid": 1, "url": "https://gitlab.example.org/team/a|[link]/-/merge_requests/1",
             "role": "author", "mergeStatus": [], "pipeline": {}, "unpublishedComments": None},
            {"iid": 2, "url": "javascript:alert(1)", "role": "reviewer", "draft": False},
        ]}
        (self.root / "mr-status.json").write_text(json.dumps(report))
        call = {"method": "tools/call", "params": {"name": "poll"}}
        response = handle(call, self.queue)
        self.assertFalse(response["isError"])
        result = json.loads(response["content"][0]["text"])
        self.assertEqual((result["pending"], result["claimed"]), (0, 0))
        markdown = result["mrStatusMarkdown"]
        self.assertIn(r"a\|\[link\]", markdown)
        self.assertNotIn("javascript:", markdown)
        self.assertNotIn("[link]", markdown)
        self.assertIn("Unknown | — | —", markdown)


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
