from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
REMOTE_SOURCES = ROOT / "Packages/MergeTetherRemote/Sources/MergeTetherRemote"
RELAY_TRANSPORT = REMOTE_SOURCES / "RemoteConnection.swift"
CRASH_UPLOAD = ROOT / "Sources/Services/CrashUpload.swift"


class IOSNetworkBoundaryTests(unittest.TestCase):
    def test_ios_network_access_is_confined_to_the_relay_and_optional_crash_transport(self):
        project = (ROOT / "Project.swift").read_text()
        ios_target = project.split('name: "MergeTetheriOS"', 1)[1]
        source_globs = re.search(r"sources:\s*\[([^\]]+)\]", ios_target)
        self.assertIsNotNone(source_globs)
        files = set(REMOTE_SOURCES.rglob("*.swift"))
        for pattern in re.findall(r'"([^"]+)"', source_globs.group(1)):
            files.update(ROOT.glob(pattern))

        automatic_networking = (
            r"\b(?:URLSession\w*|AsyncImage|WKWebView|NWConnection|NWListener)\b"
            r"|\b(?:Data|String)\s*\(\s*contentsOf\s*:"
        )
        for path in sorted(files - {RELAY_TRANSPORT, CRASH_UPLOAD}):
            with self.subTest(source=path.relative_to(ROOT)):
                match = re.search(automatic_networking, path.read_text())
                self.assertIsNone(match, "iOS transport must stay in RemoteConnection or CrashUpload")

        transport = RELAY_TRANSPORT.read_text()
        self.assertNotRegex(transport, r"\bsession\s*\.\s*(?:data|bytes|download|upload)\w*\s*\(")
