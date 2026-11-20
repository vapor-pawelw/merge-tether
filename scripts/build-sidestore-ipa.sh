#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-sidestore-ipa.sh [--build-number NUMBER]

Build MergeTether Release for iPhoneOS and package it for SideStore to sign.
Outputs go to release/sidestore along with a SHA-256 checksum and manifest.
The default build number follows the highest existing local SideStore build.
Set the external origin-only relay config via .mise.local.toml or
TUIST_MERGETETHER_RELAY_CONFIG_FILE.
USAGE
}

fail() { echo "error: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

build=""
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --build-number)
    [[ $# == 2 && "$2" =~ ^[1-9][0-9]*$ ]] || fail "--build-number requires a positive integer"
    build="$2"
    ;;
  "") [[ $# == 0 ]] || fail "expected --build-number NUMBER" ;;
  *) usage >&2; exit 2 ;;
esac
for tool in mise xcodebuildmcp python3 codesign xcrun; do
  command -v "$tool" >/dev/null || fail "missing $tool"
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."
out="$PWD/release/sidestore"
mkdir -p "$out"
scratch="$(mktemp -d "$out/.build.XXXXXX")"
locked=0
cleanup() {
  local result=$? artifact
  trap - EXIT
  if [[ "$result" != 0 && -n "${ipa:-}" ]]; then
    for artifact in "$ipa" "$ipa.sha256" "$name.json"; do
      if [[ "$scratch/$artifact" -ef "$out/$artifact" ]]; then
        rm -f -- "$out/$artifact"
      fi
    done
  fi
  rm -rf -- "$scratch"
  [[ "$locked" == 0 ]] || rm -f -- "$lock"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p build
lock="$PWD/build/.local-build.lock"
shlock -f "$lock" -p "$$" || fail "another local build is in progress in this checkout"
locked=1

commit="$(git rev-parse HEAD)"
source_label="$(git rev-parse --short HEAD)"
dirty=false
if [[ -n "$(git status --porcelain)" ]]; then
  dirty=true
  source_label="$source_label-dirty"
fi
if [[ -z "$build" ]]; then
  build="$(python3 - "$out" <<'PY'
from pathlib import Path
import plistlib
import sys
import zipfile

latest = 0
for path in Path(sys.argv[1]).glob("*.ipa"):
    if not path.is_file():
        continue
    try:
        with zipfile.ZipFile(path) as archive:
            info = plistlib.loads(archive.read("Payload/MergeTetheriOS.app/Info.plist"))
        if info.get("CFBundleIdentifier") == "com.vaporpw.MergeTether.iOS":
            latest = max(latest, int(info["CFBundleVersion"]))
    except (zipfile.BadZipFile, KeyError, ValueError, plistlib.InvalidFileException):
        sys.exit(f"error: cannot read build number from {path.name}; use --build-number")
print(latest + 1)
PY
)"
fi

mise exec -- tuist generate --no-open
origin="$(plist Derived/InfoPlists/MergeTetheriOS-Info.plist MergeTetherRelayOrigin)"
mac_origin="$(plist Derived/InfoPlists/MergeTether-Info.plist MergeTetherRelayOrigin)"
[[ -n "$origin" && "$origin" == "$mac_origin" ]] ||
  fail "configure the same external origin-only relay for both apps before building the IPA"

echo "Building MergeTetheriOS (Release, build $build)..."
xcodebuildmcp device build --project-path MergeTether.xcodeproj --scheme MergeTetheriOS \
  --configuration Release --derived-data-path "$scratch/DerivedData" --prefer-xcodebuild \
  --extra-args CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "CURRENT_PROJECT_VERSION=$build" ARCHS=arm64

app="$scratch/DerivedData/Build/Products/Release-iphoneos/MergeTetheriOS.app"
bundle_id="com.vaporpw.MergeTether.iOS"
info="$app/Info.plist"
version="$(plist "$info" CFBundleShortVersionString)"
[[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "unexpected IPA version"
[[ "$(plist "$info" CFBundleIdentifier)" == "$bundle_id" &&
   "$(plist "$info" CFBundleVersion)" == "$build" &&
   "$(plist "$info" MergeTetherRelayOrigin)" == "$origin" ]] ||
  fail "built app has unexpected bundle identity, build number or relay origin"

name="MergeTether-$version-$build-$source_label-SideStore"
ipa="$name.ipa"
mkdir "$scratch/Payload"
# Static framework dependencies are linked into the executable. Explicitly fail
# if the project gains embedded code so signing can be updated inside-out.
if [[ -n "$(find "$app" -mindepth 1 \( -name '*.appex' -o -name '*.framework' -o -name '*.dylib' -o -name '*.app' \) -print -quit)" ]]; then
  fail "embedded code found. Update the packaging step to sign its bundles before the app"
fi
ditto --norsrc --noextattr "$app" "$scratch/Payload/MergeTetheriOS.app"
codesign --force --sign - "$scratch/Payload/MergeTetheriOS.app"
(
  cd "$scratch"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry "$ipa" Payload \
    -x '*/._*' '*/.DS_Store' '*/__MACOSX' '*/__MACOSX/*'
)
/usr/bin/unzip -tq "$scratch/$ipa"
/usr/bin/unzip -Z1 "$scratch/$ipa" | awk -F / '
  $0 != "Payload/" && $0 !~ /^Payload\/MergeTetheriOS[.]app\// { bad=1 }
  { for (i=1; i<=NF; i++) if ($i ~ /^[.]_/ || $i == ".DS_Store" || $i == "__MACOSX") bad=1 }
  END { exit bad }
' || fail "IPA contains unexpected paths or macOS metadata"

ditto -x -k "$scratch/$ipa" "$scratch/verify"
extracted="$scratch/verify/Payload/MergeTetheriOS.app"
cmp "$info" "$extracted/Info.plist"
[[ "$(plist "$extracted/Info.plist" CFBundleSupportedPlatforms:0)" == iPhoneOS ]] ||
  fail "IPA is not an iPhoneOS application"
executable="$extracted/$(plist "$info" CFBundleExecutable)"
[[ -x "$executable" ]] || fail "IPA lacks an executable binary"
[[ "$(xcrun lipo -archs "$executable")" == arm64 ]] || fail "IPA executable is not thin arm64"
[[ "$(xcrun vtool -show-build "$executable" | awk '$1 == "platform" { print $2 }')" == IOS ]] ||
  fail "IPA executable is not an iOS device binary"
codesign --verify --deep --strict "$extracted"

(
  cd "$scratch"
  shasum -a 256 "$ipa" > "$ipa.sha256"
  python3 - "$ipa" "$name.json" "$bundle_id" "$version" "$build" "$commit" "$dirty" <<'PY'
import json
from pathlib import Path
import sys

ipa, manifest, bundle, version, build, commit, dirty = sys.argv[1:]
sha = Path(ipa + ".sha256").read_text().split()[0]
Path(manifest).write_text(json.dumps({
    "artifact": ipa, "sha256": sha, "bundle_identifier": bundle, "version": version,
    "build": build, "commit": commit, "dirty": dirty == "true", "platform": "iPhoneOS",
    "signature": "ad hoc, verified after extracting IPA", "sidestore_installation": "not tested",
}, indent=2) + "\n", encoding="utf-8")
PY
)
for artifact in "$ipa.sha256" "$name.json" "$ipa"; do
  [[ ! -e "$out/$artifact" && ! -L "$out/$artifact" ]] || fail "output already exists: $out/$artifact"
  ln -h "$scratch/$artifact" "$out/$artifact" || fail "could not publish $out/$artifact"
done
echo "SideStore IPA: $out/$ipa"
