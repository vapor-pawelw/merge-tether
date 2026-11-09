#!/usr/bin/env bash
# Regenerate, build and launch a development .app only after existing
# MergeTether instances and app-hosted tests have finished and been closed.

set -euo pipefail

SCHEME="${GITLABTODOS_SCHEME:-GitLabTodos}"
CONFIGURATION="${GITLABTODOS_CONFIGURATION:-Debug}"
APP_NAME="${GITLABTODOS_APP_NAME:-GitLabTodos}"
PROJECT="${GITLABTODOS_PROJECT:-GitLabTodos.xcodeproj}"

usage() {
  cat <<'USAGE'
Usage: scripts/rebuild-and-relaunch.sh [--help]

Generate the pinned Tuist project, build a development app and launch it.
Refuse while an existing MergeTether app or app-hosted test process is running;
finish active work/tests and quit the app before retrying. Nothing is killed.

This helper launches the build output; it does not replace an installed app.
For a custom installation, follow docs/building.md to preserve its bundle ID,
preferences, signing identity and installation path.

Optional environment: GITLABTODOS_SCHEME, GITLABTODOS_CONFIGURATION,
GITLABTODOS_APP_NAME, GITLABTODOS_PROJECT.
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

current_app_pids() {
  pgrep -u "$(id -u)" -x GitLabTodos || true
  if [[ "$APP_NAME" != GitLabTodos ]]; then
    pgrep -u "$(id -u)" -x "$APP_NAME" || true
  fi
}

require_no_running_app() {
  local processes pid executable
  processes="$(
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      executable="$(ps -p "$pid" -o comm= 2>/dev/null)" || continue
      printf '  PID %s: %s\n' "$pid" "$executable"
    done < <(current_app_pids)
  )"
  if [[ -n "$processes" ]]; then
    echo "MergeTether or an app-hosted test is already running:" >&2
    echo "$processes" >&2
    echo "Finish active work/tests, quit that app, then retry. No process was stopped." >&2
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
  case "${1:-}" in
    --help|-h) usage; return ;;
    "") ;;
    *) usage >&2; exit 2 ;;
  esac
  if [[ $# -gt 0 ]]; then
    usage >&2
    exit 2
  fi
  require_cmd xcodebuild
  require_cmd sed
  require_cmd open
  require_cmd pgrep
  require_cmd ps
  require_cmd id

  require_no_running_app

  local root build_dir app_path pids
  root="$(repo_root)"
  cd "$root"
  ensure_build_prerequisites "$root"

  build_dir="$(build_dir_from_xcodebuild)"
  if [[ -z "$build_dir" ]]; then
    echo "Failed to resolve CONFIGURATION_BUILD_DIR for scheme '$SCHEME'." >&2
    exit 1
  fi

  app_path="$build_dir/$APP_NAME.app"

  echo "Building $SCHEME ($CONFIGURATION)..."
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" build

  if [[ ! -d "$app_path" ]]; then
    echo "Built app not found at: $app_path" >&2
    exit 1
  fi

  require_no_running_app

  echo "Launching $app_path..."
  if ! open "$app_path"; then
    echo "Launch failed. Inspect the app bundle and Launch Services, then retry; no fallback instance was started." >&2
    exit 1
  fi

  sleep 1
  pids="$(current_app_pids)"
  if [[ -z "$pids" ]]; then
    echo "Launch failed: no running '$APP_NAME' process found." >&2
    exit 1
  fi

  echo "Running PID(s):"
  echo "$pids"
}

main "$@"
