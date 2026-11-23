"""CHANGELOG.md is bundled for What's New and parsed by the release script and workflow."""

from pathlib import Path
import re
import unittest


REPO = Path(__file__).resolve().parents[2]
UNRELEASED = re.compile(r"^## Unreleased[ \t]*$")
RELEASED = re.compile(r"^## (\d+)\.(\d+)\.(\d+) - (\d{4}-\d{2}-\d{2})$")


def headings(text):
    return [line for line in text.splitlines() if line.startswith("## ")]


def marketing_version():
    match = re.search(r'"MARKETING_VERSION": "(\d+)\.(\d+)\.(\d+)"', (REPO / "Project.swift").read_text())
    return tuple(map(int, match.groups()))


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.text = (REPO / "CHANGELOG.md").read_text(encoding="utf-8")
        self.headings = headings(self.text)

    def test_single_unreleased_section_precedes_released_versions(self):
        unreleased = [line for line in self.headings if line.startswith("## Unreleased")]
        self.assertEqual(len(unreleased), 1, "release promotion requires exactly one Unreleased heading")
        self.assertRegex(unreleased[0], UNRELEASED, "release-interactive.sh matches '## Unreleased' exactly")
        self.assertEqual(self.headings[0], unreleased[0])

    def test_release_headings_use_the_version_date_format_read_by_release_tooling(self):
        for heading in self.headings[1:]:
            with self.subTest(heading=heading):
                self.assertRegex(heading, RELEASED)

    def test_versions_are_unique_descending_and_not_newer_than_the_project(self):
        versions = [RELEASED.match(line) for line in self.headings[1:]]
        versions = [(tuple(map(int, match.groups()[:3])), match.group(4)) for match in versions if match]
        numbers = [number for number, _ in versions]
        self.assertEqual(len(numbers), len(set(numbers)), "duplicate release sections")
        self.assertEqual(numbers, sorted(numbers, reverse=True))
        dates = [date for _, date in versions]
        self.assertEqual(dates, sorted(dates, reverse=True))
        if numbers:
            self.assertLessEqual(numbers[0], marketing_version(),
                                 "a released section is newer than Project.swift MARKETING_VERSION")

    def test_released_sections_have_notes_for_whats_new(self):
        sections = re.split(r"^## ", self.text, flags=re.M)[1:]
        for section in sections:
            heading, _, body = section.partition("\n")
            if heading.startswith("Unreleased"):
                continue
            with self.subTest(heading=heading):
                self.assertTrue(body.strip(), "What's New hides a version with an empty section")


if __name__ == "__main__":
    unittest.main()
