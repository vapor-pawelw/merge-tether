from collections import Counter
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
CATALOGS = sorted(ROOT.glob("Resources/*.xcstrings")) + sorted(ROOT.glob("iOS/Resources/*.xcstrings"))
FORMAT = re.compile(r"%(?:%|(?:(\d+)\$)?([-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|[hlLzjt])?[@diouxXfFeEgGaAcsp]))")


def format_arguments(value):
    implicit_position = 0
    slots = Counter()
    for match in FORMAT.finditer(value):
        position, specifier = match.groups()
        if match.group() == "%%":
            slots[(0, "%")] += 1
        elif position is None:
            implicit_position += 1
            slots[(implicit_position, specifier)] += 1
        else:
            slots[(int(position), specifier)] += 1
    return slots


def variants(localization):
    if "stringUnit" in localization:
        return {"other": localization["stringUnit"]}
    return {category: item["stringUnit"]
            for category, item in localization["variations"]["plural"].items()}


class LocalizationTests(unittest.TestCase):
    def test_catalogs_have_complete_english_and_polish_values(self):
        self.assertTrue(CATALOGS)
        for path in CATALOGS:
            catalog = json.loads(path.read_text(encoding="utf-8"))
            for key, entry in catalog["strings"].items():
                if entry.get("shouldTranslate") is False:
                    continue
                with self.subTest(catalog=path.relative_to(ROOT), key=key):
                    localizations = entry["localizations"]
                    self.assertIn("en", localizations)
                    self.assertIn("pl", localizations)
                    if "variations" in localizations["en"]:
                        self.assertIn("variations", localizations["pl"])
                    english = variants(localizations["en"])
                    polish = variants(localizations["pl"])
                    if "variations" in localizations["pl"]:
                        self.assertEqual(set(polish), {"one", "few", "many", "other"})
                    for unit in (*english.values(), *polish.values()):
                        self.assertEqual(unit["state"], "translated")
                        self.assertTrue(unit["value"].strip())
                    for category, unit in polish.items():
                        source = english.get(category, english["other"])["value"]
                        self.assertEqual(format_arguments(unit["value"]), format_arguments(source))

    def test_system_permission_and_copyright_strings_are_localized(self):
        for directory, key in [("Resources", "NSHumanReadableCopyright"),
                               ("iOS/Resources", "NSCameraUsageDescription")]:
            with self.subTest(directory=directory, key=key):
                catalog = json.loads((ROOT / directory / "InfoPlist.xcstrings").read_text(encoding="utf-8"))
                locales = catalog["strings"][key]["localizations"]
                self.assertNotEqual(locales["en"]["stringUnit"]["value"], locales["pl"]["stringUnit"]["value"])
