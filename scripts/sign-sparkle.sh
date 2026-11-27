#!/usr/bin/env bash
set -euo pipefail

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "$identity" ]] || exit 0
[[ "$identity" != - || "${MERGETETHER_MACOS_AD_HOC_RELEASE:-NO}" == YES ]] || exit 0

framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
version="$framework/Versions/Current"
flags=(--force --sign "$identity")
[[ "$identity" == - ]] || flags+=(--options runtime)
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
