from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class IOSConversationActionTests(unittest.TestCase):
    def test_companion_does_not_offer_to_start_assistant_conversations(self):
        for path in sorted((ROOT / "iOS").rglob("*.swift")):
            with self.subTest(source=path.relative_to(ROOT)):
                self.assertNotRegex(path.read_text(), r"\b(?:assistantContextOpen|openAssistant)\b")
