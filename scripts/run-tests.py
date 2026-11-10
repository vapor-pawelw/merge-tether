#!/usr/bin/env python3
"""Verify affected changes by default; use --full for all repository tests."""

import argparse
from collections import Counter
import csv
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


class RunInterrupted(KeyboardInterrupt):
    def __init__(self, signal_number):
        self.signal_number = signal_number


def interrupt_run(signal_number, _frame):
    raise RunInterrupted(signal_number)


@contextmanager
def uninterrupted_cleanup():
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {number: signal.getsignal(number) for number in signals}
    try:
        for number in signals:
            signal.signal(number, signal.SIG_IGN)
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def test_timings(log):
    """Measure Xcode's diagnostic event timestamps; its duration fields lose fractions."""
    rows, pending, executions = [], {}, {}
    pattern = re.compile(
        r"^(\d\d):(\d\d):(\d\d\.\d+) .* _XCT_"
        r"(testCaseDidStartWithIdentifier|testCaseWithIdentifier):(<XCTTestIdentifier .*?>)"
        r"(?:testCaseRunConfiguration:| didFinishWithStatus:(\w+) duration:)")
    day, previous = 0, 0
    for line in log.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        hour, minute, second, kind, identity, status = match.groups()
        timestamp = int(hour) * 3600 + int(minute) * 60 + float(second)
        if timestamp < previous - 12 * 3600:
            day += 24 * 3600
        previous = timestamp
        timestamp += day
        if kind == "testCaseDidStartWithIdentifier" or not pending.get(identity):
            parts, end = json.JSONDecoder().raw_decode(identity[len("<XCTTestIdentifier leaf "):])
            test_id = "/".join(parts)
            arguments = identity[len("<XCTTestIdentifier leaf ") + end:].strip().rstrip(">")
            identity_key = (test_id, arguments)
            executions[identity_key] = executions.get(identity_key, 0) + 1
            occurrence = executions[identity_key]
            case_key = hashlib.sha256(json.dumps([test_id, arguments, occurrence]).encode()).hexdigest()
            row = dict(test_id=test_id, suite="/".join(parts[:-1]),
                       path=f"{test_id} / occurrence {occurrence} {arguments}".rstrip(), case_key=case_key,
                       argument_identity=arguments, result="incomplete", seconds=None, ambiguous=bool(pending.get(identity)))
            rows.append(row)
            if kind == "testCaseDidStartWithIdentifier":
                for _, previous_row in pending.get(identity, []):
                    previous_row["ambiguous"] = True
                pending.setdefault(identity, []).append((timestamp, row))
                continue
        else:
            started, row = pending[identity].pop(0)
            row["seconds"] = round(timestamp - started, 6)
        row["result"] = status
    return rows


def prune_results(root, keep_reports, keep_bundles):
    # Only directories completed by this runner participate in retention.
    runs = sorted(p for p in root.glob("run-*") if p.is_dir() and not p.is_symlink()
                  and (p / "report.json").is_file())
    for run in runs[:-keep_reports]:
        shutil.rmtree(run)
    bundles = [p / "Tests.xcresult" for p in runs[-keep_reports:] if (p / "Tests.xcresult").exists()]
    for bundle in bundles[:max(0, len(bundles) - keep_bundles)]:
        shutil.rmtree(bundle)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n")


def execution_spans(log):
    return [float(value) for value in re.findall(
        r"Test run with \d+ tests?[^\n]*? (?:passed|failed) after ([\d.]+) seconds?", log)]


def export_results(bundle, run, metadata):
    raw = {}
    for name in ("summary", "tests"):
        output = subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", name, "--path", str(bundle)], text=True, timeout=30)
        raw[name] = json.loads(output)
        write_json(run / f"{name}.json", raw[name])
    rows = []
    with tempfile.TemporaryDirectory(prefix="diagnostics-", dir=run) as temporary:
        subprocess.run(["xcrun", "xcresulttool", "export", "diagnostics", "--path", str(bundle),
                        "--output-path", temporary], check=True, stdout=subprocess.DEVNULL, timeout=30)
        for index, session in enumerate(sorted(Path(temporary).rglob("Session-*.log"))):
            with session.open("rb") as source, gzip.open(run / f"session-{index}.log.gz", "wb") as target:
                shutil.copyfileobj(source, target)
            for row in test_timings(session.read_text(errors="replace")):
                row["session"] = index
                rows.append(row)
    with (run / "timings.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=["session", "case_key", "test_id", "suite", "path", "argument_identity",
                                                   "result", "seconds", "ambiguous"])
        writer.writeheader()
        writer.writerows(rows)
    measured = [row for row in rows if row["seconds"] is not None]
    missing = [row["path"] for row in rows if row["seconds"] is None and row["result"] != "skipped"]
    metadata.update(timing_rows=len(rows), missing_durations=missing,
                    ambiguous_timings=sum(row["ambiguous"] for row in rows),
                    summed_test_seconds=sum(row["seconds"] for row in measured),
                    timing_source="Xcode diagnostic event receipt timestamps (millisecond resolution)")
    identities = Counter((row["test_id"], row["argument_identity"]) for row in rows)
    metadata["repeated_identity_groups"] = sum(count > 1 for count in identities.values())
    spans = execution_spans((run / "test.log").read_text(errors="replace"))
    metadata["swift_testing_spans_seconds"] = spans
    if len(spans) == 1:
        metadata["runner_overhead_seconds"] = metadata["phases"]["test"]["seconds"] - spans[0]
    summary = raw["summary"]
    if "startTime" in summary and "finishTime" in summary:
        metadata["xcresult_elapsed_seconds"] = summary["finishTime"] - summary["startTime"]
    suites = {}
    for row in measured:
        suites[row["suite"]] = suites.get(row["suite"], 0) + row["seconds"]
    lines = [f"Result: {summary.get('result', 'unknown')}; "
             f"passed: {summary.get('passedTests', 0)}, failed: {summary.get('failedTests', 0)}, "
             f"skipped: {summary.get('skippedTests', 0)}",
             f"Timing rows: {len(rows)}; missing non-skipped durations: {len(missing)}"]
    lines += [f"{name}: {phase['seconds']:.3f}s (exit {phase['exit_code']})"
              for name, phase in metadata["phases"].items()]
    lines += [f"Derived Data existed before run: {metadata.get('derived_data_preexisting', 'unknown')}"]
    if len(spans) == 1:
        lines += [f"Swift Testing execution: {spans[0]:.3f}s; "
                  f"test-command overhead: {metadata['runner_overhead_seconds']:.3f}s"]
    lines += [f"Summed case time: {metadata['summed_test_seconds']:.3f}s "
              "(overlapping tests; not wall clock)", "", "Slowest executions:"]
    lines += [f"{row['seconds']:9.3f}s  {row['path']}" for row in
              sorted(measured, key=lambda row: row["seconds"], reverse=True)[:20]]
    lines += ["", "Suites by summed case time (overlaps included):"]
    lines += [f"{seconds:9.3f}s  {suite}" for suite, seconds in
              sorted(suites.items(), key=lambda item: item[1], reverse=True)[:20]]
    (run / "summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines), flush=True)
    configurations = summary.get("devicesAndConfigurations", [])
    expected = sum(configuration.get(key, 0) for configuration in configurations
                   for key in ("passedTests", "failedTests", "skippedTests", "expectedFailures"))
    metadata["expected_execution_count"] = expected
    if not rows or missing or metadata["ambiguous_timings"] or not configurations or len(rows) != expected:
        raise RuntimeError("Incomplete timing export; inspect tests.json and the retained result bundle")


def stop_child(process):
    with uninterrupted_cleanup():
        try:
            for termination_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
                if process.poll() is not None:
                    return
                try:
                    os.killpg(process.pid, termination_signal)
                except ProcessLookupError:
                    return
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    continue
        finally:
            # A compiler/fixture descendant can outlive the group leader.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def run_phase(command, environment, log, timeout):
    print(f"Running {command[-1]}; log: {log}", flush=True)
    start = time.monotonic()
    error = None
    with log.open("w") as stream:
        process = subprocess.Popen(command, env=environment, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except KeyboardInterrupt as interruption:
            stop_child(process)
            code = 128 + getattr(interruption, "signal_number", signal.SIGINT)
            error = "Phase interrupted"
        except subprocess.TimeoutExpired:
            stop_child(process)
            code, error = 124, f"Phase timed out after {timeout}s"
    return dict(seconds=time.monotonic() - start, exit_code=code, command=command, error=error)


def main():
    from test_selection import full_plan, plan_changes

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", type=Path, default=Path(__file__).resolve().parents[1] / ".test-results",
                        help="Owned results/build directory (default: .test-results)")
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--only-testing", action="append", default=[], metavar="TEST_ID",
                        help="Xcode test identifier; repeat for multiple suites/cases")
    scope.add_argument("--full", action="store_true", help="Run all app, helper, tooling, remote-package and legacy-plugin tests")
    scope.add_argument("--build-only", action="store_true", help="Build the app only; for verified presentation-only changes")
    parser.add_argument("--base", help="Compare against the merge base with this Git ref (default: main, or HEAD^ on main)")
    parser.add_argument("--plan", action="store_true", help="Print the selected checks as JSON without building or creating results")
    parser.add_argument("--keep-reports", type=int, default=10, help="Retain latest N compact reports (default: 10)")
    parser.add_argument("--keep-bundles", type=int, default=2, help="Retain latest N xcresult bundles (default: 2)")
    parser.add_argument("--reuse-build", action="store_true", help="Keep owned Derived Data for incremental runs")
    parser.add_argument("--build-timeout", type=float, default=600, help="Build deadline in seconds (default: 600)")
    parser.add_argument("--test-timeout", type=float, default=1200, help="Test deadline in seconds (default: 1200)")
    args = parser.parse_args()
    if args.keep_reports < 1 or not 0 <= args.keep_bundles <= args.keep_reports:
        parser.error("require keep-reports >= 1 and 0 <= keep-bundles <= keep-reports")
    if args.build_timeout <= 0 or args.test_timeout <= 0:
        parser.error("phase timeouts must be positive")
    repo = Path(__file__).resolve().parents[1]
    if args.full:
        args.selection = full_plan([], "Explicit --full verification")
    elif args.only_testing or args.build_only:
        args.selection = dict(mode="targeted" if args.only_testing else "build", suites=args.only_testing,
                              tasks=[], paths=[], reasons=["Explicit manual scope; verify affected callers too"])
    else:
        args.selection = plan_changes(repo, args.base)
        args.only_testing = args.selection["suites"]
    if args.plan:
        print(json.dumps(args.selection, indent=2))
        return 0
    print("Verification: " + args.selection["mode"], flush=True)
    for reason in args.selection["reasons"]:
        print("  " + reason, flush=True)
    if args.only_testing:
        print("  Suites: " + ", ".join(args.only_testing), flush=True)
    for handled_signal in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(handled_signal, interrupt_run)
    root = args.results_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error(f"Another test run owns {root}")
        ownership = root / ".mergetether-test-results"
        if ownership.is_file() and not ownership.is_symlink():
            if ownership.read_text() != "MergeTether test results v1\n":
                parser.error(f"Unrecognized results ownership marker in {root}")
        elif any(path.name != ".lock" for path in root.iterdir()):
            parser.error(f"Results directory is not owned by this runner: {root}; choose an empty directory")
        else:
            ownership.write_text("MergeTether test results v1\n")
        return run_tests(args, root)


def run_tests(args, root):
    repo = Path(__file__).resolve().parents[1]
    os.chdir(repo)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    run = root / f"run-{stamp}"
    run.mkdir()
    derived = root / "DerivedData"
    bundle = run / "Tests.xcresult"
    metadata = dict(started_at=stamp, phases={}, only_testing=args.only_testing, selection=args.selection,
                    derived_data_preexisting=derived.exists(), reuse_build_requested=args.reuse_build)
    start = time.monotonic()
    code = 1
    try:
        metadata["commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True, timeout=30).strip()
        metadata["dirty"] = bool(subprocess.check_output(["git", "status", "--porcelain"], timeout=30))
        metadata["worktree_diff_sha256"] = hashlib.sha256(
            subprocess.check_output(["git", "diff", "HEAD", "--binary"], timeout=30)).hexdigest()
        metadata["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        untracked = [os.fsdecode(name) for name in subprocess.check_output(
            ["git", "ls-files", "--others", "--exclude-standard", "-z"], timeout=30).split(b"\0") if name]
        metadata["untracked_directories"] = [name for name in untracked if Path(name).is_dir() and not Path(name).is_symlink()]
        metadata["untracked_sha256"] = {name: hashlib.sha256(
            os.fsencode(os.readlink(name)) if Path(name).is_symlink() else Path(name).read_bytes()).hexdigest()
            for name in untracked if not Path(name).is_dir() or Path(name).is_symlink()}
        project = repo / "GitLabTodos.xcodeproj/project.pbxproj"
        metadata["generated_project_sha256"] = hashlib.sha256(project.read_bytes()).hexdigest() if project.exists() else None
        metadata["tuist_requirement"] = (repo / "mise.toml").read_text().strip()
        if args.selection["mode"] != "none" or "remote" in args.selection["tasks"]:
            metadata["xcode"] = subprocess.check_output(["xcodebuild", "-version"], text=True, timeout=30).strip()
        with tempfile.TemporaryDirectory(prefix="test-home-", dir=root) as home:
            (Path(home) / ".mergetether-test-home").write_text("MergeTether test home\n")
            environment = dict(os.environ, TEST_RUNNER_HOME=home, TEST_RUNNER_CFFIXED_USER_HOME=home,
                               TEST_RUNNER_MERGETETHER_TEST_FIXTURE_HOME=home)
            helper_environment = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home, PYTHONDONTWRITEBYTECODE="1")
            task_commands = {
                "tools": ([sys.executable, "-m", "unittest", "discover", "-s", "Tests/TestTools"], ""),
                "helpers": ([sys.executable, "-m", "unittest", "discover", "-s", "Tests/AutomationHelpers"], "Helpers/Automation"),
                "legacy": ([sys.executable, "-m", "unittest", "discover", "-s", "plugins/merge-tether/tests"], "plugins/merge-tether"),
                "remote": (["swift", "test", "--package-path", "Packages/MergeTetherRemote",
                            "--scratch-path", str(root / "RemoteBuild")], ""),
            }
            code = 0
            for task in args.selection["tasks"]:
                command, python_path = task_commands[task]
                task_environment = dict(helper_environment, PYTHONPATH=str(repo / python_path))
                metadata["phases"][task] = run_phase(command, task_environment, run / f"{task}.log", args.test_timeout)
                code = metadata["phases"][task]["exit_code"]
                if metadata["phases"][task]["error"]:
                    metadata["error"] = metadata["phases"][task]["error"]
                if code:
                    break
            if code:
                return code
            base = ["xcodebuild", "-project", str(repo / "GitLabTodos.xcodeproj"), "-scheme", "GitLabTodos",
                    "-configuration", "Debug", "-destination", "platform=macOS", "-derivedDataPath", str(derived),
                    "-parallel-testing-enabled", "NO"]
            actions = [] if args.selection["mode"] == "none" else [("build", "build-for-testing"), ("test", "test-without-building")]
            if args.selection["mode"] == "build":
                actions = [("build", "build")]
            for phase, action in actions:
                command = base[:]
                if phase == "test":
                    command += ["-resultBundlePath", str(bundle)]
                    command += [f"-only-testing:{identifier}" for identifier in args.only_testing]
                command.append(action)
                code = 1
                timeout = args.build_timeout if phase == "build" else args.test_timeout
                metadata["phases"][phase] = run_phase(command, environment, run / f"{phase}.log", timeout)
                code = metadata["phases"][phase]["exit_code"]
                if metadata["phases"][phase]["error"]:
                    metadata["error"] = metadata["phases"][phase]["error"]
                if phase == "test":
                    rejected = [line for line in (run / "test.log").read_text(errors="replace").splitlines()
                                if "MergeTether test guard rejected service CLI" in line]
                    if rejected:
                        code = code or 1
                        metadata["guard_rejections"] = rejected
                        metadata["error"] = "Test host attempted an installed service CLI; use a fixture executable"
                        print(metadata["error"], file=sys.stderr)
                if code:
                    break
        if bundle.exists():
            command_code = code
            code = code or 1
            export_results(bundle, run, metadata)
            code = command_code
        elif code == 0 and args.selection["mode"] in {"full", "targeted"}:
            raise RuntimeError("xcodebuild produced no result bundle")
    except KeyboardInterrupt as interruption:
        code = 128 + getattr(interruption, "signal_number", signal.SIGINT)
        metadata["error"] = "Run interrupted"
    except Exception as error:
        metadata.setdefault("error", str(error))
        print(f"Test reporting failed: {error}", file=sys.stderr)
        code = code or 1
    finally:
        with uninterrupted_cleanup():
            metadata["wall_seconds"] = time.monotonic() - start
            metadata["exit_code"] = code
            for log in run.glob("*.log"):
                with log.open("rb") as source, gzip.open(str(log) + ".gz", "wb") as target:
                    shutil.copyfileobj(source, target)
                log.unlink()
            write_json(run / "report.json", metadata)
            prune_results(root, args.keep_reports, args.keep_bundles)
            if not args.reuse_build and derived.exists():
                shutil.rmtree(derived)
            if not args.reuse_build and (root / "RemoteBuild").exists():
                shutil.rmtree(root / "RemoteBuild")
            print(f"Reports: {run}\nWall time (including export): {metadata['wall_seconds']:.3f}s", flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
