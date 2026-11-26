#!/usr/bin/env bash
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

[[ $# == 2 ]] || fail "expected the iPhoneOS app path and output IPA path"
app="$1"
output="$2"
[[ -d "$app" && -f "$app/Info.plist" ]] || fail "missing iPhoneOS application bundle"
[[ ! -e "$output" && ! -L "$output" ]] || fail "output already exists: $output"

scratch="$(mktemp -d "$(dirname "$output")/.ipa-build.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
ipa=app.ipa
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
cmp "$app/Info.plist" "$extracted/Info.plist"
[[ "$(plist "$extracted/Info.plist" CFBundleSupportedPlatforms:0)" == iPhoneOS ]] ||
  fail "IPA is not an iPhoneOS application"
executable="$extracted/$(plist "$app/Info.plist" CFBundleExecutable)"
[[ -x "$executable" ]] || fail "IPA lacks an executable binary"
[[ "$(xcrun lipo -archs "$executable")" == arm64 ]] || fail "IPA executable is not thin arm64"
[[ "$(xcrun vtool -show-build "$executable" | awk '$1 == "platform" { print $2 }')" == IOS ]] ||
  fail "IPA executable is not an iOS device binary"
codesign --verify --deep --strict "$extracted" || fail "IPA signature verification failed"
ln -h "$scratch/$ipa" "$output"
