#!/usr/bin/env bash
# Syncs Project.swift's shared marketing version and build settings from a
# git tag and renames the CHANGELOG's Unreleased section to the tagged version.
#
# Usage:
#   scripts/sync-version-from-tag.sh v0.2.0
#
# - MARKETING_VERSION: stripped-v semver (e.g. "0.2.0")
# - CURRENT_PROJECT_VERSION: reachable semver tag count + 1
# - CHANGELOG.md: `## Unreleased` renamed to `## 0.2.0 - <today>` and a fresh
#   `## Unreleased` stub opened above it.
#
# Does NOT create commits or tags. The caller is expected to review + commit.

set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: $0 vX.Y.Z (updates shared project defaults and changelog locally; no commits/tags)"
    exit 0
fi

if [[ $# -ne 1 ]]; then
    echo "usage: $0 vX.Y.Z" >&2
    exit 1
fi

TAG="$1"
if [[ ! "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: tag must match vX.Y.Z (got: ${TAG})" >&2
    exit 1
fi
VERSION="${TAG#v}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PROJECT_FILE="Project.swift"
CHANGELOG_FILE="CHANGELOG.md"

if [[ ! -f "${PROJECT_FILE}" ]] || [[ ! -f "${CHANGELOG_FILE}" ]]; then
    echo "error: must run from the repo root" >&2
    exit 1
fi

# Derive a monotonic CFBundleVersion by counting reachable semver tags + 1.
TAG_COUNT="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | wc -l | tr -d ' ')"
BUILD_NUMBER="$((TAG_COUNT + 1))"

echo "==> Setting shared version ${VERSION} and build ${BUILD_NUMBER}"
python3 - "${PROJECT_FILE}" "${VERSION}" "${BUILD_NUMBER}" <<'PYTHON'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
source = path.read_text()
for key, value in zip(('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'), sys.argv[2:]):
    source, count = re.subn(r'("' + key + r'": ")[^"]+("),', lambda match: match[1] + value + match[2] + ',', source)
    if count != 1:
        sys.exit('error: expected one shared ' + key + ' setting; project left unchanged')
path.write_text(source)
PYTHON

echo "==> Renaming CHANGELOG Unreleased section to ${VERSION}"
TODAY="$(date -u +%Y-%m-%d)"
TMP_FILE="$(mktemp)"
awk -v version="${VERSION}" -v today="${TODAY}" '
    BEGIN { replaced = 0 }
    /^## Unreleased$/ && replaced == 0 {
        print "## Unreleased"
        print ""
        print "## " version " - " today
        replaced = 1
        next
    }
    { print }
' "${CHANGELOG_FILE}" > "${TMP_FILE}"
mv "${TMP_FILE}" "${CHANGELOG_FILE}"

echo
echo "==> Done. Review with:"
echo "    git diff ${PROJECT_FILE} ${CHANGELOG_FILE}"
echo
echo "    Then commit and tag:"
echo "    git commit -am 'Release ${VERSION}'"
echo "    git tag ${TAG}"
