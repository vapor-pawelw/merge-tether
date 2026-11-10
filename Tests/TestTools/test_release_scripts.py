import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[2]


class ReleaseScriptFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mergetether-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "scripts").mkdir()
        for name in ["build-release.sh", "release-interactive.sh"]:
            shutil.copyfile(REPO / "scripts" / name, self.root / "scripts" / name)
        shutil.copyfile(REPO / "Project.swift", self.root / "Project.swift")
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", HOME=str(self.root),
                        TMPDIR=str(self.root), PYTHONDONTWRITEBYTECODE="1",
                        GITLABTODOS_RELEASE_REPO="fixture/release",
                        GITLABTODOS_HOMEBREW_TAP_REPO="")

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def run_script(self, name, *arguments):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *arguments],
                              cwd=self.root, env=self.env, capture_output=True, text=True, timeout=20)


@unittest.skipUnless(Path("/usr/libexec/PlistBuddy").exists() and Path("/usr/bin/ditto").exists(),
                     "Release app staging uses macOS plist and ZIP tools")
class ReleaseBuildTests(ReleaseScriptFixture):
    def setUp(self):
        super().setUp()
        self.executable("tuist", "")
        self.executable("xcodebuild", """
import pathlib, plistlib, re, sys
args = sys.argv[1:]
assert 'CODE_SIGNING_ALLOWED=NO' in args and 'CODE_SIGNING_REQUIRED=NO' in args
assert 'CODE_SIGN_IDENTITY=' in args
source = pathlib.Path('Project.swift').read_text()
def literal(key):
    return re.search(r'"' + key + r'": \\.string\\("([^"\\n]+)"\\)', source).group(1)
app = pathlib.Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Release/GitLabTodos.app'
(app / 'Contents').mkdir(parents=True)
info = {'CFBundleShortVersionString': literal('CFBundleShortVersionString'),
        'CFBundleVersion': literal('CFBundleVersion'), 'CFBundleIdentifier': 'com.vaporpw.GitLabTodos',
        'LSMinimumSystemVersion': '14.0'}
if pathlib.Path('missing-version').exists():
    del info['CFBundleShortVersionString']
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
""")
        # The DMG command records the actual staged bundle handed to the packager.
        self.executable("hdiutil", """
import json, pathlib, plistlib, sys
args = sys.argv[1:]
app = pathlib.Path(args[args.index('-srcfolder') + 1])
pathlib.Path(args[-1]).write_text(json.dumps(plistlib.loads((app / 'Contents/Info.plist').read_bytes())))
""")

    def packaged_info(self, version):
        release = self.root / "release"
        with zipfile.ZipFile(release / f"GitLabTodos-{version}.zip") as archive:
            info = plistlib.loads(archive.read("GitLabTodos.app/Contents/Info.plist"))
        self.assertEqual(info, json.loads((release / f"GitLabTodos-{version}.dmg").read_text()))
        self.assertEqual(info["CFBundleIdentifier"], "com.vaporpw.GitLabTodos")
        self.assertEqual(info["LSMinimumSystemVersion"], "14.0")
        return info

    def test_default_keeps_project_version_and_build_number(self):
        original = (self.root / "Project.swift").read_bytes()
        version = re.search(r'"CFBundleShortVersionString": \.string\("([^"]+)"\)',
                            original.decode()).group(1)
        result = self.run_script("build-release.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.packaged_info(version)["CFBundleShortVersionString"], version)
        self.assertEqual(self.packaged_info(version)["CFBundleVersion"], "1")
        self.assertEqual((self.root / "Project.swift").read_bytes(), original)
        self.assertFalse((self.root / "build").exists())

    def test_explicit_version_reaches_packaged_bundle_without_editing_project(self):
        original = (self.root / "Project.swift").read_bytes()
        result = self.run_script("build-release.sh", "9.8.7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.packaged_info("9.8.7")["CFBundleShortVersionString"], "9.8.7")
        self.assertEqual(self.packaged_info("9.8.7")["CFBundleVersion"], "1")
        self.assertEqual((self.root / "Project.swift").read_bytes(), original)

    def test_missing_bundle_version_stops_packaging(self):
        (self.root / "missing-version").touch()
        result = self.run_script("build-release.sh", "9.8.7")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(list((self.root / "release").glob("*.zip")))
        self.assertFalse(list((self.root / "release").glob("*.dmg")))

    def test_existing_ci_injection_keeps_its_version_and_build_number(self):
        workflow = (REPO / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Inject version into Project.swift\n", 1)[1]
        commands = step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
        commands = "\n".join(line[10:] for line in commands.splitlines())
        commands = commands.replace("${{ steps.version.outputs.version }}", "9.8.7")
        commands = commands.replace("${{ github.run_number }}", "456")
        injection = subprocess.run(["/bin/bash", "-e", "-c", commands], cwd=self.root,
                                   env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(injection.returncode, 0, injection.stdout + injection.stderr)
        result = self.run_script("build-release.sh", "9.8.7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = self.packaged_info("9.8.7")
        self.assertEqual(info["CFBundleShortVersionString"], "9.8.7")
        self.assertEqual(info["CFBundleVersion"], "456")


class ReleasePublicationTests(ReleaseScriptFixture):
    def setUp(self):
        super().setUp()
        (self.root / "CHANGELOG.md").write_text("## Unreleased\n\n- A release fixture.\n\n## 1.1.0\n")
        self.executable("git", """
import json, pathlib, sys
a = sys.argv[1:]
with pathlib.Path('git-calls.jsonl').open('a') as f: f.write(json.dumps(a) + '\\n')
if a == ['config', '--get', 'remote.origin.url']: print('https://github.com/fixture/source.git')
elif a == ['rev-parse', '--git-dir']: print('.git-fixture')
elif a == ['branch', '--show-current']: print('main')
elif a == ['tag', '--sort=-v:refname']: print('v1.1.0')
elif a == ['rev-parse', '--short', 'HEAD']: print('abc123')
elif a == ['rev-parse', 'v9.8.7']: sys.exit(1)
elif a[:3] == ['diff', '--cached', '--quiet']: sys.exit(1)
elif a == ['status', '--porcelain'] or a[:1] == ['ls-remote']: pass
elif a[:1] in [['add'], ['commit'], ['push']] or a[:2] == ['tag', '-a']: pass
else: sys.exit('unexpected git fixture call: ' + repr(a))
""")
        self.executable("gh", """
import json, os, pathlib, sys
a = sys.argv[1:]
with pathlib.Path('gh-calls.jsonl').open('a') as f: f.write(json.dumps(a) + '\\n')
if a == ['auth', 'status']: pass
elif a[:1] == ['api']:
    mode = os.environ.get('WORKFLOW_MODE', 'ok')
    if mode == 'api_failure': sys.exit(1)
    total = a[-1] == '.total_count'
    print(0 if mode == 'no_workflows' or (mode == 'missing_release' and not total) else 1)
elif a[:2] == ['run', 'list']: print('42')
elif a[:2] == ['run', 'watch']: sys.exit(1 if os.environ.get('WATCH_FAIL') else 0)
elif a[:2] == ['release', 'view']:
    if a[-1] == '.assets[].name':
        if os.environ.get('ASSET_ERROR'): sys.exit(1)
        assets = os.environ.get('ASSETS', 'GitLabTodos.dmg,GitLabTodos.zip')
        print(assets.replace(',', '\\n'))
    elif a[-1] == '.url': print('https://github.com/fixture/release/releases/tag/v9.8.7')
    else: sys.exit('unexpected release fixture call')
else: sys.exit('unexpected gh fixture call: ' + repr(a))
""")

    def publish(self):
        return self.run_script("release-interactive.sh", "--version", "9.8.7", "--yes")

    def calls(self, tool):
        return [json.loads(line) for line in (self.root / f"{tool}-calls.jsonl").read_text().splitlines()]

    def test_success_requires_workflow_and_both_release_assets(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["push", "origin", "main"], self.calls("git"))
        self.assertIn(["push", "origin", "v9.8.7"], self.calls("git"))
        self.assertTrue(any(a[:2] == ["run", "watch"] for a in self.calls("gh")))
        self.assertTrue(any(a[-1] == ".assets[].name" for a in self.calls("gh")))
        self.assertIn("Release complete.", result.stdout)

    def assert_workflow_incomplete(self, mode, reason):
        self.env["WORKFLOW_MODE"] = mode
        result = self.publish()
        self.assertIn(["push", "origin", "v9.8.7"], self.calls("git"))
        self.assertTrue(any(a[:1] == ["api"] for a in self.calls("gh")))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Release complete.", result.stdout)
        self.assertIn("v9.8.7", result.stderr)
        self.assertIn("gh release view", result.stderr)
        self.assertIn(reason, result.stderr)

    def test_workflow_api_failure_after_tag_push_is_incomplete(self):
        self.assert_workflow_incomplete("api_failure", "Could not query GitHub Actions workflows")

    def test_no_workflows_after_tag_push_is_incomplete(self):
        self.assert_workflow_incomplete("no_workflows", "No GitHub Actions workflows are configured")

    def test_missing_release_workflow_after_tag_push_is_incomplete(self):
        self.assert_workflow_incomplete("missing_release", "Workflow 'Release' is not configured")

    def test_missing_zip_is_not_a_successful_release(self):
        self.env["ASSETS"] = "GitLabTodos.dmg"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Release complete.", result.stdout)

    def test_missing_dmg_is_not_a_successful_release(self):
        self.env["ASSETS"] = "GitLabTodos.zip"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Release complete.", result.stdout)

    def test_asset_read_failure_is_not_a_successful_release(self):
        self.env["ASSET_ERROR"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Release complete.", result.stdout)

    def test_versioned_assets_remain_supported(self):
        self.env["ASSETS"] = "GitLabTodos-9.8.7.dmg,GitLabTodos-9.8.7.zip"
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Release complete.", result.stdout)

    def test_failed_workflow_is_not_a_successful_release(self):
        self.env["WATCH_FAIL"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(a[-1] == ".assets[].name" for a in self.calls("gh")))


if __name__ == "__main__":
    unittest.main()
