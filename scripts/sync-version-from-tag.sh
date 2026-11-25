#!/usr/bin/env bash
# Syncs Project.swift's shared marketing version (and, when given, build number)
# from a release tag name.
#
# Usage:
#   scripts/sync-version-from-tag.sh v0.2.0 [--build-number N]
#
# - MARKETING_VERSION: stripped-v semver (e.g. "0.2.0")
# - CURRENT_PROJECT_VERSION: changed only with an explicit --build-number.
#   Distribution builds take their build number from the Release workflow run
#   number; this helper never derives one.
#
# CHANGELOG promotion and the annotated tag belong to
# scripts/release-interactive.sh. This helper creates no commits or tags.

set -euo pipefail

usage() {
    echo "Usage: $0 vX.Y.Z [--build-number N] (updates Project.swift shared defaults only; no changelog, commits or tags)"
}

TAG="" BUILD_NUMBER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --build-number)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 1; }
            BUILD_NUMBER="$2"; shift 2 ;;
        -*) echo "error: unknown option $1" >&2; usage >&2; exit 1 ;;
        *) [[ -z "$TAG" ]] || { usage >&2; exit 1; }; TAG="$1"; shift ;;
    esac
done

if [[ ! "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: tag must match vX.Y.Z (got: ${TAG})" >&2
    exit 1
fi
if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --build-number must be a positive integer" >&2
    exit 1
fi
VERSION="${TAG#v}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PROJECT_FILE="Project.swift"
if [[ ! -f "${PROJECT_FILE}" ]]; then
    echo "error: must run from the repo root" >&2
    exit 1
fi

echo "==> Setting shared version ${VERSION}${BUILD_NUMBER:+ and build ${BUILD_NUMBER}}"
python3 - "${PROJECT_FILE}" "${VERSION}" "${BUILD_NUMBER}" <<'PYTHON'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
source = path.read_text()
for key, value in zip(('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'), sys.argv[2:]):
    if not value:
        continue
    source, count = re.subn(r'("' + key + r'": ")[^"]+("),', lambda match: match[1] + value + match[2] + ',', source)
    if count != 1:
        sys.exit('error: expected one shared ' + key + ' setting; project left unchanged')
path.write_text(source)
PYTHON

echo
echo "==> Done. Review with: git diff ${PROJECT_FILE}"
echo "    Publish through scripts/release-interactive.sh --version ${VERSION}; it promotes the"
echo "    changelog and pushes the annotated tag the Release workflow expects."
