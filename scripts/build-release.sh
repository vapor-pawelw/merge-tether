#!/usr/bin/env bash
# Builds an unsigned Release .app, ZIP and DMG for MergeTether.
#
# Usage:
#   scripts/build-release.sh [version]
#
# Defaults to the version in Project.swift's CFBundleShortVersionString when
# no argument is provided. Output lands in ./release/ with matching
# .sha256 files for both archives.

set -euo pipefail

APP_NAME="GitLabTodos"
DISPLAY_NAME="MergeTether"
SCHEME="GitLabTodos"
CONFIGURATION="Release"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [[ $# -ge 1 ]]; then
    VERSION="$1"
else
    VERSION="$(grep -E 'CFBundleShortVersionString' Project.swift \
        | head -1 \
        | sed -E 's/.*\.string\("([^"]+)"\).*/\1/')"
fi

if [[ -z "${VERSION}" ]]; then
    echo "error: could not determine version; pass it as the first argument" >&2
    exit 1
fi

echo "==> Building ${APP_NAME} ${VERSION}"

RELEASE_DIR="${REPO_ROOT}/release"
BUILD_DIR="${REPO_ROOT}/build"
DERIVED_DIR="${BUILD_DIR}/DerivedData"
STAGING_DIR="${BUILD_DIR}/staging"

rm -rf "${BUILD_DIR}"
mkdir -p "${RELEASE_DIR}" "${DERIVED_DIR}" "${STAGING_DIR}"

if ! command -v tuist >/dev/null 2>&1; then
    echo "error: tuist not on PATH — run 'brew install mise && mise install' first" >&2
    exit 1
fi

echo "==> Generating Xcode project"
tuist generate --no-open

echo "==> Building ${CONFIGURATION} .app"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED_DIR}" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    MARKETING_VERSION="${VERSION}" \
    clean build

BUILT_APP="${DERIVED_DIR}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
if [[ ! -d "${BUILT_APP}" ]]; then
    echo "error: built .app not found at ${BUILT_APP}" >&2
    exit 1
fi

STAGED_APP="${STAGING_DIR}/${APP_NAME}.app"
cp -R "${BUILT_APP}" "${STAGED_APP}"

echo "==> Packaging ZIP"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
ZIP_PATH="${RELEASE_DIR}/${ZIP_NAME}"
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${STAGED_APP}" "${ZIP_PATH}"

echo "==> Packaging DMG"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${RELEASE_DIR}/${DMG_NAME}"
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGED_APP}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

echo "==> Writing SHA256 checksums"
(
    cd "${RELEASE_DIR}"
    shasum -a 256 "${ZIP_NAME}" > "${ZIP_NAME}.sha256"
    shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
)

rm -rf "${BUILD_DIR}"

echo
echo "==> ${DISPLAY_NAME} ${VERSION}"
ls -lh "${RELEASE_DIR}/${APP_NAME}-${VERSION}".*
