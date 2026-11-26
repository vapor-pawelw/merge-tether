#!/usr/bin/env bash
set -euo pipefail

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "$identity" && "$identity" != - ]] || exit 0

framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
version="$framework/Versions/Current"
flags=(--force --sign "$identity" --options runtime)
if [[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == 'Developer ID Application: '* ]]; then
    flags+=(--timestamp)
else
    flags+=(--timestamp=none)
fi

for helper in "$version/XPCServices/Installer.xpc" "$version/XPCServices/Downloader.xpc" \
    "$version/Autoupdate" "$version/Updater.app"; do
    codesign "${flags[@]}" --preserve-metadata=entitlements "$helper"
done
codesign "${flags[@]}" "$framework"
