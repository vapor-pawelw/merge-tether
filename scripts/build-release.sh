#!/usr/bin/env bash
# Prepare local release artifacts. This script never publishes a release or tag.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: scripts/build-release.sh [X.Y.Z] [options]
  --build-number N             Positive integer (default: Project.swift setting)
  --platform macos|ios|all     Separate platform artifacts (default: macos)
  --relay-config FILE         External origin-only JSON (required for iOS distribution)
  --signing-identity NAME|SHA  Developer ID Application identity for macOS
  --ios-signing-identity NAME|SHA  Apple Distribution identity for iOS
  --team-id ID                Distribution team for the selected platforms
  --notary-profile NAME       Existing notarytool Keychain profile for macOS
  --ios-export-options FILE   Manual distribution ExportOptions.plist for iOS
  --unsigned                 Inspection builds in release/unsigned; not distributable
  --help                     Show this help without building

Run through the repository-pinned toolchain: mise exec -- bash scripts/build-release.sh
The signed macOS path submits artifacts to Apple for notarization. Use it only when
that upload is authorized. --unsigned never submits or exports an installable IPA.
Signing identities and credentials must already exist; this script creates neither.
HELP
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"
VERSION="" BUILD_NUMBER="" PLATFORM="macos" UNSIGNED=0
SIGNING_IDENTITY="" IOS_SIGNING_IDENTITY="" TEAM_ID="" NOTARY_PROFILE="" IOS_EXPORT_OPTIONS=""
RELAY_CONFIG="${TUIST_MERGETETHER_RELAY_CONFIG_FILE:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --unsigned) UNSIGNED=1; shift ;;
        --build-number|--platform|--signing-identity|--ios-signing-identity|--team-id|--notary-profile|--ios-export-options|--relay-config)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "missing value for $1 (see --help)"
            case "$1" in
                --build-number) BUILD_NUMBER="$2" ;;
                --platform) PLATFORM="$2" ;;
                --signing-identity) SIGNING_IDENTITY="$2" ;;
                --ios-signing-identity) IOS_SIGNING_IDENTITY="$2" ;;
                --team-id) TEAM_ID="$2" ;;
                --notary-profile) NOTARY_PROFILE="$2" ;;
                --ios-export-options) IOS_EXPORT_OPTIONS="$2" ;;
                --relay-config) RELAY_CONFIG="$2" ;;
            esac
            shift 2 ;;
        -*) fail "unknown option $1 (see --help)" ;;
        *) [[ -z "$VERSION" ]] || fail "unexpected argument $1"; VERSION="$1"; shift ;;
    esac
done
[[ "$PLATFORM" == macos || "$PLATFORM" == ios || "$PLATFORM" == all ]] || fail "--platform must be macos, ios or all"
project_setting() { sed -nE 's/.*"'"$1"'": "([^"]+)".*/\1/p' Project.swift | head -n1; }
VERSION="${VERSION:-$(project_setting MARKETING_VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(project_setting CURRENT_PROJECT_VERSION)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be X.Y.Z"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "--build-number must be a positive integer"
MACOS=0 IOS=0
[[ "$PLATFORM" == ios ]] || MACOS=1
[[ "$PLATFORM" == macos ]] || IOS=1
for tool in tuist xcodebuild python3 ditto shasum; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing $tool; run mise install and use mise exec -- bash scripts/build-release.sh"
done
if [[ "$MACOS" -eq 1 ]]; then
    command -v hdiutil >/dev/null 2>&1 || fail "missing hdiutil; macOS packaging requires macOS"
fi

resolve_identity() {
    local requested="$1" prefix="$2"
    security find-identity -v -p codesigning | python3 -c '
import re, sys
requested, prefix = sys.argv[1:]
identities = re.findall(r"\b([A-Fa-f0-9]{40}) \"([^\"]+)\"", sys.stdin.read())
matches = [(fingerprint, name) for fingerprint, name in identities
           if (requested == name or requested.upper() == fingerprint.upper()) and name.startswith(prefix)]
if len(matches) != 1:
    sys.exit("error: select one available " + prefix + " identity with its exact name or SHA-1 fingerprint; Apple Development is for local builds")
print(matches[0][0])
' "$requested" "$prefix"
}
if [[ -n "$RELAY_CONFIG" ]]; then
    [[ -f "$RELAY_CONFIG" ]] || fail "--relay-config must name a readable external origin-only JSON file"
    RELAY_CONFIG="$(python3 - "$RELAY_CONFIG" "$REPO_ROOT" <<'PY'
import json, pathlib, sys, urllib.parse
try:
    path = pathlib.Path(sys.argv[1]).resolve(strict=True)
    root = pathlib.Path(sys.argv[2]).resolve()
    if path == root or root in path.parents:
        raise ValueError()
    with path.open() as source:
        config = json.load(source)
    if not isinstance(config, dict) or set(config) != {'origin'} or not isinstance(config['origin'], str):
        raise ValueError()
    raw = config['origin'].strip()
    parts = urllib.parse.urlsplit(raw)
    if (not raw or not raw.isascii() or any(c.isspace() or ord(c) < 32 for c in raw)
            or '%' in raw or '\\' in raw or '?' in raw or '#' in raw
            or parts.scheme.lower() != 'https' or not parts.hostname or parts.username is not None
            or parts.password is not None or parts.path not in ('', '/')
            or (parts.port is not None and not 1 <= parts.port <= 65535)):
        raise ValueError()
except (OSError, ValueError, TypeError):
    sys.exit('error: relay config must be outside the checkout and contain only an HTTPS origin without credentials, path, query or fragment; never include tokens or keys')
print(path)
PY
)"
fi
if [[ "$IOS" -eq 1 && "$UNSIGNED" -eq 0 && -z "$RELAY_CONFIG" ]]; then
    fail "iOS distribution requires --relay-config with your own relay origin; use --unsigned only for explicit inspection"
fi
if [[ "$UNSIGNED" -eq 0 ]]; then
    [[ -n "$TEAM_ID" ]] || fail "--team-id is required for distribution"
    for tool in security codesign xcrun; do command -v "$tool" >/dev/null 2>&1 || fail "missing $tool"; done
    if [[ "$MACOS" -eq 1 ]]; then
        [[ -n "$SIGNING_IDENTITY" ]] || fail "--signing-identity Developer ID Application is required; use --unsigned only for local inspection"
        [[ -n "$NOTARY_PROFILE" ]] || fail "--notary-profile is required; configure an existing notarytool Keychain profile"
        SIGNING_IDENTITY="$(resolve_identity "$SIGNING_IDENTITY" 'Developer ID Application: ')"
        command -v spctl >/dev/null 2>&1 || fail "missing spctl"
        if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
            fail "notarytool could not authenticate the supplied --notary-profile; configure it outside this script before building"
        fi
    fi
    if [[ "$IOS" -eq 1 ]]; then
        [[ -n "$IOS_SIGNING_IDENTITY" ]] || fail "--ios-signing-identity Apple Distribution is required for an installable iOS export"
        IOS_SIGNING_IDENTITY="$(resolve_identity "$IOS_SIGNING_IDENTITY" 'Apple Distribution: ')"
        [[ -f "$IOS_EXPORT_OPTIONS" ]] || fail "--ios-export-options must name an existing manual distribution ExportOptions.plist"
        IOS_EXPORT_OPTIONS="$(cd "$(dirname "$IOS_EXPORT_OPTIONS")" && pwd)/$(basename "$IOS_EXPORT_OPTIONS")"
        IOS_PROFILE="$(python3 - "$IOS_EXPORT_OPTIONS" "$TEAM_ID" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    options = plistlib.load(source)
if options.get('teamID') != sys.argv[2] or options.get('signingStyle') != 'manual':
    sys.exit('error: iOS export options must use the selected teamID and signingStyle=manual')
if options.get('method') not in ('app-store-connect', 'release-testing', 'enterprise'):
    sys.exit('error: choose an explicit iOS distribution method: app-store-connect, release-testing or enterprise')
profile = options.get('provisioningProfiles', {}).get('com.vaporpw.MergeTether.iOS')
if not isinstance(profile, str) or not profile.strip():
    sys.exit('error: iOS export options need a provisioningProfiles entry for com.vaporpw.MergeTether.iOS; install that distribution profile first')
print(profile)
PY
)"
    fi
elif [[ -n "$SIGNING_IDENTITY$IOS_SIGNING_IDENTITY$TEAM_ID$NOTARY_PROFILE$IOS_EXPORT_OPTIONS" ]]; then
    fail "--unsigned cannot be combined with distribution credentials or export options"
fi

RELEASE_DIR="${REPO_ROOT}/release"
[[ "$UNSIGNED" -eq 0 ]] || RELEASE_DIR="${RELEASE_DIR}/unsigned"
mkdir -p "$RELEASE_DIR"
# Every run owns only its scratch directory; keep other builds and prior artifacts intact.
SCRATCH="$(mktemp -d "${REPO_ROOT}/.release-build.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/artifacts"
ARTIFACTS=()
COMMON_SETTINGS=("MARKETING_VERSION=${VERSION}" "CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
echo "==> Generating project for ${VERSION} (${BUILD_NUMBER}), platform ${PLATFORM}"
TUIST_MERGETETHER_RELAY_CONFIG_FILE="$RELAY_CONFIG" tuist generate --no-open

validate_bundle() {
    python3 - "$1" "$VERSION" "$BUILD_NUMBER" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
expected = dict(zip(('CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleIdentifier'), sys.argv[2:]))
for key, value in expected.items():
    if info.get(key) != value:
        sys.exit('error: built bundle ' + key + ' does not match requested release metadata; refusing to package')
PY
}
verify_signature() {
    codesign --verify --deep --strict "$1" || fail "code signature verification failed"
    local details
    details="$(codesign --display --verbose=4 "$1" 2>&1)" || fail "could not inspect code signature"
    [[ "$details" == *"TeamIdentifier=${TEAM_ID}"* && "$details" == *"Authority=$2"* ]] || fail "bundle signature does not match distribution identity/team"
    if [[ "$2" == 'Developer ID Application: '* ]]; then
        [[ "$details" == *'(runtime)'* && "$details" == *'Timestamp='* ]] || fail "macOS distribution signature requires hardened runtime and secure timestamp"
    fi
}
notarize() {
    local submission="$SCRATCH/notary-result.json"
    if ! xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$submission"; then
        fail "notarization submission failed; inspect the submission in notarytool before retrying"
    fi
    python3 - "$submission" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    status = json.load(source).get('status')
if status != 'Accepted':
    sys.exit('error: notarization was not Accepted; inspect the submission with notarytool log')
PY
}
if [[ "$MACOS" -eq 1 ]]; then
    SIGNING_SETTINGS=(CODE_SIGN_IDENTITY= CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
    if [[ "$UNSIGNED" -eq 0 ]]; then
        SIGNING_SETTINGS=("CODE_SIGN_IDENTITY=${SIGNING_IDENTITY}" "DEVELOPMENT_TEAM=${TEAM_ID}" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp)
    fi
    xcodebuild -project GitLabTodos.xcodeproj -scheme GitLabTodos -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$SCRATCH/macOS" \
        "${COMMON_SETTINGS[@]}" "${SIGNING_SETTINGS[@]}" clean build
    APP="$SCRATCH/macOS/Build/Products/Release/GitLabTodos.app"
    validate_bundle "$APP/Contents/Info.plist" com.vaporpw.GitLabTodos
    if [[ "$UNSIGNED" -eq 0 ]]; then
        verify_signature "$APP" 'Developer ID Application: '
        ditto -c -k --keepParent "$APP" "$SCRATCH/notarization.zip"
        notarize "$SCRATCH/notarization.zip"
        xcrun stapler staple "$APP" || fail "app notarization ticket stapling failed"
        xcrun stapler validate "$APP" || fail "app notarization ticket validation failed"
        spctl --assess --type execute "$APP" || fail "Gatekeeper rejected the notarized app"
    fi
    ZIP_NAME="GitLabTodos-${VERSION}.zip" DMG_NAME="GitLabTodos-${VERSION}.dmg"
    ditto -c -k --keepParent "$APP" "$SCRATCH/artifacts/$ZIP_NAME"
    hdiutil create -volname MergeTether -srcfolder "$APP" -ov -format UDZO "$SCRATCH/artifacts/$DMG_NAME" >/dev/null
    if [[ "$UNSIGNED" -eq 0 ]]; then
        codesign --sign "$SIGNING_IDENTITY" --timestamp "$SCRATCH/artifacts/$DMG_NAME"
        codesign --verify --strict "$SCRATCH/artifacts/$DMG_NAME" || fail "DMG signature verification failed"
        notarize "$SCRATCH/artifacts/$DMG_NAME"
        xcrun stapler staple "$SCRATCH/artifacts/$DMG_NAME" || fail "DMG notarization ticket stapling failed"
        xcrun stapler validate "$SCRATCH/artifacts/$DMG_NAME" || fail "DMG notarization ticket validation failed"
        spctl --assess --type open --context context:primary-signature "$SCRATCH/artifacts/$DMG_NAME" || fail "Gatekeeper rejected the notarized DMG"
    fi
    ARTIFACTS+=("$ZIP_NAME" "$DMG_NAME")
fi
if [[ "$IOS" -eq 1 ]]; then
    if [[ "$UNSIGNED" -eq 1 ]]; then
        xcodebuild -project GitLabTodos.xcodeproj -scheme MergeTetheriOS -configuration Release \
            -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/iOS" \
            "${COMMON_SETTINGS[@]}" CODE_SIGN_IDENTITY= CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO clean build
        IOS_APP="$SCRATCH/iOS/Build/Products/Release-iphoneos/MergeTetheriOS.app"
        validate_bundle "$IOS_APP/Info.plist" com.vaporpw.MergeTether.iOS
        IOS_NAME="MergeTetheriOS-${VERSION}-unsigned-device.zip"
        ditto -c -k --keepParent "$IOS_APP" "$SCRATCH/artifacts/$IOS_NAME"
    else
        xcodebuild -project GitLabTodos.xcodeproj -scheme MergeTetheriOS -configuration Release \
            -destination 'generic/platform=iOS' -derivedDataPath "$SCRATCH/iOS" -archivePath "$SCRATCH/iOS.xcarchive" \
            "${COMMON_SETTINGS[@]}" "CODE_SIGN_IDENTITY=${IOS_SIGNING_IDENTITY}" "DEVELOPMENT_TEAM=${TEAM_ID}" \
            CODE_SIGN_STYLE=Manual "MERGETETHER_IOS_PROVISIONING_PROFILE=${IOS_PROFILE}" archive
        IOS_APP="$SCRATCH/iOS.xcarchive/Products/Applications/MergeTetheriOS.app"
        validate_bundle "$IOS_APP/Info.plist" com.vaporpw.MergeTether.iOS
        verify_signature "$IOS_APP" 'Apple Distribution: '
        xcodebuild -exportArchive -archivePath "$SCRATCH/iOS.xcarchive" -exportPath "$SCRATCH/export" -exportOptionsPlist "$IOS_EXPORT_OPTIONS"
        shopt -s nullglob
        IPAS=("$SCRATCH/export/"*.ipa)
        [[ ${#IPAS[@]} -eq 1 ]] || fail "expected exactly one exported IPA, found ${#IPAS[@]}"
        mkdir -p "$SCRATCH/export-check"
        ditto -x -k "${IPAS[0]}" "$SCRATCH/export-check"
        EXPORTED_APPS=("$SCRATCH/export-check/Payload/"*.app)
        [[ ${#EXPORTED_APPS[@]} -eq 1 ]] || fail "exported IPA must contain exactly one app"
        validate_bundle "${EXPORTED_APPS[0]}/Info.plist" com.vaporpw.MergeTether.iOS
        verify_signature "${EXPORTED_APPS[0]}" 'Apple Distribution: '
        IOS_NAME="MergeTetheriOS-${VERSION}.ipa"
        cp "${IPAS[0]}" "$SCRATCH/artifacts/$IOS_NAME"
    fi
    ARTIFACTS+=("$IOS_NAME")
fi
# Inventory is written only after every selected platform has passed its checks.
python3 - "$SCRATCH/artifacts" "$VERSION" "$BUILD_NUMBER" "$PLATFORM" "$UNSIGNED" "${ARTIFACTS[@]}" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
version, build, platform, unsigned = sys.argv[2:6]
names = sys.argv[6:]
expected_count = {'macos': 2, 'ios': 1, 'all': 3}[platform]
if len(names) != expected_count or len(set(names)) != expected_count:
    sys.exit('error: unexpected release artifact count')
artifacts = []
for name in names:
    path = root / name
    if not path.is_file() or path.stat().st_size == 0:
        sys.exit('error: missing or empty artifact ' + name)
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    digest = digest.hexdigest()
    path.with_name(name + '.sha256').write_text(digest + '  ' + name + '\n')
    artifacts.append({'name': name, 'sha256': digest, 'platform': 'ios' if name.startswith('MergeTetheriOS-') else 'macos'})
(root / 'release-manifest.json').write_text(json.dumps({
    'version': version, 'build': build, 'distributable': unsigned == '0',
    'artifacts': artifacts,
}, indent=2) + '\n')
PY
for name in "${ARTIFACTS[@]}"; do
    cp "$SCRATCH/artifacts/$name" "$SCRATCH/artifacts/$name.sha256" "$RELEASE_DIR/"
done
cp "$SCRATCH/artifacts/release-manifest.json" "$RELEASE_DIR/release-manifest.json"
echo "==> Prepared ${#ARTIFACTS[@]} artifacts for ${VERSION} (${BUILD_NUMBER}) in ${RELEASE_DIR}"
[[ "$UNSIGNED" -eq 0 ]] || echo 'Inspection only: unsigned artifacts are not distributable; the iOS device ZIP is not installable.'
