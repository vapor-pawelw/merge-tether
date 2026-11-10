import importlib.util
import csv
import gzip
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "run-tests.py"


class TimingReportTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("run_tests", SCRIPT)
        self.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runner)

    @staticmethod
    def event(timestamp, test_id, status=None):
        identity = '<XCTTestIdentifier leaf ["Suite", "' + test_id + '"]>'
        if status is None:
            return (timestamp + ' xcodebuild[1:2] _XCT_testCaseDidStartWithIdentifier:' + identity
                    + 'testCaseRunConfiguration:<configuration>traits:<traits>\n')
        return (timestamp + ' xcodebuild[1:2] _XCT_testCaseWithIdentifier:' + identity
                + ' didFinishWithStatus:' + status + ' duration:0\n')

    def test_executions_overlap_and_repeat_without_using_rounded_durations(self):
        log = (self.event("12:00:00.000", "example(_:)")
               + self.event("12:00:00.100", "ordinary()")
               + self.event("12:00:00.125", "ordinary()", "passed")
               + self.event("12:00:00.250", "example(_:)", "failed")
               + self.event("12:00:01.000", "example(_:)")
               + self.event("12:00:01.500", "example(_:)", "passed"))
        rows = self.runner.test_timings(log)
        self.assertEqual([row["seconds"] for row in rows], [0.25, 0.025, 0.5])
        self.assertEqual(len({row["path"] for row in rows}), 3)
        self.assertEqual(rows[0]["test_id"], "Suite/example(_:)")
        self.assertEqual(rows[0]["result"], "failed")
        self.assertEqual(rows[1]["suite"], "Suite")

    def test_missing_start_or_finish_remains_visible_in_a_partial_run(self):
        log = (self.event("12:00:00.000", "missing()")
               + self.event("12:00:00.100", "noStart()", "failed"))
        rows = self.runner.test_timings(log)
        self.assertEqual(len(rows), 2)
        self.assertIsNone(rows[0]["seconds"])
        self.assertIsNone(rows[1]["seconds"])
        self.assertEqual(rows[0]["result"], "incomplete")

    def test_execution_crossing_midnight_retains_its_duration(self):
        log = (self.event("23:59:59.900", "midnight()")
               + self.event("00:00:00.125", "midnight()", "passed"))
        self.assertEqual(self.runner.test_timings(log)[0]["seconds"], 0.225)

    def test_overlapping_identical_identities_are_flagged(self):
        log = (self.event("12:00:00.000", "same()") + self.event("12:00:00.100", "same()")
               + self.event("12:00:00.200", "same()", "passed")
               + self.event("12:00:00.300", "same()", "passed"))
        rows = self.runner.test_timings(log)
        self.assertEqual([row.get("ambiguous") for row in rows], [True, True])

    def test_case_key_survives_other_tests_changing_start_order(self):
        first = self.event("12:00:00.000", "first()") + self.event("12:00:00.100", "first()", "passed")
        second = self.event("12:00:00.200", "second()") + self.event("12:00:00.300", "second()", "passed")
        before = {row["test_id"]: row.get("case_key") for row in self.runner.test_timings(first + second)}
        after = {row["test_id"]: row.get("case_key") for row in self.runner.test_timings(second + first)}
        self.assertTrue(all(before.values()))
        self.assertEqual(before, after)

    def test_execution_span_is_separate_from_xcode_runner_overhead(self):
        self.assertEqual(self.runner.execution_spans(
            "Test passed after 99 seconds.\n"
            "Test run with 1165 tests in 95 suites passed after 125.375 seconds.\n"), [125.375])
        self.assertEqual(self.runner.execution_spans(
            "Test run with 3 tests failed after 0.125 seconds with 1 issue.\n"), [0.125])
        self.assertEqual(self.runner.execution_spans("Build failed"), [])

    def test_retention_only_removes_owned_completed_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index in range(4):
                run = root / f"run-{index}"
                run.mkdir()
                (run / "report.json").write_text("{}")
                (run / "Tests.xcresult").mkdir()
            unrelated = root / "user-data"
            unrelated.mkdir()
            active = root / "run-active"
            active.mkdir()
            self.runner.prune_results(root, keep_reports=2, keep_bundles=1)
            self.assertEqual(sorted(p.name for p in root.iterdir()),
                             ["run-2", "run-3", "run-active", "user-data"])
            self.assertFalse((root / "run-2" / "Tests.xcresult").exists())
            self.assertTrue((root / "run-3" / "Tests.xcresult").exists())

    def test_failed_test_run_still_exports_timings_and_cleans_isolated_home(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "xcodebuild"
            executable.write_text(f"""#!{sys.executable}
import os, pathlib, sys
if '-version' in sys.argv:
    print('Xcode fixture')
else:
    print('runner-home=' + os.environ['TEST_RUNNER_HOME'])
    assert os.environ['TEST_RUNNER_HOME'] == os.environ['TEST_RUNNER_CFFIXED_USER_HOME']
    assert os.environ['TEST_RUNNER_MERGETETHER_TEST_FIXTURE_HOME'] == os.environ['TEST_RUNNER_HOME']
    assert (pathlib.Path(os.environ['TEST_RUNNER_HOME']) / '.mergetether-test-home').read_text() == 'MergeTether test home\\n'
    assert pathlib.Path(os.environ['TEST_RUNNER_HOME']).is_dir()
    if 'test-without-building' in sys.argv:
        pathlib.Path(sys.argv[sys.argv.index('-resultBundlePath') + 1]).mkdir()
        sys.exit(65)
""")
            executable.chmod(0o755)
            exporter = root / "xcrun"
            tree = {"testNodes": [{"nodeType": "Test Case", "name": "failed()",
                                   "durationInSeconds": 0.25, "result": "Failed"}]}
            summary = {"result": "Failed", "failedTests": 1, "startTime": 100, "finishTime": 101,
                       "devicesAndConfigurations": [{"failedTests": 1}]}
            diagnostic = (self.event("12:00:00.000", "failed()")
                          + self.event("12:00:00.250", "failed()", "failed"))
            exporter.write_text(f"""#!{sys.executable}
import json, pathlib, sys
if 'diagnostics' in sys.argv:
    directory = pathlib.Path(sys.argv[sys.argv.index('--output-path') + 1])
    (directory / 'Session-fixture.log').write_text({diagnostic!r})
else:
    print(json.dumps({tree!r} if 'tests' in sys.argv else {summary!r}))
""")
            exporter.chmod(0o755)
            results = root / "results"
            completed = subprocess.run([sys.executable, str(SCRIPT), "--only-testing", "GitLabTodosTests/FixtureTests", "--results-dir", str(results)],
                                       env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}"),
                                       capture_output=True, text=True)
            self.assertEqual(completed.returncode, 65, completed.stderr + completed.stdout)
            run = next(results.glob("run-*"))
            report = json.loads((run / "report.json").read_text())
            self.assertEqual(report["phases"]["test"]["exit_code"], 65)
            self.assertEqual(report["xcresult_elapsed_seconds"], 1)
            self.assertTrue((run / "Tests.xcresult").is_dir())
            with (run / "timings.csv").open() as stream:
                self.assertEqual(list(csv.DictReader(stream))[0]["seconds"], "0.25")
            self.assertIn("runner-home=", gzip.open(run / "test.log.gz", "rt").read())
            self.assertEqual(list(results.glob("test-home-*")), [])
            self.assertFalse((results / "DerivedData").exists())

            executable.write_text(executable.read_text().replace("sys.exit(65)", "sys.exit(0)"))
            for configuration in ([], [{"passedTests": 2}], "invalid schema"):
                summary["devicesAndConfigurations"] = configuration
                summary["result"] = "Passed"
                summary["failedTests"] = 0
                # The fake xcresult reader returns an incomplete summary while Xcode exits successfully.
                reader = exporter.read_text()
                reader = reader[:reader.index("else:\n")] + "else:\n    print(json.dumps(" + repr(summary) + "))\n"
                exporter.write_text(reader)
                completed = subprocess.run([sys.executable, str(SCRIPT), "--only-testing", "GitLabTodosTests/FixtureTests", "--results-dir", str(results)],
                                           env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}"),
                                           capture_output=True, text=True)
                self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
                report = json.loads((sorted(results.glob("run-*"))[-1] / "report.json").read_text())
                self.assertEqual(report["exit_code"], 1)

            summary["devicesAndConfigurations"] = [{"passedTests": 1}]
            reader = exporter.read_text()
            reader = reader[:reader.index("else:\n")] + "else:\n    print(json.dumps(" + repr(summary) + "))\n"
            exporter.write_text(reader)
            executable.write_text(executable.read_text().replace("sys.exit(0)",
                "print('MergeTether test guard rejected service CLI /fixture/glab'); sys.exit(0)"))
            completed = subprocess.run([sys.executable, str(SCRIPT), "--only-testing", "GitLabTodosTests/FixtureTests", "--results-dir", str(results)],
                                       env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}"),
                                       capture_output=True, text=True)
            self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)

    def test_termination_interrupts_the_child_and_retains_a_nonzero_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "xcodebuild"
            ready = root / "ready"
            descendant = root / "descendant"
            descendant_code = ("import os,pathlib,signal,time; "
                "signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                f"pathlib.Path({str(descendant)!r}).write_text(str(os.getpid())); time.sleep(60)")
            executable.write_text(f"""#!{sys.executable}
import os, pathlib, signal, subprocess, sys, time
if '-version' in sys.argv:
    print('Xcode fixture')
elif 'test-without-building' in sys.argv:
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    subprocess.Popen([sys.executable, '-c', {descendant_code!r}])
    while not pathlib.Path({str(descendant)!r}).exists(): time.sleep(0.01)
    pathlib.Path({str(ready)!r}).write_text(str(os.getpid()))
    time.sleep(60)
""")
            executable.chmod(0o755)
            results = root / "results"
            process = subprocess.Popen([sys.executable, str(SCRIPT), "--only-testing", "GitLabTodosTests/FixtureTests", "--results-dir", str(results)],
                                       env=dict(os.environ, PATH=f"{root}:{os.environ['PATH']}"),
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                time.sleep(0.05)
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=15), 143)
                report = json.loads(next(results.glob("run-*/report.json")).read_text())
                self.assertEqual(report["exit_code"], 143)
                self.assertIn("interrupt", report["error"].lower())
                self.assertEqual(list(results.glob("test-home-*")), [])
                deadline = time.monotonic() + 2
                while self.pid_exists(int(descendant.read_text())) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(self.pid_exists(int(descendant.read_text())))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                if ready.exists():
                    try:
                        os.kill(int(ready.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if descendant.exists():
                    try:
                        os.kill(int(descendant.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    @staticmethod
    def pid_exists(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def test_unowned_results_directory_cannot_lose_its_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            derived = root / "DerivedData"
            derived.mkdir()
            important = derived / "keep.txt"
            important.write_text("unowned build")
            result = subprocess.run([sys.executable, str(SCRIPT), "--only-testing", "GitLabTodosTests/FixtureTests", "--results-dir", str(root)],
                                    env=dict(os.environ, PATH=str(root)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(important.read_text(), "unowned build")

    def test_phase_timeout_stops_a_hung_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.runner.run_phase([sys.executable, "-c", "import time; time.sleep(60)"],
                                           dict(os.environ), Path(temporary) / "phase.log", timeout=0.1)
            self.assertEqual(result["exit_code"], 124)
            self.assertLess(result["seconds"], 5)
            self.assertIn("timed out", result["error"])

    def test_retention_keeps_all_bundles_below_the_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index in range(3):
                run = root / f"run-{index}"
                run.mkdir()
                (run / "report.json").write_text("{}")
                (run / "Tests.xcresult").mkdir()
            self.runner.prune_results(root, keep_reports=10, keep_bundles=5)
            self.assertEqual(len(list(root.glob("run-*/Tests.xcresult"))), 3)


if __name__ == "__main__":
    unittest.main()
