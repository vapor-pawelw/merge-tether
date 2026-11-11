import json
import hashlib
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
        for name in ["build-release.sh", "release-interactive.sh", "sync-version-from-tag.sh"]:
            shutil.copyfile(REPO / "scripts" / name, self.root / "scripts" / name)
        shutil.copyfile(REPO / "Project.swift", self.root / "Project.swift")
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", HOME=str(self.root),
                        TMPDIR=str(self.root), PYTHONDONTWRITEBYTECODE="1",
                        GITLABTODOS_RELEASE_REPO="fixture/release",
                        GITLABTODOS_HOMEBREW_TAP_REPO="", TUIST_MERGETETHER_RELAY_CONFIG_FILE="")

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def run_script(self, name, *arguments):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *arguments],
                              cwd=self.root, env=self.env, capture_output=True, text=True, timeout=20)


class ReleaseBuildTests(ReleaseScriptFixture):
    def setUp(self):
        super().setUp()
        self.executable("tuist", """
import os, pathlib
path = os.environ.get('TUIST_MERGETETHER_RELAY_CONFIG_FILE', '')
if path: pathlib.Path('generated-relay-config-path').write_text(path)
""")
        relay_config = tempfile.NamedTemporaryFile(prefix="mergetether-relay-", suffix=".json", delete=False)
        self.relay_config = Path(relay_config.name)
        relay_config.close()
        self.relay_config.write_text(json.dumps({"origin": "https://private-relay.example.test"}))
        self.addCleanup(self.relay_config.unlink, missing_ok=True)
        self.executable("security", """
print('  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (TEAM123)"')
print('  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Distribution: Fixture (TEAM123)"')
""")
        self.executable("xcodebuild", """
import json, os, pathlib, plistlib, sys, zipfile
args = sys.argv[1:]
with pathlib.Path('build-calls.jsonl').open('a') as f: f.write(json.dumps(args) + '\\n')
if '-exportArchive' in args:
    app = pathlib.Path(args[args.index('-archivePath') + 1]) / 'Products/Applications/MergeTetheriOS.app'
    output = pathlib.Path(args[args.index('-exportPath') + 1]); output.mkdir()
    if os.environ.get('NO_IPA'): sys.exit(0)
    with zipfile.ZipFile(output / 'MergeTetheriOS.ipa', 'w') as archive:
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if os.environ.get('EXPORTED_WRONG_VERSION'): info['CFBundleShortVersionString'] = '0.1.0'
        archive.writestr('Payload/MergeTetheriOS.app/Info.plist', plistlib.dumps(info))
    sys.exit(0)
settings = dict(a.split('=', 1) for a in args if '=' in a and not a.startswith('platform='))
ios = args[args.index('-scheme') + 1] == 'MergeTetheriOS'
if 'archive' in args:
    app = pathlib.Path(args[args.index('-archivePath') + 1]) / 'Products/Applications/MergeTetheriOS.app'
elif ios:
    app = pathlib.Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Release-iphoneos/MergeTetheriOS.app'
else:
    app = pathlib.Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Release/GitLabTodos.app'
info_path = app / ('Info.plist' if ios else 'Contents/Info.plist')
info_path.parent.mkdir(parents=True)
info = {'CFBundleShortVersionString': settings['MARKETING_VERSION'],
        'CFBundleVersion': settings['CURRENT_PROJECT_VERSION'],
        'CFBundleIdentifier': 'com.vaporpw.MergeTether.iOS' if ios else 'com.vaporpw.GitLabTodos',
        'LSMinimumSystemVersion': '14.0'}
if os.environ.get('WRONG_VERSION'): info['CFBundleShortVersionString'] = '0.1.0'
if os.environ.get('WRONG_BUILD'): info['CFBundleVersion'] = '1'
info_path.write_bytes(plistlib.dumps(info))
""")
        self.executable("ditto", """
import pathlib, sys, zipfile
app, output = pathlib.Path(sys.argv[-2]), pathlib.Path(sys.argv[-1])
if '-x' in sys.argv:
    with zipfile.ZipFile(app) as archive: archive.extractall(output)
else:
    with zipfile.ZipFile(output, 'w') as archive:
        for path in app.rglob('*'):
            if path.is_file(): archive.write(path, str(path.relative_to(app.parent)))
""")
        self.executable("hdiutil", """
import json, pathlib, plistlib, sys
args = sys.argv[1:]
app = pathlib.Path(args[args.index('-srcfolder') + 1])
pathlib.Path(args[-1]).write_text(json.dumps(plistlib.loads((app / 'Contents/Info.plist').read_bytes())))
""")
        self.executable("codesign", """
import os, sys
if os.environ.get('SIGNATURE_FAIL'): sys.exit(1)
if '--display' in sys.argv:
    print('Authority=' + ('Apple Distribution' if 'MergeTetheriOS.app' in sys.argv[-1] else 'Developer ID Application') + ': Fixture (TEAM123)', file=sys.stderr)
    print('TeamIdentifier=' + ('OTHER' if os.environ.get('WRONG_TEAM') else 'TEAM123'), file=sys.stderr)
    print('flags=0x10000(runtime)', file=sys.stderr)
    if not os.environ.get('MISSING_TIMESTAMP'): print('Timestamp=Nov 11, 2026', file=sys.stderr)
""")
        self.executable("spctl", "import os, sys; sys.exit(1 if os.environ.get('GATEKEEPER_FAIL') else 0)")
        self.executable("xcrun", """
import json, os, pathlib, sys
with pathlib.Path('notary-calls.jsonl').open('a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
if 'history' in sys.argv and os.environ.get('NOTARY_CREDENTIAL_FAIL'): sys.exit(1)
if 'submit' in sys.argv and os.environ.get('NOTARY_SUBMIT_FAIL'): sys.exit(1)
if 'submit' in sys.argv: print(json.dumps({'status': os.environ.get('NOTARY_STATUS', 'Accepted')}))
if os.environ.get('STAPLE_FAIL') and 'stapler' in sys.argv: sys.exit(1)
""")

    def packaged_info(self, version, unsigned=False):
        release = self.root / "release" / ("unsigned" if unsigned else "")
        with zipfile.ZipFile(release / f"GitLabTodos-{version}.zip") as archive:
            info = plistlib.loads(archive.read("GitLabTodos.app/Contents/Info.plist"))
        self.assertEqual(info, json.loads((release / f"GitLabTodos-{version}.dmg").read_text()))
        self.assertEqual(info["CFBundleIdentifier"], "com.vaporpw.GitLabTodos")
        self.assertEqual(info["LSMinimumSystemVersion"], "14.0")
        return info

    def signed_build(self, *arguments):
        return self.run_script("build-release.sh", "9.8.7", "--build-number", "456", "--relay-config", str(self.relay_config),
                               "--signing-identity", "Developer ID Application: Fixture (TEAM123)",
                               "--team-id", "TEAM123", "--notary-profile", "fixture-notary", *arguments)

    def test_unsigned_is_explicit_and_segregated_with_shared_metadata(self):
        original = (self.root / "Project.swift").read_bytes()
        result = self.run_script("build-release.sh", "9.8.7", "--build-number", "456", "--unsigned")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        info = self.packaged_info("9.8.7", unsigned=True)
        self.assertEqual(info["CFBundleShortVersionString"], "9.8.7")
        self.assertEqual(info["CFBundleVersion"], "456")
        self.assertEqual((self.root / "Project.swift").read_bytes(), original)
        self.assertFalse(list((self.root / "release").glob("*.zip")))
        manifest = json.loads((self.root / "release/unsigned/release-manifest.json").read_text())
        self.assertFalse(manifest["distributable"])
        self.assertEqual(len(manifest["artifacts"]), 2)

    def test_signed_release_verifies_notarization_and_artifact_inventory(self):
        result = self.signed_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.packaged_info("9.8.7")["CFBundleVersion"], "456")
        manifest = json.loads((self.root / "release/release-manifest.json").read_text())
        self.assertTrue(manifest["distributable"])
        self.assertEqual(manifest["version"], "9.8.7")
        self.assertEqual(manifest["build"], "456")
        self.assertEqual(len(manifest["artifacts"]), 2)
        for artifact in manifest["artifacts"]:
            path = self.root / "release" / artifact["name"]
            self.assertTrue(path.is_file())
            self.assertTrue(path.with_suffix(path.suffix + ".sha256").is_file())
        calls = [json.loads(line) for line in (self.root / "notary-calls.jsonl").read_text().splitlines()]
        self.assertEqual(sum('submit' in call for call in calls), 2)
        self.assertEqual(sum('validate' in call for call in calls), 2)

    def test_default_requires_release_credentials_before_building(self):
        result = self.run_script("build-release.sh", "9.8.7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--team-id", result.stderr)
        self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_development_identity_is_rejected(self):
        result = self.run_script("build-release.sh", "9.8.7", "--signing-identity",
                                 "Apple Development: Fixture (TEAM123)", "--team-id", "TEAM123",
                                 "--notary-profile", "fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_unavailable_identity_is_rejected(self):
        self.executable("security", "print('  0 valid identities found')")
        result = self.signed_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_notary_credentials_fail_before_building(self):
        self.env["NOTARY_CREDENTIAL_FAIL"] = "1"
        result = self.signed_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_invalid_version_and_build_do_not_invoke_tools(self):
        for arguments in [("9.8.7; bad", "--unsigned"),
                          ("9.8.7", "--build-number", "0", "--unsigned")]:
            with self.subTest(arguments=arguments):
                result = self.run_script("build-release.sh", *arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_bundle_metadata_mismatch_stops_packaging(self):
        for key in ["WRONG_VERSION", "WRONG_BUILD"]:
            with self.subTest(key=key):
                self.env[key] = "1"
                result = self.signed_build()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(list((self.root / "release").glob("*.zip")))
                self.env.pop(key)

    def test_signing_notarization_and_gatekeeper_fail_closed(self):
        for key, value in [("SIGNATURE_FAIL", "1"), ("WRONG_TEAM", "1"), ("MISSING_TIMESTAMP", "1"),
                           ("NOTARY_SUBMIT_FAIL", "1"), ("NOTARY_STATUS", "Invalid"),
                           ("STAPLE_FAIL", "1"), ("GATEKEEPER_FAIL", "1")]:
            with self.subTest(key=key):
                self.env[key] = value
                result = self.signed_build()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((self.root / "release/release-manifest.json").exists())
                self.assertFalse(list((self.root / "release").glob("*.zip")))
                self.env.pop(key)

    def test_scratch_directory_is_removed_but_unrelated_build_is_preserved(self):
        (self.root / "build").mkdir()
        sentinel = self.root / "build/keep-me"
        sentinel.touch()
        result = self.run_script("build-release.sh", "--unsigned")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(sentinel.exists())
        self.assertFalse(list(self.root.glob(".release-build.*")))

    def ios_export_options(self, team="TEAM123"):
        path = self.root / "ExportOptions.plist"
        path.write_bytes(plistlib.dumps({"teamID": team, "signingStyle": "manual",
                                        "method": "release-testing",
                                        "provisioningProfiles": {"com.vaporpw.MergeTether.iOS": "Fixture Profile"}}))
        return str(path)

    def test_signed_all_has_separate_ios_distribution_export_and_three_artifacts(self):
        result = self.signed_build("--platform", "all", "--ios-signing-identity",
                                   "Apple Distribution: Fixture (TEAM123)",
                                   "--ios-export-options", self.ios_export_options())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        release = self.root / "release"
        manifest = json.loads((release / "release-manifest.json").read_text())
        self.assertEqual(len(manifest["artifacts"]), 3)
        with zipfile.ZipFile(release / "MergeTetheriOS-9.8.7.ipa") as archive:
            info = plistlib.loads(archive.read("Payload/MergeTetheriOS.app/Info.plist"))
        self.assertEqual(info["CFBundleShortVersionString"], "9.8.7")
        self.assertEqual(info["CFBundleVersion"], "456")
        calls = [json.loads(line) for line in (self.root / "build-calls.jsonl").read_text().splitlines()]
        archive = next(call for call in calls if 'archive' in call)
        self.assertIn("MERGETETHER_IOS_PROVISIONING_PROFILE=Fixture Profile", archive)
        self.assertFalse(any(arg.startswith("PROVISIONING_PROFILE_SPECIFIER=") for arg in archive))

    def test_unsigned_ios_device_zip_is_explicitly_not_installable(self):
        result = self.run_script("build-release.sh", "9.8.7", "--platform", "all", "--unsigned")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        release = self.root / "release/unsigned"
        self.assertTrue((release / "MergeTetheriOS-9.8.7-unsigned-device.zip").exists())
        self.assertFalse(list(release.glob("*.ipa")))
        self.assertIn("not installable", result.stdout)
        self.assertEqual(len(json.loads((release / "release-manifest.json").read_text())["artifacts"]), 3)

    def test_ios_wrong_export_team_fails_before_building(self):
        result = self.run_script("build-release.sh", "9.8.7", "--platform", "ios", "--relay-config", str(self.relay_config), "--team-id", "TEAM123",
                                 "--ios-signing-identity", "Apple Distribution: Fixture (TEAM123)",
                                 "--ios-export-options", self.ios_export_options(team="OTHER"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_ios_export_inventory_and_exported_metadata_are_checked(self):
        for key in ["NO_IPA", "EXPORTED_WRONG_VERSION"]:
            with self.subTest(key=key):
                self.env[key] = "1"
                result = self.run_script("build-release.sh", "9.8.7", "--platform", "ios", "--relay-config", str(self.relay_config), "--team-id", "TEAM123",
                                         "--ios-signing-identity", "Apple Distribution: Fixture (TEAM123)",
                                         "--ios-export-options", self.ios_export_options())
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(list((self.root / "release").glob("*.ipa")))
                self.env.pop(key)

    def test_ios_distribution_requires_explicit_relay_before_building(self):
        result = self.run_script("build-release.sh", "9.8.7", "--platform", "ios")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--relay-config", result.stderr)
        self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_relay_origin_file_reaches_generation_without_logging_its_value(self):
        result = self.signed_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "generated-relay-config-path").read_text(), str(self.relay_config.resolve()))
        self.assertNotIn("private-relay.example.test", result.stdout + result.stderr)
        self.assertNotIn("private-relay.example.test", (self.root / "Project.swift").read_text())

    def test_relay_config_cannot_package_credentials_or_unsafe_origins(self):
        for config in [{"origin": "https://relay.example.test", "RELAY_ACCESS_TOKEN": "fixture-private"},
                       {"origin": "https://user:fixture-private@relay.example.test"},
                       {"origin": "http://relay.example.test"}, {"origin": "https://relay.example.test/path"}]:
            with self.subTest(config=config):
                self.relay_config.write_text(json.dumps(config))
                result = self.run_script("build-release.sh", "9.8.7", "--unsigned", "--relay-config", str(self.relay_config))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("fixture-private", result.stdout + result.stderr)
                self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_both_apps_bind_shared_version_build_settings(self):
        source = (self.root / "Project.swift").read_text()
        self.assertEqual(source.count('"CFBundleShortVersionString": .string("$(MARKETING_VERSION)")'), 2)
        self.assertEqual(source.count('"CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)")'), 2)


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
elif a[:2] == ['run', 'view']: print('456')
elif a[:2] == ['release', 'view']:
    if os.environ.get('ASSET_ERROR'): sys.exit(1)
    assets = os.environ.get('ASSETS', 'GitLabTodos-9.8.7.dmg,GitLabTodos-9.8.7.zip,MergeTetheriOS-9.8.7.ipa')
    print(json.dumps({'tagName': os.environ.get('RELEASE_TAG', 'v9.8.7'),
                      'isDraft': bool(os.environ.get('RELEASE_DRAFT')),
                      'url': os.environ.get('RELEASE_URL', 'https://github.com/fixture/release/releases/tag/v9.8.7'),
                      'assets': [{'name': name, 'size': 0 if os.environ.get('EMPTY_ASSET') else 123,
                                  'url': 'https://github.com/fixture/release/releases/download/v9.8.7/' + name}
                                 for name in (assets.split(',') + ([] if os.environ.get('NO_MANIFEST') else ['release-manifest.json']))]}))
elif a[:2] == ['release', 'download']:
    if os.environ.get('NO_MANIFEST'): sys.exit(1)
    target = pathlib.Path(a[a.index('--dir') + 1]) / 'release-manifest.json'
    assets = os.environ.get('ASSETS', 'GitLabTodos-9.8.7.dmg,GitLabTodos-9.8.7.zip,MergeTetheriOS-9.8.7.ipa').split(',')
    target.write_text(json.dumps({'version': os.environ.get('MANIFEST_VERSION', '9.8.7'), 'build': os.environ.get('MANIFEST_BUILD', '456'),
                                 'distributable': not bool(os.environ.get('MANIFEST_UNSIGNED')),
                                 'artifacts': [{'name': name, 'sha256': 'a' * 64} for name in assets]}))
else: sys.exit('unexpected gh fixture call: ' + repr(a))
""")

    def publish(self):
        (self.root / "CHANGELOG.md").write_text("## Unreleased\n\n- A release fixture.\n\n## 1.1.0\n")
        for name in ["git", "gh"]:
            (self.root / f"{name}-calls.jsonl").unlink(missing_ok=True)
        return self.run_script("release-interactive.sh", "--version", "9.8.7", "--yes")

    def calls(self, tool):
        return [json.loads(line) for line in (self.root / f"{tool}-calls.jsonl").read_text().splitlines()]

    def test_success_requires_workflow_and_all_release_assets(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["push", "origin", "main"], self.calls("git"))
        self.assertIn(["push", "origin", "v9.8.7"], self.calls("git"))
        self.assertTrue(any(a[:2] == ["run", "watch"] for a in self.calls("gh")))
        self.assertTrue(any(a[:2] == ["release", "view"] for a in self.calls("gh")))
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
        self.env["ASSETS"] = "GitLabTodos-9.8.7.dmg,GitLabTodos-9.8.7.zip,MergeTetheriOS-9.8.7.ipa"
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Release complete.", result.stdout)

    def test_stable_mac_assets_with_separate_versioned_ipa_remain_supported(self):
        self.env["ASSETS"] = "GitLabTodos.dmg,GitLabTodos.zip,MergeTetheriOS-9.8.7.ipa"
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_empty_artifact_or_stale_unsigned_missing_manifest_is_incomplete(self):
        for key, value in [("EMPTY_ASSET", "1"), ("MANIFEST_VERSION", "0.1.0"),
                           ("MANIFEST_UNSIGNED", "1"), ("MANIFEST_BUILD", "455"), ("NO_MANIFEST", "1")]:
            with self.subTest(key=key):
                self.env[key] = value
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Release complete.", result.stdout)
                self.env.pop(key)

    def test_tag_pushed_but_release_absent_is_actionable_failure(self):
        self.env["ASSET_ERROR"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(["push", "origin", "v9.8.7"], self.calls("git"))
        self.assertIn("https://github.com/fixture/release/releases/tag/v9.8.7", result.stderr)
        self.assertIn("tag v9.8.7 was pushed", result.stderr)
        self.assertNotIn("Release complete.", result.stdout)

    def test_wrong_tag_draft_and_wrong_release_url_are_rejected(self):
        for key, value in [("RELEASE_TAG", "v0.1.0"), ("RELEASE_DRAFT", "1"),
                           ("RELEASE_URL", "https://github.com/other/repo/releases/tag/v9.8.7")]:
            with self.subTest(key=key):
                self.env[key] = value
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Release complete.", result.stdout)
                self.env.pop(key)

    def test_missing_ios_distribution_artifact_is_not_complete(self):
        self.env["ASSETS"] = "GitLabTodos-9.8.7.dmg,GitLabTodos-9.8.7.zip"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MergeTetheriOS-9.8.7.ipa", result.stderr)

    def test_unsigned_ios_zip_is_not_an_installable_release_artifact(self):
        self.env["ASSETS"] = "GitLabTodos-9.8.7.dmg,GitLabTodos-9.8.7.zip,MergeTetheriOS-9.8.7-unsigned-device.zip"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Release complete.", result.stdout)

    def test_noninteractive_version_is_required_before_any_git_mutation(self):
        result = self.run_script("release-interactive.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--version", result.stderr)
        self.assertFalse((self.root / "git-calls.jsonl").exists())

    def test_failed_workflow_is_not_a_successful_release(self):
        self.env["WATCH_FAIL"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(a[:2] == ["release", "view"] for a in self.calls("gh")))


class VersionSyncTests(ReleaseScriptFixture):
    def setUp(self):
        super().setUp()
        (self.root / "CHANGELOG.md").write_text("## Unreleased\n\n- A release fixture.\n")
        self.executable("git", """
import sys
if sys.argv[1:] != ['tag', '--list', 'v[0-9]*.[0-9]*.[0-9]*']: sys.exit('unexpected git mutation')
print('v1.0.0\\nv1.1.0')
""")

    def test_sync_changes_shared_defaults_and_preserves_both_bundle_bindings(self):
        result = self.run_script("sync-version-from-tag.sh", "v9.8.7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        project = (self.root / "Project.swift").read_text()
        self.assertIn('"MARKETING_VERSION": "9.8.7"', project)
        self.assertIn('"CURRENT_PROJECT_VERSION": "3"', project)
        self.assertEqual(project.count('"CFBundleShortVersionString": .string("$(MARKETING_VERSION)")'), 2)
        self.assertEqual(project.count('"CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)")'), 2)
        self.assertIn("## 9.8.7 - ", (self.root / "CHANGELOG.md").read_text())

    def test_sync_rejects_partial_version_match_before_source_mutation(self):
        original = (self.root / "Project.swift").read_bytes()
        result = self.run_script("sync-version-from-tag.sh", "v9.8.7-invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "Project.swift").read_bytes(), original)


class ReleaseWorkflowTests(ReleaseScriptFixture):
    def run_step(self, name):
        workflow = (REPO / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: " + name + "\n", 1)[1].split("\n      - name:", 1)[0]
        commands = step.split("        run: |\n", 1)[1]
        lines = []
        for line in commands.splitlines():
            if line and not line.startswith("          "):
                break
            lines.append(line[10:])
        commands = "\n".join(lines)
        return subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", commands], cwd=self.root,
                              env=self.env, capture_output=True, text=True, timeout=20)

    def test_missing_ci_distribution_configuration_fails_without_exposing_values(self):
        names = ["APPLE_CERTIFICATES_P12_BASE64", "APPLE_CERTIFICATES_PASSWORD", "IOS_PROFILE_BASE64",
                 "NOTARY_API_PRIVATE_KEY", "NOTARY_KEY_ID", "NOTARY_ISSUER_ID", "APPLE_TEAM_ID",
                 "MACOS_RELEASE_IDENTITY", "IOS_RELEASE_IDENTITY", "IOS_EXPORT_METHOD", "MERGETETHER_RELAY_CONFIG_JSON"]
        private_value = "fixture-private-value-never-log"
        for missing_name in names:
            for missing_value in [None, ""]:
                with self.subTest(name=missing_name, value=missing_value):
                    self.env.update({name: private_value for name in names})
                    if missing_value is None:
                        self.env.pop(missing_name)
                    else:
                        self.env[missing_name] = missing_value
                    result = self.run_step("Check distribution configuration")
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(missing_name, result.stdout, result.stderr)
                    self.assertNotIn(private_value, result.stdout + result.stderr)

    def test_ci_passes_metadata_and_both_platforms_without_mutating_source(self):
        self.executable("mise", """
import json, pathlib, sys
pathlib.Path('mise-arguments.json').write_text(json.dumps(sys.argv[1:]))
""")
        self.env.update(RELEASE_VERSION="9.8.7", RELEASE_BUILD_NUMBER="456", APPLE_TEAM_ID="TEAM123",
                        MACOS_RELEASE_IDENTITY="Fixture Mac", IOS_RELEASE_IDENTITY="Fixture iOS",
                        RUNNER_TEMP=str(self.root))
        original = (self.root / "Project.swift").read_bytes()
        result = self.run_step("Build separate macOS and iOS distribution artifacts")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = json.loads((self.root / "mise-arguments.json").read_text())
        self.assertEqual(args[:5], ["exec", "--", "bash", "scripts/build-release.sh", "9.8.7"])
        self.assertEqual(args[args.index("--build-number") + 1], "456")
        self.assertEqual(args[args.index("--platform") + 1], "all")
        self.assertNotIn("--unsigned", args)
        self.assertEqual(args[args.index("--relay-config") + 1], str(self.root / "relay-build.json"))
        self.assertEqual((self.root / "Project.swift").read_bytes(), original)

    def prepare_inventory(self):
        self.env.update(RELEASE_VERSION="9.8.7", RELEASE_BUILD_NUMBER="456", APP_NAME="GitLabTodos")
        release = self.root / "release"
        release.mkdir()
        artifacts = []
        for name in ["GitLabTodos-9.8.7.dmg", "GitLabTodos-9.8.7.zip", "MergeTetheriOS-9.8.7.ipa"]:
            content = ("fixture: " + name).encode()
            (release / name).write_bytes(content)
            artifacts.append({"name": name, "sha256": hashlib.sha256(content).hexdigest(),
                              "platform": "ios" if name.startswith("MergeTetheriOS") else "macos"})
        manifest = {"version": "9.8.7", "build": "456", "distributable": True, "artifacts": artifacts}
        (release / "release-manifest.json").write_text(json.dumps(manifest))
        return release, manifest

    def test_ci_stable_names_keep_matching_manifest_and_checksums(self):
        release, _ = self.prepare_inventory()
        result = self.run_step("Verify distribution inventory and retain stable macOS names")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((release / "release-manifest.json").read_text())
        self.assertEqual({a["name"] for a in manifest["artifacts"]},
                         {"GitLabTodos.dmg", "GitLabTodos.zip", "MergeTetheriOS-9.8.7.ipa"})
        for name in ["GitLabTodos.dmg", "GitLabTodos.zip"]:
            digest = hashlib.sha256((self.root / name).read_bytes()).hexdigest()
            self.assertEqual((release / (name + ".sha256")).read_text(), digest + "  " + name + "\n")

    def test_ci_rejects_unsigned_inventory_before_stable_artifacts_are_copied(self):
        release, manifest = self.prepare_inventory()
        manifest["distributable"] = False
        (release / "release-manifest.json").write_text(json.dumps(manifest))
        result = self.run_step("Verify distribution inventory and retain stable macOS names")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "GitLabTodos.dmg").exists())

    def test_ci_rejects_changed_artifact_digest(self):
        release, _ = self.prepare_inventory()
        (release / "MergeTetheriOS-9.8.7.ipa").write_bytes(b"unexpected payload")
        result = self.run_step("Verify distribution inventory and retain stable macOS names")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "GitLabTodos.dmg").exists())

    def test_ci_prepares_and_removes_only_temporary_distribution_credentials(self):
        self.env.update(RUNNER_TEMP=str(self.root), APPLE_TEAM_ID="TEAM123", IOS_EXPORT_METHOD="release-testing",
                        APPLE_CERTIFICATES_P12_BASE64="Zml4dHVyZQ==", APPLE_CERTIFICATES_PASSWORD="fixture-only",
                        NOTARY_API_PRIVATE_KEY="fixture-private-key", NOTARY_KEY_ID="fixture-id",
                        NOTARY_ISSUER_ID="fixture-issuer", MERGETETHER_RELAY_CONFIG_JSON=json.dumps({"origin": "https://relay.example.test"}))
        import base64
        profile = {"UUID": "FIXTURE-UUID", "Name": "Fixture Distribution", "TeamIdentifier": ["TEAM123"]}
        self.env["IOS_PROFILE_BASE64"] = base64.b64encode(plistlib.dumps(profile)).decode()
        self.executable("openssl", "print('fixture-random-password')")
        self.executable("security", """
import pathlib, sys
if sys.argv[1] == 'cms': sys.stdout.buffer.write(pathlib.Path(sys.argv[-1]).read_bytes())
""")
        self.executable("xcrun", "")
        result = self.run_step("Prepare temporary distribution keychain and provisioning")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        options = plistlib.loads((self.root / "ExportOptions.plist").read_bytes())
        self.assertEqual(options["teamID"], "TEAM123")
        self.assertEqual(json.loads((self.root / "relay-build.json").read_text()), {"origin": "https://relay.example.test"})
        self.assertEqual((self.root / "relay-build.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(options["provisioningProfiles"], {"com.vaporpw.MergeTether.iOS": "Fixture Distribution"})
        self.assertFalse((self.root / "notary-key.p8").exists())
        self.assertFalse((self.root / "distribution.p12").exists())
        if not Path("/usr/libexec/PlistBuddy").exists():
            return
        unrelated = self.root / "Library/MobileDevice/Provisioning Profiles/keep.mobileprovision"
        unrelated.touch()
        cleanup = self.run_step("Remove temporary distribution credentials")
        self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)
        self.assertTrue(unrelated.exists())
        self.assertFalse(unrelated.with_name("FIXTURE-UUID.mobileprovision").exists())
        self.assertFalse((self.root / "ExportOptions.plist").exists())
        self.assertFalse((self.root / "relay-build.json").exists())



if __name__ == "__main__":
    unittest.main()
