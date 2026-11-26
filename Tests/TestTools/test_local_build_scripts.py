import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[2]


class LocalBuildScriptsTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="mergetether-local-test-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        shutil.copytree(REPO / "scripts", self.root / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls"
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", HOME=str(self.root),
                        TMPDIR=str(self.root), TUIST_MERGETETHER_RELAY_CONFIG_FILE="",
                        CALLS=str(self.calls))
        self.executable("mise", """
import os, pathlib, plistlib
plists = pathlib.Path("Derived/InfoPlists")
plists.mkdir(parents=True, exist_ok=True)
for app in ["MergeTether", "MergeTetheriOS"]:
    (plists / (app + "-Info.plist")).write_bytes(plistlib.dumps(
        {"MergeTetherRelayOrigin": os.environ.get("FIXTURE_ORIGIN", "")}))
""")

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def run_script(self, name, *arguments):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), *arguments],
                              cwd=self.root, env=self.env, capture_output=True, text=True, timeout=20)

    def test_mac_stages_build_before_quitting_and_launches_replacement(self):
        app = self.root / "Applications/MergeTether.app"
        original = app / "Contents/Info.plist"
        original.parent.mkdir(parents=True)
        original.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.vaporpw.MergeTether",
                                             "CFBundleExecutable": "PreviousExecutable",
                                             "CFBundleName": "MergeTether",
                                             "LSMinimumSystemVersion": "14.0"}))
        self.executable("codesign", "pass")
        self.executable("xcodebuildmcp", """
import os, pathlib, plistlib, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as log: log.write("build\\n")
if os.environ.get("FAIL_BUILD"): sys.exit(1)
assert "PRODUCT_BUNDLE_IDENTIFIER=com.vaporpw.MergeTether" in args
plist = pathlib.Path(args[args.index("--derived-data-path") + 1]) / "Build/Products/Debug/MergeTether.app/Contents/Info.plist"
plist.parent.mkdir(parents=True)
plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.vaporpw.MergeTether",
                                 "CFBundleExecutable": "MergeTether", "LSMinimumSystemVersion": "14.0",
                                 "MergeTetherRelayOrigin": "", "NewBuild": True}))
""")
        self.executable("swift", """
import os, pathlib, plistlib, sys
operation, app, executable, previous = sys.argv[2:6]
assert executable == "MergeTether" and previous == "PreviousExecutable"
with open(os.environ["CALLS"], "a") as log: log.write(operation + "\\n")
with (pathlib.Path(app) / "Contents/Info.plist").open("rb") as f:
    assert bool(plistlib.load(f).get("NewBuild")) == (operation == "launch")
if operation == "launch" and os.environ.get("FAIL_LAUNCH"): sys.exit(1)
""")
        self.env["FAIL_BUILD"] = "1"
        result = self.run_script("rebuild-and-relaunch.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.calls.exists(), result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["build"])
        self.assertFalse(plistlib.loads(original.read_bytes()).get("NewBuild"))

        del self.env["FAIL_BUILD"]
        self.env["FAIL_LAUNCH"] = "1"
        self.calls.unlink()
        result = self.run_script("rebuild-and-relaunch.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(), ["build", "quit", "launch"])
        self.assertFalse(plistlib.loads(original.read_bytes()).get("NewBuild"))

        del self.env["FAIL_LAUNCH"]
        self.calls.unlink()
        result = self.run_script("rebuild-and-relaunch.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["build", "quit", "launch"])
        self.assertTrue(plistlib.loads(original.read_bytes()).get("NewBuild"))
        self.assertEqual(plistlib.loads(original.read_bytes())["CFBundleExecutable"], "MergeTether")

    def test_ios_ipa_verifies_extracted_payload_before_publishing(self):
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                        "-c", "core.hooksPath=/dev/null",
                        "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "Fixture"],
                       cwd=self.root, check=True)
        self.env["FIXTURE_ORIGIN"] = "https://example.test"
        self.executable("xcodebuildmcp", """
import os, pathlib, plistlib, sys
args = sys.argv[1:]
assert "Release" in args and "CURRENT_PROJECT_VERSION=35" in args and "CODE_SIGNING_ALLOWED=NO" in args
bundle = pathlib.Path(args[args.index("--derived-data-path") + 1]) / "Build/Products/Release-iphoneos/MergeTetheriOS.app"
bundle.mkdir(parents=True)
(bundle / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.vaporpw.MergeTether.iOS", "CFBundleExecutable": "MergeTetheriOS",
    "CFBundleVersion": "35", "CFBundleShortVersionString": "1.2.0",
    "CFBundleSupportedPlatforms": ["iPhoneOS"], "MergeTetherRelayOrigin": os.environ["FIXTURE_ORIGIN"]}))
binary = bundle / "MergeTetheriOS"
binary.write_bytes(b"device executable fixture")
binary.chmod(0o755)
(bundle / "._Info.plist").write_bytes(b"AppleDouble fixture")
if "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym" in args:
    symbols = bundle.with_suffix(".app.dSYM") / "Contents/Resources/DWARF"
    symbols.mkdir(parents=True)
    (symbols / "MergeTetheriOS").write_bytes(b"private debug symbols")
""")
        self.executable("xcrun", """import sys
print("arm64" if sys.argv[1] == "lipo" else "  platform IOS")
""")
        self.executable("codesign", """
import os, pathlib, sys
if "--verify" in sys.argv:
    assert pathlib.Path(sys.argv[-1]).parents[1].name == "verify"
    if os.environ.get("REJECT_SIGNATURE"): sys.exit(1)
""")
        out = self.root / "release/ios"
        legacy = self.root / "release/sidestore"
        legacy.mkdir(parents=True)
        previous = legacy / "previous.ipa"
        with zipfile.ZipFile(previous, "w") as archive:
            archive.writestr("Payload/MergeTetheriOS.app/Info.plist", plistlib.dumps(
                {"CFBundleIdentifier": "com.vaporpw.MergeTether.iOS", "CFBundleVersion": "34"}))

        self.env["REJECT_SIGNATURE"] = "1"
        result = self.run_script("build-ios-ipa.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(out.iterdir()), [])
        self.assertTrue(previous.is_file())

        del self.env["REJECT_SIGNATURE"]
        commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"],
                                         cwd=self.root, text=True).strip()
        blocked_output = out / f"MergeTetheriOS-1.2.0-35-{commit}-dirty.ipa"
        blocked_output.mkdir()
        result = self.run_script("build-ios-ipa.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output already exists", result.stderr)
        self.assertEqual(set(out.iterdir()), {blocked_output})
        blocked_output.rmdir()

        symbols = self.root / "private-symbols"
        self.env["MERGETETHER_CRASH_SYMBOLS_DIR"] = str(symbols)
        result = self.run_script("build-ios-ipa.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        ipa, = out.glob("MergeTetheriOS-*.ipa")
        self.assertTrue((symbols / (ipa.stem + ".app.dSYM") / "Contents/Resources/DWARF/MergeTetheriOS").is_file())
        with zipfile.ZipFile(ipa) as archive:
            self.assertNotIn("Payload/MergeTetheriOS.app/._Info.plist", archive.namelist())
            self.assertFalse(any(".dSYM" in name for name in archive.namelist()))
            self.assertIsNone(archive.testzip())
        manifest = json.loads(ipa.with_suffix(".json").read_text())
        self.assertEqual(manifest["build"], "35")
        self.assertEqual(manifest["artifact"], ipa.name)
