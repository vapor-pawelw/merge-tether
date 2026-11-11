import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from installation_storage import storage_root


class InstallationStorageTests(unittest.TestCase):
    def test_explicit_authority_is_shared_with_swift(self):
        with patch.dict(os.environ, {"MERGETETHER_STORAGE_ROOT": "/tmp/local install"}):
            self.assertEqual(storage_root(), Path("/tmp/local install"))

    def test_relative_or_empty_override_fails_closed(self):
        for value in ("", "relative", "~/Library/Application Support/local", "/tmp/../other"):
            with self.subTest(value=value), patch.dict(os.environ, {"MERGETETHER_STORAGE_ROOT": value}):
                with self.assertRaises(ValueError):
                    storage_root()

    def test_bundled_helper_uses_actual_bundle_identifier_without_environment(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            contents = Path(temporary) / "Local.app/Contents"
            helper = contents / "Resources/Automation/installation_storage.py"
            helper.parent.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.vaporpw.MergeTether"}))
            self.assertEqual(storage_root(helper=helper, home=Path(temporary)),
                Path(temporary) / "Library/Application Support/com.vaporpw.MergeTether")

    def test_unbundled_helper_preserves_release_default(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(storage_root(helper=Path("/tmp/helper.py"), home=Path("/tmp/home")),
                Path("/tmp/home/Library/Application Support/com.vaporpw.GitLabTodos"))

    def test_malformed_bundled_identity_does_not_fall_back_to_release(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            helper = Path(temporary) / "Local.app/Contents/Resources/Automation/installation_storage.py"
            helper.parent.mkdir(parents=True)
            for value in ("../release", "", None):
                (helper.parents[2] / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": value or ""}))
                with self.assertRaises(ValueError):
                    storage_root(helper=helper, home=Path(temporary))
