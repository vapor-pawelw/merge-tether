#!/usr/bin/env bash
# Regenerate the Xcode project, build a Debug .app, kill any running
# instance of MergeTether and launch the freshly built one. Used during
# development to pick up code changes end-to-end.

set -euo pipefail

SCHEME="${GITLABTODOS_SCHEME:-GitLabTodos}"
CONFIGURATION="${GITLABTODOS_CONFIGURATION:-Debug}"
APP_NAME="${GITLABTODOS_APP_NAME:-GitLabTodos}"
PROJECT="${GITLABTODOS_PROJECT:-GitLabTodos.xcodeproj}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
}

build_dir_from_xcodebuild() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | sed -n 's/^[[:space:]]*CONFIGURATION_BUILD_DIR = //p' \
    | head -n1
}

refresh_project_with_tuist() {
  echo "Refreshing $PROJECT via Tuist..."
  if mise x -- tuist generate --no-open; then
    return
  fi

  echo "Tuist generate failed. Running tuist install and retrying..."
  mise x -- tuist install
  echo "Refreshing $PROJECT via Tuist (retry)..."
  mise x -- tuist generate --no-open
}

ensure_build_prerequisites() {
  local root="$1"

  if [[ -d "$root/$PROJECT" ]] && command -v mise >/dev/null 2>&1; then
    refresh_project_with_tuist
    return
  fi

  if ! command -v mise >/dev/null 2>&1; then
    if [[ ! -d "$root/$PROJECT" ]]; then
      echo "Missing $PROJECT and mise is not installed. Cannot generate project files." >&2
      exit 1
    fi
    return
  fi

  echo "Installing toolchain with mise..."
  mise install
  refresh_project_with_tuist

  if [[ ! -d "$root/$PROJECT" ]]; then
    echo "Still missing $PROJECT after Tuist generate." >&2
    exit 1
  fi
}

main() {
  require_cmd xcodebuild
  require_cmd sed
  require_cmd open
  require_cmd pgrep

  local root build_dir app_path binary_path pids
  root="$(repo_root)"
  cd "$root"
  ensure_build_prerequisites "$root"

  build_dir="$(build_dir_from_xcodebuild)"
  if [[ -z "$build_dir" ]]; then
    echo "Failed to resolve CONFIGURATION_BUILD_DIR for scheme '$SCHEME'." >&2
    exit 1
  fi

  app_path="$build_dir/$APP_NAME.app"
  binary_path="$app_path/Contents/MacOS/$APP_NAME"

  echo "Building $SCHEME ($CONFIGURATION)..."
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" build

  if [[ ! -d "$app_path" ]]; then
    echo "Built app not found at: $app_path" >&2
    exit 1
  fi

  echo "Killing running $APP_NAME instances..."
  killall "$APP_NAME" 2>/dev/null || true
  sleep 0.5

  echo "Launching $app_path..."
  if ! open -n "$app_path"; then
    echo "open failed, launching binary directly..."
    "$binary_path" >/tmp/gitlabtodos-relaunch.log 2>&1 &
  fi

  sleep 1
  pids="$(pgrep -x "$APP_NAME" || true)"
  if [[ -z "$pids" ]]; then
    echo "Launch failed: no running '$APP_NAME' process found." >&2
    exit 1
  fi

  echo "Running PID(s):"
  echo "$pids"
}

main "$@"
