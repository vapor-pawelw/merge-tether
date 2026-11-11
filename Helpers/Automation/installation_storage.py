"""Installation-scoped runtime authority shared by the bundled evidence helpers."""

import os
from pathlib import Path
import plistlib
import re

RELEASE_BUNDLE_IDENTIFIER = "com.vaporpw.GitLabTodos"
ENVIRONMENT_KEY = "MERGETETHER_STORAGE_ROOT"


def storage_root(*, helper=None, home=None):
    if ENVIRONMENT_KEY in os.environ:
        value = os.environ[ENVIRONMENT_KEY]
        root = Path(value)
        if not value or not root.is_absolute() or ".." in root.parts or any(ord(c) < 32 for c in value):
            raise ValueError("Invalid MergeTether installation storage authority")
        return root
    helper = Path(helper or __file__)
    identifier = RELEASE_BUNDLE_IDENTIFIER
    contents = next((parent for parent in helper.parents if parent.name == "Contents" and parent.parent.suffix == ".app"), None)
    if contents is not None:
        try:
            with (contents / "Info.plist").open("rb") as file:
                identifier = plistlib.load(file)["CFBundleIdentifier"]
        except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
            raise ValueError("Could not establish the bundled helper installation identity") from error
        if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", identifier) or identifier in (".", ".."):
            raise ValueError("Invalid bundled helper installation identity")
    return Path(home or Path.home()) / "Library/Application Support" / identifier
