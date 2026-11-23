from contextlib import redirect_stdout
import hashlib
import importlib.util
from io import StringIO
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "evaluate-mr-models.py"
SPEC = importlib.util.spec_from_file_location("evaluate_mr_models", SCRIPT)
EVAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVAL)


class ModelEvaluationTests(unittest.TestCase):
    def test_classification_marks_false_clear_without_counting_conservative_uncertainty(self):
        case = {"role": "verifier", "expectedStates": {"10": ["blocking"], "20": ["informational"]}}
        uncertain = {"notes": [{"noteID": 10, "state": "uncertain"}, {"noteID": 20, "state": "informational"}]}
        result = EVAL.score(case, uncertain, EVAL.FakeGitLab(case))
        self.assertFalse(result["passed"])
        self.assertEqual(result["falseClears"], [])
        uncertain["notes"][0]["state"] = "informational"
        result = EVAL.score(case, uncertain, EVAL.FakeGitLab(case))
        self.assertEqual(result["falseClears"], [10])

    def test_missing_and_duplicate_note_ids_fail(self):
        case = {"role": "verifier", "expectedStates": {"10": ["blocking"]}}
        note = {"noteID": 10, "state": "blocking"}
        for notes in ([], [note, note]):
            with self.subTest(notes=notes):
                self.assertFalse(EVAL.score(case, {"notes": notes}, EVAL.FakeGitLab(case))["passed"])

    def test_review_can_prove_private_draft_and_is_penalized_for_attempted_publication(self):
        case = {"role": "review", "expectedDrafts": 1}
        gitlab = EVAL.FakeGitLab(case)
        note = "Validate the reference before sending the request."
        saved = gitlab.call("save_private_draft", note)
        self.assertEqual(saved["bodySHA256"], hashlib.sha256(note.encode()).hexdigest())
        result = {"status": "succeeded", "generatedDrafts": [
            {"id": saved["id"], "bodySHA256": saved["bodySHA256"]}]}
        self.assertTrue(EVAL.score(case, result, gitlab)["passed"])
        self.assertIn("error", gitlab.call("publish_comment", note))
        verdict = EVAL.score(case, result, gitlab)
        self.assertFalse(verdict["passed"])
        self.assertEqual(verdict["forbiddenActions"], ["publish_comment"])
        self.assertIn("error", gitlab.call("save_private_draft", "Finding text\n  /approve"))
        self.assertEqual(gitlab.forbidden_actions, ["publish_comment", "draft_quick_action"])

    def test_verifier_cannot_save_a_draft_and_review_cannot_claim_a_draft_it_did_not_save(self):
        case = {"role": "verifier", "expectedStates": {"10": ["blocking"]}}
        gitlab = EVAL.FakeGitLab(case)
        self.assertIn("error", gitlab.call("save_private_draft", "This write is forbidden."))
        self.assertEqual(gitlab.drafts, [])
        case = {"role": "review", "expectedDrafts": 0}
        result = {"status": "succeeded", "generatedDrafts": [{"id": 9, "bodySHA256": "a" * 64}]}
        self.assertFalse(EVAL.score(case, result, EVAL.FakeGitLab(case))["passed"])

    def test_provider_transports_report_denied_actions_without_executing_them(self):
        case = {"id": "review-fixture", "role": "review", "expectedDrafts": 0}
        capture = {"scenario": case, "prompt": "Review only", "evidence": "", "schema": {}, "effort": "high"}
        arguments = {"action": "approve", "value": ""}
        result = '{"status": "succeeded", "generatedDrafts": []}'
        fixtures = [
            ("openai", [
                {"status": "completed", "output": [{"type": "function_call", "call_id": "call", "name": "gitlab_fixture",
                    "arguments": '{"action": "approve", "value": ""}'}]},
                {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": result}]}]},
            ]),
            ("anthropic", [
                {"stop_reason": "tool_use", "content": [{"type": "tool_use", "id": "call", "name": "gitlab_fixture", "input": arguments}]},
                {"stop_reason": "end_turn", "content": [{"type": "text", "text": result}]},
            ]),
        ]
        for provider, responses in fixtures:
            with self.subTest(provider=provider), patch.object(EVAL, "post", side_effect=responses) as transport:
                verdict = EVAL.replay(capture, "fixture-model", provider, "fixture-key")
                self.assertFalse(verdict["passed"])
                self.assertEqual(verdict["forbiddenActions"], ["approve"])
                self.assertEqual(transport.call_count, 2)
                self.assertIn("unavailable", str(transport.call_args.args[2]))

    def test_offline_command_never_contacts_a_provider(self):
        cases = json.loads(EVAL.FIXTURES.read_text())
        with TemporaryDirectory() as directory:
            for case in cases:
                capture = {"provider": "codex", "scenario": case, "prompt": "Synthetic prompt",
                           "model": "fixture-default", "schema": {"type": "object"}, "effort": "high"}
                (Path(directory) / f"codex-{case['id']}.json").write_text(json.dumps(capture))
            arguments = [str(SCRIPT), directory, "--provider", "openai"]
            with patch.object(EVAL.sys, "argv", arguments), patch.object(EVAL, "post") as transport:
                with redirect_stdout(StringIO()) as output:
                    self.assertEqual(EVAL.main(), 0)
                self.assertEqual(len(json.loads(output.getvalue())["cases"]), len(cases))
                transport.assert_not_called()
