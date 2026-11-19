from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
REMOTE_SOURCES = ROOT / "Packages/MergeTetherRemote/Sources/MergeTetherRemote"
RELAY_TRANSPORT = REMOTE_SOURCES / "RemoteConnection.swift"


class IOSNetworkBoundaryTests(unittest.TestCase):
    def test_ios_sources_only_use_the_shared_relay_transport(self):
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
        for path in sorted(files - {RELAY_TRANSPORT}):
            with self.subTest(source=path.relative_to(ROOT)):
                match = re.search(automatic_networking, path.read_text())
                self.assertIsNone(match, "Automatic iOS traffic must go through RemoteConnection")

        transport = RELAY_TRANSPORT.read_text()
        self.assertNotRegex(transport, r"\bsession\s*\.\s*(?:data|bytes|download|upload)\w*\s*\(")
