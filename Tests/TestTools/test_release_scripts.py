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
        for name in ["build-release.sh", "package-ios-ipa.sh", "release-interactive.sh", "sync-version-from-tag.sh"]:
            shutil.copyfile(REPO / "scripts" / name, self.root / "scripts" / name)
        shutil.copyfile(REPO / "Project.swift", self.root / "Project.swift")
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", HOME=str(self.root),
                        TMPDIR=str(self.root), PYTHONDONTWRITEBYTECODE="1",
                        MERGETETHER_RELEASE_REPO="fixture/release",
                        MERGETETHER_HOMEBREW_TAP_REPO="", TUIST_MERGETETHER_RELAY_CONFIG_FILE="")

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
import json, os, pathlib
config = os.environ.get('TUIST_MERGETETHER_RELAY_CONFIG_FILE')
pathlib.Path('generation-environment.json').write_text(json.dumps({
    'config_file': config, 'origin': os.environ.get('TUIST_MERGETETHER_RELAY_ORIGIN')}))
if config: pathlib.Path('generated-relay-config-path').write_text(config)
# Stand-in for Project.swift normalization of the configured origin.
if config is not None:
    origin = json.loads(pathlib.Path(config).read_text())['origin'].strip().lower().rstrip('/') if config else ''
else:
    origin = os.environ.get('TUIST_MERGETETHER_RELAY_ORIGIN', '').strip().lower().rstrip('/')
pathlib.Path('generated-origin').write_text(origin.removesuffix(':443'))
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
    app = pathlib.Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Release/MergeTether.app'
info_path = app / ('Info.plist' if ios else 'Contents/Info.plist')
info_path.parent.mkdir(parents=True)
info = {'CFBundleShortVersionString': settings['MARKETING_VERSION'],
        'CFBundleVersion': settings['CURRENT_PROJECT_VERSION'],
        'CFBundleIdentifier': 'com.vaporpw.MergeTether.iOS' if ios else 'com.vaporpw.MergeTether',
        'LSMinimumSystemVersion': '14.0',
        'MergeTetherRelayOrigin': os.environ.get('WRONG_RELAY_ORIGIN', pathlib.Path('generated-origin').read_text())}
if os.environ.get('WRONG_VERSION'): info['CFBundleShortVersionString'] = '0.1.0'
if os.environ.get('WRONG_BUILD'): info['CFBundleVersion'] = '1'
if ios:
    info.update(CFBundleExecutable='MergeTetheriOS', CFBundleSupportedPlatforms=['iPhoneOS'])
    binary = app / 'MergeTetheriOS'
    binary.write_bytes(b'device executable fixture')
    binary.chmod(0o755)
    (app / '._Info.plist').write_bytes(b'AppleDouble fixture')
info_path.write_bytes(plistlib.dumps(info))
if settings.get('DEBUG_INFORMATION_FORMAT') == 'dwarf-with-dsym' and not os.environ.get('NO_DSYM'):
    symbol_root = pathlib.Path(args[args.index('-archivePath') + 1]) / 'dSYMs' if 'archive' in args else app.parent
    symbols = symbol_root / (app.name + '.dSYM') / 'Contents/Resources/DWARF'
    symbols.mkdir(parents=True)
    (symbols / app.stem).write_bytes(b'private debug symbols')
""")
        self.executable("ditto", """
import os, pathlib, sys, zipfile
app, output = pathlib.Path(sys.argv[-2]), pathlib.Path(sys.argv[-1])
if '-c' not in sys.argv or '--norsrc' in sys.argv:
    os.execv('/usr/bin/ditto', sys.argv)
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
import os, pathlib, sys
if os.environ.get('SIGNATURE_FAIL'): sys.exit(1)
if '--verify' in sys.argv and pathlib.Path(sys.argv[-1]).parts[-3:] == ('verify', 'Payload', 'MergeTetheriOS.app'):
    if os.environ.get('IOS_IPA_SIGNATURE_FAIL'): sys.exit(1)
if '--display' in sys.argv:
    print('Authority=' + ('Apple Distribution' if 'MergeTetheriOS.app' in sys.argv[-1] else 'Developer ID Application') + ': Fixture (TEAM123)', file=sys.stderr)
    print('TeamIdentifier=' + ('OTHER' if os.environ.get('WRONG_TEAM') else 'TEAM123'), file=sys.stderr)
    print('flags=0x10000(runtime)', file=sys.stderr)
    if not os.environ.get('MISSING_TIMESTAMP'): print('Timestamp=Nov 11, 2026', file=sys.stderr)
""")
        self.executable("spctl", "import os, sys; sys.exit(1 if os.environ.get('GATEKEEPER_FAIL') else 0)")
        self.executable("xcrun", """
import json, os, pathlib, sys
if sys.argv[1] == 'lipo': print('arm64'); sys.exit(0)
if sys.argv[1] == 'vtool': print('  platform IOS'); sys.exit(0)
with pathlib.Path('notary-calls.jsonl').open('a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
if 'history' in sys.argv and os.environ.get('NOTARY_CREDENTIAL_FAIL'): sys.exit(1)
if 'submit' in sys.argv and os.environ.get('NOTARY_SUBMIT_FAIL'): sys.exit(1)
if 'submit' in sys.argv: print(json.dumps({'status': os.environ.get('NOTARY_STATUS', 'Accepted')}))
if os.environ.get('STAPLE_FAIL') and 'stapler' in sys.argv: sys.exit(1)
""")

    def packaged_info(self, version, unsigned=False):
        release = self.root / "release" / ("unsigned" if unsigned else "")
        with zipfile.ZipFile(release / f"MergeTether-{version}.zip") as archive:
            info = plistlib.loads(archive.read("MergeTether.app/Contents/Info.plist"))
        self.assertEqual(info, json.loads((release / f"MergeTether-{version}.dmg").read_text()))
        self.assertEqual(info["CFBundleIdentifier"], "com.vaporpw.MergeTether")
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

    def test_debug_symbols_are_exported_separately_from_public_artifacts(self):
        symbols = self.root / "private-symbols"
        self.env["MERGETETHER_CRASH_SYMBOLS_DIR"] = str(symbols)
        result = self.run_script("build-release.sh", "9.8.7", "--platform", "all", "--unsigned")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({path.name for path in symbols.iterdir()}, {"MergeTether.app.dSYM", "MergeTetheriOS.app.dSYM"})
        release = self.root / "release/unsigned"
        self.assertFalse(list(release.rglob("*.dSYM")))
        for path in release.glob("*.zip"):
            with zipfile.ZipFile(path) as artifact:
                self.assertFalse(any(".dSYM" in name for name in artifact.namelist()))

    def test_requested_debug_symbols_must_exist_before_packaging(self):
        self.env["MERGETETHER_CRASH_SYMBOLS_DIR"] = str(self.root / "private-symbols")
        self.env["NO_DSYM"] = "1"
        result = self.run_script("build-release.sh", "9.8.7", "--unsigned")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing dSYM", result.stderr)
        self.assertFalse(list((self.root / "release/unsigned").glob("*.zip")))

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

    def test_sideload_release_packages_the_device_app_with_matching_metadata(self):
        result = self.signed_build("--platform", "all", "--ios-sideload")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        release = self.root / "release"
        ipa = release / "MergeTetheriOS-9.8.7-Sideload.ipa"
        manifest = json.loads((release / "release-manifest.json").read_text())
        self.assertTrue(manifest["distributable"])
        self.assertEqual({entry["name"] for entry in manifest["artifacts"]},
                         {ipa.name, "MergeTether-9.8.7.dmg", "MergeTether-9.8.7.zip"})
        with zipfile.ZipFile(ipa) as archive:
            info = plistlib.loads(archive.read("Payload/MergeTetheriOS.app/Info.plist"))
            self.assertNotIn("Payload/MergeTetheriOS.app/._Info.plist", archive.namelist())
            self.assertIsNone(archive.testzip())
        self.assertEqual(info["CFBundleShortVersionString"], "9.8.7")
        self.assertEqual(info["CFBundleVersion"], "456")
        self.assertEqual(info["MergeTetherRelayOrigin"], self.packaged_info("9.8.7")["MergeTetherRelayOrigin"])
        calls = [json.loads(line) for line in (self.root / "build-calls.jsonl").read_text().splitlines()]
        ios_build = next(call for call in calls if "MergeTetheriOS" in call)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", ios_build)
        self.assertIn("generic/platform=iOS", ios_build)
        self.assertFalse(any("archive" in call or "-exportArchive" in call for call in calls))

    def test_sideload_signature_failure_prevents_release_inventory(self):
        self.env["IOS_IPA_SIGNATURE_FAIL"] = "1"
        result = self.signed_build("--platform", "all", "--ios-sideload")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("IPA signature verification failed", result.stderr)
        self.assertEqual(list((self.root / "release").iterdir()), [])

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

    def signed_build_without_relay(self, *arguments):
        return self.run_script("build-release.sh", "9.8.7", "--build-number", "456",
                               "--signing-identity", "Developer ID Application: Fixture (TEAM123)",
                               "--team-id", "TEAM123", "--notary-profile", "fixture-notary", *arguments)

    def test_signed_macos_release_requires_relay_config(self):
        result = self.signed_build_without_relay()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--relay-config", result.stderr)
        self.assertIn("--no-relay", result.stderr)
        self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_explicit_no_relay_builds_macos_with_an_empty_origin(self):
        self.env["TUIST_MERGETETHER_RELAY_ORIGIN"] = "https://user-default.example.test"
        result = self.signed_build_without_relay("--no-relay")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.root / "generation-environment.json").read_text())["config_file"], "")
        self.assertEqual(self.packaged_info("9.8.7")["MergeTetherRelayOrigin"], "")
        for arguments in [("--no-relay", "--relay-config", str(self.relay_config)),
                          ("--no-relay", "--platform", "all")]:
            with self.subTest(arguments=arguments):
                (self.root / "build-calls.jsonl").unlink(missing_ok=True)
                result = self.signed_build_without_relay(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "build-calls.jsonl").exists())

    def test_bundle_relay_origin_mismatch_stops_packaging(self):
        for value in ["https://other-relay.example.test", ""]:
            with self.subTest(value=value):
                self.env["WRONG_RELAY_ORIGIN"] = value
                result = self.signed_build()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("MergeTetherRelayOrigin", result.stderr)
                self.assertNotIn("private-relay.example.test", result.stdout + result.stderr)
                self.assertFalse(list((self.root / "release").glob("*.zip")))
                self.env.pop("WRONG_RELAY_ORIGIN")

    def test_configured_origin_is_normalized_before_comparison(self):
        self.relay_config.write_text(json.dumps({"origin": " HTTPS://Private-Relay.Example.Test:443/ "}))
        result = self.signed_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.packaged_info("9.8.7")["MergeTetherRelayOrigin"], "https://private-relay.example.test")

    def test_mise_relay_origin_not_cleared_when_relay_flag_omitted_for_unsigned(self):
        self.env.pop("TUIST_MERGETETHER_RELAY_CONFIG_FILE")
        self.env["TUIST_MERGETETHER_RELAY_ORIGIN"] = "https://user-default.example.test"
        result = self.run_script("build-release.sh", "9.8.7", "--build-number", "456", "--unsigned")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        generation = json.loads((self.root / "generation-environment.json").read_text())
        self.assertIsNone(generation["config_file"])
        self.assertEqual(generation["origin"], "https://user-default.example.test")
        self.assertEqual(self.packaged_info("9.8.7", unsigned=True)["MergeTetherRelayOrigin"],
                         "https://user-default.example.test")

    def test_both_apps_bind_shared_version_build_settings(self):
        source = (self.root / "Project.swift").read_text()
        self.assertEqual(source.count('"CFBundleShortVersionString": .string("$(MARKETING_VERSION)")'), 2)
        self.assertEqual(source.count('"CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)")'), 2)


class ReleasePublicationTests(ReleaseScriptFixture):
    def setUp(self):
        super().setUp()
        (self.root / "CHANGELOG.md").write_text("## Unreleased\n\n- A release fixture.\n\n## 1.1.0\n")
        self.head = "a" * 40
        self.executable("git", """
import json, os, pathlib, sys
a = sys.argv[1:]
with pathlib.Path('git-calls.jsonl').open('a') as f: f.write(json.dumps(a) + '\\n')
head = os.environ.get('FAKE_HEAD', 'a' * 40)
if a == ['config', '--get', 'remote.origin.url']: print('https://github.com/fixture/source.git')
elif a == ['rev-parse', '--git-dir']: print('.git-fixture')
elif a == ['branch', '--show-current']: print(os.environ.get('FAKE_BRANCH', 'main'))
elif a == ['tag', '--sort=-v:refname']: print('v1.1.0')
elif a == ['rev-parse', '--short', 'HEAD']: print(head[:7])
elif a == ['rev-parse', 'HEAD']: print(head)
elif a == ['rev-parse', 'v9.8.7']: sys.exit(1)
elif a[:3] == ['diff', '--cached', '--quiet']: sys.exit(1)
elif a == ['status', '--porcelain']: print(os.environ.get('FAKE_STATUS', ''), end='')
elif a == ['status', '--porcelain', '--', 'CHANGELOG.md']: print(os.environ.get('FAKE_CHANGELOG_STATUS', ''), end='')
elif a[:2] == ['ls-remote', 'origin'] and a[2:3] == ['refs/heads/main']:
    if os.environ.get('LS_REMOTE_FAIL'): sys.exit(1)
    print(os.environ.get('FAKE_REMOTE_HEAD', head) + '\\trefs/heads/main')
elif a[:1] == ['ls-remote']: pass
elif a[:1] == ['push'] and a[2:] == ['main'] and os.environ.get('BRANCH_PUSH_FAIL'): sys.exit(1)
elif a[:1] in [['add'], ['commit'], ['push']] or a[:2] == ['tag', '-a'] or a[:2] == ['reset', '--keep']: pass
else: sys.exit('unexpected git fixture call: ' + repr(a))
""")
        # Stand-in for the full suite: records its invocation and writes a report for FAKE_HEAD.
        (self.root / "scripts/run-tests.py").write_text("""
import json, os, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
with (root / 'verification-calls.jsonl').open('a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
code = int(os.environ.get('VERIFICATION_EXIT', '0'))
run = root / '.test-results' / 'run-fixture-new'
run.mkdir(parents=True, exist_ok=True)
(run / 'report.json').write_text(json.dumps({'commit': os.environ.get('VERIFIED_HEAD', 'a' * 40), 'dirty': False,
                                             'exit_code': code, 'selection': {'mode': 'full'}}))
sys.exit(code)
""")
        self.write_report(mode="full")
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
    assets = os.environ.get('ASSETS', 'MergeTether-9.8.7.dmg,MergeTether-9.8.7.zip')
    print(json.dumps({'tagName': os.environ.get('RELEASE_TAG', 'v9.8.7'),
                      'isDraft': bool(os.environ.get('RELEASE_DRAFT')),
                      'url': os.environ.get('RELEASE_URL', 'https://github.com/fixture/release/releases/tag/v9.8.7'),
                      'assets': [{'name': name, 'size': 0 if os.environ.get('EMPTY_ASSET') else 123,
                                  'url': 'https://github.com/fixture/release/releases/download/v9.8.7/' + name}
                                 for name in (assets.split(',') + ([] if os.environ.get('NO_MANIFEST') else ['release-manifest.json'])
                                              + ([] if os.environ.get('NO_APPCAST') else ['appcast.xml']))]}))
elif a[:2] == ['release', 'download']:
    if os.environ.get('NO_MANIFEST'): sys.exit(1)
    target = pathlib.Path(a[a.index('--dir') + 1]) / 'release-manifest.json'
    assets = os.environ.get('ASSETS', 'MergeTether-9.8.7.dmg,MergeTether-9.8.7.zip').split(',')
    target.write_text(json.dumps({'version': os.environ.get('MANIFEST_VERSION', '9.8.7'), 'build': os.environ.get('MANIFEST_BUILD', '456'),
                                 'distributable': not bool(os.environ.get('MANIFEST_UNSIGNED')),
                                 'artifacts': [{'name': name, 'sha256': 'a' * 64} for name in assets]}))
else: sys.exit('unexpected gh fixture call: ' + repr(a))
""")

    def write_report(self, name="run-fixture-old", **overrides):
        report = dict(commit=self.head, dirty=False, exit_code=0, selection=dict(mode="full"))
        if "mode" in overrides:
            report["selection"] = dict(mode=overrides.pop("mode"))
        report.update(overrides)
        run = self.root / ".test-results" / name
        run.mkdir(parents=True, exist_ok=True)
        (run / "report.json").write_text(json.dumps(report))

    def assert_no_publication(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls("git") if (self.root / "git-calls.jsonl").exists() else []
        self.assertFalse([a for a in calls if a[:1] in (["commit"], ["push"], ["add"]) or a[:2] == ["tag", "-a"]])
        self.assertIn("## Unreleased\n\n- A release fixture.", (self.root / "CHANGELOG.md").read_text())

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
        self.env["ASSETS"] = "MergeTether.dmg"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Release complete.", result.stdout)

    def test_missing_update_feed_is_not_a_successful_release(self):
        self.env["NO_APPCAST"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("appcast.xml", result.stderr)

    def test_missing_dmg_is_not_a_successful_release(self):
        self.env["ASSETS"] = "MergeTether.zip"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Release complete.", result.stdout)

    def test_asset_read_failure_is_not_a_successful_release(self):
        self.env["ASSET_ERROR"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Release complete.", result.stdout)

    def test_versioned_assets_remain_supported(self):
        self.env["ASSETS"] = "MergeTether-9.8.7.dmg,MergeTether-9.8.7.zip"
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Release complete.", result.stdout)

    def test_stable_mac_assets_remain_supported(self):
        self.env["ASSETS"] = "MergeTether.dmg,MergeTether.zip"
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

    def test_public_release_rejects_ios_artifacts(self):
        for asset in ["MergeTetheriOS-9.8.7-Sideload.ipa", "MergeTetheriOS-9.8.7-unsigned-device.zip", "other.ipa"]:
            with self.subTest(asset=asset):
                self.env["ASSETS"] = f"MergeTether.dmg,MergeTether.zip,{asset}"
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("The public release contains iOS assets", result.stderr)

    def test_publication_refuses_ios_before_git_mutation(self):
        result = self.run_script("release-interactive.sh", "--version", "9.8.7", "--yes", "--platform", "all")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Public releases support macOS only", result.stderr)
        self.assertFalse((self.root / "git-calls.jsonl").exists())

    def test_noninteractive_version_is_required_before_any_git_mutation(self):
        result = self.run_script("release-interactive.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--version", result.stderr)
        self.assertFalse((self.root / "git-calls.jsonl").exists())

    def test_noninteractive_release_refuses_non_main_branch(self):
        self.env["FAKE_BRANCH"] = "feature"
        result = self.publish()
        self.assert_no_publication(result)
        self.assertIn("must run from 'main'", result.stderr)

    def test_noninteractive_release_refuses_dirty_tree(self):
        self.env["FAKE_STATUS"] = " M Sources/App.swift\n"
        result = self.publish()
        self.assert_no_publication(result)
        self.assertIn("clean working tree", result.stderr)

    def test_release_refuses_uncommitted_changelog_edits(self):
        self.env["FAKE_CHANGELOG_STATUS"] = " M CHANGELOG.md\n"
        result = self.publish()
        self.assert_no_publication(result)
        self.assertIn("uncommitted changes", result.stderr)

    def test_release_refuses_when_local_branch_behind_origin(self):
        for key, value in [("FAKE_REMOTE_HEAD", "b" * 40), ("LS_REMOTE_FAIL", "1")]:
            with self.subTest(key=key):
                self.env[key] = value
                result = self.publish()
                self.assert_no_publication(result)
                self.assertIn("origin/main", result.stderr)
                self.env.pop(key)

    def test_existing_passing_full_report_for_head_is_reused(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "verification-calls.jsonl").exists())
        self.assertIn("passing full run", result.stdout)

    def test_missing_or_unsuitable_report_runs_full_verification_first(self):
        for overrides in [dict(commit="c" * 40), dict(mode="targeted"), dict(dirty=True), dict(exit_code=1)]:
            with self.subTest(overrides=overrides):
                shutil.rmtree(self.root / ".test-results")
                (self.root / "verification-calls.jsonl").unlink(missing_ok=True)
                self.write_report(**overrides)
                result = self.publish()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = [json.loads(line) for line in (self.root / "verification-calls.jsonl").read_text().splitlines()]
                self.assertEqual(calls, [["--full"]])
                git_calls = self.calls("git")
                self.assertLess(git_calls.index(["rev-parse", "HEAD"]),
                                next(i for i, a in enumerate(git_calls) if a[:1] == ["commit"]))

    def test_failing_or_mismatched_verification_blocks_publication(self):
        for key, value in [("VERIFICATION_EXIT", "1"), ("VERIFIED_HEAD", "d" * 40)]:
            with self.subTest(key=key):
                shutil.rmtree(self.root / ".test-results")
                self.env[key] = value
                result = self.publish()
                self.assert_no_publication(result)
                self.env.pop(key)

    def test_failed_branch_push_removes_local_changelog_commit(self):
        self.env["BRANCH_PUSH_FAIL"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(["reset", "--keep", self.head], self.calls("git"))
        self.assertNotIn(["push", "origin", "v9.8.7"], self.calls("git"))

    def test_failed_workflow_is_not_a_successful_release(self):
        self.env["WATCH_FAIL"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(a[:2] == ["release", "view"] for a in self.calls("gh")))


class VersionSyncTests(ReleaseScriptFixture):
    def setUp(self):
        super().setUp()
        (self.root / "CHANGELOG.md").write_text("## Unreleased\n\n- A release fixture.\n")
        self.executable("git", "import sys; sys.exit('unexpected git call')")

    def test_sync_changes_shared_version_and_preserves_both_bundle_bindings(self):
        original_build = re.search(r'"CURRENT_PROJECT_VERSION": "([^"]+)"', (self.root / "Project.swift").read_text())[1]
        result = self.run_script("sync-version-from-tag.sh", "v9.8.7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        project = (self.root / "Project.swift").read_text()
        self.assertIn('"MARKETING_VERSION": "9.8.7"', project)
        self.assertIn(f'"CURRENT_PROJECT_VERSION": "{original_build}"', project)
        self.assertEqual(project.count('"CFBundleShortVersionString": .string("$(MARKETING_VERSION)")'), 2)
        self.assertEqual(project.count('"CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)")'), 2)
        self.assertIn("release-interactive.sh", result.stdout)

    def test_sync_leaves_changelog_promotion_to_the_release_script(self):
        before = (self.root / "CHANGELOG.md").read_bytes()
        result = self.run_script("sync-version-from-tag.sh", "v9.8.7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "CHANGELOG.md").read_bytes(), before)

    def test_sync_sets_build_number_only_when_explicit(self):
        result = self.run_script("sync-version-from-tag.sh", "v9.8.7", "--build-number", "42")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"CURRENT_PROJECT_VERSION": "42"', (self.root / "Project.swift").read_text())

    def test_sync_rejects_partial_version_match_before_source_mutation(self):
        original = (self.root / "Project.swift").read_bytes()
        for arguments in [("v9.8.7-invalid",), ("v9.8.7", "--build-number", "0")]:
            with self.subTest(arguments=arguments):
                result = self.run_script("sync-version-from-tag.sh", *arguments)
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
        names = ["APPLE_CERTIFICATES_P12_BASE64", "APPLE_CERTIFICATES_PASSWORD",
                 "NOTARY_API_PRIVATE_KEY", "NOTARY_KEY_ID", "NOTARY_ISSUER_ID", "APPLE_TEAM_ID",
                 "MACOS_RELEASE_IDENTITY",
                 "MERGETETHER_SPARKLE_PUBLIC_KEY", "MERGETETHER_SPARKLE_PRIVATE_KEY"]
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

    def test_ci_does_not_require_private_relay_or_ios_distribution_configuration(self):
        self.env.update(APPLE_CERTIFICATES_P12_BASE64="fixture", APPLE_CERTIFICATES_PASSWORD="fixture",
                        NOTARY_API_PRIVATE_KEY="fixture", NOTARY_KEY_ID="fixture", NOTARY_ISSUER_ID="fixture",
                        APPLE_TEAM_ID="TEAM123", MACOS_RELEASE_IDENTITY="Fixture Mac",
                        MERGETETHER_SPARKLE_PUBLIC_KEY="fixture",
                        MERGETETHER_SPARKLE_PRIVATE_KEY="fixture")
        for name in ["MERGETETHER_RELAY_CONFIG_JSON", "IOS_PROFILE_BASE64", "IOS_RELEASE_IDENTITY", "IOS_EXPORT_METHOD"]:
            self.env.pop(name, None)
        result = self.run_step("Check distribution configuration")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ci_builds_only_mac_without_a_relay_and_preserves_source_metadata(self):
        self.executable("mise", """
import json, pathlib, sys
pathlib.Path('mise-arguments.json').write_text(json.dumps(sys.argv[1:]))
""")
        self.env.update(RELEASE_VERSION="9.8.7", RELEASE_BUILD_NUMBER="456", APPLE_TEAM_ID="TEAM123",
                        MACOS_RELEASE_IDENTITY="Fixture Mac",
                        RUNNER_TEMP=str(self.root))
        original = (self.root / "Project.swift").read_bytes()
        result = self.run_step("Build macOS distribution artifacts without a relay")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = json.loads((self.root / "mise-arguments.json").read_text())
        self.assertEqual(args[:5], ["exec", "--", "bash", "scripts/build-release.sh", "9.8.7"])
        self.assertEqual(args[args.index("--build-number") + 1], "456")
        self.assertEqual(args[args.index("--platform") + 1], "macos")
        self.assertIn("--no-relay", args)
        self.assertNotIn("--ios-sideload", args)
        self.assertNotIn("--ios-signing-identity", args)
        self.assertNotIn("--ios-export-options", args)
        self.assertNotIn("--unsigned", args)
        self.assertNotIn("--relay-config", args)
        self.assertEqual((self.root / "Project.swift").read_bytes(), original)

    def prepare_inventory(self):
        self.env.update(RELEASE_VERSION="9.8.7", RELEASE_BUILD_NUMBER="456", APP_NAME="MergeTether")
        release = self.root / "release"
        release.mkdir()
        artifacts = []
        for name in ["MergeTether-9.8.7.dmg", "MergeTether-9.8.7.zip"]:
            content = ("fixture: " + name).encode()
            (release / name).write_bytes(content)
            artifacts.append({"name": name, "sha256": hashlib.sha256(content).hexdigest(),
                              "platform": "macos"})
        manifest = {"version": "9.8.7", "build": "456", "distributable": True, "artifacts": artifacts}
        (release / "release-manifest.json").write_text(json.dumps(manifest))
        return release, manifest

    def test_ci_stable_names_keep_matching_manifest_and_checksums(self):
        release, _ = self.prepare_inventory()
        result = self.run_step("Verify distribution inventory and retain stable macOS names")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((release / "release-manifest.json").read_text())
        self.assertEqual({a["name"] for a in manifest["artifacts"]},
                         {"MergeTether.dmg", "MergeTether.zip"})
        for name in ["MergeTether.dmg", "MergeTether.zip"]:
            digest = hashlib.sha256((self.root / name).read_bytes()).hexdigest()
            self.assertEqual((release / (name + ".sha256")).read_text(), digest + "  " + name + "\n")

    def test_ci_rejects_unsigned_inventory_before_stable_artifacts_are_copied(self):
        release, manifest = self.prepare_inventory()
        manifest["distributable"] = False
        (release / "release-manifest.json").write_text(json.dumps(manifest))
        result = self.run_step("Verify distribution inventory and retain stable macOS names")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "MergeTether.dmg").exists())

    def test_ci_rejects_changed_artifact_digest(self):
        release, _ = self.prepare_inventory()
        (release / "MergeTether-9.8.7.dmg").write_bytes(b"unexpected payload")
        result = self.run_step("Verify distribution inventory and retain stable macOS names")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "MergeTether.dmg").exists())

    def test_ci_publishes_only_after_attaching_the_update_feed_and_mac_archives(self):
        self.env.update(APP_NAME="MergeTether", RELEASE_REPO="fixture/release", TAG="v9.8.7", VERSION="9.8.7")
        (self.root / "CHANGELOG.md").write_text("## 9.8.7 - 2026-01-01\n\n- Fixture release.\n")
        self.executable("gh", """
import json, os, pathlib, sys
args = sys.argv[1:]
with pathlib.Path('release-arguments.jsonl').open('a') as calls: calls.write(json.dumps(args) + '\\n')
if args[:2] == ['release', 'view']:
    if 'assets' in args:
        print(os.environ.get('DRAFT_HAS_IOS_ASSETS', 'false'))
        sys.exit(0)
    status = os.environ.get('RELEASE_STATUS')
    if status is None: sys.exit(1)
    print(status)
""")
        calls_path = self.root / "release-arguments.jsonl"
        for command in ["create", "upload"]:
            with self.subTest(command=command):
                calls_path.write_text("")
                if command == "upload":
                    self.env["RELEASE_STATUS"] = "true"
                result = self.run_step("Create GitHub Release")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
                args = calls[-3]
                self.assertEqual(args[:3], ["release", command, "v9.8.7"])
                if command == "create":
                    self.assertIn("--draft", args)
                self.assertEqual(args[-6:], ["MergeTether.dmg", "MergeTether.zip",
                                            "release/release-manifest.json", "release/appcast.xml",
                                            "release/MergeTether.dmg.sha256", "release/MergeTether.zip.sha256"])
                self.assertEqual(calls[-2][:7],
                                 ["release", "view", "v9.8.7", "--repo", "fixture/release", "--json", "assets"])
                self.assertEqual(calls[-1], ["release", "edit", "v9.8.7", "--repo", "fixture/release", "--draft=false", "--latest"])

        calls_path.write_text("")
        self.env["DRAFT_HAS_IOS_ASSETS"] = "true"
        result = self.run_step("Create GitHub Release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("The draft contains iOS assets", result.stdout)
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
        self.assertFalse(any("--draft=false" in args for args in calls))

        calls_path.write_text("")
        self.env["RELEASE_STATUS"] = "false"
        result = self.run_step("Create GitHub Release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release is already published", result.stdout)
        self.assertEqual(len(calls_path.read_text().splitlines()), 1)

    def test_release_build_needs_full_verification_before_secrets(self):
        release = (REPO / ".github/workflows/release.yml").read_text()
        verify = (REPO / ".github/workflows/verify.yml").read_text()
        self.assertIn("  verify:\n    uses: ./.github/workflows/verify.yml\n", release)
        build = release.split("\n  build:\n", 1)[1].split("\n    steps:", 1)[0]
        self.assertIn("needs: verify", build)
        self.assertIn("workflow_call:", verify)
        self.assertIn("pull_request:", verify)
        self.assertRegex(verify, r"push:\n\s+branches:\n\s+- main")
        self.assertIn("python3 scripts/run-tests.py --full", verify)
        self.assertIn('TUIST_MERGETETHER_RELAY_CONFIG_FILE="" mise exec -- tuist generate --no-open', verify)
        self.assertIn("npm ci --prefix prototypes/remote-relay", verify)
        self.assertIn("node-version-file: prototypes/remote-relay/package.json", verify)
        self.assertNotIn("secrets.", verify)

    def test_ci_inventory_exposes_the_built_dmg_digest(self):
        release, _ = self.prepare_inventory()
        output = self.root / "github-output"
        self.env["GITHUB_OUTPUT"] = str(output)
        result = self.run_step("Verify distribution inventory and retain stable macOS names")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        digest = hashlib.sha256((self.root / "MergeTether.dmg").read_bytes()).hexdigest()
        self.assertEqual(output.read_text(), f"dmg_sha256={digest}\n")

    def test_cask_update_rejects_failed_download_and_unexpected_digest(self):
        self.executable("curl", """
import os, pathlib, sys
if os.environ.get('CURL_FAIL'): sys.exit(22)
pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes(b'published dmg')
pathlib.Path('curl-arguments').write_text(' '.join(sys.argv[1:]))
""")
        self.executable("sha256sum", """
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest() + '  ' + sys.argv[1])
""")
        output = self.root / "github-output"
        expected = hashlib.sha256(b"published dmg").hexdigest()
        self.env.update(ASSET_URL="https://github.com/fixture/release/releases/download/v9.8.7/MergeTether.dmg",
                        GITHUB_OUTPUT=str(output), EXPECTED_SHA256=expected)
        result = self.run_step("Download release asset and verify SHA256")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"sha256={expected}", output.read_text())
        arguments = (self.root / "curl-arguments").read_text()
        for flag in ["--fail", "--retry 5", "--retry-all-errors"]:
            self.assertIn(flag, arguments)
        for key, value in [("CURL_FAIL", "1"), ("EXPECTED_SHA256", "b" * 64), ("EXPECTED_SHA256", "")]:
            with self.subTest(key=key, value=value):
                output.write_text("")
                saved = self.env.get(key)
                self.env[key] = value
                result = self.run_step("Download release asset and verify SHA256")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("sha256=", output.read_text())
                if saved is None:
                    self.env.pop(key)
                else:
                    self.env[key] = saved

    def test_ci_prepares_and_removes_only_temporary_distribution_credentials(self):
        self.env.update(RUNNER_TEMP=str(self.root),
                        APPLE_CERTIFICATES_P12_BASE64="Zml4dHVyZQ==", APPLE_CERTIFICATES_PASSWORD="fixture-only",
                        NOTARY_API_PRIVATE_KEY="fixture-private-key", NOTARY_KEY_ID="fixture-id",
                        NOTARY_ISSUER_ID="fixture-issuer")
        self.executable("openssl", "print('fixture-random-password')")
        self.executable("security", """
import pathlib, sys
if sys.argv[1] == 'create-keychain': pathlib.Path(sys.argv[-1]).touch()
if sys.argv[1] == 'delete-keychain': pathlib.Path(sys.argv[-1]).unlink()
""")
        self.executable("xcrun", "")
        result = self.run_step("Prepare temporary macOS distribution keychain")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "relay-build.json").exists())
        keychain = self.root / "release-signing.keychain-db"
        self.assertTrue(keychain.exists())
        self.assertFalse((self.root / "notary-key.p8").exists())
        self.assertFalse((self.root / "distribution.p12").exists())
        unrelated = self.root / "Library/MobileDevice/Provisioning Profiles/keep.mobileprovision"
        unrelated.parent.mkdir(parents=True)
        unrelated.touch()
        cleanup = self.run_step("Remove temporary distribution credentials")
        self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)
        self.assertTrue(unrelated.exists())
        self.assertFalse(keychain.exists())
        self.assertFalse((self.root / "relay-build.json").exists())



if __name__ == "__main__":
    unittest.main()
