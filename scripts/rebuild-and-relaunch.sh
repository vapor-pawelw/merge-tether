#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/rebuild-and-relaunch.sh [--app PATH]

Build MergeTether for macOS, quit the running app (force if needed), then
replace and open the installation. Defaults to ~/Applications/MergeTether.app
or an existing installation in ~/Applications or /Applications.
An existing installation supplies the bundle ID and signing identity.

Optional environment: MERGETETHER_SCHEME, MERGETETHER_CONFIGURATION,
MERGETETHER_APP_NAME, MERGETETHER_PROJECT.
USAGE
}

fail() { echo "error: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }

release_bundle_id="com.vaporpw.MergeTether"
target=""
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --app) [[ $# == 2 && -n "$2" ]] || fail "--app requires a path"; target="$2" ;;
  "") [[ $# == 0 ]] || fail "expected --app PATH" ;;
  *) usage >&2; exit 2 ;;
esac
if [[ -z "$target" ]]; then
  target="$HOME/Applications/MergeTether.app"
  for candidate in "$target" /Applications/MergeTether.app; do
    if [[ -d "$candidate" ]]; then target="$candidate"; break; fi
  done
fi
[[ "$target" == /* ]] || target="$PWD/$target"
[[ "$target" == *.app && ! -L "$target" ]] || fail "select a local .app directory, not a symlink"
for tool in mise xcodebuildmcp swift codesign; do
  command -v "$tool" >/dev/null || fail "missing $tool"
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."
script_dir="$PWD/scripts"
scheme="${MERGETETHER_SCHEME:-MergeTether}"
configuration="${MERGETETHER_CONFIGURATION:-Debug}"
app_name="${MERGETETHER_APP_NAME:-MergeTether}"
project="${MERGETETHER_PROJECT:-MergeTether.xcodeproj}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/mergetether-macos.XXXXXX")"
stage=""
replacing=0
locked=0
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$result" != 0 && -n "$stage" ]]; then
    if [[ "$replacing" == 1 && ! -e "$stage/New.app" && -e "$target" ]] &&
        ! mv "$target" "$stage/Failed.app"; then
      echo "Could not move failed installation. Staged apps are at $stage" >&2
      stage=""
    elif [[ -d "$stage/Previous.app" ]] &&
        { [[ -e "$target" || -L "$target" ]] || ! mv "$stage/Previous.app" "$target"; }; then
      echo "Previous installation retained at $stage/Previous.app" >&2
      stage=""
    fi
  fi
  [[ -z "$stage" ]] || rm -rf -- "$stage"
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

bundle_id="$release_bundle_id"
identity="-"
team=""
requirement=""
old_origin=""
old_executable="$app_name"
if [[ -e "$target" ]]; then
  old_plist="$target/Contents/Info.plist"
  old_executable="$(plist "$old_plist" CFBundleExecutable)"
  [[ "$old_executable" == "$app_name" || "$(plist "$old_plist" CFBundleName)" == "$app_name" ]] ||
    fail "existing app at $target is not the selected MergeTether product"
  bundle_id="$(plist "$old_plist" CFBundleIdentifier)"
  old_origin="$(plist "$old_plist" MergeTetherRelayOrigin 2>/dev/null || true)"
  codesign --verify --strict "$target"
  codesign -d --extract-certificates="$scratch/leaf" "$target" 2>/dev/null
  if [[ -f "$scratch/leaf0" ]]; then
    identity="$(shasum -a 1 "$scratch/leaf0" | cut -d ' ' -f 1)"
    if ! security find-identity -v -p codesigning | awk -v sha="$identity" 'tolower($2) == sha { found=1 } END { exit !found }'; then
      fail "signing identity for $target is unavailable in Keychain"
    fi
    team="$(codesign -dv "$target" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    requirement="$(codesign -d -r- "$target" 2>&1 | sed -n '/^designated => /p')"
    [[ -n "$requirement" ]] || fail "could not read the installed signing requirement"
  fi
fi

mise exec -- tuist generate --no-open
generated_origin="$(plist "Derived/InfoPlists/$app_name-Info.plist" MergeTetherRelayOrigin)"
if [[ -n "$old_origin" && -z "$generated_origin" ]]; then
  fail "existing app uses a relay. Set the origin-only config in .mise.local.toml or TUIST_MERGETETHER_RELAY_CONFIG_FILE"
fi

echo "Building $scheme ($configuration)..."
xcodebuildmcp macos build --project-path "$project" --scheme "$scheme" \
  --configuration "$configuration" --derived-data-path "$scratch/DerivedData" --prefer-xcodebuild \
  --extra-args "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" "CODE_SIGN_IDENTITY=$identity" \
  "DEVELOPMENT_TEAM=$team" CODE_SIGN_STYLE=Manual

built="$scratch/DerivedData/Build/Products/$configuration/$app_name.app"
built_plist="$built/Contents/Info.plist"
[[ "$(plist "$built_plist" CFBundleIdentifier)" == "$bundle_id" &&
   "$(plist "$built_plist" MergeTetherRelayOrigin)" == "$generated_origin" ]] ||
  fail "built app has unexpected bundle identity or relay configuration"

mkdir -p "$(dirname "$target")"
stage="$(mktemp -d "$(dirname "$target")/.mergetether-relaunch.XXXXXX")"
ditto "$built" "$stage/New.app"
codesign --verify --deep --strict "$stage/New.app"
if [[ -n "$requirement" ]]; then
  new_requirement="$(codesign -d -r- "$stage/New.app" 2>&1 | sed -n '/^designated => /p')"
  [[ "$new_requirement" == "$requirement" ]] || fail "built app changed the installed signing requirement"
fi

swift "$script_dir/mergetether-app-lifecycle.swift" quit "$target" "$app_name" "$old_executable"
if [[ -e "$target" ]]; then mv "$target" "$stage/Previous.app"; fi
replacing=1
mv "$stage/New.app" "$target"
swift "$script_dir/mergetether-app-lifecycle.swift" launch "$target" "$app_name" "$old_executable"
echo "Running $target"
