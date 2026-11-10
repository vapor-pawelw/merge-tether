import importlib.util
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import sys
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/test_selection.py"


class TestSelectionTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("test_selection", SCRIPT)
        self.selector = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.selector)

    def test_documentation_needs_no_app_launch(self):
        plan = self.selector.select_paths(REPO, ["docs/building.md", "AGENTS.md"])
        self.assertEqual(plan["mode"], "none")
        self.assertEqual(plan["tasks"], [])

    def test_usage_change_runs_its_tests_without_unrelated_workflows(self):
        plan = self.selector.select_paths(REPO, ["Sources/Model/AssistantUsage.swift"])
        self.assertEqual(plan["mode"], "targeted")
        self.assertEqual(plan["suites"], [f"GitLabTodosTests/{suite}" for suite in sorted(self.selector.GROUPS["usage"])])

    def test_view_actions_are_not_assumed_to_be_visual_only(self):
        plan = self.selector.select_paths(REPO, ["Sources/Views/InboxAttentionActions.swift"])
        self.assertEqual(plan["mode"], "full")

    def test_shared_and_unknown_sources_fail_closed_to_full(self):
        for path in ["Sources/Services/SettingsManager.swift", "Sources/Model/GitLabMergeRequest.swift",
                     "Sources/Services/NewService.swift", "Project.swift", "Resources/Board.xcstrings",
                     "Tests/Support/InMemoryGitLab.swift", "scripts/test_selection.py"]:
            with self.subTest(path=path):
                self.assertEqual(self.selector.select_paths(REPO, [path])["mode"], "full")

    def test_test_only_edit_runs_the_suite_and_deleted_test_falls_back(self):
        plan = self.selector.select_paths(REPO, ["Tests/AssistantUsageTests.swift"])
        self.assertEqual(plan["suites"], ["GitLabTodosTests/AssistantUsageTests"])
        self.assertEqual(self.selector.select_paths(REPO, ["Tests/DeletedTests.swift"])["mode"], "full")

    def test_tooling_only_changes_run_python_without_building_app(self):
        plan = self.selector.select_paths(REPO, ["Tests/TestTools/test_run_tests.py"])
        self.assertEqual(plan["mode"], "none")
        self.assertEqual(plan["tasks"], ["tools"])

    def test_changes_combine_and_unknown_change_overrides_targeting(self):
        plan = self.selector.select_paths(REPO, ["Sources/Model/AssistantUsage.swift",
                                               "Tests/TestTools/test_run_tests.py"])
        self.assertEqual(plan["mode"], "targeted")
        self.assertEqual(plan["tasks"], ["tools"])
        self.assertEqual(self.selector.select_paths(REPO, plan["paths"] + ["unknown.txt"])["mode"], "full")

    def test_usage_changes_include_store_runner_and_presentation_consumers(self):
        plan = self.selector.select_paths(REPO, ["Sources/Model/AssistantUsage.swift"])
        self.assertEqual(plan["mode"], "targeted")
        self.assertIn("GitLabTodosTests/AssistantUsageStoreTests", plan["suites"])
        self.assertIn("GitLabTodosTests/AssistantUsageRunnerTests", plan["suites"])

    def test_remote_package_change_includes_app_consumers_and_package_tests(self):
        plan = self.selector.select_paths(REPO, ["Packages/MergeTetherRemote/Sources/MergeTetherRemote/Models.swift"])
        self.assertEqual(plan["mode"], "full")
        self.assertIn("remote", plan["tasks"])

    def test_runner_full_and_manual_plans_are_explicit_and_do_not_start_xcode(self):
        for arguments, mode in [(["--full"], "full"),
                                (["--only-testing", "GitLabTodosTests/AssistantUsageTests"], "targeted")]:
            result = subprocess.run([sys.executable, str(REPO / "scripts/run-tests.py"), "--plan", *arguments],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertEqual(plan["mode"], mode)
            self.assertEqual(plan["tasks"], self.selector.TASKS if mode == "full" else [])

    def test_standalone_selection_runs_and_reports_without_xcode_or_an_app_project(self):
        for fails in [False, True]:
            with self.subTest(fails=fails), tempfile.TemporaryDirectory() as folder:
                repo = Path(folder)
                (repo / "scripts").mkdir()
                for name in ["run-tests.py", "test_selection.py"]:
                    shutil.copyfile(REPO / "scripts" / name, repo / "scripts" / name)
                (repo / "mise.toml").write_text('[tools]\ntuist = "4.180.0"\n')
                (repo / ".gitignore").write_text(".test-results/\n__pycache__/\n")
                def git(*args):
                    subprocess.run(["git", "-C", folder, *args], check=True, capture_output=True)
                git("init", "-q", "-b", "main")
                git("add", ".")
                git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.test",
                    "commit", "-qm", "fixture")
                tests = repo / "Tests/TestTools"
                tests.mkdir(parents=True)
                (tests / "test_selected.py").write_text(
                    "import unittest\nclass Selected(unittest.TestCase):\n"
                    f"    def test_selected(self): self.assertEqual({fails!r}, False)\n")
                result = subprocess.run([sys.executable, str(repo / "scripts/run-tests.py"), "--base", "HEAD"],
                                        env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 1 if fails else 0, result.stderr + result.stdout)
                run = next((repo / ".test-results").glob("run-*"))
                report = json.loads((run / "report.json").read_text())
                self.assertEqual(report["selection"]["mode"], "none")
                self.assertEqual(set(report["phases"]), {"tools"})
                self.assertEqual(report["exit_code"], result.returncode)
                self.assertTrue((run / "tools.log.gz").is_file())
                self.assertFalse((run / "Tests.xcresult").exists())
                self.assertFalse(list((repo / ".test-results").glob("test-home-*")))

    def test_git_selection_includes_branch_staged_unstaged_untracked_and_both_rename_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            def git(*args):
                return subprocess.check_output(["git", "-C", folder, *args], text=True).strip()
            def commit():
                git("add", ".")
                git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.test",
                    "commit", "-qm", "fixture")
            git("init", "-q", "-b", "main")
            for name in ["old.swift", "staged.swift", "unstaged.swift"]:
                (repo / name).write_text("initial")
            commit()
            git("checkout", "-qb", "feature")
            (repo / "committed.swift").write_text("branch change")
            commit()
            git("mv", "old.swift", "new.swift")
            (repo / "staged.swift").write_text("staged change")
            git("add", "staged.swift")
            (repo / "unstaged.swift").write_text("unstaged change")
            (repo / "untracked.swift").write_text("untracked change")
            paths, comparison = self.selector.changed_paths(repo)
            self.assertEqual(set(paths), {"committed.swift", "old.swift", "new.swift", "staged.swift",
                                          "unstaged.swift", "untracked.swift"})
            self.assertTrue(comparison)

            # A worktree can undo a staged edit; neither side should disappear from the scope.
            git("reset", "--hard", "-q", "HEAD")
            (repo / "staged.swift").write_text("staged only")
            git("add", "staged.swift")
            (repo / "staged.swift").write_text("initial")
            self.assertIn("staged.swift", self.selector.changed_paths(repo)[0])

    def test_all_mapping_groups_reference_existing_test_suites(self):
        for group, suites in self.selector.GROUPS.items():
            for suite in suites:
                with self.subTest(group=group, suite=suite):
                    self.assertTrue((REPO / "Tests" / f"{suite}.swift").is_file())

    def test_missing_git_history_and_empty_scope_fall_back_to_full(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(self.selector.plan_changes(Path(folder))["mode"], "full")
        self.assertEqual(self.selector.select_paths(REPO, [])["mode"], "full")

    def test_clean_main_checks_last_commit_instead_of_claiming_nothing_changed(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            def git(*args):
                return subprocess.check_output(["git", "-C", folder, *args], text=True).strip()
            git("init", "-q", "-b", "main")
            (repo / "first").write_text("first")
            git("add", ".")
            git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.test",
                "commit", "-qm", "initial")
            (repo / "second").write_text("second")
            git("add", ".")
            git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c", "user.email=test@example.test",
                "commit", "-qm", "next")
            self.assertEqual(self.selector.changed_paths(repo)[0], ["second"])
            (repo / "docs.md").write_text("current local change")
            self.assertEqual(self.selector.changed_paths(repo)[0], ["docs.md"])


if __name__ == "__main__":
    unittest.main()
